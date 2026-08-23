import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../services/key_escrow.dart';
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

/// Thrown by [KeystoreKey.persist] when neither secure storage nor the
/// key escrow would accept the key. Both homes failing at once is the
/// only state in which the caller must NOT report a successful unlock:
/// the DB opened, but nothing on the device remembers how.
class KeyPersistException implements Exception {
  const KeyPersistException({
    required this.secureStorageError,
    required this.escrowError,
  });

  final String secureStorageError;
  final String escrowError;

  @override
  String toString() => 'KeyPersistException: neither secure storage nor the '
      'key escrow stored the database key '
      '(secure storage: $secureStorageError; escrow: $escrowError)';
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
  /// The secure-storage key holding the SQLCipher passphrase. Public so
  /// the startup gate can name it when it records the secure-storage
  /// marker (`SecureStorageMigration.markVerified`) for an install that
  /// is already on the new format.
  static const storageKey = 'trail_db_passphrase_v1';
  static const _secure = secureStorage;

  /// Injectable "does the encrypted DB already exist?" probe. Production
  /// answers by stat'ing the file [TrailDatabase.open] opens; tests swap
  /// in a temp-dir predicate via [setDbFileExistsForTest].
  static Future<bool> Function() _dbFileExists = _defaultDbFileExists;

  /// Whether an encrypted `trail.db` is on disk. Public so the startup
  /// gate ([computeStartupKeyState]) can ask the same question through
  /// the same seam rather than duplicating the path logic.
  ///
  /// Never answers `false` for "I could not tell" — see
  /// [_defaultDbFileExists].
  static Future<bool> dbFileExists() => _dbFileExists();

  /// Throws [StateError] when the question cannot be answered at all
  /// (path_provider unregistered, a storage-layer error). It used to
  /// answer `false` there, which is the single most dangerous lie in
  /// this file: "no DB on disk" is exactly the condition under which
  /// [getOrCreate] is allowed to mint a fresh random key, so a failed
  /// `stat` could orphan a real log. "I could not look" is not "there is
  /// nothing there" — the caller (the startup gate, and through it
  /// `runStartupGates`) turns the throw into `/startup-failed`.
  static Future<bool> _defaultDbFileExists() async {
    try {
      return await File(await TrailDatabase.dbPath()).exists();
    } catch (e) {
      throw StateError('cannot determine whether trail.db exists: $e');
    }
  }

  @visibleForTesting
  static void setDbFileExistsForTest(Future<bool> Function()? probe) {
    _dbFileExists = probe ?? _defaultDbFileExists;
  }

  /// [lastReadSource] when the key came straight out of secure storage.
  static const sourceSecureStorage = 'secure storage';

  /// [lastReadSource] when secure storage could not produce the key and
  /// Trail's own escrow did (`lib/services/key_escrow.dart`).
  static const sourceEscrow = 'escrow';

  /// Where the most recent successful [read] got the key from — one of
  /// [sourceSecureStorage] / [sourceEscrow], or `null` when nothing has
  /// been read yet or nothing was found. Diagnostics renders it; nothing
  /// branches on it.
  static String? lastReadSource;

  /// Text of the last secure-storage read that *threw*, kept for the same
  /// Diagnostics line. A throw here is the 0.17.5 incident's signature.
  static String? lastSecureStorageError;

  /// Text of the last escrow read that reported an error (a bad GCM tag,
  /// an invalidated alias, or `MissingPluginException` in the WorkManager
  /// isolate, which has no handler for our channel).
  static String? lastEscrowError;

  /// Returns the stored key, or `null` if none is stored. Never generates.
  /// Use this when the caller needs to decide between "proceed" and
  /// "prompt for passphrase".
  ///
  /// Two-source read since 0.17.6. Secure storage is still the primary,
  /// but neither of its failure modes is trusted on its own:
  ///
  /// * a **throw** (the 0.17.5 incident — a read that threw/hung after
  ///   the `flutter_secure_storage` 10 → 11 upgrade), and
  /// * a **silent null**, which is what 11.x returns for data written by
  ///   9.x and what a lost Jetpack master key returns for everything
  ///   (gotcha 37) — indistinguishable from "no key was ever stored".
  ///
  /// Both fall through to [KeyEscrow], Trail's own copy. A hit is
  /// best-effort written back into secure storage so the next launch is
  /// a normal one; that write is allowed to fail silently, because the
  /// escrow will simply serve the key again.
  ///
  /// A throw that the escrow **cannot** rescue is re-thrown, not turned
  /// into `null`: gotcha 30's startup gate exists to route exactly that
  /// to `/startup-failed`, and a swallowed throw would look to
  /// [getOrCreate] like "no key was ever stored" — the one state in
  /// which it is allowed to mint a fresh one.
  static Future<String?> read() async {
    String? v;
    try {
      v = await _secure.read(key: storageKey);
    } catch (e) {
      debugPrint('secure storage read failed: $e');
      lastSecureStorageError = '$e';
      final rescued = await _readFromEscrow();
      if (rescued != null) return rescued;
      rethrow;
    }
    if (v != null && v.isNotEmpty) {
      lastReadSource = sourceSecureStorage;
      return v;
    }
    return _readFromEscrow();
  }

  /// Never throws: [KeyEscrow.load] is total, and the re-persist is
  /// wrapped. Returns `null` for both "escrow is empty" and "escrow could
  /// not be read" — the difference is recorded in [lastEscrowError] and
  /// surfaced in Diagnostics, but neither is a key.
  static Future<String?> _readFromEscrow() async {
    final result = await KeyEscrow.instance.load();
    if (result.error != null) {
      lastEscrowError = result.error;
      debugPrint('key escrow read failed: ${result.error}');
      return null;
    }
    final key = result.key;
    if (key == null || key.isEmpty) return null;
    lastReadSource = sourceEscrow;
    try {
      await _secure.write(key: storageKey, value: key);
    } catch (e) {
      // Expected whenever secure storage is the thing that is broken.
      debugPrint('secure storage re-persist from escrow failed: $e');
    }
    return key;
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
  ///
  /// Throws whatever the two probes throw, too: if [dbFileExists] or
  /// [PassphraseService.isEnabled] cannot answer, this method must not
  /// guess. Generating a key on a "probably fresh" install is the one
  /// mistake that cannot be undone.
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
    await _secure.write(key: storageKey, value: key);
    return key;
  }

  /// Persists a caller-supplied key to **both** homes (gotcha 38): the
  /// escrow first, then secure storage. Used by the passphrase setup and
  /// recovery flows: derive → verify by opening the DB → persist so the
  /// background isolate and future UI launches can read it back
  /// transparently.
  ///
  /// Escrow first on purpose. In the 2026-08-23 incident every
  /// `flutter_secure_storage` call is a chance for its
  /// `createRSAKeysIfNeeded` to regenerate the RSA pair and orphan the
  /// store for good; the verified key must already be somewhere safe
  /// before we poke it. A secure-storage write that throws is then
  /// **swallowed** (logged, and recorded in [lastSecureStorageError] —
  /// which is also how `PassphraseRecoveryService` detects "the plugin is
  /// the broken part") as long as the escrow accepted the key. A
  /// successful write clears that field: the store demonstrably works
  /// now, so a stale read error must not keep claiming otherwise.
  ///
  /// Throws [KeyPersistException] only when **neither** home took it —
  /// the one case where the caller must not tell the user their log is
  /// unlocked, because the next launch would find no key at all.
  static Future<void> persist(String key) async {
    Object? escrowError;
    try {
      await KeyEscrow.instance.store(key);
    } catch (e) {
      escrowError = e;
      lastEscrowError = '$e';
      debugPrint('key escrow persist failed: $e');
    }
    try {
      await _secure.write(key: storageKey, value: key);
      lastSecureStorageError = null;
    } catch (e) {
      debugPrint('secure storage persist failed: $e');
      lastSecureStorageError = '$e';
      if (escrowError != null) {
        throw KeyPersistException(secureStorageError: '$e', escrowError: '$escrowError');
      }
    }
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
  static Future<void> reset() => _secure.delete(key: storageKey);
}
