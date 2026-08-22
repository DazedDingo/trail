import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'providers/backup_provider.dart';
import 'providers/onboarding_provider.dart';
import 'services/failed_photo_uris.dart';
import 'services/notification_service.dart';
import 'services/scheduler/workmanager_scheduler.dart';

/// Entry point for Trail.
///
/// `main` stays on the critical path only for what the router's
/// `redirect` rule must know synchronously on the very first frame: the
/// onboarding flag and the post-restore "needs unlock" probe. They run
/// concurrently via [Future.wait]. Everything else — the WorkManager
/// dispatcher registration, the notification channels, the failed-photo
/// denylist — is deferred to a post-first-frame callback
/// ([_initDeferredServices]). Before 0.14.1 all five awaits ran serially
/// ahead of `runApp` and cost ~150–400 ms of time-to-first-frame
/// (docs/PERF_PLAN.md §3 #3).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // **Bigger image cache for slideshow scrubbing.** Flutter's defaults
  // are 1 000 entries / 100 MB, sized for a UI that loads handfuls of
  // images on screen at a time. Trail's slideshow can scrub through
  // hundreds of pings in a single session; with the default cache,
  // older frames get evicted during normal use and the user sees gray
  // re-loads when scrubbing backward. 250 MB / 5 000 entries fits an
  // entire month of 4h-cadence pings (~180 thumbnails at 320 px ≈
  // 30 MB) with headroom for re-visits. Low-RAM devices can still
  // hit OOM but this is a slideshow app, not a 50-image-deep nav stack
  // — the worst case is image cache spillover, not crash.
  PaintingBinding.instance.imageCache
    ..maximumSize = 5000
    ..maximumSizeBytes = 250 * 1024 * 1024;
  // The two router gates, concurrently. `computeNeedsUnlock` detects the
  // post-restore case: auto-backup has put the encrypted DB + salt back
  // in place, but the Keystore-bound secure storage is empty (Android
  // wipes per-app Keystore aliases on uninstall). In that case we must
  // route to /unlock so the user can re-enter their passphrase rather
  // than let providers hit PassphraseNeededException one by one.
  final gates = await Future.wait<bool>([
    OnboardingGate.isComplete(),
    computeNeedsUnlock(),
  ]);
  final onboarded = gates[0];
  final needsUnlock = gates[1];
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
        needsUnlockProvider.overrideWith((_) => needsUnlock),
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
///
/// Each runs fire-and-forget under [_guarded]: a failure here must not
/// take down an app that has already painted.
void _initDeferredServices() {
  unawaited(_guarded('workmanager', WorkmanagerScheduler.initialize));
  unawaited(_guarded('notifications', NotificationService.initialize));
  unawaited(_guarded('failed-photo denylist', FailedPhotoUris.preload));
}

Future<void> _guarded(String label, Future<void> Function() init) async {
  try {
    await init();
  } catch (e) {
    debugPrint('[main] deferred init "$label" failed: $e');
  }
}
