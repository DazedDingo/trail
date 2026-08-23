import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../services/secure_storage.dart';

import '../services/passphrase_service.dart';
import 'database.dart';

/// Thrown by [KeystoreKey.getOrCreate] when an encrypted `trail.db`
/// already exists on disk but no key is stored and no passphrase salt is
/// available to re-derive one.
class KeyMissingException implements Exception {
  const KeyMissingException();
  @override
  String toString() =>
      'KeyMissingException: trail.db exists but its encryption key is gone';
}

/// Manages the DB passphrase that SQLCipher uses to encrypt `trail.db`.
///
/// Two modes, chosen by the presence of the [PassphraseService] salt file:
///
/// **Keystore (legacy / default).** No salt file. First call generates a
/// cryptographically-strong random 32-byte key, base64url-encodes it, and
/// stores it in Android Keystore via [FlutterSecureStorage]. Subsequent
/// launches read it back. The user never sees the key.
///
/// **Passphrase (backup-enabled).** Salt file present. The derived key
/// (PBKDF2 of the user's passphrase + the salt) is persisted here the same
/// way, so the background WorkManager isolate reads it with no extra flow.
/// The critical rule: [getOrCreate] must NOT generate a random key when the
/// salt file exists — that would silently destroy the user's ability to
/// unlock a restored DB. In that case it returns `null` and the caller
/// routes to the passphrase-entry screen.
///
/// Consequences shared by both modes:
/// - Reinstalling the app clears the EncryptedSharedPreferences master key
///   (Android removes the app's Keystore entries on uninstall), so the
///   secure-storage value is gone after reinstall.
///   - Keystore mode: if the DB file came back too (auto-backup), a
///     fresh random key would leave it permanently unreadable, so
///     [getOrCreate] throws [KeyMissingException] instead and the app
///     routes to `/recover`. With no DB file it is a clean first run and
///     a new key is generated.
///   - Passphrase mode: salt file is restored from auto-backup, secure
///     storage is empty, DB is restored and still encrypted with the
///     derived key. Entering the passphrase re-derives and re-persists
///     the key, and history is recovered.
class KeystoreKey {
  static const _storageKey = 'trail_db_passphrase_v1';
  static const _secure = secureStorage;

  /// Injectable "does the encrypted DB already exist?" probe. Production
  /// answers by stat'ing the file [TrailDatabase.open] opens; tests swap
  /// in a temp-dir predicate via [setDbFileExistsForTest].
  static Future<bool> Function() _dbFileExists = _defaultDbFileExists;

  /// Whether an encrypted `trail.db` is on disk. Public so the startup
  /// gate ([computeStartupKeyState]) can ask the same question through
  /// the same seam rather than duplicating the path logic.
  static Future<bool> dbFileExists() => _dbFileExists();

  static Future<bool> _defaultDbFileExists() async {
    try {
      return await File(await TrailDatabase.dbPath()).exists();
    } catch (_) {
      // path_provider unavailable (unit tests) or a transient IO error.
      // We cannot prove a log exists, so fall back to the pre-guard
      // behaviour rather than locking a fresh install out of onboarding.
      return false;
    }
  }

  @visibleForTesting
  static void setDbFileExistsForTest(Future<bool> Function()? probe) {
    _dbFileExists = probe ?? _defaultDbFileExists;
  }

  /// Returns the stored key, or `null` if none is stored. Never generates.
  /// Use this when the caller needs to decide between "proceed" and
  /// "prompt for passphrase".
  static Future<String?> read() async {
    final v = await _secure.read(key: _storageKey);
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Returns the existing key, or generates + persists a new random one
  /// **only if passphrase mode is not active and there is no DB to
  /// orphan**. If the salt file exists but secure storage is empty (the
  /// post-restore case), returns `null` so the caller can route to the
  /// passphrase-entry flow rather than silently overwriting with a random
  /// key that would never decrypt the restored DB.
  ///
  /// Throws [KeyMissingException] when there is no key, no salt, and a
  /// `trail.db` nonetheless exists on disk — a Keystore wipe, a restore
  /// onto a new device, or a failed secure-storage upgrade. Minting a
  /// fresh random key there would leave the user's log permanently
  /// unreadable *and* hide the fact that anything went wrong, so we
  /// refuse and let the caller offer the recovery screen. Creation stays
  /// allowed only on a genuinely fresh install (no DB file).
  static Future<String?> getOrCreate() async {
    final existing = await read();
    if (existing != null) return existing;
    if (await PassphraseService.isEnabled()) {
      // Passphrase mode, no key stored → caller must unlock.
      return null;
    }
    if (await dbFileExists()) throw const KeyMissingException();
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    final key = base64UrlEncode(bytes);
    await _secure.write(key: _storageKey, value: key);
    return key;
  }

  /// Persists a caller-supplied key. Used by the passphrase setup and
  /// recovery flows: derive → verify by opening the DB → persist so the
  /// background isolate and future UI launches can read it back
  /// transparently.
  static Future<void> persist(String key) async {
    await _secure.write(key: _storageKey, value: key);
  }

  /// Whether a key is already stored. Callers interested in the broader
  /// "should I route to unlock?" question should combine this with
  /// [PassphraseService.isEnabled].
  static Future<bool> hasExisting() async {
    return await read() != null;
  }

  /// Deletes the stored key. Caller is responsible for also deleting
  /// the DB file if they intend to start fresh — otherwise the app is
  /// stuck unable to decrypt an orphan DB.
  static Future<void> reset() => _secure.delete(key: _storageKey);
}
