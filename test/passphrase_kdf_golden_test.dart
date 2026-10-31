import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/passphrase_service.dart';

/// A golden vector for the passphrase → SQLCipher key derivation.
///
/// `passphrase_service_test.dart` already proves the derivation is
/// deterministic and sensitive to both inputs. That is not enough: it
/// compares pointycastle against itself, so a library upgrade that
/// changed the output would keep every one of those tests green while
/// silently making every existing passphrase-mode install unopenable.
/// Passphrase mode is the DB key's last line of defence — it is what
/// saved the log during the 2026-08-23 Keystore incident — so the exact
/// bytes are pinned here against an expectation computed OUTSIDE Dart:
///
/// ```
/// python3 -c "import hashlib,base64; print(base64.urlsafe_b64encode(
///   hashlib.pbkdf2_hmac('sha256', b'correct horse battery staple',
///                       bytes(range(16)), 210000, 32)).decode())"
/// ```
///
/// If this test ever fails, do NOT update the expected string. Either the
/// parameters in [PassphraseService] changed (iterations, key length,
/// digest, encoding) or the crypto library's PBKDF2 changed behaviour.
/// Both mean existing users can no longer derive their own key, which is
/// permanent data loss, not a test to fix.
void main() {
  group('PassphraseService.deriveKey — golden vector', () {
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));

    test('matches PBKDF2-HMAC-SHA256 computed by an independent library',
        () {
      expect(
        PassphraseService.deriveKey('correct horse battery staple', salt),
        'GEZcreCWwYW19gdliR_KP3RHfiP9m2_Ij694MakXU6w=',
      );
    });

    test('the parameters that vector depends on are unchanged', () {
      // Pinned separately so a failure says WHICH input moved rather than
      // just "the bytes differ".
      expect(PassphraseService.iterations, 210000);
      expect(PassphraseService.keyBytes, 32);
    });

    test('a non-ASCII passphrase is UTF-8 encoded, not truncated', () {
      // Same Python one-liner with b'p\xc3\xa4ssw\xc3\xb6rd'.
      expect(
        PassphraseService.deriveKey('pässwörd', salt),
        'uge_QUpUNqzW3H-cJYT7K5r1EvzfLpg0OD-P1sdYtw0=',
      );
    });
  });
}
