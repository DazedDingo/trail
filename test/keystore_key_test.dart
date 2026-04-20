import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/db/keystore_key.dart';
import 'package:trail/services/passphrase_service.dart';

/// [KeystoreKey] calls `flutter_secure_storage` which internally talks to a
/// native MethodChannel. There's no DI seam in the class (the secure-storage
/// instance is a `static final`), so we fake the platform channel directly.
///
/// The channel name + method names are lifted from
/// `flutter_secure_storage_platform_interface`. Keep them in sync if the
/// package is ever bumped.
const _channelName = 'plugins.it_nomads.com/flutter_secure_storage';
const _storageKey = 'trail_db_passphrase_v1';

class _FakeSecureStorage {
  final Map<String, String> _store = {};
  final List<MethodCall> calls = [];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return _store[key];
      case 'write':
        _store[key!] = args['value'] as String;
        return null;
      case 'delete':
        _store.remove(key);
        return null;
      case 'containsKey':
        return _store.containsKey(key);
      case 'readAll':
        return Map<String, String>.from(_store);
      case 'deleteAll':
        _store.clear();
        return null;
      default:
        return null;
    }
  }

  void preset(String value) => _store[_storageKey] = value;
  void clear() => _store.clear();
  String? current() => _store[_storageKey];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;

  setUp(() {
    fake = _FakeSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      null,
    );
  });

  group('KeystoreKey.getOrCreate', () {
    test('returns the existing key when one is already stored', () async {
      fake.preset('existing-passphrase-abc');
      final key = await KeystoreKey.getOrCreate();
      expect(key, 'existing-passphrase-abc');

      // Crucially, we must NOT rotate when a valid key already exists —
      // doing so would render every historical DB row unreadable.
      final writeCalls = fake.calls.where((c) => c.method == 'write').toList();
      expect(writeCalls, isEmpty, reason: 'must not overwrite existing key');
    });

    test('generates and persists a new key on first launch', () async {
      expect(fake.current(), isNull);
      final key = await KeystoreKey.getOrCreate();
      expect(key, isNotEmpty);
      expect(fake.current(), key,
          reason: 'generated key must be persisted immediately');
    });

    test('generated key is a 32-byte base64url blob (no padding)', () async {
      final key = await KeystoreKey.getOrCreate();
      // 32 bytes base64url → 43 chars, unpadded. If this drops below 256 bits
      // of entropy we want to fail loudly — SQLCipher's strength rests on it.
      final decoded = base64Url.decode(base64.normalize(key!));
      expect(decoded.length, 32,
          reason: '32 bytes = 256 bits of entropy for SQLCipher');
    });

    test('two fresh generations produce DIFFERENT keys (entropy sanity)',
        () async {
      // Two completely independent KeystoreKey.getOrCreate runs against
      // empty storage should never collide. If they ever do, Random.secure()
      // has broken or someone swapped it for a deterministic PRNG.
      final a = await KeystoreKey.getOrCreate();
      fake.clear();
      final b = await KeystoreKey.getOrCreate();
      expect(a, isNot(equals(b)));
    });

    test('treats empty string as "no key" and rotates', () async {
      // Defensive: if a previous version wrote "" (bug), we must regenerate
      // rather than hand back an empty passphrase to SQLCipher.
      fake.preset('');
      final key = await KeystoreKey.getOrCreate();
      expect(key, isNotEmpty);
      expect(fake.current(), key);
    });

    test('second call after generation returns the SAME key (idempotent)',
        () async {
      final first = await KeystoreKey.getOrCreate();
      final second = await KeystoreKey.getOrCreate();
      expect(second, first,
          reason: 'a second launch must re-read, not regenerate');
    });

    test('writes under the versioned storage key `trail_db_passphrase_v1`',
        () async {
      // The "_v1" suffix is a deliberate future-proofing seam — if we ever
      // rotate the key derivation scheme we bump the suffix and leave the
      // old entry intact for a migration pass. Changing this key silently
      // would orphan every installed user's encrypted DB.
      await KeystoreKey.getOrCreate();
      final write = fake.calls.singleWhere((c) => c.method == 'write');
      final args = (write.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'trail_db_passphrase_v1');
    });
  });

  group('KeystoreKey.hasExisting', () {
    test('true when a non-empty key is stored', () async {
      fake.preset('something');
      expect(await KeystoreKey.hasExisting(), isTrue);
    });

    test('false when storage is empty (fresh install / Keystore wiped)',
        () async {
      expect(await KeystoreKey.hasExisting(), isFalse);
    });

    test('false when stored value is the empty string', () async {
      // Same defensive contract as getOrCreate — empty string is treated as
      // "no key", which lets the "reset DB" UI offer a recovery path.
      fake.preset('');
      expect(await KeystoreKey.hasExisting(), isFalse);
    });

    test('does not itself generate a key as a side-effect', () async {
      await KeystoreKey.hasExisting();
      expect(fake.calls.any((c) => c.method == 'write'), isFalse,
          reason: 'hasExisting is a probe, never a mutator');
      expect(fake.current(), isNull);
    });
  });

  group('KeystoreKey.reset', () {
    test('deletes the stored passphrase', () async {
      fake.preset('to-be-wiped');
      await KeystoreKey.reset();
      expect(fake.current(), isNull);
    });

    test('is a no-op when there is nothing to delete', () async {
      // flutter_secure_storage's delete is idempotent; we mirror that so the
      // "reset DB" recovery flow never throws on an already-empty store.
      await KeystoreKey.reset();
      expect(fake.current(), isNull);
    });

    test('calls delete on the platform channel with the versioned key',
        () async {
      fake.preset('x');
      await KeystoreKey.reset();
      final del = fake.calls.singleWhere((c) => c.method == 'delete');
      final args = (del.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'trail_db_passphrase_v1');
    });

    test('after reset, getOrCreate generates a fresh key', () async {
      fake.preset('original');
      await KeystoreKey.reset();
      final fresh = await KeystoreKey.getOrCreate();
      expect(fresh, isNot('original'));
      expect(fresh, isNotEmpty);
    });
  });

  group('KeystoreKey.read', () {
    test('returns the stored value when one exists', () async {
      fake.preset('stored-key');
      expect(await KeystoreKey.read(), 'stored-key');
    });

    test('returns null when storage is empty', () async {
      expect(await KeystoreKey.read(), isNull);
    });

    test('returns null for empty string (treated as "not set")', () async {
      fake.preset('');
      expect(await KeystoreKey.read(), isNull);
    });

    test('never writes as a side-effect', () async {
      await KeystoreKey.read();
      expect(fake.calls.any((c) => c.method == 'write'), isFalse);
    });
  });

  group('KeystoreKey.persist', () {
    test('writes the provided value under the versioned storage key', () async {
      await KeystoreKey.persist('derived-key-abc');
      expect(fake.current(), 'derived-key-abc');
      final write = fake.calls.singleWhere((c) => c.method == 'write');
      final args = (write.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'trail_db_passphrase_v1');
      expect(args['value'], 'derived-key-abc');
    });

    test('overwrites any existing value', () async {
      fake.preset('old-key');
      await KeystoreKey.persist('new-key');
      expect(fake.current(), 'new-key');
    });
  });

  group('KeystoreKey.getOrCreate — passphrase-mode aware', () {
    // These tests exercise the salt-file guard: when passphrase mode is
    // active (salt file present) AND secure storage is empty, getOrCreate
    // MUST NOT generate a random key — doing so would silently destroy the
    // user's ability to unlock a restored DB. It should return null and
    // let the caller route to the passphrase-entry screen.
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('trail_keystore_passphrase_');
      PassphraseService.setSaltDirForTest(tempDir);
    });

    tearDown(() async {
      PassphraseService.setSaltDirForTest(null);
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('returns null when salt exists and storage is empty (post-restore)',
        () async {
      await PassphraseService.generateAndPersistSalt();
      expect(fake.current(), isNull);
      final result = await KeystoreKey.getOrCreate();
      expect(result, isNull,
          reason:
              'Passphrase mode is active, no derived key stored → caller '
              'must route to /unlock rather than get a random key here.');
      expect(fake.calls.any((c) => c.method == 'write'), isFalse,
          reason: 'Must NOT silently overwrite the "needs unlock" signal.');
    });

    test('returns the stored key when salt exists and storage is populated',
        () async {
      await PassphraseService.generateAndPersistSalt();
      fake.preset('derived-from-passphrase-xyz');
      final result = await KeystoreKey.getOrCreate();
      expect(result, 'derived-from-passphrase-xyz');
    });

    test('generates a random key when salt is absent (legacy / new install)',
        () async {
      // No salt file → keystore mode → normal behaviour.
      final result = await KeystoreKey.getOrCreate();
      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(fake.current(), result);
    });
  });
}
