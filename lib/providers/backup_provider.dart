import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/keystore_key.dart';
import '../services/passphrase_service.dart';

/// Reflects whether the "cloud backup passphrase" mode is active on this
/// install. Single source of truth is the salt file — this provider just
/// probes it.
///
/// The settings screen invalidates this provider after the user completes
/// the setup / disable flow so the tile repaints without a restart.
final backupEnabledProvider = FutureProvider<bool>((ref) async {
  return PassphraseService.isEnabled();
});

/// Synchronous flag read once at startup by [main] and overridden into the
/// ProviderScope so the router can consult it inside `redirect` without
/// async plumbing. `true` = the DB needs the user's backup passphrase
/// before it can open (post-restore case).
final needsUnlockProvider = StateProvider<bool>((ref) => false);

/// Computed at startup: the DB needs unlocking iff passphrase mode is
/// active (salt file present) AND there's no key in secure storage.
/// Every other combination is a healthy startup.
Future<bool> computeNeedsUnlock() async {
  if (!await PassphraseService.isEnabled()) return false;
  final stored = await KeystoreKey.read();
  return stored == null;
}
