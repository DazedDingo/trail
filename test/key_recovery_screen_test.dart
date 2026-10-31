import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:trail/providers/backup_provider.dart';
import 'package:trail/screens/key_recovery_screen.dart';

/// UX-level coverage for the `/recover` gate. The screen is the only
/// place in the app that is allowed to decide what happens to an
/// encrypted log whose key has vanished, so every branch is pinned:
/// which buttons exist, that "Start a new log" is confirm-gated and calls
/// the set-aside seam, and that "Try again" re-probes and releases the
/// router gates on success.
///
/// 0.18.0 retired the screen's second variant ("Update needed first")
/// along with `flutter_secure_storage`. The last group pins that it
/// cannot come back: it told the user to install an older release, which
/// Android can only honour by uninstalling first — deleting the very log
/// this screen exists to protect.
Future<void> _pump(
  WidgetTester tester, {
  bool saltPresent = false,
  StartupKeyState probeResult = StartupKeyState.keyMissing,
  Future<String?> Function()? setAside,
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
              keyMissingProvider.overrideWith((_) => true),
              startupKeyStateProbeProvider
                  .overrideWithValue(() async => probeResult),
              if (setAside != null)
                setAsideDbProvider.overrideWithValue(setAside),
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

  group('KeyRecoveryScreen — the retired downgrade prompt stays retired', () {
    testWidgets('no probe outcome can bring back an older-release prompt',
        (tester) async {
      for (final probe in StartupKeyState.values) {
        await _pump(tester, probeResult: probe);
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.text('Update needed first'), findsNothing,
            reason: 'probe $probe');
        expect(find.textContaining('Get Trail 0.17'), findsNothing,
            reason: 'probe $probe');
        expect(find.textContaining('releases/tag'), findsNothing,
            reason: 'probe $probe');
      }
    });

    testWidgets('what is left is the key-missing copy and its safe actions',
        (tester) async {
      await _pump(tester);
      expect(find.text("Can't open your log"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      expect(
          find.widgetWithText(TextButton, 'Start a new log'), findsOneWidget);
    });
  });
}
