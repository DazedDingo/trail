import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/backup_provider.dart';
import 'providers/onboarding_provider.dart';
import 'screens/contacts_screen.dart';
import 'screens/home_screen.dart';
import 'screens/history_screen.dart';
import 'screens/passphrase_entry_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/onboarding/onboarding_flow.dart';
import 'theme/app_theme.dart';

/// Root widget.
///
/// Trail defaults to dark mode (user preference across all their apps) and
/// uses `ThemeMode.dark` explicitly rather than `system`. Every screen is
/// built against the dark palette; there is no light theme to fall back to.
class TrailApp extends ConsumerWidget {
  const TrailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    return MaterialApp.router(
      title: 'Trail',
      theme: trailDarkTheme,
      darkTheme: trailDarkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}

/// Router is a provider so the onboarding redirect rule can read the
/// onboarding-complete state synchronously. We watch
/// [onboardingCompleteProvider] via `refreshListenable` to rebuild the router
/// on state changes.
final _routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/lock',
    redirect: (context, state) {
      final onboarded = ref.read(onboardingCompleteProvider);
      final needsUnlock = ref.read(needsUnlockProvider);
      final loc = state.matchedLocation;
      // Onboarding is a hard gate. Until it completes, the user cannot reach
      // any real screen — including the biometric lock, which would pop a
      // system dialog before the user has consented to the flow.
      if (!onboarded && !loc.startsWith('/onboarding')) {
        return '/onboarding';
      }
      if (onboarded && loc.startsWith('/onboarding')) {
        // After onboarding, if the DB was restored from backup the user
        // needs to unlock it before anything else touches the DB.
        return needsUnlock ? '/unlock' : '/lock';
      }
      // Post-restore gate: if passphrase mode is active but no key is
      // stored, route every non-unlock screen to /unlock. Once the user
      // enters the passphrase, PassphraseEntryScreen flips
      // needsUnlockProvider and we fall through to /lock → /home.
      if (onboarded && needsUnlock && loc != '/unlock') {
        return '/unlock';
      }
      if (onboarded && !needsUnlock && loc == '/unlock') {
        return '/lock';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingFlow()),
      GoRoute(path: '/unlock', builder: (_, __) => const PassphraseEntryScreen()),
      GoRoute(path: '/lock', builder: (_, __) => const LockScreen()),
      GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/contacts', builder: (_, __) => const ContactsScreen()),
    ],
  );
});
