import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'package:geolocator/geolocator.dart';

import '../../db/database.dart';
import '../../db/ping_dao.dart';
import '../../models/ping.dart';
import '../location_service.dart';
import '../notification_service.dart';
import '../panic/panic_service.dart';
import 'scheduler_policy.dart';
import 'worker_run_log.dart';

/// WorkManager scheduler for the 4h scheduled-ping cadence.
///
/// Key invariants (from PLAN.md "Hard rules"):
/// - No persistent foreground service for scheduled pings.
/// - Low-battery policy: <20% drop to 8h cadence, <5% skip entirely.
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
  static const lowBatteryCadence = SchedulerPolicy.lowBatteryCadence;
  static const retryDelay = SchedulerPolicy.retryDelay;

  /// Registers the top-level [_callbackDispatcher] with the native plugin.
  /// Safe to call on every app launch — the plugin de-dupes.
  static Future<void> initialize() async {
    await Workmanager().initialize(_callbackDispatcher);
  }

  /// Enqueue / replace the baseline 4h periodic worker.
  static Future<void> enqueuePeriodic({
    Duration frequency = defaultCadence,
  }) async {
    await Workmanager().registerPeriodicTask(
      periodicTaskName,
      periodicTaskName,
      frequency: frequency,
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
  final location = LocationService();
  // Grab battery first — we need it even if we skip the fix entirely.
  final snapshot = await location.getScheduledPing();
  try {
    final dao = PingDao(db);
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

    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: SchedulerPolicy.nextCadence(snapshot.batteryPct),
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
