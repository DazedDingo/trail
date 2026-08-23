import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/db/keystore_key.dart';
import 'package:trail/services/key_escrow.dart';
import 'package:trail/providers/backup_provider.dart';
import 'package:trail/services/passphrase_service.dart';
import 'package:trail/services/secure_storage_migration.dart';
import 'package:trail/services/startup_gates.dart';

/// `computeStartupKeyState` is the one probe `main()` runs before the
/// first frame; the router turns its answer into `/lock`, `/unlock` or
/// `/recover`. Getting it wrong either locks a healthy user out or —
/// worse — lets `KeystoreKey.getOrCreate` mint a key over a log it can
/// no longer read.
///
/// Same MethodChannel fake as `keystore_key_test.dart`.
const _channelName = 'plugins.it_nomads.com/flutter_secure_storage';
const _storageKey = 'trail_db_passphrase_v1';

class _FakeSecureStorage {
  final Map<String, String> _store = {};

  Future<Object?> handle(MethodCall call) async {
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

  void presetKey(String value) => _store[_storageKey] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;
  late Directory tempDir;
  late File dbFile;
  late SharedPreferences prefs;

  /// The marker release A leaves behind. Its presence/absence is what
  /// separates "the key is gone" from "this build cannot read the store".
  Future<void> presetMarker() => SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );

  setUp(() async {
    fake = _FakeSecureStorage();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
    tempDir = await Directory.systemTemp.createTemp('trail_startup_key_');
    dbFile = File('${tempDir.path}/trail.db');
    PassphraseService.setSaltDirForTest(tempDir);
    KeystoreKey.setDbFileExistsForTest(() => dbFile.exists());
  });

  tearDown(() async {
    KeystoreKey.setDbFileExistsForTest(null);
    PassphraseService.setSaltDirForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      null,
    );
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('computeStartupKeyState', () {
    test('fresh install (nothing anywhere) → ok', () async {
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('key stored, no DB yet → ok', () async {
      fake.presetKey('k');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('key stored + DB on disk → ok (the normal launch)', () async {
      fake.presetKey('k');
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('key stored + salt present → ok, never asks for the passphrase',
        () async {
      fake.presetKey('derived');
      await PassphraseService.generateAndPersistSalt();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('salt present + no key → needsUnlock (auto-backup restore)',
        () async {
      await PassphraseService.generateAndPersistSalt();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.needsUnlock);
    });

    test('salt present + no key + no DB yet → still needsUnlock', () async {
      // Salt restored ahead of the DB: the user must supply the
      // passphrase before anything creates a DB with a random key.
      await PassphraseService.generateAndPersistSalt();
      expect(await computeStartupKeyState(), StartupKeyState.needsUnlock);
    });

    test('DB present, no key, no salt, marker present → keyMissing',
        () async {
      await presetMarker();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.keyMissing);
    });

    test('empty-string key is treated as no key → keyMissing', () async {
      await presetMarker();
      fake.presetKey('');
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.keyMissing);
    });

    test('probing never creates a key or a DB', () async {
      await dbFile.writeAsString('db');
      await computeStartupKeyState();
      expect(fake._store, isEmpty);
      expect(await dbFile.readAsString(), 'db');
    });

    test('after the DB is set aside, the state goes back to ok', () async {
      await presetMarker();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.keyMissing);
      await dbFile.rename('${tempDir.path}/trail.db.locked-20260822-1435');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });
  });

  group('the flutter_secure_storage 11 marker gate', () {
    test('DB + no key + NO marker → notMigrated, not keyMissing', () async {
      // The 11.x failure mode: the 9.2.4 values are still in the prefs
      // file, they just read back null. Nothing has been lost, so the
      // recovery screen must not offer to set the log aside.
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.notMigrated);
    });

    test('DB + no key + marker → keyMissing (release A really ran)',
        () async {
      await presetMarker();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.keyMissing);
    });

    test('a malformed marker counts as no marker → notMigrated', () async {
      await prefs.setString(SecureStorageMigration.markerKey, '{oops');
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.notMigrated);
    });

    test('no DB at all → ok even with no marker (clean first run)',
        () async {
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('salt + no key + no marker → needsUnlock still wins', () async {
      // Passphrase mode can re-derive the key from the user's passphrase
      // whatever the storage format did, so never send them to /recover.
      await PassphraseService.generateAndPersistSalt();
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.needsUnlock);
    });

    test('key reads fine + no marker → ok AND the marker is written',
        () async {
      // A working install is never blocked on bookkeeping: record the
      // marker so the next launch cannot mistake it for an unmigrated one.
      fake.presetKey('k');
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
      final marker = await SecureStorageMigration.readMarker(prefs: prefs);
      expect(marker, isNotNull);
      expect(marker!.present, ['trail_db_passphrase_v1']);
    });

    test('key reads fine + existing marker → left exactly as it was',
        () async {
      await presetMarker();
      final before = prefs.getString(SecureStorageMigration.markerKey);
      fake.presetKey('k');
      expect(await computeStartupKeyState(), StartupKeyState.ok);
      expect(prefs.getString(SecureStorageMigration.markerKey), before);
    });

    test('writing the marker never writes to secure storage', () async {
      fake.presetKey('k');
      await computeStartupKeyState();
      expect(fake._store, {'trail_db_passphrase_v1': 'k'});
    });

    test('a notMigrated probe creates neither a key nor a marker',
        () async {
      await dbFile.writeAsString('db');
      expect(await computeStartupKeyState(), StartupKeyState.notMigrated);
      expect(fake._store, isEmpty);
      expect(prefs.getString(SecureStorageMigration.markerKey), isNull);
      expect(await dbFile.readAsString(), 'db');
    });
  });

  group('computeNeedsUnlock is unchanged', () {
    test('false with no salt, whatever else is on disk', () async {
      await dbFile.writeAsString('db');
      expect(await computeNeedsUnlock(), isFalse);
    });

    test('true with a salt and no key', () async {
      await PassphraseService.generateAndPersistSalt();
      expect(await computeNeedsUnlock(), isTrue);
    });

    test('false with a salt and a key', () async {
      await PassphraseService.generateAndPersistSalt();
      fake.presetKey('derived');
      expect(await computeNeedsUnlock(), isFalse);
    });

    test('agrees with computeStartupKeyState on the needsUnlock arm',
        () async {
      await PassphraseService.generateAndPersistSalt();
      expect(await computeNeedsUnlock(), isTrue);
      expect(await computeStartupKeyState(), StartupKeyState.needsUnlock);
    });
  });

  group('a probe that cannot answer becomes a startup failure', () {
    // The gate has four answers and each one sends the user somewhere
    // different. A probe that cannot look must pick none of them: it
    // used to be folded into `ok` (mint a key — the unrecoverable one)
    // or `notMigrated` (send the user off to install 0.17.3 for no
    // reason). Now it throws, and `runStartupGates` turns that into
    // `/startup-failed`, which names the actual error.
    test('the DB stat throws → computeStartupKeyState throws', () async {
      KeystoreKey.setDbFileExistsForTest(
        () async => throw StateError('cannot determine whether trail.db exists'),
      );
      await expectLater(computeStartupKeyState(), throwsA(isA<StateError>()));
    });

    test('… and runStartupGates reports failed(keyState) with that error',
        () async {
      final boom = StateError('cannot determine whether trail.db exists');
      KeystoreKey.setDbFileExistsForTest(() async => throw boom);
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: computeStartupKeyState,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.keyState);
      expect(outcome.failure!.error, same(boom));
      expect(outcome.failure!.timedOut, isFalse);
    });

    test('the salt stat throws → failed(keyState), not a wrong diagnosis',
        () async {
      // With a DB on disk and no marker this would otherwise be reported
      // as `notMigrated` → "install 0.17.3 first", which is advice for a
      // problem the user does not have.
      await dbFile.writeAsString('db');
      PassphraseService.setSaltDirForTest(null);
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: computeStartupKeyState,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.keyState);
      expect(outcome.failure!.error, isA<MissingPluginException>());
    });

    test('a readable key short-circuits both stats', () async {
      // A healthy install must never be locked out by a filesystem
      // hiccup: the gate returns on the first successful read.
      fake.presetKey('stored-key');
      KeystoreKey.setDbFileExistsForTest(() async => throw StateError('nope'));
      PassphraseService.setSaltDirForTest(null);
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('a Keystore read that throws is reported as keyState too',
        () async {
      // The most likely shape of the 0.17.5 field bug: fss 11 fails to
      // unwrap and the whole of `main` used to die before `runApp`.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async => throw PlatformException(code: 'Failed to unwrap key'),
      );
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: computeStartupKeyState,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure!.stage, StartupStage.keyState);
      expect(outcome.failure!.error, isA<PlatformException>());
    });
  });

  group('a thrown read that the escrow can rescue (0.17.7/0.17.8)', () {
    // The 2026-08-23 incident, one launch later: secure storage still
    // throws on every read, but Trail's own escrow holds the DB key. The
    // gate must come back `ok` — the key IS available — rather than
    // taking the whole app to /startup-failed for a store nobody needs
    // any more.
    const escrowChannel = 'trail/key_escrow_startup_state_test';
    String? escrowedKey;

    void installEscrow() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(escrowChannel),
        (call) async {
          switch (call.method) {
            case 'load':
              final key = escrowedKey;
              return key == null ? null : Uint8List.fromList(utf8.encode(key));
            default:
              return null;
          }
        },
      );
    }

    void makeSecureStorageThrow() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async => throw PlatformException(
          code: 'Exception encountered',
          message: 'Failed to unwrap key',
        ),
      );
    }

    setUp(() {
      escrowedKey = null;
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

    test('secure storage throws + escrow has the key + DB on disk → ok',
        () async {
      escrowedKey = 'escrowed-db-key';
      await dbFile.writeAsString('db');
      makeSecureStorageThrow();
      expect(await computeStartupKeyState(), StartupKeyState.ok);
      expect(KeystoreKey.lastReadSource, KeystoreKey.sourceEscrow);
    });

    test('… and runStartupGates reports a healthy startup', () async {
      escrowedKey = 'escrowed-db-key';
      await dbFile.writeAsString('db');
      makeSecureStorageThrow();
      final outcome = await runStartupGates(
        readOnboarded: () async => true,
        readKeyState: computeStartupKeyState,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.keyState, StartupKeyState.ok);
    });

    test('a salt as well does not send the user to /unlock', () async {
      // The key is available; passphrase mode is irrelevant here.
      escrowedKey = 'escrowed-db-key';
      await PassphraseService.generateAndPersistSalt();
      await dbFile.writeAsString('db');
      makeSecureStorageThrow();
      expect(await computeStartupKeyState(), StartupKeyState.ok);
    });

    test('an empty escrow still rethrows — /startup-failed, never ok',
        () async {
      await dbFile.writeAsString('db');
      makeSecureStorageThrow();
      await expectLater(
        computeStartupKeyState(),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
