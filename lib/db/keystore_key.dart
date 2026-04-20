import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/passphrase_service.dart';

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
///   - Keystore mode: onboarding generates a fresh random key → old DB
///     becomes unreadable → user re-does onboarding.
///   - Passphrase mode: salt file is restored from auto-backup, secure
///     storage is empty, DB is restored and still encrypted with the
///     derived key. Entering the passphrase re-derives and re-persists
///     the key, and history is recovered.
class KeystoreKey {
  static const _storageKey = 'trail_db_passphrase_v1';
  static final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Returns the stored key, or `null` if none is stored. Never generates.
  /// Use this when the caller needs to decide between "proceed" and
  /// "prompt for passphrase".
  static Future<String?> read() async {
    final v = await _secure.read(key: _storageKey);
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Returns the existing key, or generates + persists a new random one
  /// **only if passphrase mode is not active**. If the salt file exists
  /// but secure storage is empty (the post-restore case), returns `null`
  /// so the caller can route to the passphrase-entry flow rather than
  /// silently overwriting with a random key that would never decrypt
  /// the restored DB.
  static Future<String?> getOrCreate() async {
    final existing = await read();
    if (existing != null) return existing;
    if (await PassphraseService.isEnabled()) {
      // Passphrase mode, no key stored → caller must unlock.
      return null;
    }
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
