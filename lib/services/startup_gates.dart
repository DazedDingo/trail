import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/backup_provider.dart';
import '../providers/onboarding_provider.dart';

/// How long either startup gate may take before Trail gives up on it.
///
/// Both gates are Keystore reads behind a platform channel. A channel
/// call that never returns used to mean the Android splash stayed up
/// forever with no first Flutter frame and no way out; 15 s is far longer
/// than a healthy read (single-digit ms) and short enough that a stuck
/// device still reaches a screen the user can act on.
const startupGateTimeout = Duration(seconds: 15);

/// SharedPreferences key holding the last startup failure, as
/// `{at, stage, error, stack}`. Read by the diagnostics screen.
const lastStartupErrorKey = 'trail_last_startup_error_v1';

/// SharedPreferences key: `true` when the most recent [runStartupGates]
/// call failed and has not yet succeeded again.
///
/// Read at the very top of the WorkManager dispatcher
/// (`_callbackDispatcher` in `workmanager_scheduler.dart`), before any
/// handler opens the DB or touches secure storage. The live incident this
/// guards against: a `flutter_secure_storage` 11 Keystore read that fails
/// with `Failed to unwrap key` / `KeyStoreException UNKNOWN_ERROR -1000`.
/// Every plugin init is another chance for its `createRSAKeysIfNeeded` to
/// see a transient null key and regenerate the RSA pair — which would
/// orphan every stored secret for good. When the last launch could not
/// even get past `runStartupGates`, the worker skips the tick entirely
/// rather than risk one more init.
const startupBlockedKey = 'trail_startup_blocked_v1';

/// Cap on the persisted stack trace. A full Flutter stack is tens of KB
/// and SharedPreferences is not a crash reporter.
const maxPersistedStackChars = 2000;

/// Which part of startup was running when it failed.
enum StartupStage {
  /// `OnboardingGate.isComplete()` — the secure-storage onboarding flag.
  onboarding,

  /// `computeStartupKeyState()` — the SQLCipher key / salt / marker probe.
  keyState,

  /// Anything else that escaped before the first frame: a plugin
  /// registrant, `runApp` itself, a `FlutterError` during the first
  /// build. Caught by the `runZonedGuarded` + `FlutterError.onError`
  /// pair in `main()`.
  uncaught;

  /// Human label — this string reaches the user on the failure screen,
  /// in the diagnostics line and in the copied bug report.
  String get label => switch (this) {
        StartupStage.onboarding => 'onboarding flag',
        StartupStage.keyState => 'encryption key state',
        StartupStage.uncaught => 'app startup',
      };
}

/// One startup gate that did not answer.
@immutable
class StartupFailure {
  final StartupStage stage;
  final Object error;
  final StackTrace? stackTrace;

  /// `true` when the gate never completed and [startupGateTimeout] fired,
  /// as opposed to throwing. Worth distinguishing: a hang points at the
  /// platform channel, a throw at the value behind it.
  final bool timedOut;

  const StartupFailure({
    required this.stage,
    required this.error,
    this.stackTrace,
    this.timedOut = false,
  });

  /// One line, for the top of the failure screen.
  String get headline => timedOut
      ? 'Timed out reading the ${stage.label}.'
      : 'Failed reading the ${stage.label}.';

  /// The monospace block the failure screen shows and "Copy details"
  /// puts on the clipboard.
  String get details {
    final buf = StringBuffer()
      ..writeln('Stage: ${stage.label}')
      ..writeln('Timed out: $timedOut')
      ..writeln('Error: $error');
    final stack = firstStackLines(stackTrace);
    if (stack.isNotEmpty) {
      buf
        ..writeln('')
        ..writeln('Stack:')
        ..writeln(stack);
    }
    return buf.toString();
  }
}

/// Coarse cause bucket for a startup failure's diagnostic text, used to
/// pick the failure screen's messaging above the generic error block.
enum StartupFailureKind {
  /// The text names Android's Keystore (or `keystore2`, or the specific
  /// `flutter_secure_storage` 11 unwrap / algorithm-migration failures)
  /// — the live incident this screen variant exists for.
  keystore,

  /// The gate hit [startupGateTimeout] before it heard back.
  timeout,

  /// Anything else — the generic failure card is enough.
  other,
}

/// Pure: classify [errorText] into a [StartupFailureKind].
///
/// Callers pass [StartupFailure.details], which carries both the error's
/// string form and the literal `Timed out: true`/`Timed out: false` line
/// — so a single string argument is enough to answer both questions.
/// Keystore text wins over a timeout match: a Keystore read can itself
/// time out, and the Keystore-specific copy is still the more useful
/// thing to show in that case.
StartupFailureKind classifyStartupFailure(String errorText) {
  const keystoreMarkers = [
    'Failed to unwrap key',
    'KeyStoreException',
    'AndroidKeyStore',
    'keystore2',
    'UNKNOWN_ERROR',
    'Migration failed after algorithm change',
    'Key mismatch after algorithm change',
  ];
  if (keystoreMarkers.any(errorText.contains)) {
    return StartupFailureKind.keystore;
  }
  if (errorText.contains('Timed out: true')) {
    return StartupFailureKind.timeout;
  }
  return StartupFailureKind.other;
}

/// What `main()` learned before it called `runApp`.
///
/// Exactly one of the two shapes: [ready] carries the two router gates,
/// [failed] carries the diagnosis. There is no third state — the whole
/// point is that startup always ends in a `runApp`.
@immutable
class StartupOutcome {
  final bool ok;
  final bool onboarded;
  final StartupKeyState keyState;
  final StartupFailure? failure;

  const StartupOutcome.ready({
    required this.onboarded,
    required this.keyState,
  })  : ok = true,
        failure = null;

  const StartupOutcome.failed(StartupFailure this.failure)
      : ok = false,
        // Never consulted: `startupRedirect` hard-gates on the failure
        // before it looks at either flag. Defaults chosen so that even a
        // bypass cannot mint a key over an existing log — `keyState.ok`
        // still routes through `KeystoreKey.getOrCreate`, which refuses.
        onboarded = false,
        keyState = StartupKeyState.ok;
}

/// Runs both router gates, concurrently, and never throws.
///
/// This is the whole of what used to sit between `main()` and `runApp`:
///
/// ```dart
/// final onboarded = await OnboardingGate.isComplete();
/// final keyState = await computeStartupKeyState();
/// ```
///
/// Either read is a `flutter_secure_storage` platform call, and either
/// could throw (a Keystore unwrap failure surfaces as a
/// `PlatformException`) or simply never come back. Both used to take the
/// app down before the first frame — no Flutter UI, no biometric prompt,
/// just the Android splash forever. Now every outcome is a value:
/// [StartupOutcome.failed] with the stage, error and stack, which the
/// router turns into `/startup-failed`.
///
/// Still two awaits and still overlapping (CLAUDE.md gotcha 30) — the
/// timeouts are attached before either is awaited.
///
/// [readOnboarded] and [readKeyState] are injectable so the truth table
/// can be asserted without a Keystore; [timeout] so a hang can be driven
/// under `fakeAsync`.
Future<StartupOutcome> runStartupGates({
  Future<bool> Function()? readOnboarded,
  Future<StartupKeyState> Function()? readKeyState,
  Duration timeout = startupGateTimeout,
}) async {
  final onboardingGate = _runGate<bool>(
    StartupStage.onboarding,
    readOnboarded ?? OnboardingGate.isComplete,
    timeout,
  );
  final keyStateGate = _runGate<StartupKeyState>(
    StartupStage.keyState,
    readKeyState ?? computeStartupKeyState,
    timeout,
  );
  final onboarding = await onboardingGate;
  final keyState = await keyStateGate;
  // Earlier stage wins when both fail: the onboarding flag is the first
  // thing startup asks for, and reporting two errors on one screen helps
  // nobody. The second is still in the log via `debugPrint`.
  final failure = onboarding.failure ?? keyState.failure;
  if (failure != null) return StartupOutcome.failed(failure);
  return StartupOutcome.ready(
    onboarded: onboarding.value as bool,
    keyState: keyState.value as StartupKeyState,
  );
}

class _GateResult<T> {
  final T? value;
  final StartupFailure? failure;
  const _GateResult.value(T this.value) : failure = null;
  const _GateResult.failed(StartupFailure this.failure) : value = null;
}

Future<_GateResult<T>> _runGate<T>(
  StartupStage stage,
  Future<T> Function() read,
  Duration timeout,
) async {
  try {
    // `Future.sync` so a synchronous throw from [read] lands here too.
    final value = await Future<T>.sync(read).timeout(timeout);
    return _GateResult<T>.value(value);
  } on TimeoutException catch (e, s) {
    debugPrint('[startup] gate "${stage.label}" timed out after $timeout');
    return _GateResult<T>.failed(
      StartupFailure(stage: stage, error: e, stackTrace: s, timedOut: true),
    );
  } catch (e, s) {
    debugPrint('[startup] gate "${stage.label}" threw: $e');
    return _GateResult<T>.failed(
      StartupFailure(stage: stage, error: e, stackTrace: s),
    );
  }
}

/// The persisted record of the last failed startup.
@immutable
class LastStartupError {
  final DateTime at;
  final String stage;
  final String error;
  final String stack;

  const LastStartupError({
    required this.at,
    required this.stage,
    required this.error,
    required this.stack,
  });
}

/// `23 Aug 2026 09:14` — the day-before-month house style, plus the time
/// (two startup failures in one day are the interesting case).
final DateFormat _startupErrorDateFormat = DateFormat('d MMM yyyy HH:mm');

/// Writes [failure] to [lastStartupErrorKey]. Best-effort by contract:
/// this runs from an error handler, so a prefs failure must never become
/// a second error. Returns whether the write landed.
Future<bool> persistStartupError(
  StartupFailure failure, {
  DateTime? at,
  SharedPreferences? prefs,
}) async {
  try {
    final store = prefs ?? await SharedPreferences.getInstance();
    return await store.setString(
      lastStartupErrorKey,
      jsonEncode({
        'at': (at ?? DateTime.now()).millisecondsSinceEpoch,
        'stage': failure.stage.label,
        'error': failure.error.toString(),
        'stack': truncateStack(failure.stackTrace),
      }),
    );
  } catch (e) {
    debugPrint('[startup] could not persist the startup error: $e');
    return false;
  }
}

/// The persisted record, or `null` if startup has never failed here.
Future<LastStartupError?> readLastStartupError({
  SharedPreferences? prefs,
}) async {
  try {
    final store = prefs ?? await SharedPreferences.getInstance();
    return parseLastStartupError(store.getString(lastStartupErrorKey));
  } catch (_) {
    return null;
  }
}

/// Pure: decode the record. Malformed / missing → `null`; a garbage pref
/// must read as "nothing recorded", never throw (same rule as
/// `WorkerRunLog` and the secure-storage marker).
LastStartupError? parseLastStartupError(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final at = decoded['at'];
    if (at is! int) return null;
    return LastStartupError(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      stage: decoded['stage'] as String? ?? 'unknown',
      error: decoded['error'] as String? ?? '',
      stack: decoded['stack'] as String? ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// Pure: the diagnostics-screen line for [error].
String describeLastStartupError(LastStartupError? error) {
  if (error == null) return 'Last startup error: none';
  final when = _startupErrorDateFormat.format(error.at.toLocal());
  return 'Last startup error: $when · ${error.stage} · ${error.error}';
}

/// Pure: the first [maxLines] frames of [stack] — enough to name the
/// plugin that threw without turning the screen into a wall of frames.
String firstStackLines(StackTrace? stack, {int maxLines = 12}) {
  if (stack == null) return '';
  final lines = stack
      .toString()
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length <= maxLines) return lines.join('\n');
  return '${lines.take(maxLines).join('\n')}\n… '
      '${lines.length - maxLines} more frames';
}

/// Writes [blocked] to [startupBlockedKey]. Best-effort, same contract as
/// [persistStartupError]: this runs from `main()`'s critical path and the
/// failure screen's "Try again", so a prefs failure must never become a
/// second error. Returns whether the write landed.
Future<bool> setStartupBlocked(bool blocked, {SharedPreferences? prefs}) async {
  try {
    final store = prefs ?? await SharedPreferences.getInstance();
    return await store.setBool(startupBlockedKey, blocked);
  } catch (e) {
    debugPrint('[startup] could not persist the startup-blocked flag: $e');
    return false;
  }
}

/// Reads [startupBlockedKey] for the diagnostics screen. Best-effort:
/// unlike the dispatcher's own read (which must fail safe by pausing —
/// see [startupBlockedKey]), a broken prefs backend here should read as
/// "not paused" rather than take down an otherwise-working screen.
Future<bool> readStartupBlocked({SharedPreferences? prefs}) async {
  try {
    final store = prefs ?? await SharedPreferences.getInstance();
    return store.getBool(startupBlockedKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// Pure: [stack] clipped to [maxChars] for persistence.
String truncateStack(StackTrace? stack, {int maxChars = maxPersistedStackChars}) {
  if (stack == null) return '';
  final text = stack.toString();
  return text.length <= maxChars ? text : text.substring(0, maxChars);
}
