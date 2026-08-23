import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:trail/providers/backup_provider.dart';
import 'package:trail/screens/key_recovery_screen.dart';

/// UX-level coverage for the `/recover` gate (the data-safety net for the
/// `flutter_secure_storage` 9 → 10 → 11 migration). The screen is the
/// only place in the app that is allowed to decide what happens to an
/// encrypted log whose key has vanished, so every branch is pinned:
/// which buttons exist, that "Start a new log" is confirm-gated and calls
/// the set-aside seam, and that "Try again" re-probes and releases the
/// router gates on success.
Future<void> _pump(
  WidgetTester tester, {
  bool saltPresent = false,
  bool notMigrated = false,
  StartupKeyState probeResult = StartupKeyState.keyMissing,
  Future<String?> Function()? setAside,
  Future<bool> Function(Uri)? launch,
  ProviderContainer? container,
}) async {
  final router = GoRouter(
    initialLocation: '/recover',
    routes: [
      GoRoute(path: '/recover', builder: (_, __) => const KeyRecoveryScreen()),
      GoRoute(
        path: '/lock',
        builder: (_, __) => const Scaffold(body: Text('lock stub')),
      ),
      GoRoute(
        path: '/unlock',
        builder: (_, __) => const Scaffold(body: Text('unlock stub')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container ??
          ProviderContainer(
            overrides: [
              backupEnabledProvider.overrideWith((_) async => saltPresent),
              keyMissingProvider.overrideWith((_) => !notMigrated),
              notMigratedProvider.overrideWith((_) => notMigrated),
              startupKeyStateProbeProvider
                  .overrideWithValue(() async => probeResult),
              if (setAside != null)
                setAsideDbProvider.overrideWithValue(setAside),
              if (launch != null) launchUrlProvider.overrideWithValue(launch),
            ],
          ),
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('KeyRecoveryScreen — what the user sees', () {
    testWidgets('states plainly that the log has not been changed',
        (tester) async {
      await _pump(tester);
      expect(find.text("Can't open your log"), findsOneWidget);
      expect(
        find.textContaining('still on the phone and has NOT been changed'),
        findsOneWidget,
      );
    });

    testWidgets('always offers Try again and Start a new log', (tester) async {
      await _pump(tester);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Start a new log'), findsOneWidget);
    });

    testWidgets('hides the passphrase button when no salt file exists',
        (tester) async {
      await _pump(tester, saltPresent: false);
      expect(find.text('Use backup passphrase'), findsNothing);
    });

    testWidgets('shows the passphrase button only when the salt exists',
        (tester) async {
      await _pump(tester, saltPresent: true);
      expect(find.text('Use backup passphrase'), findsOneWidget);
    });

    testWidgets('passphrase button routes to /unlock', (tester) async {
      await _pump(tester, saltPresent: true);
      await tester.tap(find.text('Use backup passphrase'));
      await tester.pumpAndSettle();
      expect(find.text('unlock stub'), findsOneWidget);
    });
  });

  group('KeyRecoveryScreen — Try again', () {
    testWidgets('still-missing keeps the user here with an explanation',
        (tester) async {
      await _pump(tester, probeResult: StartupKeyState.keyMissing);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Still no key'), findsOneWidget);
      expect(find.text("Can't open your log"), findsOneWidget);
    });

    testWidgets('ok releases the gate and proceeds to /lock', (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.ok),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(container.read(keyMissingProvider), isFalse);
      expect(container.read(needsUnlockProvider), isFalse);
      expect(find.text('lock stub'), findsOneWidget);
    });

    testWidgets('needsUnlock hands off to /unlock with the gates flipped',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.needsUnlock),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(container.read(keyMissingProvider), isFalse);
      expect(container.read(needsUnlockProvider), isTrue);
      expect(find.text('unlock stub'), findsOneWidget);
    });

    testWidgets('a throwing probe is reported, not crashed on',
        (tester) async {
      await _pump(tester);
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => throw StateError('keystore down')),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not check the key store'),
          findsOneWidget);
    });
  });

  group('KeyRecoveryScreen — Start a new log', () {
    testWidgets('confirm dialog spells out the rename and the non-deletion',
        (tester) async {
      var called = 0;
      await _pump(tester, setAside: () async {
        called++;
        return 'trail.db.locked-20260822-1435';
      });
      await tester.tap(find.text('Start a new log'));
      await tester.pumpAndSettle();
      expect(find.text('Start a new log?'), findsOneWidget);
      expect(
        find.textContaining('trail.db.locked-<yyyyMMdd-HHmm>'),
        findsOneWidget,
      );
      expect(find.textContaining('it is not deleted'), findsOneWidget);
      expect(called, 0, reason: 'nothing happens until the user confirms');
    });

    testWidgets('cancelling leaves the log alone and stays on the screen',
        (tester) async {
      var called = 0;
      await _pump(tester, setAside: () async {
        called++;
        return null;
      });
      await tester.tap(find.text('Start a new log'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(called, 0);
      expect(find.text("Can't open your log"), findsOneWidget);
    });

    testWidgets('confirming calls the set-aside seam exactly once',
        (tester) async {
      var called = 0;
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.keyMissing),
          setAsideDbProvider.overrideWithValue(() async {
            called++;
            return 'trail.db.locked-20260822-1435';
          }),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Start a new log'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start a new log'));
      await tester.pumpAndSettle();
      expect(called, 1);
      expect(container.read(keyMissingProvider), isFalse);
      expect(find.text('lock stub'), findsOneWidget);
    });

    testWidgets('a failing set-aside surfaces the error, gate stays shut',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.keyMissing),
          setAsideDbProvider
              .overrideWithValue(() async => throw StateError('read-only fs')),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Start a new log'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start a new log'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not move the old log aside'),
          findsOneWidget);
      expect(container.read(keyMissingProvider), isTrue);
    });
  });

  group('KeyRecoveryScreen — the notMigrated variant (fss 11)', () {
    testWidgets('renames the problem and spells out the fix', (tester) async {
      await _pump(tester, notMigrated: true);
      expect(find.text('Update needed first'), findsOneWidget);
      expect(find.text("Can't open your log"), findsNothing);
      expect(
        find.textContaining(
            'This version can only read the new secure-storage format'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing has been deleted.'), findsOneWidget);
      expect(
        find.textContaining('Install Trail 0.17.3 from the releases page'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Secure storage: migrated'),
        findsOneWidget,
      );
    });

    testWidgets('hides "Start a new log" — it would be destructive advice',
        (tester) async {
      await _pump(tester, notMigrated: true);
      expect(find.text('Start a new log'), findsNothing);
    });

    testWidgets('hides the passphrase button even when a salt exists',
        (tester) async {
      // A salt cannot help here: the derived key would be written through
      // a store this build cannot reconcile with the old one.
      await _pump(tester, notMigrated: true, saltPresent: true);
      expect(find.text('Use backup passphrase'), findsNothing);
    });

    testWidgets('keeps Try again', (tester) async {
      await _pump(tester, notMigrated: true);
      expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
    });

    testWidgets('the release button opens the 0.17.3 tag', (tester) async {
      final opened = <Uri>[];
      await _pump(
        tester,
        notMigrated: true,
        launch: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await tester.tap(find.text('Get Trail 0.17.3'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), releaseUrl0173);
      expect(
        releaseUrl0173,
        'https://github.com/DazedDingo/trail/releases/tag/v0.17.3-105',
      );
    });

    testWidgets('a browser that will not open shows the URL to type',
        (tester) async {
      await _pump(tester, notMigrated: true, launch: (_) async => false);
      await tester.tap(find.text('Get Trail 0.17.3'));
      await tester.pumpAndSettle();
      expect(find.textContaining(releaseUrl0173), findsOneWidget);
    });

    testWidgets('a throwing launcher is reported, not crashed on',
        (tester) async {
      await _pump(
        tester,
        notMigrated: true,
        launch: (_) async => throw StateError('no browser'),
      );
      await tester.tap(find.text('Get Trail 0.17.3'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not open a browser'), findsOneWidget);
    });

    testWidgets('Try again while still unmigrated keeps the user here',
        (tester) async {
      await _pump(
        tester,
        notMigrated: true,
        probeResult: StartupKeyState.notMigrated,
      );
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Still on the old storage format'),
          findsOneWidget);
      expect(find.text('Update needed first'), findsOneWidget);
    });

    testWidgets('Try again after the upgrade releases both gates',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => false),
          notMigratedProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.ok),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(container.read(notMigratedProvider), isFalse);
      expect(container.read(keyMissingProvider), isFalse);
      expect(find.text('lock stub'), findsOneWidget);
    });

    testWidgets('a probe that now says keyMissing switches the copy over',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => false),
          notMigratedProvider.overrideWith((_) => true),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.keyMissing),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(container.read(notMigratedProvider), isFalse);
      expect(container.read(keyMissingProvider), isTrue,
          reason: 'the gate must stay shut while the diagnosis changes');
      expect(find.text("Can't open your log"), findsOneWidget);
      expect(find.textContaining('Still no key'), findsOneWidget);
    });

    testWidgets('and the reverse: keyMissing → notMigrated re-points it',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          backupEnabledProvider.overrideWith((_) async => false),
          keyMissingProvider.overrideWith((_) => true),
          notMigratedProvider.overrideWith((_) => false),
          startupKeyStateProbeProvider
              .overrideWithValue(() async => StartupKeyState.notMigrated),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container: container);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(container.read(notMigratedProvider), isTrue);
      expect(container.read(keyMissingProvider), isFalse);
      expect(find.text('Update needed first'), findsOneWidget);
    });
  });

  group('KeyRecoveryScreen — the default variant is untouched', () {
    testWidgets('no release button when the marker says A ran',
        (tester) async {
      await _pump(tester);
      expect(find.text('Get Trail 0.17.3'), findsNothing);
      expect(find.text("Can't open your log"), findsOneWidget);
      expect(find.text('Start a new log'), findsOneWidget);
    });
  });
}
