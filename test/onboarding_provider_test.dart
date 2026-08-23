import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/db/keystore_key.dart';
import 'package:trail/providers/onboarding_provider.dart';

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
/// Same MethodChannel fake as `keystore_key_test.dart`.
const _channelName = 'plugins.it_nomads.com/flutter_secure_storage';

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
  late SharedPreferences prefs;
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    fake = _FakeSecureStorage();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      fake.handle,
    );
    tempDir = await Directory.systemTemp.createTemp('trail_onboarding_');
    dbFile = File(p.join(tempDir.path, 'trail.db'));
    KeystoreKey.setDbFileExistsForTest(() => dbFile.exists());
  });

  tearDown(() async {
    KeystoreKey.setDbFileExistsForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
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
