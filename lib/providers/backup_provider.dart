import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
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

/// Synchronous flag, overridden at startup exactly like
/// [needsUnlockProvider]. `true` = an encrypted `trail.db` exists but its
/// key is gone and there is no salt to re-derive one, so the router must
/// hard-gate on `/recover`.
final keyMissingProvider = StateProvider<bool>((ref) => false);

/// Seam for the recovery screen's "Try again" button. Overridden in
/// widget tests so the three outcomes can be driven without a Keystore.
final startupKeyStateProbeProvider =
    Provider<Future<StartupKeyState> Function()>((ref) {
  return computeStartupKeyState;
});

/// Seam for the recovery screen's "Start a new log" action. Returns the
/// name the DB was moved to, or `null` if there was nothing to move.
final setAsideDbProvider = Provider<Future<String?> Function()>((ref) {
  return TrailDatabase.setAsideForRecovery;
});

/// The three ways startup can find the SQLCipher key.
enum StartupKeyState {
  /// A key is stored, or this is a clean first run with no DB to open.
  ok,

  /// Passphrase mode is active (salt file present) and no key is stored —
  /// the auto-backup restore path. Route to `/unlock`.
  needsUnlock,

  /// A `trail.db` exists but there is neither a key nor a salt. Keystore
  /// wipe, restore onto a new device, or a secure-storage upgrade that
  /// dropped the value. Route to `/recover`; never mint a new key.
  keyMissing,
}

/// Computed at startup: the DB needs unlocking iff passphrase mode is
/// active (salt file present) AND there's no key in secure storage.
/// Every other combination is a healthy startup.
Future<bool> computeNeedsUnlock() async {
  if (!await PassphraseService.isEnabled()) return false;
  final stored = await KeystoreKey.read();
  return stored == null;
}

/// The startup gate, as one value. Superset of [computeNeedsUnlock]: the
/// `keyMissing` arm is the case that used to fall through to
/// `KeystoreKey.getOrCreate` minting a fresh random key over a perfectly
/// good (but now unreadable) log.
Future<StartupKeyState> computeStartupKeyState() async {
  if (await KeystoreKey.read() != null) return StartupKeyState.ok;
  if (await PassphraseService.isEnabled()) return StartupKeyState.needsUnlock;
  if (await KeystoreKey.dbFileExists()) return StartupKeyState.keyMissing;
  return StartupKeyState.ok;
}
