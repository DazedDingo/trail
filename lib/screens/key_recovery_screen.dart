import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/backup_provider.dart';

/// Hard gate shown when an encrypted `trail.db` is on disk but the key
/// that opens it is gone and there is no passphrase salt to re-derive
/// one — a Keystore wipe, a restore onto a new device, or a
/// secure-storage library upgrade that lost the value.
///
/// The one rule this screen exists to enforce: **never silently mint a
/// new key over an existing log.** `KeystoreKey.getOrCreate` throws
/// [KeyMissingException] in that state, `computeStartupKeyState` reports
/// [StartupKeyState.keyMissing], and the router parks the user here until
/// they pick one of three deliberate outcomes:
///
///   * **Try again** — re-probe. Covers a transient Keystore failure and
///     the case where auto-backup restored the salt file a moment later.
///   * **Use backup passphrase** — only when a salt file exists; hands
///     off to `/unlock`, which can re-derive the real key.
///   * **Start a new log** — moves the old DB aside (never deletes it)
///     so a fresh, empty one can be created.
///
/// One variant, chosen by [notMigratedProvider]: when the secure-storage
/// marker release A writes is *also* absent, the likely cause is not key
/// loss at all but this build's `flutter_secure_storage` 11.x reading a
/// 9.2.4 store that was never rewritten — the old bytes are still in the
/// prefs file, they just read back empty. That variant offers the 0.17.3
/// download instead, and deliberately hides "Start a new log": setting
/// the log aside would be destructive advice for a problem an install of
/// the intermediate release fixes.
class KeyRecoveryScreen extends ConsumerStatefulWidget {
  const KeyRecoveryScreen({super.key});

  @override
  ConsumerState<KeyRecoveryScreen> createState() => _KeyRecoveryScreenState();
}

/// The intermediate release the `notMigrated` variant sends the user to —
/// the last build that can still read the 9.2.4 store and rewrite it.
const releaseUrl0173 =
    'https://github.com/DazedDingo/trail/releases/tag/v0.17.3-105';

class _KeyRecoveryScreenState extends ConsumerState<KeyRecoveryScreen> {
  bool _working = false;
  String? _notice;

  Future<void> _tryAgain() async {
    setState(() {
      _working = true;
      _notice = null;
    });
    StartupKeyState state;
    try {
      state = await ref.read(startupKeyStateProbeProvider)();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _notice = 'Could not check the key store: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);
    switch (state) {
      case StartupKeyState.ok:
        _release(needsUnlock: false);
        context.go('/lock');
      case StartupKeyState.needsUnlock:
        _release(needsUnlock: true);
        context.go('/unlock');
      case StartupKeyState.keyMissing:
        _hold(notMigrated: false);
        setState(() => _notice =
            'Still no key. Your log has not been touched — you can try '
            'again after a restart, or start a new log below.');
      case StartupKeyState.notMigrated:
        _hold(notMigrated: true);
        setState(() => _notice =
            'Still on the old storage format. Your log has not been '
            'touched — install 0.17.3, open it once, then come back.');
    }
  }

  /// Opens the 0.17.3 release page. A failure is reported with the URL so
  /// the user can type it in rather than being left with a dead button.
  Future<void> _openReleasePage() async {
    setState(() {
      _working = true;
      _notice = null;
    });
    var ok = false;
    try {
      ok = await ref.read(launchUrlProvider)(Uri.parse(releaseUrl0173));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      if (!ok) _notice = 'Could not open a browser. The page is: $releaseUrl0173';
    });
  }

  /// Flip the router's gates before navigating, the same way
  /// `PassphraseEntryScreen` does — `redirect` reads these synchronously
  /// and would otherwise bounce us straight back here.
  void _release({required bool needsUnlock}) {
    ref.read(keyMissingProvider.notifier).state = false;
    ref.read(notMigratedProvider.notifier).state = false;
    ref.read(needsUnlockProvider.notifier).state = needsUnlock;
  }

  /// Keep the gate shut, but re-point it at the diagnosis the probe just
  /// returned so the screen shows the matching copy. The two flags stay
  /// mutually exclusive, exactly as `main()` sets them.
  void _hold({required bool notMigrated}) {
    ref.read(keyMissingProvider.notifier).state = !notMigrated;
    ref.read(notMigratedProvider.notifier).state = notMigrated;
  }

  Future<void> _startNewLog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start a new log?'),
        content: const Text(
          'This moves the current log aside as '
          'trail.db.locked-<yyyyMMdd-HHmm> (it is not deleted) and starts '
          'an empty one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start a new log'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      await ref.read(setAsideDbProvider)();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _notice = 'Could not move the old log aside: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);
    // With no DB file in place, `KeystoreKey.getOrCreate` is allowed to
    // generate again and the first provider that opens the DB creates an
    // empty one.
    _release(needsUnlock: false);
    context.go('/lock');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saltPresent = ref.watch(backupEnabledProvider).value ?? false;
    final notMigrated = ref.watch(notMigratedProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          notMigrated ? 'Update needed first' : "Can't open your log",
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                notMigrated
                    ? Icons.system_update_alt_outlined
                    : Icons.lock_reset_outlined,
                size: 56,
                color: scheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                notMigrated
                    ? 'This version can only read the new secure-storage '
                        'format, and your secrets were never migrated. '
                        'Nothing has been deleted. Install Trail 0.17.3 from '
                        'the releases page, open it once (Settings \u2192 '
                        "Diagnostics should say 'Secure storage: "
                        "migrated \u2026'), then install this version again."
                    : "Trail can't find the key to your encrypted location "
                        'log. This can happen after a restore to a new device '
                        'or a failed storage update. Your log file is still '
                        'on the phone and has NOT been changed.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (_notice != null) ...[
                const SizedBox(height: 16),
                Text(
                  _notice!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              if (notMigrated) ...[
                // The one action that actually fixes this state. "Start a
                // new log" is deliberately absent: the secrets are still
                // on the phone, so setting the log aside would throw away
                // a log 0.17.3 can hand back.
                FilledButton.icon(
                  onPressed: _working ? null : _openReleasePage,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Get Trail 0.17.3'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _working ? null : _tryAgain,
                  child: const Text('Try again'),
                ),
              ] else ...[
                FilledButton(
                  onPressed: _working ? null : _tryAgain,
                  child: _working
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Try again'),
                ),
                if (saltPresent) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _working
                        ? null
                        : () {
                            // A salt appeared after startup classified this
                            // as keyMissing; release the gate or `redirect`
                            // bounces us straight back here.
                            _release(needsUnlock: true);
                            context.go('/unlock');
                          },
                    child: const Text('Use backup passphrase'),
                  ),
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _working ? null : _startNewLog,
                  child: const Text('Start a new log'),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                notMigrated
                    ? 'Nothing on this screen deletes anything. Your log and '
                        'your saved secrets stay exactly where they are until '
                        '0.17.3 has moved them across.'
                    : 'Nothing on this screen deletes anything. '
                        '"Start a new log" renames the old file so it stays '
                        'on the phone — you can see it under Settings → '
                        'Diagnostics.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
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
