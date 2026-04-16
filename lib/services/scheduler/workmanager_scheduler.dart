import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../db/database.dart';
import '../../db/ping_dao.dart';
import '../../models/ping.dart';
import '../location_service.dart';
import 'scheduler_policy.dart';

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
    await Workmanager().initialize(
      _callbackDispatcher,
      isInDebugMode: false,
    );
  }

  /// Enqueue / replace the baseline 4h periodic worker.
  static Future<void> enqueuePeriodic({
    Duration frequency = defaultCadence,
  }) async {
    await Workmanager().registerPeriodicTask(
      periodicTaskName,
      periodicTaskName,
      frequency: frequency,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(
        // ignore: constant_identifier_names — workmanager enum uses snake_case
        networkType: NetworkType.not_required,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
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
        default:
          return true;
      }
    } catch (_) {
      // Never throw out of the worker — WorkManager will mark failed and
      // apply backoff, which we don't want for a transient bug. Swallow and
      // let the next scheduled window pick up.
      return true;
    }
  });
}

Future<bool> _handleScheduled() async {
  final location = LocationService();
  // Grab battery first — we need it even if we skip the fix entirely.
  final snapshot = await location.getScheduledPing();
  final db = await TrailDatabase.open();
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
      return true;
    }
    await dao.insert(snapshot);

    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: SchedulerPolicy.nextCadence(snapshot.batteryPct),
    );

    if (SchedulerPolicy.shouldRetry(snapshot)) {
      await WorkmanagerScheduler.enqueueRetry();
    }
    return true;
  } finally {
    await db.close();
  }
}

Future<bool> _handleRetry() async {
  final location = LocationService();
  final ping = await location.getScheduledPing();
  final db = await TrailDatabase.open();
  try {
    await PingDao(db).insert(ping);
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
  } finally {
    await db.close();
  }
  // And immediately attempt a fresh ping without waiting for the 4h window.
  return _handleScheduled();
}
