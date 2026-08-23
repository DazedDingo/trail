import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/secure_storage.dart';
import 'package:trail/services/secure_storage_migration.dart';

/// `SecureStorageMigration` is the evidence trail for the
/// `flutter_secure_storage` 9.2.4 → 10.3.1 cipher migration: it re-writes
/// every secret through the new cipher and only then records the marker
/// that release B (11.x) will refuse to upgrade without.
///
/// Same MethodChannel fake as `keystore_key_test.dart` — there is no DI
/// seam under the plugin, so we fake the platform channel directly.
const _channelName = 'plugins.it_nomads.com/flutter_secure_storage';

class _FakeSecureStorage {
  final Map<String, String> _store = {};
  final List<MethodCall> calls = [];

  /// Keys whose `read` should throw, simulating a Keystore/decrypt error.
  final Set<String> failReads = {};

  /// Keys whose `write` lands mangled, simulating a store that accepts
  /// the write and then hands back something else on the next read.
  final Set<String> corruptWrites = {};

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        if (failReads.contains(key)) {
          throw PlatformException(code: 'Exception', message: 'decrypt failed');
        }
        return _store[key];
      case 'write':
        final value = args['value'] as String;
        _store[key!] = corruptWrites.contains(key) ? '$value-mangled' : value;
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

  void preset(String key, String value) => _store[key] = value;
  String? current(String key) => _store[key];
  int writesFor(String key) => calls
      .where((c) =>
          c.method == 'write' &&
          (c.arguments as Map)['key'] == key)
      .length;
}

Map<String, Object?> _decodeMarker(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(SecureStorageMigration.markerKey)!) as Map)
        .cast<String, Object?>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;
  late SharedPreferences prefs;

  setUp(() async {
    fake = _FakeSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      null,
    );
  });

  Future<MigrationReport> run() => SecureStorageMigration.verifyAndRewrite(
        storage: secureStorage,
        prefs: prefs,
      );

  group('knownKeys', () {
    test('covers every secret Trail writes, DB key first', () {
      expect(SecureStorageMigration.knownKeys, const [
        'trail_db_passphrase_v1',
        'trail_onboarded_v1',
        'trail_panic_duration_v1',
        'trail_panic_auto_send_v1',
        'trail_github_pat_v1',
        'trail_coverage_token_v1',
      ]);
    });
  });

  group('verifyAndRewrite — all present', () {
    setUp(() {
      for (final key in SecureStorageMigration.knownKeys) {
        fake.preset(key, 'value-for-$key');
      }
    });

    test('rewrites every key and reports it', () async {
      final report = await run();
      expect(report.ok, isTrue);
      expect(report.present, SecureStorageMigration.knownKeys);
      expect(report.rewritten, SecureStorageMigration.knownKeys);
      expect(report.mismatched, isEmpty);
      expect(report.errors, isEmpty);
    });

    test('the rewritten values re-read equal — nothing is corrupted',
        () async {
      await run();
      for (final key in SecureStorageMigration.knownKeys) {
        expect(fake.current(key), 'value-for-$key');
      }
    });

    test('each key is written back exactly once', () async {
      await run();
      for (final key in SecureStorageMigration.knownKeys) {
        expect(fake.writesFor(key), 1);
      }
    });

    test('writes the marker with the full present list', () async {
      final report = await run();
      expect(report.markerWritten, isTrue);
      final marker = _decodeMarker(prefs);
      expect(marker['present'], SecureStorageMigration.knownKeys);
      expect(marker['at'], isA<int>());
      expect(
        DateTime.fromMillisecondsSinceEpoch(marker['at']! as int)
            .difference(DateTime.now())
            .inMinutes
            .abs(),
        lessThan(2),
      );
    });

    test('a second run is idempotent and keeps the FIRST timestamp',
        () async {
      await run();
      final firstAt = _decodeMarker(prefs)['at'];
      final second = await run();
      expect(second.ok, isTrue);
      expect(second.markerWritten, isTrue);
      expect(second.rewritten, SecureStorageMigration.knownKeys);
      expect(_decodeMarker(prefs)['at'], firstAt,
          reason: 'diagnostics should name the upgrade, not today');
    });
  });

  group('verifyAndRewrite — partial / missing keys', () {
    test('a missing optional key is still a success, just not present',
        () async {
      // Realistic install: DB key + onboarding flag, no PAT/token.
      fake.preset('trail_db_passphrase_v1', 'k');
      fake.preset('trail_onboarded_v1', '1');
      final report = await run();
      expect(report.ok, isTrue);
      expect(report.present,
          ['trail_db_passphrase_v1', 'trail_onboarded_v1']);
      expect(report.present, isNot(contains('trail_github_pat_v1')));
      expect(_decodeMarker(prefs)['present'],
          ['trail_db_passphrase_v1', 'trail_onboarded_v1']);
    });

    test('an absent key is never written (no empty values created)',
        () async {
      fake.preset('trail_db_passphrase_v1', 'k');
      await run();
      expect(fake.writesFor('trail_github_pat_v1'), 0);
      expect(fake.current('trail_github_pat_v1'), isNull);
    });

    test('a completely empty store still succeeds (fresh install)',
        () async {
      final report = await run();
      expect(report.ok, isTrue);
      expect(report.present, isEmpty);
      expect(report.markerWritten, isTrue);
      expect(_decodeMarker(prefs)['present'], isEmpty);
    });

    test('an empty-string value counts as present and is rewritten',
        () async {
      fake.preset('trail_onboarded_v1', '');
      final report = await run();
      expect(report.present, ['trail_onboarded_v1']);
      expect(report.rewritten, ['trail_onboarded_v1']);
    });
  });

  group('verifyAndRewrite — failures withhold the marker', () {
    test('a read that throws is recorded and blocks the marker', () async {
      fake.preset('trail_db_passphrase_v1', 'k');
      fake.failReads.add('trail_db_passphrase_v1');
      final report = await run();
      expect(report.ok, isFalse);
      expect(report.errors.keys, contains('trail_db_passphrase_v1'));
      expect(report.markerWritten, isFalse);
      expect(prefs.getString(SecureStorageMigration.markerKey), isNull);
    });

    test('one failing key does not stop the others being rewritten',
        () async {
      fake.preset('trail_db_passphrase_v1', 'k');
      fake.preset('trail_onboarded_v1', '1');
      fake.failReads.add('trail_db_passphrase_v1');
      final report = await run();
      expect(report.rewritten, ['trail_onboarded_v1']);
      expect(report.errors.length, 1);
    });

    test('a value that reads back different is a mismatch, not an error',
        () async {
      // The store answers OK but hands back something else — exactly the
      // silent-corruption case the marker exists to catch.
      fake.preset('trail_github_pat_v1', 'ghp_x');
      fake.corruptWrites.add('trail_github_pat_v1');
      final report = await run();
      expect(report.errors, isEmpty);
      expect(report.mismatched, ['trail_github_pat_v1']);
      expect(report.rewritten, isEmpty);
      expect(report.ok, isFalse);
      expect(report.markerWritten, isFalse);
      expect(prefs.getString(SecureStorageMigration.markerKey), isNull);
    });

    test('verifyAndRewrite never throws, even when everything fails',
        () async {
      for (final key in SecureStorageMigration.knownKeys) {
        fake.preset(key, 'v');
        fake.failReads.add(key);
      }
      final report = await run();
      expect(report.errors.length, SecureStorageMigration.knownKeys.length);
      expect(report.markerWritten, isFalse);
    });
  });

  group('markVerified — the startup gate\'s "already fine" shortcut', () {
    test('writes a marker when there is none', () async {
      final wrote = await SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );
      expect(wrote, isTrue);
      final marker = await SecureStorageMigration.readMarker(prefs: prefs);
      expect(marker, isNotNull);
      expect(marker!.present, ['trail_db_passphrase_v1']);
      expect(
        marker.at.difference(DateTime.now()).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('never overwrites the richer marker verifyAndRewrite wrote',
        () async {
      for (final key in SecureStorageMigration.knownKeys) {
        fake.preset(key, 'v');
      }
      await run();
      final before = _decodeMarker(prefs);
      final wrote = await SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );
      expect(wrote, isTrue, reason: 'a marker is on disk either way');
      expect(_decodeMarker(prefs)['at'], before['at']);
      expect(_decodeMarker(prefs)['present'],
          SecureStorageMigration.knownKeys);
    });

    test('a second call is a no-op, timestamp and all', () async {
      await SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );
      final first = _decodeMarker(prefs);
      await SecureStorageMigration.markVerified(
        present: const ['trail_onboarded_v1'],
        prefs: prefs,
      );
      expect(_decodeMarker(prefs), first);
    });

    test('an empty present list is still a valid marker', () async {
      expect(
        await SecureStorageMigration.markVerified(
            present: const [], prefs: prefs),
        isTrue,
      );
      final marker = await SecureStorageMigration.readMarker(prefs: prefs);
      expect(marker, isNotNull);
      expect(marker!.present, isEmpty);
    });

    test('a malformed marker is replaced, not trusted', () async {
      await prefs.setString(SecureStorageMigration.markerKey, '{oops');
      await SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );
      final marker = await SecureStorageMigration.readMarker(prefs: prefs);
      expect(marker, isNotNull);
      expect(marker!.present, ['trail_db_passphrase_v1']);
    });

    test('touches secure storage not at all', () async {
      await SecureStorageMigration.markVerified(
        present: const ['trail_db_passphrase_v1'],
        prefs: prefs,
      );
      expect(fake.calls, isEmpty);
    });
  });

  group('marker parsing + description', () {
    test('readMarker round-trips what verifyAndRewrite wrote', () async {
      fake.preset('trail_db_passphrase_v1', 'k');
      await run();
      final marker = await SecureStorageMigration.readMarker(prefs: prefs);
      expect(marker, isNotNull);
      expect(marker!.present, ['trail_db_passphrase_v1']);
    });

    test('no marker → null', () async {
      expect(await SecureStorageMigration.readMarker(prefs: prefs), isNull);
    });

    test('malformed JSON reads as "not yet verified", never throws', () {
      expect(SecureStorageMigration.parseMarker('{oops'), isNull);
      expect(SecureStorageMigration.parseMarker('[]'), isNull);
      expect(SecureStorageMigration.parseMarker('{"present":[]}'), isNull);
      expect(SecureStorageMigration.parseMarker('{"at":"nope"}'), isNull);
      expect(SecureStorageMigration.parseMarker(''), isNull);
      expect(SecureStorageMigration.parseMarker(null), isNull);
    });

    test('a marker with no present list decodes as empty, not null', () {
      final m = SecureStorageMigration.parseMarker('{"at":0}');
      expect(m, isNotNull);
      expect(m!.present, isEmpty);
    });

    test('describeMarker(null) is the not-verified line', () {
      expect(SecureStorageMigration.describeMarker(null),
          'Secure storage: not yet verified');
    });

    test('describeMarker names the date and the n/6 count', () {
      final line = SecureStorageMigration.describeMarker(
        MigrationMarker(
          at: DateTime(2026, 8, 22, 14, 35),
          present: const ['a', 'b', 'c', 'd', 'e'],
        ),
      );
      expect(line, 'Secure storage: migrated 22 Aug 2026 · 5/6 secrets present');
    });
  });
}
