import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

/// Derives a SQLCipher passphrase from a user-chosen backup passphrase.
///
/// Salt lives in `trail_salt_v1.bin` alongside the DB file. Both files are
/// `include`d in the Android auto-backup rules — together they let a fresh
/// install (or a fresh device) decrypt the restored DB once the user
/// re-enters their passphrase. Without the salt, PBKDF2 output would vary
/// per install and the restored DB would be unreadable even with the
/// correct passphrase.
///
/// The presence of the salt file is also the single source of truth for
/// "is backup enabled?" — no separate flag in secure storage (that would
/// desync post-restore).
class PassphraseService {
  /// PBKDF2-SHA256 iteration count. 210,000 is OWASP 2023's minimum for
  /// SHA-256; higher is fine but adds perceptible startup latency on
  /// older devices. Changing this number is a migration — existing
  /// passphrases will stop deriving the same key.
  static const iterations = 210000;

  /// 32 bytes = 256 bits — matches the SQLCipher default key size.
  static const keyBytes = 32;

  /// 16-byte random salt. Regenerated only during setup; rotated on
  /// passphrase change via a full rekey.
  static const saltBytes = 16;

  static const _saltFileName = 'trail_salt_v1.bin';

  /// Resolved lazily so tests can override via [setSaltDirForTest].
  static Directory? _overrideDir;

  @visibleForTesting
  static void setSaltDirForTest(Directory? dir) {
    _overrideDir = dir;
  }

  static Future<Directory> _saltDir() async {
    return _overrideDir ?? await getApplicationDocumentsDirectory();
  }

  static Future<File> _saltFile() async {
    final dir = await _saltDir();
    return File(p.join(dir.path, _saltFileName));
  }

  /// Whether a salt is persisted — synonymous with "passphrase mode is
  /// active". Callers use this to decide between legacy Keystore-random
  /// key generation and the derive-from-passphrase path.
  ///
  /// Any filesystem / plugin failure is treated as "not enabled" so
  /// unit tests without path_provider wired up (and production
  /// devices with transient IO errors) fall through to the legacy
  /// Keystore path rather than hard-failing at startup.
  static Future<bool> isEnabled() async {
    try {
      final f = await _saltFile();
      return f.exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns the persisted salt, or null if passphrase mode has never
  /// been set up on this install.
  static Future<Uint8List?> readSalt() async {
    final f = await _saltFile();
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length != saltBytes) {
      // Corrupted or pre-v1 file — treat as missing. Caller will surface
      // this as a setup-required state.
      return null;
    }
    return bytes;
  }

  /// Creates a new random salt and persists it. Caller is responsible
  /// for immediately deriving the key and rekeying the DB; a salt with
  /// no matching key is useless and would trigger the "recovery"
  /// startup path on the next launch.
  static Future<Uint8List> generateAndPersistSalt() async {
    final rnd = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(saltBytes, (_) => rnd.nextInt(256)),
    );
    final f = await _saltFile();
    await f.writeAsBytes(salt, flush: true);
    return salt;
  }

  /// Removes the salt file. Only called when the user explicitly
  /// disables backup or resets the DB — otherwise the file must
  /// outlive uninstall via auto-backup.
  static Future<void> deleteSalt() async {
    final f = await _saltFile();
    if (await f.exists()) await f.delete();
  }

  /// PBKDF2-HMAC-SHA256. Returns a base64url-encoded 32-byte key suitable
  /// for passing to `sqflite_sqlcipher`'s `password:` parameter.
  ///
  /// Base64url (not hex) matches the format of the legacy Keystore-random
  /// key, so the rest of the pipeline (`KeystoreKey.persist`, SQLCipher
  /// PRAGMA, background-isolate reads) is format-agnostic between modes.
  static String deriveKey(String passphrase, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, keyBytes));
    final out = pbkdf2.process(Uint8List.fromList(utf8.encode(passphrase)));
    return base64UrlEncode(out);
  }

  /// Convenience: enforce the minimum length we allow on set-up. The
  /// backup is only as strong as the passphrase — shorter than this and
  /// PBKDF2's work factor can be brute-forced offline by anyone who
  /// grabs the Google Drive backup blob.
  static const minPassphraseLength = 12;

  static String? validate(String passphrase) {
    if (passphrase.length < minPassphraseLength) {
      return 'Passphrase must be at least $minPassphraseLength characters.';
    }
    return null;
  }
}
