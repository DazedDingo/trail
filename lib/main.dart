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
/// We intentionally keep `main` thin: initialise the WorkManager dispatcher
/// (which registers the background callback with the native WorkManager
/// plugin), load the "onboarding complete" flag into the Riverpod store
/// synchronously so the router can read it in its redirect rule, then hand
/// off to [TrailApp].
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WorkmanagerScheduler.initialize();
  // Eagerly create the panic notification channel so the first panic
  // triggers a notification with no first-use latency.
  await NotificationService.initialize();
  // Load the persisted "this image already failed to load" denylist so
  // the slideshow + gallery can skip known-broken URLs synchronously
  // on first render instead of flashing the placeholder for a frame.
  await FailedPhotoUris.preload();
  final onboarded = await OnboardingGate.isComplete();
  // Detect the post-restore case: auto-backup has put the encrypted DB +
  // salt back in place, but the Keystore-bound secure storage is empty
  // (Android wipes per-app Keystore aliases on uninstall). In that case
  // we must route to /unlock so the user can re-enter their passphrase
  // rather than let providers hit PassphraseNeededException one by one.
  final needsUnlock = await computeNeedsUnlock();
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
