import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:geolocator/geolocator.dart';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../db/area_photo_dao.dart';
import '../../db/database.dart';
import '../../db/keystore_key.dart';
import '../../db/ping_dao.dart';
import '../../db/ping_photo_dao.dart';
import '../../models/area_photo.dart';
import '../../models/ping.dart';
import '../../models/ping_photo.dart';
import '../auto_photo_service.dart';
import '../cell_photo_picker.dart';
import '../coverage/coverage_service.dart';
import '../how_is_it_service.dart';
import '../location_service.dart';
import '../notification_service.dart';
import '../online_photo_service.dart';
import '../panic/panic_service.dart';
import '../photo_shuffle_prefs.dart';
import '../startup_gates.dart';
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

  /// SharedPreferences key for the cadence (in minutes) most recently
  /// registered with WorkManager. Written by [enqueuePeriodic] right after
  /// `registerPeriodicTask` succeeds, so every caller (UI cadence picker,
  /// `switchSchedulerMode`, boot, the periodic tick itself) records it for
  /// free. Read by the periodic tick via [lastEnqueuedMinutes] to decide
  /// whether re-registering this tick is even necessary
  /// ([SchedulerPolicy.shouldReenqueuePeriodic]).
  static const _lastEnqueuedMinutesKey = 'trail_scheduler_last_enqueued_min_v1';

  /// The cadence, in minutes, last successfully registered with
  /// WorkManager — or `null` if we've never recorded one (fresh install,
  /// cleared prefs, or upgrading from a version predating this marker).
  static Future<int?> lastEnqueuedMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastEnqueuedMinutesKey);
  }

  /// Registers the top-level [_callbackDispatcher] with the native
  /// plugin. Memoised per isolate: the first call does the channel
  /// round-trip, concurrent and later callers share that future, and a
  /// failure resets the memo so the next call retries. Every enqueue /
  /// cancel path awaits this, so no caller has to sequence it — `main()`
  /// kicks it off after the first frame, and the lock screen's
  /// `enqueuePeriodic` (which can run in that same post-frame phase)
  /// simply waits on the shared future instead of racing it.
  ///
  /// Safe in the background isolate as well: natively `initialize` only
  /// persists the callback handle (the same value every time), so the
  /// one extra call per worker spawn is a single cheap channel hop.
  static Future<void> initialize() => _initFuture ??= _initializeOnce();

  static Future<void>? _initFuture;

  static Future<void> _initializeOnce() async {
    try {
      await nativeInitialize();
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  /// The native registration call. Replaceable so tests can verify the
  /// memoisation + gating without a platform implementation.
  @visibleForTesting
  static Future<void> Function() nativeInitialize =
      () => Workmanager().initialize(_callbackDispatcher);

  /// Drops the memoised init so a test can start from a cold isolate.
  @visibleForTesting
  static void resetInitializationForTest() => _initFuture = null;

  /// Enqueue / replace the baseline periodic worker at the given
  /// [frequency]. When `null` the user's chosen cadence (default 4h)
  /// is read from [CadenceStore]; callers that already know the
  /// cadence (e.g. the battery-aware branch in [_handleScheduled])
  /// pass it explicitly.
  static Future<void> enqueuePeriodic({
    Duration? frequency,
  }) async {
    await initialize();
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastEnqueuedMinutesKey, effective.inMinutes);
  }

  /// Enqueue a single delayed retry after a no-fix.
  static Future<void> enqueueRetry({
    Duration delay = retryDelay,
  }) async {
    await initialize();
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
    await initialize();
    await Workmanager().registerOneOffTask(
      '${bootTaskName}_${DateTime.now().millisecondsSinceEpoch}',
      bootTaskName,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      tag: tagBoot,
    );
  }

  static Future<void> cancelAll() async {
    await initialize();
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

/// True when the last [runStartupGates] call (in `main()`, or the failure
/// screen's "Try again") failed and has not yet succeeded again — see the
/// doc on [startupBlockedKey]. Pure function of an already-loaded
/// [SharedPreferences] so it can be unit-tested without driving
/// `Workmanager().executeTask` (which wraps a closure the native plugin
/// invokes, and is not otherwise reachable from a test).
@visibleForTesting
bool shouldPauseWorker(SharedPreferences prefs) =>
    prefs.getBool(startupBlockedKey) ?? false;

/// Records the dispatcher's 'paused' outcome for [taskName] and returns
/// `true` (WorkManager success) WITHOUT touching secure storage or the
/// DB. Called at the very top of [_callbackDispatcher], ahead of the
/// `switch` — including for [PanicService.panicTaskName]: the
/// background continuous-panic tick (`_handlePanic`) has no DB-free
/// sub-path to preserve. Composing the SMS via
/// `PanicService.openPanicSms`/`autoSendSms` only ever happens in the UI
/// isolate, from `home_screen.dart`, after a fix has already been
/// written — the background tick itself must open the DB just to log the
/// panic row before it can post the receipt notification, so pausing it
/// entirely (rather than trying to salvage a partial run) is the safe
/// choice here.
@visibleForTesting
Future<bool> pauseWorkerForStartupFailure(String taskName) async {
  await WorkerRunLog.record(
    task: taskName,
    outcome: 'paused',
    note: 'startup failed on last launch — skipped to protect the '
        'encryption key',
  );
  return true;
}

/// Top-level entry point for every background task.
///
/// MUST be top-level (not a static method) because the plugin re-resolves it
/// by symbol name across isolate boundaries.
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    // Guard first, ahead of every handler (including panic — see
    // `pauseWorkerForStartupFailure`): a startup that could not even get
    // through `runStartupGates` means the Keystore may be misbehaving, and
    // every further plugin init here is one more chance to regenerate the
    // RSA key pair over a still-good log.
    final prefs = await SharedPreferences.getInstance();
    if (shouldPauseWorker(prefs)) {
      return await pauseWorkerForStartupFailure(taskName);
    }
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
    } on KeyMissingException {
      // No key in Trail's store AND none in the escrow — and since
      // 0.17.9 that means something, because both channels are registered
      // in this isolate too (`packages/trail_secure_store` is a real
      // `FlutterPlugin`, and `FlutterEngine(Context)` runs
      // `GeneratedPluginRegistrant` for the background engine
      // `workmanager_android`'s `BackgroundWorker` builds). Before that
      // the escrow handler lived in `MainActivity`, so this branch mostly
      // meant "wrong isolate" rather than "no key".
      //
      // Skip the tick rather than mint anything: `getOrCreate` refuses to
      // create a key while `trail.db` exists, and the recovery screen the
      // UI shows is the only place that can put this right.
      debugPrint('[scheduler] Skipping ping — DB key unavailable.');
      await WorkerRunLog.record(
        task: taskName,
        outcome: 'key_unavailable',
        note: 'key unavailable in Trail store and escrow',
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

/// [db] lets the boot path (which already opened its own handle for the
/// boot-marker row) pass it through instead of paying a second SQLCipher
/// key-derivation cost. Whoever opens the handle is responsible for
/// closing it — when [db] is supplied, this function leaves it open for
/// the caller.
Future<bool> _handleScheduled({Database? db}) async {
  // Open the DB first so a locked-backup install bails before spending
  // ~30s on GPS. `TrailDatabase.open` throws [PassphraseNeededException]
  // in that case, caught by the dispatcher. Skipped entirely when [db] is
  // already supplied.
  final closeWhenDone = db == null;
  final database = db ?? await TrailDatabase.open();
  try {
    final dao = PingDao(database);

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
    final insertedId = await dao.insert(snapshot);

    // "How is it?" prompt (#4). Opt-in via Settings; off on install.
    // Frequency picker rate-limits — `everyPing` keeps the v1 cadence,
    // `hourly`/`every4h`/`daily` enforce a min-elapsed gate against the
    // last-posted timestamp. Off short-circuits before any DAO work.
    // Real-fix only — no_fix rows aren't worth commenting on.
    if (snapshot.source != PingSource.noFix) {
      final hisService = HowIsItService();
      final frequency = await hisService.getFrequency();
      final lastPosted = await hisService.getLastPostedAt();
      if (shouldPostHowIsIt(
        frequency: frequency,
        lastPostedAt: lastPosted,
        now: DateTime.now().toUtc(),
      )) {
        // Rebuild a Ping with the assigned rowid so the notification
        // payload carries the right target for the reply handler.
        final stored =
            Ping.fromMap({...snapshot.toMap(), 'id': insertedId});
        await NotificationService.postHowIsItPrompt(stored);
        await hisService.setLastPostedAt(DateTime.now().toUtc());
      }
    }

    // Online auto-photos (#6). Default ON; user can opt out via
    // Settings → Map → Auto-fetch photos. Privacy: leaks lat/lon to
    // Wikimedia Commons. Best-effort — failures are swallowed because
    // photos are decorative; the ping row is already committed.
    //
    // The network/charging gate is evaluated AFTER `isEnabled()` so a user
    // who has the feature off never pays the extra `Battery().batteryState`
    // platform call. Metered connections only qualify while charging — no
    // reason to burn a user's mobile data *and* battery on decorative
    // photos in the same tick.
    if (snapshot.source != PingSource.noFix &&
        snapshot.lat != null &&
        snapshot.lon != null &&
        await AutoPhotoService().isEnabled()) {
      final isCharging = await _isCharging();
      if (SchedulerPolicy.shouldAutoFetchPhotos(
        networkState: snapshot.networkState,
        isCharging: isCharging,
      )) {
        await _autoFetchPhotos(
          database,
          pingId: insertedId,
          lat: snapshot.lat!,
          lon: snapshot.lon!,
        );
      } else {
        debugPrint('[scheduler] Skipping auto-photo fetch — '
            'network=${snapshot.networkState}, charging=$isCharging.');
      }
    }

    // Map detail (Phase C, docs/TIMELINE_IMPORT.md §3). Prefs-only
    // bookkeeping: if no installed archive renders this place at street
    // zoom, queue it for the next app open to fetch on Wi-Fi. No
    // network and no extra DB work happen here — the worker must stay
    // cheap, and the coverage server is the user's own box, which is
    // not reachable from a 4 h background tick on mobile data anyway.
    if (snapshot.source != PingSource.noFix &&
        snapshot.lat != null &&
        snapshot.lon != null) {
      await CoverageService.noteFixInWorker(snapshot.lat!, snapshot.lon!);
    }

    final userCadence = await CadenceStore.get();
    final effectiveCadence = SchedulerPolicy.nextCadence(
      snapshot.batteryPct,
      base: userCadence.value,
    );
    // Re-registering with WorkManager is a platform round-trip that briefly
    // cancels + re-arms the native job; only pay for it when the cadence
    // this tick actually differs from what's currently registered.
    final lastEnqueuedMinutes = await WorkmanagerScheduler.lastEnqueuedMinutes();
    if (SchedulerPolicy.shouldReenqueuePeriodic(
      effective: effectiveCadence,
      lastEnqueuedMinutes: lastEnqueuedMinutes,
    )) {
      await WorkmanagerScheduler.enqueuePeriodic(frequency: effectiveCadence);
    }

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
    if (closeWhenDone) await database.close();
  }
}

/// Single passive `Battery().batteryState` read, used only to gate the
/// auto-photo fetch (`SchedulerPolicy.shouldAutoFetchPhotos`). `.charging`
/// and `.full` both count as "charging" — `.full` means plugged in and
/// topped off, which is exactly as safe to spend metered data/battery on
/// as actively charging. Any platform failure (no battery API, channel
/// error) degrades to "not charging" — the safer default for the gate.
Future<bool> _isCharging() async {
  try {
    final state = await Battery().batteryState;
    return state == BatteryState.charging || state == BatteryState.full;
  } catch (_) {
    return false;
  }
}

/// Photos persisted per-ping. Five photos surfaces a slideshow without
/// dominating the gallery sheet. The cell pool is intentionally wider
/// so repeat visits get variety.
const int kPhotosPerPing = 5;

/// Wider pool fetched once per cell. ~20 hits is the sweet spot:
/// generous enough that a daily commuter sees fresh photos for weeks
/// before the rotation repeats, narrow enough that GeoSearch + the
/// imageinfo hop stay inside one HTTP round-trip and a few hundred ms.
const int kCellPoolSize = 20;

/// Best-effort online-photo fetch + write. Called from the background
/// dispatcher after a successful real-fix ping. Failures swallow into
/// no-op — photos are decorative; the ping row is already committed.
///
/// Cell-cache flow (0.13.3):
///   1. Quantize lat/lon to a ~110 m cell.
///   2. If the cell has a cached photo pool, pick a rotated slice
///      keyed on (pingId + shuffle salt) and write that slice as the
///      ping's photos. NO Wikimedia hit.
///   3. Otherwise, fetch a wider pool from Wikimedia, persist it in
///      `area_photos` for future pings in this cell, then pick the
///      same kind of rotated slice for the current ping.
Future<void> _autoFetchPhotos(
  Database db, {
  required int pingId,
  required double lat,
  required double lon,
}) async {
  try {
    final photoDao = PingPhotoDao(db);
    // Idempotency — if a previous dispatch already wrote photos for
    // this ping (rare, but possible on retry chains), don't double.
    if (await photoDao.onlineCountForPing(pingId) > 0) return;

    final cellLat = quantizeCellLat(lat);
    final cellLon = quantizeCellLon(lon);
    final areaDao = AreaPhotoDao(db);
    final salt = await PhotoShufflePrefs.getSalt();

    var pool = await areaDao.byCell(cellLat, cellLon);
    if (pool.isEmpty) {
      final fetched = await OnlinePhotoService().fetchNearby(
        lat: lat,
        lon: lon,
        limit: kCellPoolSize,
      );
      if (fetched.isEmpty) return;
      final discoveredAt = DateTime.now().toUtc();
      final toCache = <AreaPhoto>[];
      for (final f in fetched) {
        toCache.add(AreaPhoto(
          cellLat: cellLat,
          cellLon: cellLon,
          uri: f.uri,
          thumbUri: f.thumbUri,
          attribution: f.attribution,
          license: f.license,
          discoveredAt: discoveredAt,
        ));
      }
      await areaDao.insertForCell(
        cellLat: cellLat,
        cellLon: cellLon,
        photos: toCache,
      );
      pool = await areaDao.byCell(cellLat, cellLon);
      if (pool.isEmpty) return; // a peer writer wiped + raced — bail
    }

    final picks = pickRotatedPhotos(
      allCellPhotos: pool,
      pingId: pingId,
      k: kPhotosPerPing,
      salt: salt,
    );
    if (picks.isEmpty) return;
    final now = DateTime.now().toUtc();
    final rows = <PingPhoto>[];
    for (var i = 0; i < picks.length; i++) {
      final p = picks[i];
      rows.add(PingPhoto(
        pingId: pingId,
        uri: p.uri,
        source: PingPhotoSource.wikimedia,
        attribution: p.attribution,
        license: p.license,
        thumbUri: p.thumbUri,
        fetchedAt: now,
        ordinal: i,
      ));
    }
    await photoDao.insertAll(rows);
  } catch (_) {
    // Swallow — auto-photos are a nice-to-have, not part of the
    // load-bearing ping pipeline. WorkerRunLog captures the ping
    // outcome; photo failures don't deserve a separate marker.
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
    // And immediately attempt a fresh ping without waiting for the 4h
    // window — pass this same handle through so the tick doesn't pay a
    // second SQLCipher key-derivation cost (one DB open per boot tick).
    return await _handleScheduled(db: db);
  } finally {
    await db.close();
  }
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
