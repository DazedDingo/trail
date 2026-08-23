import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/backup_provider.dart';
import '../providers/startup_provider.dart';
import '../services/passphrase_recovery_service.dart';

/// Gate shown when Trail's DB has been restored (from Android auto-backup)
/// onto a fresh install, or when the Keystore-backed secure store has
/// broken and the backup passphrase is the way back in.
///
/// All of the work lives in [PassphraseRecoveryService] — this screen owns
/// the text field, the error slot, the result sheet and the router gates,
/// and nothing else. The flow it drives:
///
///   1. Derive a candidate key from the entered passphrase + the salt.
///   2. Probe-open the DB with it; a wrong passphrase stops here with
///      nothing written anywhere.
///   3. Persist it to Trail's own escrow (+ secure storage when that
///      still works).
///   4. If secure storage refused, rescue what can be read out of it,
///      set the broken store aside and seed a fresh one — then show the
///      user exactly which settings survived.
class PassphraseEntryScreen extends ConsumerStatefulWidget {
  const PassphraseEntryScreen({super.key});

  @override
  ConsumerState<PassphraseEntryScreen> createState() =>
      _PassphraseEntryScreenState();
}

class _PassphraseEntryScreenState
    extends ConsumerState<PassphraseEntryScreen> {
  final _controller = TextEditingController();
  bool _obscured = true;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    final result =
        await ref.read(passphraseRecoveryProvider).unlock(_controller.text);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _working = false;
        _error = result.error;
      });
      return;
    }
    final rescue = result.rescue;
    if (rescue != null) await _showRescueSheet(rescue);
    if (!mounted) return;
    // Flip the router's gates before navigating: `redirect` reads them
    // synchronously and would otherwise bounce us back here — and the
    // startup failure that sent the user down this path is now resolved.
    ref.read(needsUnlockProvider.notifier).state = false;
    ref.read(startupFailureProvider.notifier).state = null;
    context.go('/lock');
  }

  Future<void> _showRescueSheet(SecureStorageRescueSummary summary) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    summary.rebuilt
                        ? Icons.lock_open_outlined
                        : Icons.warning_amber_outlined,
                    color: Theme.of(sheetContext).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Secure storage rebuilt',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                describeRescueOutcome(summary),
                style: Theme.of(sheetContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Unlock backup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.shield_moon_outlined,
                  size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                'Restored backup detected',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Trail found an encrypted history file on this install. '
                'Enter the backup passphrase you set to unlock it.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                obscureText: _obscured,
                enabled: !_working,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Backup passphrase',
                  errorText: _error,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscured ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _working ? null : _submit,
                child: _working
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Unlock'),
              ),
              const SizedBox(height: 24),
              Text(
                'Lost the passphrase? The backup cannot be recovered — same '
                'trade-off as any end-to-end encrypted backup. You can '
                'reset and start fresh from Settings → Reset DB.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
