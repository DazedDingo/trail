import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/backup_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/startup_provider.dart';
import '../services/startup_gates.dart';

/// The screen that exists so the Android splash can never be the last
/// thing a user sees.
///
/// Before 0.17.6 `main()` awaited both router gates and called `runApp`
/// only afterwards, so a `flutter_secure_storage` read that threw — or
/// simply never returned — left the app on the native splash with no
/// first Flutter frame, no biometric prompt and no way to report it.
/// `runStartupGates` now turns every such outcome into a
/// [StartupFailure], `startupRedirect` hard-gates on this route, and the
/// user gets the stage, the error and a stack they can paste into a bug
/// report.
///
/// Three deliberate actions, in the same shape as `KeyRecoveryScreen`:
///
///   * **Copy details** — the whole block onto the clipboard.
///   * **Try again** — re-runs the gates. A transient Keystore failure or
///     a slow first boot clears on the second attempt, and there is no
///     reason to make the user force-stop the app to find that out.
///   * **Open diagnostics** — `/diagnostics` is the one route allowed
///     past this gate: it reads permissions, the worker log, the
///     secure-storage marker and the locked-aside file list, and opens
///     the DB only behind its own button.
///
/// Nothing on this screen writes or deletes anything.
class StartupFailureScreen extends ConsumerStatefulWidget {
  const StartupFailureScreen({super.key});

  @override
  ConsumerState<StartupFailureScreen> createState() =>
      _StartupFailureScreenState();
}

class _StartupFailureScreenState extends ConsumerState<StartupFailureScreen> {
  bool _working = false;
  String? _notice;

  Future<void> _copyDetails(StartupFailure failure) async {
    final blob = 'Trail startup failure — '
        '${DateTime.now().toUtc().toIso8601String()}\n\n'
        '${failure.details}';
    await Clipboard.setData(ClipboardData(text: blob));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Startup details copied to clipboard.')),
    );
  }

  Future<void> _tryAgain() async {
    setState(() {
      _working = true;
      _notice = null;
    });
    StartupOutcome outcome;
    try {
      outcome = await ref.read(startupGatesProbeProvider)();
    } catch (e) {
      // `runStartupGates` is documented never to throw; a stub that does
      // must not strand the button in its spinner.
      if (!mounted) return;
      setState(() {
        _working = false;
        _notice = 'Could not re-check: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);
    if (!outcome.ok) {
      // Re-point the gate at the new diagnosis; the screen stays put.
      ref.read(startupFailureProvider.notifier).state = outcome.failure;
      setState(() => _notice =
          'Still failing. Nothing has been deleted — you can try again '
          'after a restart, or send the copied details to the developer.');
      return;
    }
    // Flip every router gate before navigating, the same way
    // `KeyRecoveryScreen` does — `redirect` reads them synchronously and
    // would otherwise bounce us straight back here.
    ref.read(onboardingCompleteProvider.notifier).state = outcome.onboarded;
    ref.read(needsUnlockProvider.notifier).state =
        outcome.keyState == StartupKeyState.needsUnlock;
    ref.read(keyMissingProvider.notifier).state =
        outcome.keyState == StartupKeyState.keyMissing;
    ref.read(notMigratedProvider.notifier).state =
        outcome.keyState == StartupKeyState.notMigrated;
    ref.read(startupFailureProvider.notifier).state = null;
    context.go('/lock');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = ref.watch(startupFailureProvider);
    // Only reachable for the split second between "Try again" clearing
    // the gate and `context.go` landing, but a null-crash on the crash
    // screen would be a poor joke.
    final details = failure?.details ?? 'No details were recorded.';
    return Scaffold(
      appBar: AppBar(title: const Text("Trail couldn't start")),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline, size: 56, color: scheme.error),
              const SizedBox(height: 16),
              Text(
                'Something failed before the first screen could load. '
                'Nothing has been deleted.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (failure != null) ...[
                const SizedBox(height: 12),
                Text(
                  failure.headline,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    details,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              if (_notice != null) ...[
                const SizedBox(height: 16),
                Text(
                  _notice!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: failure == null || _working
                    ? null
                    : () => _copyDetails(failure),
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copy details'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _working ? null : _tryAgain,
                child: _working
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Try again'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed:
                    _working ? null : () => context.push('/diagnostics'),
                child: const Text('Open diagnostics'),
              ),
              const SizedBox(height: 24),
              Text(
                'If this keeps happening, send the copied details to the '
                'developer.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
