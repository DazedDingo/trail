import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/keystore_key.dart';
import '../services/passphrase_recovery_service.dart';
import '../services/passphrase_service.dart';
import '../services/secure_storage_migration.dart';

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

/// Seam for the passphrase-entry screen's unlock action — the whole
/// derive → verify → persist → rebuild-secure-storage flow. Overridden in
/// widget tests so it can be driven without a Keystore or SQLCipher.
final passphraseRecoveryProvider = Provider<PassphraseRecoveryService>((ref) {
  return PassphraseRecoveryService();
});

/// Seam for the recovery screen's "Try again" button. Overridden in
/// widget tests so every outcome can be driven without a Keystore.
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
///
/// "DB on disk, no key, no salt" has exactly one answer again. Between
/// 0.17.4 and 0.17.10 it had two: with the `SecureStorageMigration`
/// marker absent it reported a fourth state, `notMigrated`, on the theory
/// that `flutter_secure_storage` 11.x was reading a 9.2.4 store the 0.17.3
/// rewrite had never touched — nothing lost, so `/recover` sent the user
/// to install 0.17.3 first. That diagnosis is impossible now that the
/// library is gone, and its advice had become actively harmful: v0.17.3-105
/// carries a LOWER `versionCode` than current builds, so Android refuses
/// the install and the user would have to uninstall — which deletes the
/// encrypted log. The state now means what it says, and `keyMissing`'s
/// screen (Try again / Use backup passphrase / Start a new log) is the
/// correct, non-destructive answer to it.
///
/// **May throw**, deliberately. Every probe it calls now reports "I could
/// not look" as an exception rather than folding it into a cheerful
/// `false`/`ok`: `KeystoreKey.read` (a Keystore unwrap failure),
/// `PassphraseService.isEnabled` (the salt-file stat) and
/// `KeystoreKey.dbFileExists` (the DB stat). `runStartupGates` is the
/// only production caller and turns any of them into `/startup-failed`,
/// which is a screen the user can act on — unlike the silent
/// mis-diagnoses the swallows used to produce.
Future<StartupKeyState> computeStartupKeyState() async {
  if (await KeystoreKey.read() != null) {
    // The key reads back, so this install is healthy whatever the marker
    // says. Record one if it is missing (a device whose SharedPreferences
    // were cleared, or one that never ran a migration pass) — a working
    // install must never be gated on a bookkeeping pref, and the marker
    // is what Diagnostics renders as "migrated <date>". Costs one prefs
    // read on the happy path, next to two Keystore unwraps.
    await SecureStorageMigration.markVerified(
      present: const [KeystoreKey.storageKey],
    );
    return StartupKeyState.ok;
  }
  if (await PassphraseService.isEnabled()) return StartupKeyState.needsUnlock;
  // No key, no salt, but a log on disk: the key is genuinely unreadable.
  if (await KeystoreKey.dbFileExists()) return StartupKeyState.keyMissing;
  return StartupKeyState.ok;
}
