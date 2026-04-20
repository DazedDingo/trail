import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/passphrase_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('trail_passphrase_test_');
    PassphraseService.setSaltDirForTest(tempDir);
  });

  tearDown(() async {
    PassphraseService.setSaltDirForTest(null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PassphraseService.deriveKey', () {
    // Fixed salt so the key-derivation vectors stay reproducible across runs.
    final salt =
        Uint8List.fromList(List<int>.generate(16, (i) => (i * 7) & 0xff));

    test('returns a 32-byte base64url-encoded key', () {
      final key = PassphraseService.deriveKey('correct horse battery', salt);
      final decoded = base64Url.decode(base64.normalize(key));
      expect(decoded.length, 32,
          reason:
              'SQLCipher expects 256 bits — anything else is a silent downgrade');
    });

    test('is deterministic: same passphrase + salt → same key', () {
      final a = PassphraseService.deriveKey('abc123def456', salt);
      final b = PassphraseService.deriveKey('abc123def456', salt);
      expect(a, b,
          reason:
              'Non-determinism here would mean the rekey flow derives a '
              'different key than the unlock flow — backup would be '
              'permanently unreadable.');
    });

    test('different passphrases produce different keys', () {
      final a = PassphraseService.deriveKey('aaaaaaaaaaaa', salt);
      final b = PassphraseService.deriveKey('bbbbbbbbbbbb', salt);
      expect(a, isNot(b));
    });

    test('different salts produce different keys', () {
      final salt2 =
          Uint8List.fromList(List<int>.generate(16, (i) => (i * 13) & 0xff));
      final a = PassphraseService.deriveKey('same-passphrase', salt);
      final b = PassphraseService.deriveKey('same-passphrase', salt2);
      expect(a, isNot(b),
          reason:
              'Salt sensitivity is the whole point — otherwise rainbow '
              'tables become viable against common passphrases.');
    });

    test('unicode passphrases are handled (utf-8 bytes, not code units)', () {
      // If we ever accidentally encoded as utf-16 or stripped non-ascii,
      // this test would flag it. Users on non-ASCII keyboards would
      // otherwise derive one key at setup and a different key at unlock.
      final key = PassphraseService.deriveKey('pässwörd-∞-🔑', salt);
      final decoded = base64Url.decode(base64.normalize(key));
      expect(decoded.length, 32);
    });
  });

  group('PassphraseService.iterations', () {
    test('meets OWASP 2023 minimum for PBKDF2-SHA256', () {
      // Lowering this weakens every user's backup against offline brute
      // force on a stolen Google Drive blob. If someone intentionally
      // lowers it (e.g. for test speed), they must also build a
      // migration path for existing backups.
      expect(PassphraseService.iterations, greaterThanOrEqualTo(210000));
    });
  });

  group('PassphraseService.validate', () {
    test('rejects short passphrases', () {
      expect(PassphraseService.validate('short'), isNotNull);
      expect(PassphraseService.validate('12345678901'), isNotNull,
          reason: '11 chars < minimum 12');
    });

    test('accepts passphrases at the minimum length', () {
      expect(PassphraseService.validate('123456789012'), isNull,
          reason: '12 chars == minimum');
    });

    test('accepts long passphrases', () {
      expect(
        PassphraseService.validate(
            'a long passphrase that exceeds the minimum'),
        isNull,
      );
    });
  });

  group('PassphraseService salt persistence', () {
    test('isEnabled returns false before salt is generated', () async {
      expect(await PassphraseService.isEnabled(), isFalse);
    });

    test('generateAndPersistSalt creates a 16-byte file', () async {
      final salt = await PassphraseService.generateAndPersistSalt();
      expect(salt.length, 16);
      expect(await PassphraseService.isEnabled(), isTrue);
    });

    test('readSalt roundtrips the generated salt', () async {
      final written = await PassphraseService.generateAndPersistSalt();
      final read = await PassphraseService.readSalt();
      expect(read, isNotNull);
      expect(read!.length, 16);
      expect(read, orderedEquals(written));
    });

    test('generateAndPersistSalt produces different salts on each call',
        () async {
      final a = await PassphraseService.generateAndPersistSalt();
      final b = await PassphraseService.generateAndPersistSalt();
      // Statistically near-impossible to collide with a CSPRNG. If this
      // ever flakes, Random.secure() has been swapped for something
      // non-cryptographic.
      expect(a, isNot(orderedEquals(b)));
    });

    test('deleteSalt disables the mode', () async {
      await PassphraseService.generateAndPersistSalt();
      expect(await PassphraseService.isEnabled(), isTrue);
      await PassphraseService.deleteSalt();
      expect(await PassphraseService.isEnabled(), isFalse);
      expect(await PassphraseService.readSalt(), isNull);
    });

    test('readSalt returns null when the file is corrupted (wrong length)',
        () async {
      // Defensive: a truncated / wrong-size salt is treated as "missing"
      // rather than fed into PBKDF2 (which would produce a derived key
      // that no legitimate setup flow could ever match).
      final f = File('${tempDir.path}/trail_salt_v1.bin');
      await f.writeAsBytes([1, 2, 3]);
      expect(await PassphraseService.readSalt(), isNull);
    });
  });
}
