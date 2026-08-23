import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'app.dart';
import 'providers/backup_provider.dart';
import 'providers/onboarding_provider.dart';
import 'services/coverage/coverage_service.dart';
import 'services/failed_photo_uris.dart';
import 'services/memory_pressure.dart';
import 'services/notification_service.dart';
import 'services/scheduler/workmanager_scheduler.dart';
import 'services/secure_storage_migration.dart';

/// Entry point for Trail.
///
/// `main` stays on the critical path only for what the router's
/// `redirect` rule must know synchronously on the very first frame: the
/// onboarding flag and the startup key state ("needs unlock" /
/// "key missing"). Both futures are started before either is awaited, so
/// they still overlap. Everything else — the WorkManager
/// dispatcher registration, the notification channels, the failed-photo
/// denylist — is deferred to a post-first-frame callback
/// ([_initDeferredServices]). Before 0.14.1 all five awaits ran serially
/// ahead of `runApp` and cost ~150–400 ms of time-to-first-frame
/// (docs/PERF_PLAN.md §3 #3).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Image cache: 1 000 entries / 120 MB (0.14.1, down from 5 000 /
  // 250 MB). Sized so the slideshow's 100-frame warm-up + lookahead and
  // a month of 320 px thumbnails still fit — see memory_pressure.dart
  // for the arithmetic — without making Trail the first app Android
  // evicts. On `onTrimMemory` the observer drops the image + tile
  // caches; both rebuild on demand.
  configureImageCache();
  WidgetsBinding.instance.addObserver(MemoryPressureObserver());
  // Map-detail catch-up on every foreground (Phase C,
  // docs/TIMELINE_IMPORT.md §3). The observer only ever calls into
  // CoverageService, which gates on the user's toggles, the network
  // label and its own 10-minute throttle before it does anything.
  WidgetsBinding.instance.addObserver(_coverageResume);
  // The two router gates, concurrently — still two awaits, no more
  // (gotcha 30). `computeStartupKeyState` folds the old
  // `computeNeedsUnlock` probe and the "key is gone entirely" probe into
  // one pass over the same two reads, so both providers below come from
  // a single value:
  //   - needsUnlock: auto-backup has put the encrypted DB + salt back in
  //     place, but the Keystore-bound secure storage is empty (Android
  //     wipes per-app Keystore aliases on uninstall) → /unlock.
  //   - keyMissing: a trail.db exists with neither key nor salt → the
  //     /recover screen, because minting a fresh key here would orphan
  //     the user's whole log.
  //   - notMigrated: the same, plus release A's secure-storage marker is
  //     absent → the /recover screen's "install 0.17.3 first" variant,
  //     because flutter_secure_storage 11 cannot read a store the 10.x
  //     rewrite never touched (it reads back empty, nothing is deleted).
  // Both beat letting providers hit their exceptions one by one.
  final onboardedFuture = OnboardingGate.isComplete();
  final keyStateFuture = computeStartupKeyState();
  final onboarded = await onboardedFuture;
  final keyState = await keyStateFuture;
  // Registered *before* `runApp` so it runs right after the first frame
  // is rasterised — ahead of any post-frame callback a screen registers
  // from its own `initState` (the lock screen's auto-unlock, for one).
  // Nothing below relies on that ordering, though: each deferred
  // service is idempotent and awaited by its own call sites.
  WidgetsBinding.instance.addPostFrameCallback((_) => _initDeferredServices());
  runApp(
    ProviderScope(
      overrides: [
        onboardingCompleteProvider.overrideWith((_) => onboarded),
        needsUnlockProvider
            .overrideWith((_) => keyState == StartupKeyState.needsUnlock),
        keyMissingProvider
            .overrideWith((_) => keyState == StartupKeyState.keyMissing),
        notMigratedProvider
            .overrideWith((_) => keyState == StartupKeyState.notMigrated),
      ],
      child: const TrailApp(),
    ),
  );
}

/// Bootstraps the services nothing on the first frame depends on.
///
///   - [WorkmanagerScheduler.initialize] registers the background
///     callback with the native plugin. Memoised; every enqueue/cancel
///     path awaits it, so the lock screen's opportunistic
///     `enqueuePeriodic` cannot race ahead of the registration.
///   - [NotificationService.initialize] creates the panic + "How is it?"
///     channels now so the first panic posts with no first-use latency.
///     Idempotent, and every `post*` call self-invokes it anyway.
///   - [FailedPhotoUris.preload] reads the persisted denylist.
///     `isFailed` is sync and treats an unloaded denylist as "nothing
///     failed"; `register` awaits the preload so an early failure merges
///     into — never clobbers — the persisted set.
///   - [CoverageResumeObserver.run] drains the pending map-detail queue
///     the background worker built up (Phase C). Reads the network
///     label, then no-ops unless the feature is on, a server is
///     configured, and the connection is one the user allowed.
///   - [SecureStorageMigration.verifyAndRewrite] re-writes every Trail
///     secret through the current ciphers and refreshes the marker the
///     startup gate requires. Still worth running on 11.x: it is the only
///     thing that keeps the marker in step with what is actually readable,
///     and it cannot throw out here — each key is tried in its own
///     try/catch and a failure only withholds the marker. Safe to run
///     alongside the DB open: it only reads and re-writes secure storage,
///     and writing an identical value back is a no-op for every consumer.
///   - [MapLibreMap.preWarm] builds the native renderer's shared
///     resources (maplibre_gl 0.27.0) before any map is mounted, so the
///     first `/map` visit doesn't pay for it. Fire-and-forget by design;
///     failing is a missed optimisation, not an error.
///
/// Each runs fire-and-forget under [_guarded]: a failure here must not
/// take down an app that has already painted.
void _initDeferredServices() {
  unawaited(_guarded('workmanager', WorkmanagerScheduler.initialize));
  unawaited(_guarded('map detail', _coverageResume.run));
  unawaited(_guarded('notifications', NotificationService.initialize));
  unawaited(_guarded('failed-photo denylist', FailedPhotoUris.preload));
  unawaited(_guarded(
    'secure storage migration',
    () => SecureStorageMigration.verifyAndRewrite(),
  ));
  unawaited(MapLibreMap.preWarm().catchError((Object e) {
    debugPrint('preWarm failed: $e');
  }));
}

/// One instance, used both as the resume observer and as the cold-start
/// post-frame call — sharing it means the service's throttle sees both.
final _coverageResume = CoverageResumeObserver();

Future<void> _guarded(String label, Future<void> Function() init) async {
  try {
    await init();
  } catch (e) {
    debugPrint('[main] deferred init "$label" failed: $e');
  }
}
