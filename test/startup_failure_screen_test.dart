import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:trail/providers/backup_provider.dart';
import 'package:trail/providers/onboarding_provider.dart';
import 'package:trail/providers/startup_provider.dart';
import 'package:trail/screens/startup_failure_screen.dart';
import 'package:trail/services/startup_gates.dart';

/// UX-level coverage for `/startup-failed` — the screen that replaced
/// "the Android splash, forever". It is the only surface a user has when
/// `main()` cannot reach the first frame, so every promise it makes is
/// pinned: that nothing was deleted, that the details are copyable, and
/// that "Try again" really does release the router gates on success.
const _failure = StartupFailure(
  stage: StartupStage.keyState,
  error: 'PlatformException(Failed to unwrap key)',
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  StartupFailure? failure = _failure,
  Future<StartupOutcome> Function()? probe,
}) async {
  final container = ProviderContainer(
    overrides: [
      startupFailureProvider.overrideWith((_) => failure),
      onboardingCompleteProvider.overrideWith((_) => false),
      if (probe != null) startupGatesProbeProvider.overrideWithValue(probe),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/startup-failed',
    routes: [
      GoRoute(
        path: '/startup-failed',
        builder: (_, __) => const StartupFailureScreen(),
      ),
      GoRoute(
        path: '/lock',
        builder: (_, __) => const Scaffold(body: Text('lock stub')),
      ),
      GoRoute(
        path: '/diagnostics',
        builder: (_, __) => const Scaffold(body: Text('diagnostics stub')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('StartupFailureScreen — what the user sees', () {
    testWidgets('names itself and promises nothing was deleted',
        (tester) async {
      await _pump(tester);
      expect(find.text("Trail couldn't start"), findsOneWidget);
      expect(
        find.textContaining(
          'Something failed before the first screen could load. '
          'Nothing has been deleted.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the stage, the error and the footer', (tester) async {
      await _pump(tester);
      expect(
        find.text('Failed reading the encryption key state.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Stage: encryption key state'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Failed to unwrap key'),
        findsWidgets,
      );
      expect(
        find.textContaining(
          'If this keeps happening, send the copied details to the '
          'developer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the details block is selectable and monospace',
        (tester) async {
      await _pump(tester);
      final block = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(block.style?.fontFamily, 'monospace');
      expect(block.data, contains('Stage: encryption key state'));
    });

    testWidgets('offers exactly the three actions', (tester) async {
      await _pump(tester);
      expect(
        find.widgetWithText(FilledButton, 'Copy details'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, 'Open diagnostics'),
        findsOneWidget,
      );
    });

    testWidgets('a timeout reads as a timeout, not a throw', (tester) async {
      await _pump(
        tester,
        failure: const StartupFailure(
          stage: StartupStage.onboarding,
          error: 'TimeoutException after 0:00:15.000000',
          timedOut: true,
        ),
      );
      expect(
        find.text('Timed out reading the onboarding flag.'),
        findsOneWidget,
      );
      expect(find.textContaining('Timed out: true'), findsOneWidget);
    });
  });

  group('Copy details', () {
    testWidgets('puts the stage and error on the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pump(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Copy details'));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(copied.single, contains('Trail startup failure'));
      expect(copied.single, contains('Stage: encryption key state'));
      expect(copied.single, contains('Failed to unwrap key'));
      expect(
        find.text('Startup details copied to clipboard.'),
        findsOneWidget,
      );
    });
  });

  group('Try again', () {
    testWidgets('success clears the gate and lands on /lock', (tester) async {
      final container = await _pump(
        tester,
        probe: () async => const StartupOutcome.ready(
          onboarded: true,
          keyState: StartupKeyState.ok,
        ),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Try again'));
      await tester.pumpAndSettle();

      expect(container.read(startupFailureProvider), isNull,
          reason: 'the router gate must be released');
      expect(container.read(onboardingCompleteProvider), isTrue,
          reason: 'the re-probed flags replace the failed-startup defaults');
      expect(container.read(needsUnlockProvider), isFalse);
      expect(container.read(keyMissingProvider), isFalse);
      expect(container.read(notMigratedProvider), isFalse);
      expect(find.text('lock stub'), findsOneWidget);
    });

    testWidgets('a re-probe that says "needs unlock" sets that gate too',
        (tester) async {
      final container = await _pump(
        tester,
        probe: () async => const StartupOutcome.ready(
          onboarded: true,
          keyState: StartupKeyState.needsUnlock,
        ),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Try again'));
      await tester.pumpAndSettle();
      expect(container.read(startupFailureProvider), isNull);
      expect(container.read(needsUnlockProvider), isTrue);
    });

    testWidgets('still failing → stays put, keeps the gate, shows a notice',
        (tester) async {
      const second = StartupFailure(
        stage: StartupStage.onboarding,
        error: 'still broken',
        timedOut: true,
      );
      final container = await _pump(
        tester,
        probe: () async => const StartupOutcome.failed(second),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Try again'));
      await tester.pumpAndSettle();

      expect(container.read(startupFailureProvider), same(second),
          reason: 'the gate stays shut, re-pointed at the new diagnosis');
      expect(find.textContaining('Still failing.'), findsOneWidget);
      expect(find.textContaining('Nothing has been deleted'), findsWidgets);
      expect(find.text('lock stub'), findsNothing);
      expect(find.textContaining('still broken'), findsOneWidget);
    });

    testWidgets('a probe that throws does not strand the spinner',
        (tester) async {
      final container = await _pump(
        tester,
        probe: () async => throw StateError('probe blew up'),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not re-check:'), findsOneWidget);
      expect(container.read(startupFailureProvider), same(_failure));
      expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
    });
  });

  group('Open diagnostics', () {
    testWidgets('navigates to /diagnostics', (tester) async {
      await _pump(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Open diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('diagnostics stub'), findsOneWidget);
    });
  });

  group('degenerate state', () {
    testWidgets('a null failure renders without crashing', (tester) async {
      // Only reachable between "Try again" clearing the gate and the
      // navigation landing — a null-crash on the crash screen would be a
      // poor joke.
      await _pump(tester, failure: null);
      expect(find.text("Trail couldn't start"), findsOneWidget);
      expect(find.text('No details were recorded.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Copy details'))
            .onPressed,
        isNull,
        reason: 'nothing to copy',
      );
    });
  });
}
