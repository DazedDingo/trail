import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/backup_provider.dart';
import 'providers/onboarding_provider.dart';
import 'screens/archive_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/home_location_screen.dart';
import 'screens/home_screen.dart';
import 'screens/history_screen.dart';
import 'screens/import_timeline_screen.dart';
import 'screens/key_recovery_screen.dart';
import 'screens/map_screen.dart';
import 'screens/passphrase_entry_screen.dart';
import 'screens/places_screen.dart';
import 'screens/regions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/trips_screen.dart';
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

/// The router's whole `redirect` rule, as a pure function.
///
/// Every hard gate Trail has lives here: onboarding, the post-restore
/// passphrase prompt, and the "key is gone entirely" recovery screen.
/// Pure + top-level so the truth table can be asserted without mounting
/// a router or a `ProviderScope` (CLAUDE.md gotcha 18) — see
/// `test/startup_redirect_test.dart`. The provider below is the only
/// caller; it supplies the three flags from Riverpod and
/// [location] from `state.matchedLocation`.
///
/// Note there is no `locked` input: the biometric lock is a *screen*
/// (`/lock`, the router's `initialLocation`), not a gate — `LockScreen`
/// decides for itself when to let the user through, so `redirect` never
/// reasons about it.
///
/// Returns the path to bounce to, or `null` to allow [location].
String? startupRedirect({
  required String location,
  required bool onboarded,
  required bool needsUnlock,
  required bool keyMissing,
}) {
  final loc = location;
  // Onboarding is a hard gate. Until it completes, the user cannot reach
  // any real screen — including the biometric lock, which would pop a
  // system dialog before the user has consented to the flow.
  if (!onboarded && !loc.startsWith('/onboarding')) {
    return '/onboarding';
  }
  if (onboarded && loc.startsWith('/onboarding')) {
    // After onboarding, if the DB was restored from backup the user
    // needs to unlock it before anything else touches the DB.
    if (keyMissing) return '/recover';
    return needsUnlock ? '/unlock' : '/lock';
  }
  // Key-missing gate: an encrypted trail.db exists but its key is
  // gone and no salt can re-derive it. Hard-gate on /recover exactly
  // like /unlock — every provider that touches the DB would otherwise
  // throw KeyMissingException one by one. Checked BEFORE the unlock
  // gate: the two are mutually exclusive by construction
  // (`computeStartupKeyState`), and if they ever both went true the
  // recovery screen is the one that can reach /unlock, not vice versa.
  if (onboarded && keyMissing && loc != '/recover') {
    return '/recover';
  }
  if (onboarded && !keyMissing && loc == '/recover') {
    return '/lock';
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
}

/// Router is a provider so the onboarding redirect rule can read the
/// onboarding-complete state synchronously. We watch
/// [onboardingCompleteProvider] via `refreshListenable` to rebuild the router
/// on state changes.
final _routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/lock',
    redirect: (context, state) => startupRedirect(
      location: state.matchedLocation,
      onboarded: ref.read(onboardingCompleteProvider),
      needsUnlock: ref.read(needsUnlockProvider),
      keyMissing: ref.read(keyMissingProvider),
    ),
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingFlow()),
      GoRoute(path: '/unlock', builder: (_, __) => const PassphraseEntryScreen()),
      GoRoute(path: '/recover', builder: (_, __) => const KeyRecoveryScreen()),
      GoRoute(path: '/lock', builder: (_, __) => const LockScreen()),
      GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/contacts', builder: (_, __) => const ContactsScreen()),
      GoRoute(
        path: '/map',
        builder: (_, state) =>
            MapScreen(initialFilter: state.extra as DateTimeRange?),
      ),
      GoRoute(path: '/stats', builder: (_, __) => const StatsScreen()),
      GoRoute(path: '/trips', builder: (_, __) => const TripsScreen()),
      GoRoute(path: '/places', builder: (_, __) => const PlacesScreen()),
      GoRoute(path: '/regions', builder: (_, __) => const RegionsScreen()),
      GoRoute(path: '/archive', builder: (_, __) => const ArchiveScreen()),
      GoRoute(
        path: '/import-timeline',
        builder: (_, __) => const ImportTimelineScreen(),
      ),
      GoRoute(
        path: '/diagnostics',
        builder: (_, __) => const DiagnosticsScreen(),
      ),
      GoRoute(
        path: '/home-location',
        builder: (_, __) => const HomeLocationScreen(),
      ),
    ],
  );
});
