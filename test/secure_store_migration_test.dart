import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/secure_store_migration.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// `MigratingSecureStore` is the one-launch bridge between
/// `flutter_secure_storage` and Trail's own store.
///
/// Three properties matter, and each is a way the 2026-08-23 incident
/// could repeat:
///
///  1. **A healthy legacy store is drained exactly once per key.** Every
///     call to that plugin is another run of `createRSAKeysIfNeeded`,
///     which regenerates its RSA pair the moment Android says the alias
///     is missing — so "once, then never again" is a safety property, not
///     an optimisation.
///  2. **A broken legacy store cannot take the app down.** A throw, or a
///     read that never returns, has to come back as "nothing found" plus
///     a recorded diagnosis — never as an exception through the startup
///     gate, and never as a reason to skip the marker.
///  3. **Nothing is ever deleted.** The migration copies; the legacy
///     store is left exactly as it was for `SecureStorageRescue`.
const _storeChannel = 'trail/secure_store_migration_test';
const _legacyChannel = 'plugins.it_nomads.com/flutter_secure_storage';

const _knownKeys = <String>[
  'trail_db_passphrase_v1',
  'trail_onboarded_v1',
  'trail_github_pat_v1',
];

/// Stand-in for `TrailSecureStorePlugin`'s store channel.
class _FakeStoreNative {
  final Map<String, String> entries = {};
  final List<MethodCall> calls = [];
  final Set<String> failWrites = {};
  final Set<String> failReads = {};

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        if (failReads.contains(key)) {
          throw PlatformException(code: 'AEADBadTagException');
        }
        return entries[key];
      case 'write':
        if (failWrites.contains(key)) {
          throw PlatformException(code: 'KeyStoreException');
        }
        entries[key!] = args['value']! as String;
        return null;
      case 'delete':
        entries.remove(key);
        return null;
      case 'deleteAll':
        entries.clear();
        return null;
      case 'containsKey':
        return entries.containsKey(key);
      case 'readAll':
        return Map<String, String>.from(entries);
      case 'status':
        return <String, Object?>{
          'aliasExists': true,
          'entryCount': entries.length,
        };
      default:
        return null;
    }
  }

  int readsFor(String key) => calls
      .where((c) =>
          c.method == 'read' && (c.arguments as Map)['key'] == key)
      .length;
}

/// Stand-in for `flutter_secure_storage`, with the incident's two failure
/// modes on switches: a throw, and a read that never comes back.
class _FakeLegacyNative {
  final Map<String, String> entries = {};
  final List<MethodCall> calls = [];
  bool throwOnRead = false;
  bool hangOnRead = false;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        if (hangOnRead) return Completer<Object?>().future;
        if (throwOnRead) {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'Failed to unwrap key',
          );
        }
        return entries[key];
      case 'write':
        entries[key!] = args['value']! as String;
        return null;
      case 'delete':
        entries.remove(key);
        return null;
      default:
        return null;
    }
  }

  int readsFor(String key) => calls
      .where((c) =>
          c.method == 'read' && (c.arguments as Map)['key'] == key)
      .length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeStoreNative store;
  late _FakeLegacyNative legacy;
  late SharedPreferences prefs;

  MigratingSecureStore build({Duration? legacyTimeout}) =>
      MigratingSecureStore(
        store: const TrailSecureStore(channel: MethodChannel(_storeChannel)),
        legacy: legacySecureStorageForTest,
        knownKeys: _knownKeys,
        prefs: prefs,
        legacyTimeout: legacyTimeout ?? const Duration(seconds: 3),
      );

  setUp(() async {
    store = _FakeStoreNative();
    legacy = _FakeLegacyNative();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel(_storeChannel),
        store.handle,
      )
      ..setMockMethodCallHandler(
        const MethodChannel(_legacyChannel),
        legacy.handle,
      );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel(_storeChannel), null)
      ..setMockMethodCallHandler(const MethodChannel(_legacyChannel), null);
  });

  group('read — the new store answers', () {
    test('a hit never touches the legacy plugin', () async {
      store.entries['trail_onboarded_v1'] = '1';
      expect(await build().read(key: 'trail_onboarded_v1'), '1');
      expect(legacy.calls, isEmpty,
          reason: 'the hot path must not pay for the migration');
    });

    test('a hit on one key does not migrate the others', () async {
      store.entries['trail_onboarded_v1'] = '1';
      final s = build();
      await s.read(key: 'trail_onboarded_v1');
      expect(s.migrated, isFalse);
      expect(prefs.getBool(MigratingSecureStore.markerKey), isNull);
    });
  });

  group('read — a miss falls through to the legacy store', () {
    test('the legacy value is returned', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      expect(await build().read(key: 'trail_github_pat_v1'), 'ghp_secret');
    });

    test('… and copied into the new store', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      await build().read(key: 'trail_github_pat_v1');
      expect(store.entries['trail_github_pat_v1'], 'ghp_secret');
    });

    test('… and NOT deleted from the legacy store', () async {
      // `SecureStorageRescue` still has to be able to read it, and this
      // release is the first time the new store has ever been written.
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      await build().read(key: 'trail_github_pat_v1');
      expect(legacy.entries['trail_github_pat_v1'], 'ghp_secret');
      expect(legacy.calls.any((c) => c.method == 'delete'), isFalse);
    });

    test('the legacy store is read at most ONCE per key', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      final s = build();
      await s.read(key: 'trail_github_pat_v1');
      // Now serve it from the new store; a second miss must not re-ask.
      store.entries.clear();
      await s.read(key: 'trail_github_pat_v1');
      expect(legacy.readsFor('trail_github_pat_v1'), 1);
    });

    test('a legacy null is nothing, and is not recorded as a failure',
        () async {
      final s = build();
      expect(await s.read(key: 'trail_github_pat_v1'), isNull);
      expect(s.legacyFailedFor('trail_github_pat_v1'), isFalse);
      expect(s.lastLegacyError, isNull);
      expect(store.entries, isEmpty, reason: 'nothing to copy');
    });

    test('an empty legacy value is returned but not copied', () async {
      legacy.entries['trail_github_pat_v1'] = '';
      final s = build();
      expect(await s.read(key: 'trail_github_pat_v1'), '');
      expect(store.entries.containsKey('trail_github_pat_v1'), isFalse,
          reason: 'an empty secret is a bug to leave behind, not to carry');
    });

    test('a store that refuses the copy still returns the value', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      store.failWrites.add('trail_github_pat_v1');
      expect(await build().read(key: 'trail_github_pat_v1'), 'ghp_secret');
    });
  });

  group('read — a legacy store that will not open', () {
    setUp(() => legacy.throwOnRead = true);

    test('the throw is swallowed and the read answers null', () async {
      await expectLater(build().read(key: 'trail_onboarded_v1'), completion(isNull));
    });

    test('the failure is recorded per key and globally', () async {
      final s = build();
      await s.read(key: 'trail_onboarded_v1');
      expect(s.legacyFailedFor('trail_onboarded_v1'), isTrue);
      expect(s.legacyFailedFor('trail_github_pat_v1'), isFalse,
          reason: 'that key has not been tried yet');
      expect(s.lastLegacyError, contains('Failed to unwrap key'));
    });

    test('a hang is capped by legacyTimeout and reads as a failure',
        () async {
      // The 0.17.5 shape: a platform call that never returns. Before the
      // timeout this was a frozen Android splash.
      legacy
        ..throwOnRead = false
        ..hangOnRead = true;
      final s = build(legacyTimeout: const Duration(milliseconds: 20));
      expect(await s.read(key: 'trail_onboarded_v1'), isNull);
      expect(s.legacyFailedFor('trail_onboarded_v1'), isTrue);
      expect(s.lastLegacyError, contains('TimeoutException'));
    });

    test('a broken key is still only tried once', () async {
      final s = build();
      await s.read(key: 'trail_onboarded_v1');
      await s.read(key: 'trail_onboarded_v1');
      expect(legacy.readsFor('trail_onboarded_v1'), 1,
          reason: 'retrying is how createRSAKeysIfNeeded gets its chance');
    });

    test('a store read that itself throws propagates — never swallowed',
        () async {
      // Our own store failing is a different problem: `KeystoreKey.read`
      // has to see it so the escrow fallback and /startup-failed still fire.
      store.failReads.add('trail_db_passphrase_v1');
      await expectLater(
        build().read(key: 'trail_db_passphrase_v1'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('the marker', () {
    test('lands once every known key has been tried lazily', () async {
      final s = build();
      for (final key in _knownKeys) {
        await s.read(key: key);
      }
      expect(s.migrated, isTrue);
      expect(prefs.getBool(MigratingSecureStore.markerKey), isTrue);
    });

    test('is NOT written while a key is still untried', () async {
      final s = build();
      await s.read(key: _knownKeys.first);
      expect(prefs.getBool(MigratingSecureStore.markerKey), isNull);
    });

    test('stops every future legacy call, for keys never tried', () async {
      await prefs.setBool(MigratingSecureStore.markerKey, true);
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      final s = build();
      expect(await s.read(key: 'trail_github_pat_v1'), isNull);
      expect(legacy.calls, isEmpty,
          reason: 'the marker is a hard stop, not a hint');
    });

    test('an unreadable prefs backend reads as "not migrated"', () async {
      // Never a reason to skip the migration: re-reading the legacy store
      // is wasteful, never destructive.
      final s = MigratingSecureStore(
        store: const TrailSecureStore(channel: MethodChannel(_storeChannel)),
        legacy: legacySecureStorageForTest,
        knownKeys: _knownKeys,
      );
      SharedPreferences.setMockInitialValues({});
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      expect(await s.read(key: 'trail_github_pat_v1'), 'ghp_secret');
    });
  });

  group('migrateLegacySecrets — the post-frame pass', () {
    test('copies every legacy secret across', () async {
      legacy.entries.addAll({
        'trail_db_passphrase_v1': 'db-key',
        'trail_onboarded_v1': '1',
      });
      await build().migrateLegacySecrets();
      expect(store.entries, {
        'trail_db_passphrase_v1': 'db-key',
        'trail_onboarded_v1': '1',
      });
    });

    test('does not overwrite what the new store already holds', () async {
      store.entries['trail_db_passphrase_v1'] = 'the-current-key';
      legacy.entries['trail_db_passphrase_v1'] = 'a-stale-key';
      await build().migrateLegacySecrets();
      expect(store.entries['trail_db_passphrase_v1'], 'the-current-key');
      expect(legacy.readsFor('trail_db_passphrase_v1'), 0);
    });

    test('sets the marker on a clean pass', () async {
      await build().migrateLegacySecrets();
      expect(prefs.getBool(MigratingSecureStore.markerKey), isTrue);
    });

    test('sets the marker even when EVERY legacy read throws', () async {
      // The incident phone. Retrying next launch would gain nothing and
      // risk the plugin regenerating its RSA pair.
      legacy.throwOnRead = true;
      final s = build();
      await s.migrateLegacySecrets();
      expect(prefs.getBool(MigratingSecureStore.markerKey), isTrue);
      expect(s.lastLegacyError, contains('Failed to unwrap key'));
      expect(store.entries, isEmpty);
    });

    test('never throws, whatever both stores do', () async {
      legacy.throwOnRead = true;
      store.failReads.addAll(_knownKeys);
      await expectLater(build().migrateLegacySecrets(), completes);
    });

    test('a second call is a no-op', () async {
      legacy.entries['trail_onboarded_v1'] = '1';
      final s = build();
      await s.migrateLegacySecrets();
      final before = legacy.calls.length;
      await s.migrateLegacySecrets();
      expect(legacy.calls.length, before);
    });

    test('picks up where the lazy path left off', () async {
      legacy.entries.addAll({
        'trail_onboarded_v1': '1',
        'trail_github_pat_v1': 'ghp_secret',
      });
      final s = build();
      await s.read(key: 'trail_onboarded_v1');
      await s.migrateLegacySecrets();
      expect(legacy.readsFor('trail_onboarded_v1'), 1);
      expect(store.entries['trail_github_pat_v1'], 'ghp_secret');
    });
  });

  group('the other methods delegate to the new store only', () {
    test('write goes straight through', () async {
      await build().write(key: 'trail_onboarded_v1', value: '1');
      expect(store.entries['trail_onboarded_v1'], '1');
      expect(legacy.calls, isEmpty);
    });

    test('a write marks the key done so a later miss cannot resurrect the '
        'legacy value', () async {
      legacy.entries['trail_github_pat_v1'] = 'the-old-token';
      final s = build();
      await s.write(key: 'trail_github_pat_v1', value: 'the-new-token');
      store.entries.remove('trail_github_pat_v1');
      expect(await s.read(key: 'trail_github_pat_v1'), isNull);
    });

    test('delete goes straight through and marks the key done', () async {
      legacy.entries['trail_github_pat_v1'] = 'the-old-token';
      store.entries['trail_github_pat_v1'] = 'the-new-token';
      final s = build();
      await s.delete(key: 'trail_github_pat_v1');
      expect(store.entries, isEmpty);
      expect(await s.read(key: 'trail_github_pat_v1'), isNull);
      expect(legacy.entries['trail_github_pat_v1'], 'the-old-token',
          reason: 'the migration never deletes from the legacy store');
    });

    test('containsKey agrees with read during the migration window',
        () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      expect(await build().containsKey(key: 'trail_github_pat_v1'), isTrue);
    });

    test('readAll and status are the new store, verbatim', () async {
      store.entries.addAll({'a': '1', 'b': '2'});
      final s = build();
      expect(await s.readAll(), {'a': '1', 'b': '2'});
      expect((await s.status()).entryCount, 2);
      expect(legacy.calls, isEmpty);
    });

    test('deleteAll clears the new store and stops the migration', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      store.entries['a'] = '1';
      final s = build();
      await s.deleteAll();
      expect(store.entries, isEmpty);
      expect(await s.read(key: 'trail_github_pat_v1'), isNull);
      expect(legacy.calls, isEmpty);
    });
  });

  group('resetForTest', () {
    test('forgets the attempted keys and the marker', () async {
      legacy.entries['trail_github_pat_v1'] = 'ghp_secret';
      final s = build();
      await s.read(key: 'trail_github_pat_v1');
      expect(s.attemptedKeys, contains('trail_github_pat_v1'));
      s.resetForTest();
      expect(s.attemptedKeys, isEmpty);
      expect(s.migrated, isFalse);
      expect(s.lastLegacyError, isNull);
    });
  });
}

/// The same options the app pins, constructed locally so this file does
/// not depend on the app-wide singleton's lifecycle.
const legacySecureStorageForTest = FlutterSecureStorage(
  aOptions: AndroidOptions(
    migrateOnAlgorithmChange: true,
    resetOnError: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
  ),
);
