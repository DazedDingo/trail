import 'package:flutter/services.dart';

/// Wraps a list of plaintext export files in a single AES-256
/// encrypted zip via the native `EncryptedZipPlugin` (zip4j).
///
/// Why a method channel and not pure Dart: the goal is "open with any
/// off-the-shelf unzip tool" — 7-Zip, macOS Archive Utility, Linux
/// `7z`, Android's built-in file managers. That's the WinZip AES
/// extension, and there's no maintained pure-Dart implementation. The
/// previous `TRLENC01` format was bespoke and required a Python
/// decrypt script; users rejected the friction.
///
/// The zip's per-entry filenames are visible (zip metadata isn't
/// encrypted by AES-256 ZipCrypto), but the file *contents* are
/// AES-256 encrypted — fine for `trail-2026-04.gpx` since the name
/// gives away nothing the recipient doesn't already know.
class EncryptedExportService {
  static const _channel =
      MethodChannel('com.dazeddingo.trail/encrypted_zip');

  /// Bundles [inputPaths] into a single encrypted zip at [outputPath]
  /// using [passphrase]. Returns the path to the produced zip
  /// (== [outputPath]).
  ///
  /// Throws [PlatformException] on zip4j errors (disk full, bad path,
  /// etc.) — caller should surface a friendly message.
  static Future<String> createZip({
    required List<String> inputPaths,
    required String outputPath,
    required String passphrase,
  }) async {
    final out = await _channel.invokeMethod<String>('createZip', {
      'inputs': inputPaths,
      'output': outputPath,
      'passphrase': passphrase,
    });
    return out ?? outputPath;
  }

  /// Sane heuristic for the passphrase prompt — accepts anything
  /// the user has the patience to type, but warns below 8 chars
  /// because zip4j's PBKDF2 work factor is the only thing standing
  /// between the file and a determined offline attacker.
  static String? validatePassphrase(String? input) {
    final t = input ?? '';
    if (t.isEmpty) return 'Required';
    if (t.length < 8) return 'Use at least 8 characters';
    return null;
  }
}
