import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/database.dart';
import '../db/keystore_key.dart';
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

/// Synchronous flag, overridden at startup exactly like
/// [keyMissingProvider]. `true` = this build's `flutter_secure_storage`
/// (11.x) cannot read what is on disk because the 0.17.3 rewrite never
/// ran, so `/recover` shows the "install 0.17.3 first" variant instead of
/// the generic key-loss copy.
final notMigratedProvider = StateProvider<bool>((ref) => false);

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

/// Seam for the recovery screen's "Get Trail 0.17.3" link. Overridden in
/// widget tests so the variant can be exercised without a url_launcher
/// platform channel.
final launchUrlProvider = Provider<Future<bool> Function(Uri)>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});

/// The four ways startup can find the SQLCipher key.
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

  /// Same shape as [keyMissing] — DB on disk, no key, no salt — but the
  /// `SecureStorageMigration` marker is absent too, so the likely cause
  /// is this build (`flutter_secure_storage` 11.x) reading a store that
  /// release A never rewrote: 11.x dropped every branch that could read
  /// 9.2.4's Jetpack data, and the old values simply read back as `null`.
  /// Nothing is lost — the bytes are still in the prefs file — so the
  /// recovery screen sends the user to install 0.17.3 first rather than
  /// offering "start a new log".
  notMigrated,
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
/// **May throw**, deliberately. Every probe it calls now reports "I could
/// not look" as an exception rather than folding it into a cheerful
/// `false`/`ok`: `KeystoreKey.read` (a Keystore unwrap failure),
/// `PassphraseService.isEnabled` (the salt-file stat) and
/// `KeystoreKey.dbFileExists` (the DB stat). `runStartupGates` is the
/// only production caller and turns any of them into `/startup-failed`,
/// which is a screen the user can act on — unlike the four silent
/// mis-diagnoses the swallows used to produce.
Future<StartupKeyState> computeStartupKeyState() async {
  if (await KeystoreKey.read() != null) {
    // The key reads back under 11.x's ciphers, so this install is on the
    // new format whatever the marker says. Record one if it is missing
    // (a device that jumped straight to B and had nothing to migrate, or
    // one whose SharedPreferences were cleared) — a working install must
    // never be gated on a bookkeeping pref. Costs one prefs read on the
    // happy path, next to two Keystore unwraps.
    await SecureStorageMigration.markVerified(
      present: const [KeystoreKey.storageKey],
    );
    return StartupKeyState.ok;
  }
  if (await PassphraseService.isEnabled()) return StartupKeyState.needsUnlock;
  if (await KeystoreKey.dbFileExists()) {
    // No key, no salt, but a log on disk. If release A's marker is absent
    // this is very likely 11.x looking at an un-rewritten 9.2.4 store
    // (reads come back `null`, nothing throws and nothing is deleted) —
    // a different problem with a different, non-destructive answer.
    if (await SecureStorageMigration.readMarker() == null) {
      return StartupKeyState.notMigrated;
    }
    return StartupKeyState.keyMissing;
  }
  return StartupKeyState.ok;
}
