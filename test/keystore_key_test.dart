import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trail/db/keystore_key.dart';
import 'package:trail/services/key_escrow.dart';
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

/// Records what `KeystoreKey.persist` asks of the escrow, and can refuse
/// like a Keystore whose alias has gone. Shares [events] with the secure-
/// storage fake so the ORDER of the two writes can be asserted — the
/// escrow must go first (see the doc on `KeystoreKey.persist`).
class _RecordingEscrow extends KeyEscrow {
  _RecordingEscrow(this.events)
      : super(channel: const MethodChannel('trail/key_escrow_persist_test'));

  final List<String> events;
  final List<String> stored = [];
  bool throws = false;

  @override
  Future<void> store(String key) async {
    events.add('escrow');
    if (throws) {
      throw PlatformException(code: 'KeyStoreException', message: 'nope');
    }
    stored.add(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;
  late Directory saltDir;

  setUp(() async {
    fake = _FakeSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
    // Default every test to "no DB on disk" — the production probe goes
    // through path_provider, which is unavailable here. Individual tests
    // override it to exercise the guard.
    KeystoreKey.setDbFileExistsForTest(() async => false);
    // Likewise for the salt probe. `PassphraseService.isEnabled` no
    // longer swallows a path_provider failure into "backup is off"
    // (that lie is what let `getOrCreate` mint a key over a restored
    // log), so every test needs a real, empty directory to stat.
    saltDir = await Directory.systemTemp.createTemp('trail_keystore_salt_');
    PassphraseService.setSaltDirForTest(saltDir);
  });

  tearDown(() async {
    KeystoreKey.setDbFileExistsForTest(null);
    PassphraseService.setSaltDirForTest(null);
    if (saltDir.existsSync()) await saltDir.delete(recursive: true);
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

  group('KeystoreKey.getOrCreate — DB-present guard', () {
    // The data-safety net for the flutter_secure_storage 9 → 10 → 11
    // migration: if the store comes back empty but trail.db is still on
    // disk, minting a fresh random key would make the user's whole log
    // permanently unreadable AND hide that anything went wrong.
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('trail_keystore_dbfile_');
      dbFile = File(p.join(tempDir.path, 'trail.db'));
      KeystoreKey.setDbFileExistsForTest(() => dbFile.exists());
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('fresh install (no DB file) still creates a key', () async {
      expect(dbFile.existsSync(), isFalse);
      final key = await KeystoreKey.getOrCreate();
      expect(key, isNotNull);
      expect(fake.current(), key);
    });

    test('DB present + empty storage throws KeyMissingException', () async {
      await dbFile.writeAsString('not really SQLCipher, but it exists');
      await expectLater(
        KeystoreKey.getOrCreate(),
        throwsA(isA<KeyMissingException>()),
      );
    });

    test('DB present + empty storage writes NOTHING', () async {
      await dbFile.writeAsString('x');
      await expectLater(
        KeystoreKey.getOrCreate(),
        throwsA(isA<KeyMissingException>()),
      );
      expect(fake.calls.any((c) => c.method == 'write'), isFalse,
          reason: 'a mint here would orphan the log forever');
      expect(fake.calls.any((c) => c.method == 'delete'), isFalse);
      expect(fake.current(), isNull);
      expect(dbFile.existsSync(), isTrue, reason: 'the log is never touched');
    });

    test('DB present + key stored returns the key, no throw', () async {
      await dbFile.writeAsString('x');
      fake.preset('the-real-key');
      expect(await KeystoreKey.getOrCreate(), 'the-real-key');
    });

    test('DB present + salt file keeps the passphrase null path (no throw)',
        () async {
      // Passphrase mode is checked BEFORE the DB guard: there the user
      // has a real way back in, so /unlock wins over /recover.
      await dbFile.writeAsString('x');
      PassphraseService.setSaltDirForTest(tempDir);
      addTearDown(() => PassphraseService.setSaltDirForTest(null));
      await PassphraseService.generateAndPersistSalt();
      expect(await KeystoreKey.getOrCreate(), isNull);
      expect(fake.calls.any((c) => c.method == 'write'), isFalse);
    });

    test('after the DB is set aside, creation is allowed again', () async {
      await dbFile.writeAsString('x');
      await expectLater(
        KeystoreKey.getOrCreate(),
        throwsA(isA<KeyMissingException>()),
      );
      await dbFile.rename(p.join(tempDir.path, 'trail.db.locked-20260822-1435'));
      final key = await KeystoreKey.getOrCreate();
      expect(key, isNotNull);
      expect(fake.current(), key);
    });
  });

  group('KeystoreKey.dbFileExists', () {
    test('reflects the injected probe', () async {
      KeystoreKey.setDbFileExistsForTest(() async => true);
      expect(await KeystoreKey.dbFileExists(), isTrue);
      KeystoreKey.setDbFileExistsForTest(() async => false);
      expect(await KeystoreKey.dbFileExists(), isFalse);
    });

    test('null resets to the production probe, which throws off-device',
        () async {
      // path_provider is not registered under `flutter test`, so the
      // production probe cannot answer. It used to swallow that into
      // `false` — "no DB on disk" — which is precisely the condition
      // that lets `getOrCreate` mint a fresh random key. "I could not
      // look" must be loud.
      KeystoreKey.setDbFileExistsForTest(null);
      await expectLater(
        KeystoreKey.dbFileExists(),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('cannot determine whether trail.db exists'))),
      );
    });
  });

  group('KeystoreKey.getOrCreate — a probe that cannot answer', () {
    // The rule these pin: when Trail cannot tell whether a log exists,
    // or whether passphrase mode is on, it refuses to guess. Guessing
    // "fresh install" writes a random key that no restored DB will ever
    // open again.
    test('a throwing DB probe propagates and writes NOTHING', () async {
      KeystoreKey.setDbFileExistsForTest(
        () async => throw StateError('cannot determine whether trail.db exists'),
      );
      await expectLater(
        KeystoreKey.getOrCreate(),
        throwsA(isA<StateError>()),
      );
      expect(fake.calls.any((c) => c.method == 'write'), isFalse,
          reason: 'a key minted here could orphan a real log');
      expect(fake.current(), isNull);
    });

    test('a salt probe that cannot resolve its directory propagates',
        () async {
      // The production "path_provider is not registered" path.
      PassphraseService.setSaltDirForTest(null);
      await expectLater(KeystoreKey.getOrCreate(), throwsA(anything));
      expect(fake.calls.any((c) => c.method == 'write'), isFalse);
      expect(fake.current(), isNull);
    });

    test('an existing key short-circuits both probes', () async {
      // `getOrCreate` reads first; a healthy install never reaches the
      // probes, so a broken filesystem cannot lock it out.
      fake.preset('already-here');
      KeystoreKey.setDbFileExistsForTest(() async => throw StateError('nope'));
      PassphraseService.setSaltDirForTest(null);
      expect(await KeystoreKey.getOrCreate(), 'already-here');
    });
  });

  group('KeystoreKey.read — key escrow fallback (0.17.6)', () {
    // The 0.17.5 incident: a secure-storage read that threw left the app
    // with no key at all, and the key is the only way into the user's
    // whole log. Trail now keeps its own escrowed copy
    // (`lib/services/key_escrow.dart`, MethodChannel `trail/key_escrow`)
    // and `read` consults it on BOTH secure-storage failure modes — a
    // throw, and a silent null (which is what fss 11 returns for 9.x data
    // and what a lost Jetpack master key returns for everything).
    const escrowChannel = 'trail/key_escrow_keystore_test';

    late List<MethodCall> escrowCalls;
    late List<MethodCall> secureCalls;
    String? escrowedKey;
    String? escrowFailure;

    void installEscrow() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(escrowChannel),
        (call) async {
          escrowCalls.add(call);
          if (escrowFailure != null) {
            throw PlatformException(code: escrowFailure!);
          }
          switch (call.method) {
            case 'load':
              final key = escrowedKey;
              return key == null ? null : Uint8List.fromList(utf8.encode(key));
            case 'status':
              return <String, Object?>{
                'present': escrowedKey != null,
                'storedAt': escrowedKey == null ? null : 1755900000000,
                'aliasExists': escrowedKey != null,
                'keySha256': escrowedKey == null
                    ? null
                    : KeyEscrow.fingerprintOf(escrowedKey!),
              };
            default:
              return null;
          }
        },
      );
    }

    /// Replaces the outer fake with one whose `read` throws — the exact
    /// shape of the incident this feature exists for.
    void makeSecureStorageReadThrow() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async {
          secureCalls.add(call);
          if (call.method == 'read') {
            throw PlatformException(
              code: 'Exception encountered',
              message: 'accessing FlutterSecureStorage',
            );
          }
          return null;
        },
      );
    }

    setUp(() {
      escrowCalls = [];
      secureCalls = [];
      escrowedKey = null;
      escrowFailure = null;
      KeystoreKey.lastReadSource = null;
      KeystoreKey.lastSecureStorageError = null;
      KeystoreKey.lastEscrowError = null;
      installEscrow();
      KeyEscrow.setInstanceForTest(
        const KeyEscrow(channel: MethodChannel(escrowChannel)),
      );
    });

    tearDown(() {
      KeyEscrow.setInstanceForTest(null);
      KeystoreKey.lastReadSource = null;
      KeystoreKey.lastSecureStorageError = null;
      KeystoreKey.lastEscrowError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(escrowChannel),
        null,
      );
    });

    test('secure storage throws + escrow has the key → key is returned',
        () async {
      escrowedKey = 'escrowed-key-abc';
      makeSecureStorageReadThrow();
      expect(await KeystoreKey.read(), 'escrowed-key-abc');
    });

    test('a throw records the source as escrow and keeps the error text',
        () async {
      escrowedKey = 'escrowed-key-abc';
      makeSecureStorageReadThrow();
      await KeystoreKey.read();
      expect(KeystoreKey.lastReadSource, KeystoreKey.sourceEscrow);
      expect(KeystoreKey.lastSecureStorageError, contains('PlatformException'));
    });

    test('a throw re-persists the escrowed key back into secure storage',
        () async {
      escrowedKey = 'escrowed-key-abc';
      makeSecureStorageReadThrow();
      await KeystoreKey.read();
      final writes = secureCalls.where((c) => c.method == 'write').toList();
      expect(writes, hasLength(1),
          reason: 'best-effort heal so the next launch is a normal one');
      final args = (writes.single.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'trail_db_passphrase_v1');
      expect(args['value'], 'escrowed-key-abc');
    });

    test('a re-persist that also throws still returns the key', () async {
      escrowedKey = 'escrowed-key-abc';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async {
          secureCalls.add(call);
          throw PlatformException(code: 'Exception encountered');
        },
      );
      expect(await KeystoreKey.read(), 'escrowed-key-abc',
          reason: 'a broken store must not veto the escrow');
    });

    test('secure storage returns null + escrow has the key → key', () async {
      // fss 11 reads 9.x data as a silent null (gotcha 37) — never assume
      // null means "the user never had a key".
      escrowedKey = 'silently-lost-key';
      expect(await KeystoreKey.read(), 'silently-lost-key');
      expect(KeystoreKey.lastReadSource, KeystoreKey.sourceEscrow);
      expect(fake.current(), 'silently-lost-key',
          reason: 'the silent-null path heals secure storage too');
    });

    test('secure storage null + escrow empty → null', () async {
      expect(await KeystoreKey.read(), isNull);
      expect(KeystoreKey.lastReadSource, isNull);
      expect(escrowCalls.map((c) => c.method), contains('load'));
    });

    test('secure storage null + escrow empty still hits the DB-present '
        'guard', () async {
      // The escrow must not weaken the "never mint a key over an existing
      // log" rule — with nothing anywhere, getOrCreate still refuses.
      KeystoreKey.setDbFileExistsForTest(() async => true);
      await expectLater(
        KeystoreKey.getOrCreate(),
        throwsA(isA<KeyMissingException>()),
      );
      expect(fake.current(), isNull);
    });

    test('a throw the escrow cannot rescue is re-thrown, never nulled',
        () async {
      // Gotcha 30: a read that FAILED is not a read that found nothing.
      // Swallowing it would look to getOrCreate like a fresh install and
      // hide the failure from the /startup-failed gate.
      makeSecureStorageReadThrow();
      await expectLater(KeystoreKey.read(), throwsA(isA<PlatformException>()));
      expect(KeystoreKey.lastReadSource, isNull);
    });

    test('a throw with an unreadable escrow is re-thrown too', () async {
      escrowFailure = 'AEADBadTagException';
      makeSecureStorageReadThrow();
      await expectLater(KeystoreKey.read(), throwsA(isA<PlatformException>()));
      expect(KeystoreKey.lastEscrowError, contains('AEADBadTagException'));
    });

    test('an escrow that errors is not treated as "no key ever existed"',
        () async {
      escrowFailure = 'AEADBadTagException';
      expect(await KeystoreKey.read(), isNull);
      expect(KeystoreKey.lastEscrowError, contains('AEADBadTagException'));
      expect(KeystoreKey.lastReadSource, isNull);
    });

    test('no escrow handler (WorkManager isolate) degrades to null, '
        'no throw', () async {
      KeyEscrow.setInstanceForTest(
        const KeyEscrow(channel: MethodChannel('trail/key_escrow_absent')),
      );
      expect(await KeystoreKey.read(), isNull);
      expect(KeystoreKey.lastEscrowError, 'MissingPluginException');
    });

    test('secure storage answers → the escrow is never consulted', () async {
      fake.preset('healthy-key');
      expect(await KeystoreKey.read(), 'healthy-key');
      expect(KeystoreKey.lastReadSource, KeystoreKey.sourceSecureStorage);
      expect(escrowCalls, isEmpty,
          reason: 'the hot path must not pay for the hedge');
    });

    test('getOrCreate served from the escrow does not mint a new key',
        () async {
      escrowedKey = 'escrowed-key-abc';
      KeystoreKey.setDbFileExistsForTest(() async => true);
      expect(await KeystoreKey.getOrCreate(), 'escrowed-key-abc');
    });
  });

  group('KeystoreKey.persist — two homes (0.17.8)', () {
    // gotcha 38: the DB key lives in secure storage AND Trail's own
    // escrow. `persist` is where the second copy is made, and it is the
    // probe the passphrase-recovery flow uses to decide whether the
    // plugin is the broken part.
    late List<String> events;
    late _RecordingEscrow escrow;

    void secureStorageWritesThrow() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async {
          if (call.method == 'write') {
            events.add('secure');
            throw PlatformException(
              code: 'Exception encountered',
              message: 'Failed to unwrap key',
            );
          }
          return null;
        },
      );
    }

    setUp(() {
      events = [];
      escrow = _RecordingEscrow(events);
      KeyEscrow.setInstanceForTest(escrow);
      KeystoreKey.lastSecureStorageError = null;
      KeystoreKey.lastEscrowError = null;
      // Wrap the outer fake so the happy path records its ordering too.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async {
          if (call.method == 'write') events.add('secure');
          return fake.handle(call);
        },
      );
    });

    tearDown(() {
      KeyEscrow.setInstanceForTest(null);
      KeystoreKey.lastSecureStorageError = null;
      KeystoreKey.lastEscrowError = null;
    });

    test('stores in both homes', () async {
      await KeystoreKey.persist('derived-key-abc');
      expect(escrow.stored, ['derived-key-abc']);
      expect(fake.current(), 'derived-key-abc');
    });

    test('escrows FIRST — every plugin call is a chance to lose the store',
        () async {
      await KeystoreKey.persist('derived-key-abc');
      expect(events, ['escrow', 'secure']);
    });

    test('a secure-storage write that throws is swallowed when the escrow '
        'took it', () async {
      secureStorageWritesThrow();
      await KeystoreKey.persist('derived-key-abc');
      expect(escrow.stored, ['derived-key-abc'],
          reason: 'the surviving copy is the whole point');
    });

    test('… and the failure is recorded for the recovery flow to branch on',
        () async {
      secureStorageWritesThrow();
      await KeystoreKey.persist('derived-key-abc');
      expect(KeystoreKey.lastSecureStorageError, contains('PlatformException'));
    });

    test('a successful write CLEARS a stale secure-storage error', () async {
      KeystoreKey.lastSecureStorageError = 'PlatformException(from a read)';
      await KeystoreKey.persist('derived-key-abc');
      expect(KeystoreKey.lastSecureStorageError, isNull,
          reason: 'the store demonstrably works now; a stale error would '
              'send the recovery flow into a needless rebuild');
    });

    test('an escrow that refuses does not stop the secure-storage write',
        () async {
      escrow.throws = true;
      await KeystoreKey.persist('derived-key-abc');
      expect(fake.current(), 'derived-key-abc');
      expect(KeystoreKey.lastEscrowError, contains('KeyStoreException'));
    });

    test('BOTH failing throws KeyPersistException', () async {
      escrow.throws = true;
      secureStorageWritesThrow();
      await expectLater(
        KeystoreKey.persist('derived-key-abc'),
        throwsA(isA<KeyPersistException>()),
      );
    });

    test('the KeyPersistException names both failures', () async {
      escrow.throws = true;
      secureStorageWritesThrow();
      try {
        await KeystoreKey.persist('derived-key-abc');
        fail('expected a throw');
      } on KeyPersistException catch (e) {
        expect(e.toString(), contains('KeyStoreException'));
        expect(e.toString(), contains('Failed to unwrap key'));
      }
    });

    test('a key persisted only to the escrow still reads back', () async {
      // The end-to-end promise: an unlock that could not reach secure
      // storage must still survive into the next `read()`.
      secureStorageWritesThrow();
      await KeystoreKey.persist('derived-key-abc');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async => throw PlatformException(code: 'Exception encountered'),
      );
      KeyEscrow.setInstanceForTest(_ServingEscrow('derived-key-abc'));
      expect(await KeystoreKey.read(), 'derived-key-abc');
    });
  });
}

/// A [KeyEscrow] that simply hands back the key it was built with — used
/// to close the loop on "persisted to the escrow only, still readable".
class _ServingEscrow extends KeyEscrow {
  _ServingEscrow(this.key)
      : super(channel: const MethodChannel('trail/key_escrow_serving_test'));

  final String key;

  @override
  Future<EscrowResult> load() async => EscrowResult(key: key);
}
