import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../db/database.dart';
import '../db/keystore_key.dart';
import '../providers/backup_provider.dart';
import '../services/passphrase_service.dart';

/// Gate shown when Trail's DB has been restored (from Android auto-backup)
/// onto a fresh install, but the user hasn't yet supplied the backup
/// passphrase needed to decrypt it.
///
/// Flow:
///   1. Read the restored salt (`PassphraseService.readSalt`).
///   2. Derive a candidate key from the entered passphrase.
///   3. Probe-open the DB with that key — if it's wrong, SQLCipher surfaces
///      `file is not a database` on the first query, which we catch and
///      report as "wrong passphrase".
///   4. On success, persist the derived key to secure storage so the
///      background isolate and future launches read it transparently,
///      invalidate the memoised handle, and route to `/home`.
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
    final entered = _controller.text;
    if (entered.isEmpty) {
      setState(() => _error = 'Enter your backup passphrase.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final salt = await PassphraseService.readSalt();
      if (salt == null) {
        setState(() {
          _working = false;
          _error =
              'Salt file missing — backup data is incomplete. Reset DB in settings.';
        });
        return;
      }
      final derived = PassphraseService.deriveKey(entered, salt);
      // Probe the DB: open + cheap query forces SQLCipher to verify the
      // key. Wrong passphrase → `SqfliteFfiException` / `DatabaseException`
      // with "file is not a database" or similar.
      final db = await TrailDatabase.openWithKey(derived);
      try {
        await db.rawQuery('SELECT count(*) FROM pings');
      } finally {
        await db.close();
      }
      await KeystoreKey.persist(derived);
      await TrailDatabase.invalidateShared();
      if (!mounted) return;
      // Flip the router's gate so the next redirect lets us through to
      // the lock screen instead of bouncing us back to /unlock.
      ref.read(needsUnlockProvider.notifier).state = false;
      context.go('/lock');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('file is not a database') ||
        s.contains('file is encrypted') ||
        s.contains('not a database')) {
      return 'Passphrase did not unlock the backup. Try again.';
    }
    return 'Unlock failed: $e';
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
