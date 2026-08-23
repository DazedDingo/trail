import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/providers/backup_provider.dart';
import 'package:trail/services/startup_gates.dart';

/// `runStartupGates` is the reason the Android splash can no longer be
/// the last thing a user sees.
///
/// Both gates are `flutter_secure_storage` platform calls. Until 0.17.6
/// `main()` awaited them raw, so a `PlatformException` out of a Keystore
/// unwrap — or a channel call that simply never returned — killed `main`
/// before `runApp`: no first Flutter frame, no biometric prompt, no way
/// for the user to report it. Every one of those outcomes must now be a
/// value, never a throw and never a hang.
class _StorageBlewUp implements Exception {
  final String message;
  const _StorageBlewUp(this.message);
  @override
  String toString() => 'PlatformException(Failed to unwrap key: $message)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runStartupGates — happy path', () {
    test('both gates answer → ready with both values', () async {
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: () async => StartupKeyState.needsUnlock,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.failure, isNull);
      expect(outcome.onboarded, isTrue);
      expect(outcome.keyState, StartupKeyState.needsUnlock);
    });

    test('a first run reads through as onboarded:false, keyState:ok',
        () async {
      final outcome = await runStartupGates(
        readOnboarded: () async => false,
        readKeyState: () async => StartupKeyState.ok,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.onboarded, isFalse);
      expect(outcome.keyState, StartupKeyState.ok);
    });

    test('the two gates still overlap (gotcha 30)', () {
      // Both futures must be in flight before either is awaited — two
      // 5 s reads have to cost 5 s, not 10 s.
      fakeAsync((async) {
        StartupOutcome? outcome;
        runStartupGates(
          readOnboarded: () =>
              Future.delayed(const Duration(seconds: 5), () => true),
          readKeyState: () => Future.delayed(
              const Duration(seconds: 5), () => StartupKeyState.ok),
        ).then((o) => outcome = o);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(outcome?.ok, isTrue);
      });
    });
  });

  group('runStartupGates — a gate that throws', () {
    test('the onboarding read throws → failed(onboarding) with the error',
        () async {
      const boom = _StorageBlewUp('onboarding');
      final outcome = await runStartupGates(
        readOnboarded: () async => throw boom,
        readKeyState: () async => StartupKeyState.ok,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.onboarding);
      expect(outcome.failure!.error, same(boom));
      expect(outcome.failure!.timedOut, isFalse);
      expect(outcome.failure!.stackTrace, isNotNull);
    });

    test('the key-state read throws → failed(keyState) with the error',
        () async {
      const boom = _StorageBlewUp('trail_db_passphrase_v1');
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: () async => throw boom,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.keyState);
      expect(outcome.failure!.error, same(boom));
      expect(outcome.failure!.timedOut, isFalse);
    });

    test('a synchronous throw is caught too', () async {
      // `Future.sync` in the gate wrapper — a plugin that throws before
      // it ever returns a future must not escape either.
      final outcome = await runStartupGates(
        readOnboarded: () => throw const _StorageBlewUp('sync'),
        readKeyState: () async => StartupKeyState.ok,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.onboarding);
    });

    test('both gates fail → the first stage is the one reported', () async {
      const first = _StorageBlewUp('onboarding');
      const second = _StorageBlewUp('key state');
      final outcome = await runStartupGates(
        readOnboarded: () async => throw first,
        readKeyState: () async => throw second,
      );
      expect(outcome.failure!.stage, StartupStage.onboarding);
      expect(outcome.failure!.error, same(first));
    });

    test('a failed outcome carries safe defaults for the router flags',
        () async {
      // Never read (the redirect hard-gates first), but `keyState.ok`
      // means even a bypass goes through `KeystoreKey.getOrCreate`,
      // which refuses to mint a key over an existing log.
      final outcome = await runStartupGates(
        readOnboarded: () async => throw const _StorageBlewUp('x'),
        readKeyState: () async => StartupKeyState.ok,
      );
      expect(outcome.onboarded, isFalse);
      expect(outcome.keyState, StartupKeyState.ok);
    });
  });

  group('runStartupGates — a gate that hangs', () {
    test('key state never completes → failed(timedOut) after 15 s', () {
      fakeAsync((async) {
        final stuck = Completer<StartupKeyState>();
        StartupOutcome? outcome;
        runStartupGates(
          readOnboarded: () async => true,
          readKeyState: () => stuck.future,
        ).then((o) => outcome = o);

        async.elapse(const Duration(seconds: 14));
        async.flushMicrotasks();
        expect(outcome, isNull,
            reason: 'still inside the 15 s budget — do not give up early');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(outcome, isNotNull, reason: 'the splash must never win');
        expect(outcome!.ok, isFalse);
        expect(outcome!.failure!.stage, StartupStage.keyState);
        expect(outcome!.failure!.timedOut, isTrue);
        expect(outcome!.failure!.error, isA<TimeoutException>());
      });
    });

    test('the onboarding read hangs → failed(timedOut, onboarding)', () {
      fakeAsync((async) {
        final stuck = Completer<bool>();
        StartupOutcome? outcome;
        runStartupGates(
          readOnboarded: () => stuck.future,
          readKeyState: () async => StartupKeyState.ok,
        ).then((o) => outcome = o);
        async.elapse(startupGateTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(outcome!.failure!.stage, StartupStage.onboarding);
        expect(outcome!.failure!.timedOut, isTrue);
      });
    });

    test('both hang → one screen, the first stage', () {
      fakeAsync((async) {
        final a = Completer<bool>();
        final b = Completer<StartupKeyState>();
        StartupOutcome? outcome;
        runStartupGates(readOnboarded: () => a.future, readKeyState: () => b.future)
            .then((o) => outcome = o);
        async.elapse(startupGateTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(outcome!.failure!.stage, StartupStage.onboarding);
        expect(outcome!.failure!.timedOut, isTrue);
      });
    });

    test('a short injected timeout is honoured', () {
      fakeAsync((async) {
        StartupOutcome? outcome;
        runStartupGates(
          readOnboarded: () => Completer<bool>().future,
          readKeyState: () async => StartupKeyState.ok,
          timeout: const Duration(milliseconds: 200),
        ).then((o) => outcome = o);
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
        expect(outcome!.failure!.timedOut, isTrue);
      });
    });
  });

  group('StartupFailure — what the user is shown and copies', () {
    test('headline names the stage and distinguishes hang from throw', () {
      const thrown = StartupFailure(
        stage: StartupStage.keyState,
        error: 'boom',
      );
      final hung = StartupFailure(
        stage: StartupStage.keyState,
        error: TimeoutException('x', startupGateTimeout),
        timedOut: true,
      );
      expect(thrown.headline, 'Failed reading the encryption key state.');
      expect(hung.headline, 'Timed out reading the encryption key state.');
    });

    test('details carry stage, error and the head of the stack', () {
      final failure = StartupFailure(
        stage: StartupStage.onboarding,
        error: const _StorageBlewUp('onboarding'),
        stackTrace: StackTrace.fromString('#0 frameOne\n#1 frameTwo'),
      );
      expect(failure.details, contains('Stage: onboarding flag'));
      expect(failure.details, contains('Failed to unwrap key: onboarding'));
      expect(failure.details, contains('#0 frameOne'));
      expect(failure.details, contains('Timed out: false'));
    });

    test('firstStackLines caps the frame count and says how many are left',
        () {
      final long = StackTrace.fromString(
        List.generate(30, (i) => '#$i frame$i').join('\n'),
      );
      final head = firstStackLines(long, maxLines: 5);
      expect(head.split('\n').length, 6, reason: '5 frames + the tail note');
      expect(head, contains('#4 frame4'));
      expect(head, isNot(contains('#5 frame5')));
      expect(head, contains('25 more frames'));
    });

    test('firstStackLines on a null / short stack', () {
      expect(firstStackLines(null), '');
      expect(firstStackLines(StackTrace.fromString('#0 only')), '#0 only');
    });

    test('truncateStack clips at 2 000 chars', () {
      final huge = StackTrace.fromString('x' * 5000);
      expect(truncateStack(huge).length, maxPersistedStackChars);
      expect(truncateStack(null), '');
      expect(truncateStack(StackTrace.fromString('short')), 'short');
    });
  });

  group('classifyStartupFailure — picking the failure-screen messaging', () {
    test('the live incident: "Failed to unwrap key" classifies as keystore',
        () {
      expect(
        classifyStartupFailure(
          'Stage: encryption key state\nTimed out: false\n'
          'Error: PlatformException(Failed to unwrap key, null, null)',
        ),
        StartupFailureKind.keystore,
      );
    });

    for (final marker in [
      'Failed to unwrap key',
      'KeyStoreException',
      'AndroidKeyStore',
      'keystore2',
      'UNKNOWN_ERROR',
      'Migration failed after algorithm change',
      'Key mismatch after algorithm change',
    ]) {
      test('"$marker" classifies as keystore', () {
        expect(classifyStartupFailure('Error: boom ($marker)'),
            StartupFailureKind.keystore);
      });
    }

    test('a plain timeout (no keystore marker) classifies as timeout', () {
      expect(
        classifyStartupFailure(
          'Stage: onboarding flag\nTimed out: true\n'
          'Error: TimeoutException after 0:00:15.000000',
        ),
        StartupFailureKind.timeout,
      );
    });

    test('a keystore marker wins over a timeout in the same text', () {
      expect(
        classifyStartupFailure(
          'Stage: encryption key state\nTimed out: true\n'
          'Error: PlatformException(Failed to unwrap key)',
        ),
        StartupFailureKind.keystore,
      );
    });

    test('anything else classifies as other', () {
      expect(
        classifyStartupFailure(
          'Stage: onboarding flag\nTimed out: false\n'
          'Error: StateError(something unrelated)',
        ),
        StartupFailureKind.other,
      );
    });

    test('"Timed out: false" alone never reads as a timeout', () {
      expect(
        classifyStartupFailure('Timed out: false\nError: whatever'),
        isNot(StartupFailureKind.timeout),
      );
    });
  });

  group('startup-blocked flag — pausing the worker', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('unset reads as not blocked', () async {
      expect(await readStartupBlocked(prefs: prefs), isFalse);
    });

    test('setStartupBlocked(true) is read back by readStartupBlocked',
        () async {
      expect(await setStartupBlocked(true, prefs: prefs), isTrue);
      expect(await readStartupBlocked(prefs: prefs), isTrue);
      expect(prefs.getBool(startupBlockedKey), isTrue);
    });

    test('setStartupBlocked(false) clears a previously-set flag', () async {
      await setStartupBlocked(true, prefs: prefs);
      expect(await setStartupBlocked(false, prefs: prefs), isTrue);
      expect(await readStartupBlocked(prefs: prefs), isFalse);
    });

    test('writing never throws when the prefs backend is broken', () async {
      expect(await setStartupBlocked(true, prefs: _ThrowingPrefs()), isFalse);
    });

    test('reading never throws when the prefs backend is broken', () async {
      expect(await readStartupBlocked(prefs: _ThrowingPrefs()), isFalse);
    });
  });

  group('persistence — the diagnostics breadcrumb', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('a failure is written as parseable JSON', () async {
      final at = DateTime.utc(2026, 8, 23, 9, 14);
      final wrote = await persistStartupError(
        StartupFailure(
          stage: StartupStage.keyState,
          error: const _StorageBlewUp('trail_db_passphrase_v1'),
          stackTrace: StackTrace.fromString('#0 frameOne'),
          timedOut: true,
        ),
        at: at,
        prefs: prefs,
      );
      expect(wrote, isTrue);

      final raw = prefs.getString(lastStartupErrorKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['at'], at.millisecondsSinceEpoch);
      expect(decoded['stage'], 'encryption key state');
      expect(decoded['error'], contains('Failed to unwrap key'));
      expect(decoded['stack'], contains('#0 frameOne'));
    });

    test('the persisted stack is clipped to 2 000 chars', () async {
      await persistStartupError(
        StartupFailure(
          stage: StartupStage.uncaught,
          error: 'boom',
          stackTrace: StackTrace.fromString('y' * 9000),
        ),
        prefs: prefs,
      );
      final decoded =
          jsonDecode(prefs.getString(lastStartupErrorKey)!) as Map;
      expect((decoded['stack'] as String).length, maxPersistedStackChars);
    });

    test('round-trips through readLastStartupError', () async {
      final at = DateTime.utc(2026, 8, 23, 9, 14);
      await persistStartupError(
        const StartupFailure(
          stage: StartupStage.onboarding,
          error: 'nope',
        ),
        at: at,
        prefs: prefs,
      );
      final read = await readLastStartupError(prefs: prefs);
      expect(read, isNotNull);
      expect(read!.stage, 'onboarding flag');
      expect(read.error, 'nope');
      expect(read.at.toUtc(), at);
      expect(read.stack, '');
    });

    test('nothing recorded → null, and the diagnostics line says "none"',
        () async {
      expect(await readLastStartupError(prefs: prefs), isNull);
      expect(describeLastStartupError(null), 'Last startup error: none');
    });

    test('a garbage pref reads as "nothing recorded", never a throw', () {
      // Same rule as WorkerRunLog and the secure-storage marker: bad
      // JSON must not blank (or crash) the diagnostics screen.
      expect(parseLastStartupError(null), isNull);
      expect(parseLastStartupError(''), isNull);
      expect(parseLastStartupError('not json at all'), isNull);
      expect(parseLastStartupError('[]'), isNull);
      expect(parseLastStartupError('{"stage":"x"}'), isNull,
          reason: 'no timestamp → not a record');
      expect(parseLastStartupError('{"at":"yesterday"}'), isNull);
    });

    test('a partial record still parses, with empty fields', () {
      final parsed = parseLastStartupError('{"at":0}');
      expect(parsed, isNotNull);
      expect(parsed!.stage, 'unknown');
      expect(parsed.error, '');
      expect(parsed.stack, '');
    });

    test('the diagnostics line names the date, the stage and the error', () {
      final line = describeLastStartupError(LastStartupError(
        at: DateTime.utc(2026, 8, 23, 9, 14).toLocal(),
        stage: 'encryption key state',
        error: 'PlatformException(Failed to unwrap key)',
        stack: '',
      ));
      expect(line, startsWith('Last startup error: '));
      expect(line, contains('encryption key state'));
      expect(line, contains('Failed to unwrap key'));
    });

    test('persisting never throws when the prefs backend is broken too',
        () async {
      // The write runs from an error handler; a second error there is
      // exactly what we cannot afford.
      await expectLater(
        persistStartupError(
          const StartupFailure(stage: StartupStage.uncaught, error: 'x'),
          prefs: _ThrowingPrefs(),
        ),
        completion(isFalse),
      );
    });

    test('reading never throws when the prefs backend is broken', () async {
      expect(await readLastStartupError(prefs: _ThrowingPrefs()), isNull);
    });
  });
}

/// A `SharedPreferences` whose writes throw — the "prefs backend is
/// broken too" case for [persistStartupError]'s best-effort contract.
class _ThrowingPrefs implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('prefs unavailable');
  }
}
