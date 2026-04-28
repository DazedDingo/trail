import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'package:geolocator/geolocator.dart';

import '../../db/database.dart';
import '../../db/ping_dao.dart';
import '../../models/ping.dart';
import '../location_service.dart';
import '../notification_service.dart';
import '../panic/panic_service.dart';
import 'scheduler_mode.dart';
import 'scheduler_policy.dart';
import 'worker_run_log.dart';

/// WorkManager scheduler for the user-configured scheduled-ping cadence
/// (default 4h; see [PingCadence]).
///
/// Key invariants (from PLAN.md "Hard rules"):
/// - No persistent foreground service for scheduled pings.
/// - Low-battery policy: <20% doubles the user's cadence, <5% skips
///   entirely.
/// - On no-fix, re-enqueue a one-shot 5-minute retry.
/// - Always write a row per attempt — no silent gaps.
///
/// Isolate model: the background callback runs in a freshly-spawned Dart
/// isolate with no plugin registrations beyond those WorkManager auto-wires.
/// We explicitly call `WidgetsFlutterBinding.ensureInitialized` there and
/// open our own DB handle — we cannot share the UI isolate's handle.
class WorkmanagerScheduler {
  static const periodicTaskName = 'trail_scheduled_ping';
  static const retryTaskName = 'trail_retry_ping';
  static const bootTaskName = 'trail_boot_ping';
  static const tagScheduled = 'trail:scheduled';
  static const tagRetry = 'trail:retry';
  static const tagBoot = 'trail:boot';

  // Cadence/retry thresholds live in SchedulerPolicy so they can be unit-
  // tested without workmanager. Aliased here for public call-sites.
  static const defaultCadence = SchedulerPolicy.defaultCadence;
  static const retryDelay = SchedulerPolicy.retryDelay;

  /// Registers the top-level [_callbackDispatcher] with the native plugin.
  /// Safe to call on every app launch — the plugin de-dupes.
  static Future<void> initialize() async {
    await Workmanager().initialize(_callbackDispatcher);
  }

  /// Enqueue / replace the baseline periodic worker at the given
  /// [frequency]. When `null` the user's chosen cadence (default 4h)
  /// is read from [CadenceStore]; callers that already know the
  /// cadence (e.g. the battery-aware branch in [_handleScheduled])
  /// pass it explicitly.
  static Future<void> enqueuePeriodic({
    Duration? frequency,
  }) async {
    final effective = frequency ?? (await CadenceStore.get()).value;
    await Workmanager().registerPeriodicTask(
      periodicTaskName,
      periodicTaskName,
      frequency: effective,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        // Policy invariants live in SchedulerPolicy so they are test-
        // guarded — this config is the single biggest battery lever.
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: SchedulerPolicy.requiresBatteryNotLow,
        requiresCharging: SchedulerPolicy.requiresCharging,
        requiresDeviceIdle: SchedulerPolicy.requiresDeviceIdle,
        requiresStorageNotLow: SchedulerPolicy.requiresStorageNotLow,
      ),
      tag: tagScheduled,
    );
  }

  /// Enqueue a single delayed retry after a no-fix.
  static Future<void> enqueueRetry({
    Duration delay = retryDelay,
  }) async {
    await Workmanager().registerOneOffTask(
      '${retryTaskName}_${DateTime.now().millisecondsSinceEpoch}',
      retryTaskName,
      initialDelay: delay,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      tag: tagRetry,
    );
  }

  /// Enqueue a one-shot boot-time ping. Called from the native BootReceiver
  /// via its own worker path (see `BootReceiver.kt`).
  static Future<void> enqueueBoot() async {
    await Workmanager().registerOneOffTask(
      '${bootTaskName}_${DateTime.now().millisecondsSinceEpoch}',
      bootTaskName,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      tag: tagBoot,
    );
  }

  static Future<void> cancelAll() async {
    await Workmanager().cancelAll();
  }

  /// UI-isolate synchronous kick of the scheduled handler. Writes one row
  /// using the same code path the 4h worker does — a manual diagnostic for
  /// "is the pipeline broken or is the OS just throttling my worker?"
  ///
  /// Uses the UI isolate's shared DB handle (never open a second SQLCipher
  /// connection here — that path races first-install key derivation, see
  /// the 0.1.3 bug). Returns the row that landed, or `null` if low-battery
  /// policy skipped the fix.
  static Future<Ping?> runNow() async {
    final location = LocationService();
    final snapshot = await location.getScheduledPing();
    final db = await TrailDatabase.shared();
    final dao = PingDao(db);
    if (SchedulerPolicy.shouldSkipForLowBattery(snapshot.batteryPct)) {
      final skip = Ping(
        timestampUtc: DateTime.now().toUtc(),
        batteryPct: snapshot.batteryPct,
        networkState: snapshot.networkState,
        source: PingSource.noFix,
        note: SchedulerPolicy.skipNote,
      );
      await dao.insert(skip);
      return skip;
    }
    await dao.insert(snapshot);
    return snapshot;
  }
}

/// Top-level entry point for every background task.
///
/// MUST be top-level (not a static method) because the plugin re-resolves it
/// by symbol name across isolate boundaries.
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      switch (taskName) {
        case WorkmanagerScheduler.periodicTaskName:
          return await _handleScheduled();
        case WorkmanagerScheduler.retryTaskName:
          return await _handleRetry();
        case WorkmanagerScheduler.bootTaskName:
          return await _handleBoot();
        case PanicService.panicTaskName:
          return await _handlePanic();
        default:
          return true;
      }
    } on PassphraseNeededException {
      // Post-restore case: DB is locked pending the user's passphrase.
      // Can't write a marker row (DB is the thing we can't open), so we
      // just return success and let the next scheduled window try again.
      // The UI gate will have routed the user to /unlock by now anyway.
      debugPrint('[scheduler] Skipping ping — awaiting backup passphrase.');
      // Dispatcher-level log so the diagnostics screen shows the skip
      // even though no ping row landed.
      await WorkerRunLog.record(
        task: taskName,
        outcome: 'awaiting_passphrase',
      );
      return true;
    } catch (e) {
      // Never throw out of the worker — WorkManager will mark failed and
      // apply backoff, which we don't want for a transient bug. Swallow and
      // let the next scheduled window pick up.
      await WorkerRunLog.record(
        task: taskName,
        outcome: 'error',
        note: '$e',
      );
      return true;
    }
  });
}

Future<bool> _handleScheduled() async {
  // Open the DB first so a locked-backup install bails before spending
  // ~30s on GPS. `TrailDatabase.open` throws [PassphraseNeededException]
  // in that case, caught by the dispatcher.
  final db = await TrailDatabase.open();
  try {
    final dao = PingDao(db);

    // Motion-aware short-circuit. When the user has it on AND the last
    // two real fixes are < 50 m apart AND the latest is < 2 h old we
    // log a no_fix row with note "motion-aware skip" and *don't* warm
    // up GPS — that's the most expensive part of every periodic tick.
    // Falls through to the normal fix path after 2 h of consecutive
    // skips so slow drift can't go undetected forever.
    if (await MotionAwareStore.isEnabled()) {
      final motionSkip = await _maybeMotionAwareSkip(dao);
      if (motionSkip != null) {
        await dao.insert(motionSkip);
        await WorkerRunLog.record(
          task: WorkmanagerScheduler.periodicTaskName,
          outcome: 'motion_aware_skip',
          note: motionSkip.note,
        );
        return true;
      }
    }

    final location = LocationService();
    // Grab battery first — we need it even if we skip the fix entirely.
    final snapshot = await location.getScheduledPing();
    if (SchedulerPolicy.shouldSkipForLowBattery(snapshot.batteryPct)) {
      await dao.insert(Ping(
        timestampUtc: DateTime.now().toUtc(),
        batteryPct: snapshot.batteryPct,
        networkState: snapshot.networkState,
        source: PingSource.noFix,
        note: SchedulerPolicy.skipNote,
      ));
      await WorkerRunLog.record(
        task: WorkmanagerScheduler.periodicTaskName,
        outcome: 'low_battery_skip',
        note: 'batt=${snapshot.batteryPct}%',
      );
      return true;
    }
    await dao.insert(snapshot);

    final userCadence = await CadenceStore.get();
    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: SchedulerPolicy.nextCadence(
        snapshot.batteryPct,
        base: userCadence.value,
      ),
    );

    if (SchedulerPolicy.shouldRetry(snapshot)) {
      await WorkmanagerScheduler.enqueueRetry();
    }
    await WorkerRunLog.record(
      task: WorkmanagerScheduler.periodicTaskName,
      outcome: snapshot.source == PingSource.noFix ? 'no_fix' : 'ok',
      note: snapshot.source == PingSource.noFix ? snapshot.note : null,
    );
    return true;
  } finally {
    await db.close();
  }
}

Future<bool> _handleRetry() async {
  final db = await TrailDatabase.open();
  final location = LocationService();
  final ping = await location.getScheduledPing();
  try {
    await PingDao(db).insert(ping);
    await WorkerRunLog.record(
      task: WorkmanagerScheduler.retryTaskName,
      outcome: ping.source == PingSource.noFix ? 'no_fix' : 'ok',
      note: ping.source == PingSource.noFix ? ping.note : null,
    );
    return true;
  } finally {
    await db.close();
  }
}

/// Background-isolate panic handler. Invoked from:
///   - `PanicForegroundService.kt` timer ticks (continuous mode)
///   - Native quick-settings tile / home-screen widget taps (Phase 3)
///
/// Uses `LocationAccuracy.best` and a short 45s budget — same rationale
/// as the UI-isolate [PanicService.triggerOnce]. Writes a `panic` row and
/// posts the visible panic-receipt notification so the user sees the
/// confirmation even though the UI isolate isn't running.
Future<bool> _handlePanic() async {
  final db = await TrailDatabase.open();
  try {
    final location = LocationService();
    final ping = await location.getScheduledPing(
      source: PingSource.panic,
      accuracy: LocationAccuracy.best,
      timeout: const Duration(seconds: 45),
    );
    await PingDao(db).insert(ping);
    await NotificationService.postPanicReceipt(ping);
    await WorkerRunLog.record(
      task: PanicService.panicTaskName,
      outcome: ping.source == PingSource.noFix ? 'no_fix' : 'ok',
      note: ping.source == PingSource.noFix ? ping.note : null,
    );
    return true;
  } finally {
    await db.close();
  }
}

Future<bool> _handleBoot() async {
  final db = await TrailDatabase.open();
  try {
    final dao = PingDao(db);
    // Always log the boot marker first so the gap is visible in history even
    // if the subsequent fix attempt fails.
    await dao.insert(Ping(
      timestampUtc: DateTime.now().toUtc(),
      source: PingSource.boot,
      note: 'device_boot',
    ));
    await WorkerRunLog.record(
      task: WorkmanagerScheduler.bootTaskName,
      outcome: 'ok',
      note: 'boot marker written',
    );
  } finally {
    await db.close();
  }
  // And immediately attempt a fresh ping without waiting for the 4h window.
  return _handleScheduled();
}

/// Decides whether the periodic worker should short-circuit GPS for
/// this tick because the user is plausibly stationary. Returns a
/// pre-built `no_fix` Ping to log when skipping; null when the worker
/// should proceed to a real fix.
///
/// Heuristic: the two most-recent pings have GPS fixes within
/// `MotionAwareStore.stationaryThresholdMeters` of each other AND the
/// newest is younger than `MotionAwareStore.confirmAfter`. A fix
/// outside that window forces a real ping so a slow drift can't go
/// undetected.
Future<Ping?> _maybeMotionAwareSkip(PingDao dao) async {
  final recent = await dao.recent(limit: 2);
  if (recent.length < 2) return null;
  final newest = recent[0]; // recent() returns newest-first
  final older = recent[1];
  if (newest.lat == null ||
      newest.lon == null ||
      older.lat == null ||
      older.lon == null) {
    return null;
  }
  final dist = _greatCircleMeters(
    newest.lat!,
    newest.lon!,
    older.lat!,
    older.lon!,
  );
  if (dist >= MotionAwareStore.stationaryThresholdMeters) return null;

  final age = DateTime.now().toUtc().difference(newest.timestampUtc);
  if (age >= MotionAwareStore.confirmAfter) return null;

  return Ping(
    timestampUtc: DateTime.now().toUtc(),
    source: PingSource.noFix,
    note: 'motion-aware skip '
        '(${dist.toStringAsFixed(0)}m, '
        '${age.inMinutes}m old)',
  );
}

double _greatCircleMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0; // earth radius (m)
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _toRad(double deg) => deg * (math.pi / 180);
