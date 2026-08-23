import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/db/keystore_key.dart';
import 'package:trail/providers/onboarding_provider.dart';
import 'package:trail/services/secure_storage.dart';

/// `OnboardingGate.isComplete` is the FIRST thing `main()` asks for, and
/// in the 2026-08-23 incident it was also the first thing to die:
/// `flutter_secure_storage` 11 threw on every read, the gate propagated,
/// and `/startup-failed` was as far as the user ever got — with a
/// perfectly good backup passphrase in their head and a perfectly good
/// log on disk.
///
/// Since 0.17.8 a thrown read falls through to two independent answers
/// (the SharedPreferences mirror, then "is there a trail.db?") and only
/// then gives up. A *silent null* is still a genuine first run.
///
/// 0.17.9 adds the third shape: the flag now lives in Trail's own store
/// ([_channelName]), and on the upgrade launch a miss there consults the
/// LEGACY plugin ([_legacyChannelName]) exactly once. A legacy read that
/// *fails* is swallowed by `MigratingSecureStore`, so `isComplete` has to
/// notice it via `legacyFailedFor` — otherwise the incident phone reads
/// `null`, i.e. "first run", and gets walked back through onboarding.
///
/// Same MethodChannel fake as `keystore_key_test.dart`, twice over.
const _channelName = 'trail/secure_store';
const _legacyChannelName = 'plugins.it_nomads.com/flutter_secure_storage';

class _FakeSecureStorage {
  final Map<String, String> store = {};
  final List<MethodCall> calls = [];
  bool throwOnRead = false;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        if (throwOnRead) {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'Failed to unwrap key',
          );
        }
        return store[key];
      case 'write':
        store[key!] = args['value'] as String;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fake;
  late _FakeSecureStorage legacy;
  late SharedPreferences prefs;
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    fake = _FakeSecureStorage();
    legacy = _FakeSecureStorage();
    secureStorage.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
    // A legacy store that answers cleanly with "nothing here" — the
    // healthy-upgrade shape. Groups that model the incident make it throw.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_legacyChannelName),
      legacy.handle,
    );
    tempDir = await Directory.systemTemp.createTemp('trail_onboarding_');
    dbFile = File(p.join(tempDir.path, 'trail.db'));
    KeystoreKey.setDbFileExistsForTest(() => dbFile.exists());
  });

  tearDown(() async {
    KeystoreKey.setDbFileExistsForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_legacyChannelName),
      null,
    );
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('OnboardingGate.isComplete — the healthy path', () {
    test("'1' in secure storage → true", () async {
      fake.store[OnboardingGate.storageKey] = '1';
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('a silent null is a genuine first run → false', () async {
      // Nothing threw: this really is a new install, even with a mirror
      // absent and no DB. Must NOT be rescued into `true`.
      expect(await OnboardingGate.isComplete(), isFalse);
    });

    test('any other value is not "complete"', () async {
      fake.store[OnboardingGate.storageKey] = 'yes';
      expect(await OnboardingGate.isComplete(), isFalse);
    });

    test('a healthy read never consults the fallbacks', () async {
      fake.store[OnboardingGate.storageKey] = '1';
      await dbFile.writeAsString('db');
      await OnboardingGate.isComplete();
      expect(prefs.getBool(OnboardingGate.mirrorKey), isNull,
          reason: 'the hot path writes nothing');
    });
  });

  group('OnboardingGate.isComplete — a plugin that throws', () {
    setUp(() => fake.throwOnRead = true);

    test('mirror says true → true', () async {
      await prefs.setBool(OnboardingGate.mirrorKey, true);
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('no mirror but a trail.db exists → true', () async {
      // A log on disk is proof onboarding happened, whatever the
      // Keystore says. Walking this user back through the first-run flow
      // is the outcome this whole fallback exists to prevent.
      await dbFile.writeAsString('an encrypted log');
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('no mirror, no DB → false', () async {
      expect(await OnboardingGate.isComplete(), isFalse);
    });

    test('a mirror set to false is not an answer; the DB still is',
        () async {
      await prefs.setBool(OnboardingGate.mirrorKey, false);
      await dbFile.writeAsString('db');
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('a DB probe that ALSO throws degrades to false, never rethrows',
        () async {
      // "I could not look" is not "yes". The key-state gate rethrows the
      // same plugin failure a moment later, so /startup-failed still
      // happens — with the accurate stage on it.
      KeystoreKey.setDbFileExistsForTest(
        () async => throw StateError('cannot determine whether trail.db exists'),
      );
      expect(await OnboardingGate.isComplete(), isFalse);
    });

    test('never throws, whatever the fallbacks do', () async {
      KeystoreKey.setDbFileExistsForTest(() async => throw StateError('nope'));
      await expectLater(OnboardingGate.isComplete(), completes);
    });
  });

  group('OnboardingGate.isComplete — a legacy store that will not open '
      '(0.17.9)', () {
    // The upgrade launch on the incident phone: Trail's own store is
    // empty, so the flag can only come from `flutter_secure_storage` —
    // and that is the thing throwing `UNKNOWN_ERROR -1000`. The wrapper
    // swallows the throw, so the read looks like a silent null; without
    // `legacyFailedFor` this user gets the first-run flow.
    setUp(() => legacy.throwOnRead = true);

    test('no mirror but a trail.db exists → true', () async {
      await dbFile.writeAsString('an encrypted log');
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('mirror says true → true', () async {
      await prefs.setBool(OnboardingGate.mirrorKey, true);
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('nothing to vouch for it → false, and no crash', () async {
      expect(await OnboardingGate.isComplete(), isFalse);
    });

    test('the answer is re-seeded into the new store AND the mirror',
        () async {
      // Without this the NEXT launch — marker set, legacy off-limits —
      // reads a plain null and walks the user into onboarding anyway.
      await dbFile.writeAsString('db');
      await OnboardingGate.isComplete();
      expect(fake.store[OnboardingGate.storageKey], '1');
      expect(prefs.getBool(OnboardingGate.mirrorKey), isTrue);
    });

    test('… so the second launch answers from the new store alone',
        () async {
      await dbFile.writeAsString('db');
      await OnboardingGate.isComplete();
      legacy.calls.clear();
      expect(await OnboardingGate.isComplete(), isTrue);
      expect(legacy.calls, isEmpty,
          reason: 'every legacy call is another createRSAKeysIfNeeded');
    });
  });

  group('OnboardingGate.isComplete — a healthy legacy store (0.17.9)', () {
    test('the flag migrates across on first read', () async {
      legacy.store[OnboardingGate.storageKey] = '1';
      expect(await OnboardingGate.isComplete(), isTrue);
      expect(fake.store[OnboardingGate.storageKey], '1',
          reason: 'copied into Trail\'s store on the way past');
    });

    test('a clean legacy null is still a genuine first run', () async {
      await dbFile.writeAsString('db');
      expect(await OnboardingGate.isComplete(), isFalse,
          reason: 'the legacy store answered; a DB alone must not '
              'override a definite "no"');
    });

    test('the legacy store is consulted at most once for the flag',
        () async {
      await OnboardingGate.isComplete();
      await OnboardingGate.isComplete();
      expect(legacy.calls.where((c) => c.method == 'read'), hasLength(1));
    });
  });

  group('OnboardingGate.markComplete', () {
    test('writes secure storage AND the prefs mirror', () async {
      await OnboardingGate.markComplete(prefs: prefs);
      expect(fake.store[OnboardingGate.storageKey], '1');
      expect(prefs.getBool(OnboardingGate.mirrorKey), isTrue);
    });

    test('still writes the mirror when secure storage refuses', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async => throw PlatformException(code: 'KeyStoreException'),
      );
      await OnboardingGate.markComplete(prefs: prefs);
      expect(prefs.getBool(OnboardingGate.mirrorKey), isTrue,
          reason: 'the mirror is what makes the next launch survivable');
    });

    test('the mirror it writes is what a later thrown read reads back',
        () async {
      await OnboardingGate.markComplete(prefs: prefs);
      fake.throwOnRead = true;
      expect(await OnboardingGate.isComplete(), isTrue);
    });

    test('writeMirror on its own is enough', () async {
      await OnboardingGate.writeMirror(prefs: prefs);
      expect(prefs.getBool(OnboardingGate.mirrorKey), isTrue);
      expect(fake.store, isEmpty, reason: 'no secret leaves for prefs');
    });
  });
}
