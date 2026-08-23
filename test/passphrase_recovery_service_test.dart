import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:trail/db/keystore_key.dart';
import 'package:trail/providers/onboarding_provider.dart';
import 'package:trail/services/key_escrow.dart';
import 'package:trail/services/passphrase_recovery_service.dart';
import 'package:trail/services/passphrase_service.dart';
import 'package:trail/services/secure_storage_migration.dart';
import 'package:trail/services/secure_storage_rescue.dart';
import 'package:trail/services/startup_gates.dart';

/// The unlock-and-repair flow, end to end, minus the two things a unit
/// test cannot have: SQLCipher (gotcha 3) and the AndroidKeyStore.
///
/// The DB probe is still a REAL database open — the injected verifier
/// points a `sqflite_common_ffi` handle at the real `trail.db` for the
/// right key and at a file of garbage for a wrong one, so the "wrong
/// passphrase" branch is driven by SQLite's genuine `file is not a
/// database` rather than a hand-written string.
const _channelName = 'plugins.it_nomads.com/flutter_secure_storage';

/// Same libsqlite3 loader workaround as `ping_dao_test.dart` — must be a
/// top-level function (CLAUDE.md gotcha 8).
void _ffiInit() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      for (final candidate in const [
        'libsqlite3.so.0',
        '/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      ]) {
        try {
          return DynamicLibrary.open(candidate);
        } on ArgumentError {
          // Try next candidate.
        }
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
}

/// The secure-storage plugin, with an on/off switch for the incident:
/// while [broken] every call throws the 2026-08-23 error.
class _FakeSecureStorage {
  _FakeSecureStorage(this.events);

  /// Shared with the escrow + rescue fakes so the ORDER of the whole
  /// flow can be asserted in one list.
  final List<String> events;
  final Map<String, String> store = {};
  final List<MethodCall> calls = [];
  bool broken = false;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (broken) {
      throw PlatformException(
        code: 'Exception encountered',
        message: 'Failed to unwrap key',
      );
    }
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return store[key];
      case 'write':
        store[key!] = args['value'] as String;
        if (key == KeystoreKey.storageKey) events.add('persist');
        return null;
      case 'delete':
        store.remove(key);
        return null;
      default:
        return null;
    }
  }
}

class _FakeEscrow extends KeyEscrow {
  _FakeEscrow(this.events)
      : super(channel: const MethodChannel('trail/key_escrow_recovery_test'));

  final List<String> events;
  final List<String> stored = [];
  bool throws = false;

  /// Idempotent like `KeyEscrowPlugin.store`: re-storing the same key is
  /// a no-op, so a second call from `KeystoreKey.persist` does not show
  /// up as another event.
  @override
  Future<void> store(String key) async {
    if (throws) {
      events.add('escrow');
      throw PlatformException(code: 'KeyStoreException', message: 'nope');
    }
    if (stored.contains(key)) return;
    events.add('escrow');
    stored.add(key);
  }
}

class _FakeRescue extends SecureStorageRescue {
  _FakeRescue(this.events, {required this.onSetAside, this.onRescue})
      : super(
          channel: const MethodChannel('trail/secure_storage_rescue_fake'),
        );

  final List<String> events;

  /// Lets the test model "the store works again once it has been rebuilt".
  final void Function() onSetAside;

  /// Fires the instant `rescue()` is entered, so a test can snapshot how
  /// many secure-storage calls had been made by then. Must be zero.
  final void Function()? onRescue;

  RescueResult result = const RescueResult(ok: false, attempts: ['none → x']);
  SetAsideResult setAsideResult = const SetAsideResult(
    stamp: '20260823-1030',
    movedFiles: ['FlutterSecureStorage.broken-20260823-1030.xml'],
    deletedAliases: ['com.dazeddingo.trail.FlutterSecureStoragePluginKeyOAEP'],
  );

  /// Default: a healthy store. The broken groups override it (or set
  /// `KeystoreKey.lastSecureStorageError`) to trip the diagnosis.
  RescueStatus statusResult = const RescueStatus(
    storeFileExists: true,
    wrappedKeyPresent: true,
    aliasExists: true,
  );

  @override
  Future<RescueStatus> status() async => statusResult;

  @override
  Future<RescueResult> rescue() async {
    events.add('rescue');
    onRescue?.call();
    return result;
  }

  @override
  Future<SetAsideResult> setAside() async {
    events.add('setAside');
    onSetAside();
    return setAsideResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late List<String> events;
  late int secureCallsAtRescue;
  late _FakeSecureStorage secure;
  late _FakeEscrow escrow;
  late _FakeRescue rescue;
  late SharedPreferences prefs;
  late Directory tempDir;
  late String garbagePath;
  late DatabaseFactory factory;

  const passphrase = 'correct horse battery staple';
  final fixedNow = DateTime(2026, 8, 23, 10, 30);
  // A FIXED salt, written by name (`passphrase_service_test.dart` does the
  // same) so the 210k-iteration PBKDF2 runs once for the whole file
  // instead of once per `setUp` — the production `unlock` path still
  // derives for real on every test that calls it.
  final fixedSalt =
      Uint8List.fromList(List<int>.generate(16, (i) => (i * 7 + 3) % 256));
  late String rightKey;

  setUpAll(() {
    rightKey = PassphraseService.deriveKey(passphrase, fixedSalt);
  });

  /// The production shape: open the log, run one query, close. Right key
  /// → the real ffi DB; wrong key → a file that is not a database.
  Future<void> verify(String key) async {
    final path = key == rightKey ? p.join(tempDir.path, 'trail.db') : garbagePath;
    final db = await factory.openDatabase(path);
    try {
      await db.rawQuery('SELECT count(*) FROM pings');
    } finally {
      await db.close();
    }
  }

  PassphraseRecoveryService service() => PassphraseRecoveryService(
        verifyKey: verify,
        rescue: rescue,
        prefs: prefs,
        now: () => fixedNow,
      );

  setUp(() async {
    factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
    events = [];
    secureCallsAtRescue = -1;
    secure = _FakeSecureStorage(events);
    escrow = _FakeEscrow(events);
    rescue = _FakeRescue(
      events,
      onSetAside: () => secure.broken = false,
      onRescue: () => secureCallsAtRescue = secure.calls.length,
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      secure.handle,
    );
    KeyEscrow.setInstanceForTest(escrow);
    KeystoreKey.lastSecureStorageError = null;
    KeystoreKey.lastEscrowError = null;
    KeystoreKey.lastReadSource = null;

    tempDir = await Directory.systemTemp.createTemp('trail_recovery_');
    PassphraseService.setSaltDirForTest(tempDir);
    await File(p.join(tempDir.path, 'trail_salt_v1.bin'))
        .writeAsBytes(fixedSalt, flush: true);

    // A real, tiny SQLite log for the happy path…
    final db = await factory.openDatabase(p.join(tempDir.path, 'trail.db'));
    await db.execute('CREATE TABLE pings (id INTEGER PRIMARY KEY);');
    await db.close();
    // …and a file that genuinely is not a database for the sad one.
    garbagePath = p.join(tempDir.path, 'not-a-db.bin');
    await File(garbagePath).writeAsBytes(List<int>.generate(4096, (i) => i % 251));
  });

  tearDown(() async {
    KeyEscrow.setInstanceForTest(null);
    SecureStorageRescue.setInstanceForTest(null);
    PassphraseService.setSaltDirForTest(null);
    KeystoreKey.lastSecureStorageError = null;
    KeystoreKey.lastEscrowError = null;
    KeystoreKey.lastReadSource = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('a wrong passphrase', () {
    test('is reported as "Wrong passphrase"', () async {
      final result = await service().unlock('nope nope nope nope');
      expect(result.ok, isFalse);
      expect(result.error, contains('Wrong passphrase'));
    });

    test('writes NOTHING anywhere', () async {
      await service().unlock('nope nope nope nope');
      expect(secure.store, isEmpty);
      expect(escrow.stored, isEmpty);
      expect(prefs.getString(secureStorageRescueKey), isNull);
      expect(prefs.getString(SecureStorageMigration.markerKey), isNull);
    });

    test('never reaches the rescue, let alone the destructive step',
        () async {
      await service().unlock('nope nope nope nope');
      expect(events, isEmpty);
      expect(secure.calls, isEmpty);
    });

    test('an empty passphrase stops before the salt is even read',
        () async {
      final result = await service().unlock('');
      expect(result.ok, isFalse);
      expect(result.error, 'Enter your backup passphrase.');
      expect(secure.store, isEmpty);
    });

    test('a missing salt is its own message', () async {
      await PassphraseService.deleteSalt();
      final result = await service().unlock(passphrase);
      expect(result.ok, isFalse);
      expect(result.error, PassphraseRecoveryService.saltMissingMessage);
      expect(escrow.stored, isEmpty);
    });

    test('a non-key DB failure is not blamed on the passphrase', () async {
      final result = await PassphraseRecoveryService(
        verifyKey: (_) async => throw StateError('disk on fire'),
        rescue: rescue,
        prefs: prefs,
        now: () => fixedNow,
      ).unlock(passphrase);
      expect(result.ok, isFalse);
      expect(result.error, contains('disk on fire'));
      expect(result.error, isNot(contains('Wrong passphrase')));
    });
  });

  group('the right passphrase, healthy secure storage', () {
    test('persists the derived key to both homes', () async {
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(escrow.stored, [rightKey]);
      expect(secure.store[KeystoreKey.storageKey], rightKey);
    });

    test('does NOT rebuild anything', () async {
      final result = await service().unlock(passphrase);
      expect(result.rescue, isNull);
      expect(events, ['escrow', 'persist'],
          reason: 'setAside is irreversible; a working store never sees it');
    });

    test('records the migration marker and releases the worker', () async {
      await setStartupBlocked(true, prefs: prefs);
      await service().unlock(passphrase);
      expect(await SecureStorageMigration.readMarker(prefs: prefs), isNotNull);
      expect(await readStartupBlocked(prefs: prefs), isFalse);
    });
  });

  group('the right passphrase, a broken plugin — the live incident', () {
    setUp(() {
      secure.broken = true;
      // What startup left behind: the onboarding/key read threw this
      // launch. That, not a speculative write, is what tells the flow the
      // plugin is the broken part.
      KeystoreKey.lastSecureStorageError =
          'PlatformException(Exception encountered, Failed to unwrap key)';
    });

    test('unlocks anyway: the escrow takes the verified key', () async {
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(escrow.stored, [rightKey]);
    });

    test('escrow → rescue → setAside → persist, in that order', () async {
      await service().unlock(passphrase);
      expect(events, ['escrow', 'rescue', 'setAside', 'persist'],
          reason: 'after setAside the wrapped AES key is gone forever, and '
              'every plugin call before the rescue risks regenerating the '
              'RSA pair that would orphan it');
    });

    test('the plugin is not touched at all before the rescue reads it',
        () async {
      await service().unlock(passphrase);
      expect(secureCallsAtRescue, 0,
          reason: 'createRSAKeysIfNeeded runs on every call; one write '
              'ahead of the rescue could orphan the wrapped AES key');
    });

    test('re-persists the DB key and the onboarding flag into the fresh '
        'store', () async {
      await service().unlock(passphrase);
      expect(secure.store[KeystoreKey.storageKey], rightKey);
      expect(secure.store[OnboardingGate.storageKey], '1');
    });

    test('re-persists every rescued value', () async {
      rescue.result = const RescueResult(
        ok: true,
        method: 'decrypt OAEP SHA-256/MGF1-SHA1',
        values: {
          'trail_panic_duration_v1': '30',
          'trail_panic_auto_send_v1': 'true',
          'trail_github_pat_v1': 'ghp_secret',
        },
      );
      final result = await service().unlock(passphrase);
      expect(secure.store['trail_panic_duration_v1'], '30');
      expect(secure.store['trail_panic_auto_send_v1'], 'true');
      expect(secure.store['trail_github_pat_v1'], 'ghp_secret');
      expect(result.rescue!.method, 'decrypt OAEP SHA-256/MGF1-SHA1');
    });

    test('the summary counts what came back and what did not', () async {
      rescue.result = const RescueResult(
        ok: true,
        method: 'decrypt OAEP SHA-256/MGF1-SHA1',
        values: {
          'trail_panic_duration_v1': '30',
          'trail_panic_auto_send_v1': 'true',
        },
      );
      final summary = (await service().unlock(passphrase)).rescue!;
      expect(summary.rebuilt, isTrue);
      expect(summary.recovered, hasLength(4));
      expect(summary.missing,
          ['trail_github_pat_v1', 'trail_coverage_token_v1']);
    });

    test('writes the onboarding mirror so the next launch cannot be '
        'gated on the plugin', () async {
      await service().unlock(passphrase);
      expect(prefs.getBool(OnboardingGate.mirrorKey), isTrue);
    });

    test('records the marker and releases the worker', () async {
      await setStartupBlocked(true, prefs: prefs);
      await service().unlock(passphrase);
      expect(await SecureStorageMigration.readMarker(prefs: prefs), isNotNull);
      expect(await readStartupBlocked(prefs: prefs), isFalse);
    });

    test('persists the summary for Diagnostics', () async {
      await service().unlock(passphrase);
      final read = await PassphraseRecoveryService.readSummary(prefs: prefs);
      expect(read, isNotNull);
      expect(read!.at, fixedNow);
      expect(read.rebuilt, isTrue);
    });

    test('a rescue that recovers nothing still rebuilds and re-seeds the '
        'two things we know', () async {
      rescue.result = const RescueResult(
        ok: false,
        attempts: ['decrypt OAEP SHA-256/MGF1-SHA1 → KeyStoreException'],
      );
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      final summary = result.rescue!;
      expect(summary.rebuilt, isTrue);
      expect(summary.recovered,
          [KeystoreKey.storageKey, OnboardingGate.storageKey]);
      expect(summary.missing, hasLength(4));
      expect(summary.attempts, hasLength(1),
          reason: 'the attempt list is the bug report');
    });

    test('a setAside that fails leaves the store alone and says so',
        () async {
      rescue.setAsideResult = const SetAsideResult(error: 'IOException');
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue, reason: 'the log is still unlocked');
      final summary = result.rescue!;
      expect(summary.rebuilt, isFalse);
      expect(summary.recovered, isEmpty,
          reason: 'nothing is written into a store that was not rebuilt');
      expect(summary.error, contains('IOException'));
      expect(events, ['escrow', 'rescue', 'setAside'],
          reason: 'no persist into a store that was never rebuilt');
    });

    test('a rescue channel error does not stop the rebuild', () async {
      rescue.result = const RescueResult(error: 'MissingPluginException');
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(result.rescue!.rebuilt, isTrue);
      expect(result.rescue!.error, contains('MissingPluginException'));
    });

    test('an escrow that refuses is a hard failure, not a fake unlock',
        () async {
      escrow.throws = true;
      final result = await service().unlock(passphrase);
      expect(result.ok, isFalse);
      expect(result.error, contains('could not save the key'));
      expect(events, ['escrow'],
          reason: 'never set the store aside without a surviving key');
      expect(secure.store, isEmpty);
    });
  });

  group('diagnosing the plugin without a startup error', () {
    // Second launch of the same incident: the escrow served the key, so
    // startup never threw — but the store still holds a wrapped AES key
    // with no alias left to unwrap it. `status()` is read-only, so asking
    // costs nothing.
    test('a wrapped key with no alias trips the rebuild', () async {
      secure.broken = true;
      rescue.statusResult = const RescueStatus(
        storeFileExists: true,
        wrappedKeyPresent: true,
        aliasExists: false,
      );
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(result.rescue, isNotNull);
      expect(events, ['escrow', 'rescue', 'setAside', 'persist']);
    });

    test('a healthy status leaves the store alone', () async {
      rescue.statusResult = const RescueStatus(
        storeFileExists: true,
        wrappedKeyPresent: true,
        aliasExists: true,
      );
      final result = await service().unlock(passphrase);
      expect(result.rescue, isNull);
      expect(events, ['escrow', 'persist']);
    });

    test('a status the channel cannot answer is not "broken"', () async {
      rescue.statusResult = const RescueStatus(error: 'MissingPluginException');
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(result.rescue, isNull);
      expect(events, ['escrow', 'persist']);
    });

    test('a store that breaks between the check and the write is still '
        'repaired', () async {
      // The one case the diagnosis cannot see coming: status says healthy,
      // the write throws anyway. Same safe order, one launch earlier than
      // it would otherwise happen.
      rescue.statusResult = const RescueStatus(
        storeFileExists: true,
        wrappedKeyPresent: true,
        aliasExists: true,
      );
      secure.broken = true;
      final result = await service().unlock(passphrase);
      expect(result.ok, isTrue);
      expect(result.rescue!.rebuilt, isTrue);
      expect(events, ['escrow', 'rescue', 'setAside', 'persist'],
          reason: 'the escrow still came first and the rescue still beat '
              'setAside');
    });
  });

  group('the result sheet copy', () {
    SecureStorageRescueSummary summary({
      bool rebuilt = true,
      List<String> recovered = const [],
      List<String> missing = const [],
      String? error,
    }) =>
        SecureStorageRescueSummary(
          at: fixedNow,
          rebuilt: rebuilt,
          method: 'decrypt OAEP SHA-256/MGF1-SHA1',
          recovered: recovered,
          missing: missing,
          error: error,
        );

    test('names what came back and what has to be re-entered', () {
      final text = describeRescueOutcome(summary(
        recovered: const [
          'trail_db_passphrase_v1',
          'trail_onboarded_v1',
          'trail_panic_duration_v1',
          'trail_panic_auto_send_v1',
        ],
        missing: const ['trail_github_pat_v1', 'trail_coverage_token_v1'],
      ));
      expect(text, startsWith('Log unlocked.'));
      expect(text, contains('recovered 4 of 6 settings'));
      expect(text, contains('database key, onboarding flag'));
      expect(
        text,
        contains('Could not recover: GitHub token, map-detail server token '
            '— re-enter them in Settings.'),
      );
    });

    test('no "could not recover" sentence when nothing is missing', () {
      final text = describeRescueOutcome(summary(
        recovered: SecureStorageMigration.knownKeys,
      ));
      expect(text, contains('recovered 6 of 6 settings'));
      expect(text, isNot(contains('Could not recover')));
    });

    test('a failed rebuild says the log is still safe', () {
      final text = describeRescueOutcome(
        summary(rebuilt: false, error: 'IOException'),
      );
      expect(text, contains('could not be rebuilt'));
      expect(text, contains('IOException'));
      expect(text, contains('your log is safe'));
    });
  });

  group('the Diagnostics lines', () {
    test('never run reads as such', () {
      expect(describeSecureStorageRescue(null),
          'Secure storage rescue: never run');
    });

    test('names the date, the count and the method', () {
      final line = describeSecureStorageRescue(SecureStorageRescueSummary(
        at: fixedNow,
        rebuilt: true,
        method: 'decrypt OAEP SHA-256/MGF1-SHA1',
        recovered: const ['trail_db_passphrase_v1', 'trail_onboarded_v1'],
        missing: const ['trail_github_pat_v1'],
      ));
      expect(line, contains('23 Aug 2026'));
      expect(line, contains('2/6 recovered'));
      expect(line, contains('decrypt OAEP SHA-256/MGF1-SHA1'));
    });

    test('a store file that is present reads as present', () {
      expect(
        describeSecureStorageStoreFile(const RescueStatus(
          storeFileExists: true,
          wrappedKeyPresent: true,
          aliasExists: true,
        )),
        'Secure storage store file: present',
      );
    });

    test('a set-aside copy dates the line', () {
      final line = describeSecureStorageStoreFile(const RescueStatus(
        storeFileExists: true,
        brokenCopies: ['FlutterSecureStorage.broken-20260823-1030.xml'],
      ));
      expect(line, 'Secure storage store file: present · set aside on '
          '23 Aug 2026');
    });

    test('an unparseable copy name still renders', () {
      final line = describeSecureStorageStoreFile(const RescueStatus(
        brokenCopies: ['weird.xml'],
      ));
      expect(line, contains('missing'));
      expect(line, contains('weird.xml'));
    });

    test('a channel error is reported, not hidden', () {
      expect(
        describeSecureStorageStoreFile(
          const RescueStatus(error: 'MissingPluginException'),
        ),
        contains('MissingPluginException'),
      );
    });

    test('the broken-copy stamp parser', () {
      expect(
        parseBrokenCopyStamp('FlutterSecureStorage.broken-20260823-1030.xml'),
        DateTime(2026, 8, 23, 10, 30),
      );
      expect(parseBrokenCopyStamp('FlutterSecureStorage.xml'), isNull);
      expect(parseBrokenCopyStamp(''), isNull);
    });
  });

  group('the persisted summary', () {
    test('round-trips through JSON', () {
      final original = SecureStorageRescueSummary(
        at: fixedNow,
        rebuilt: true,
        method: 'm',
        recovered: const ['a'],
        missing: const ['b'],
        attempts: const ['x → y'],
        error: 'e',
      );
      final back = SecureStorageRescueSummary.parse(original.toJson())!;
      expect(back.at, fixedNow);
      expect(back.rebuilt, isTrue);
      expect(back.method, 'm');
      expect(back.recovered, ['a']);
      expect(back.missing, ['b']);
      expect(back.attempts, ['x → y']);
      expect(back.error, 'e');
    });

    test('garbage in prefs reads as "never run", never throws', () {
      expect(SecureStorageRescueSummary.parse('{oops'), isNull);
      expect(SecureStorageRescueSummary.parse(''), isNull);
      expect(SecureStorageRescueSummary.parse(null), isNull);
      expect(SecureStorageRescueSummary.parse(jsonEncode({'at': 'soon'})),
          isNull);
    });
  });

  group('isWrongPassphrase', () {
    test('recognises SQLCipher\'s three phrasings', () {
      expect(
        PassphraseRecoveryService.isWrongPassphrase(
          StateError('file is not a database (code 26)'),
        ),
        isTrue,
      );
      expect(
        PassphraseRecoveryService.isWrongPassphrase(
          StateError('file is encrypted or is not a database'),
        ),
        isTrue,
      );
    });

    test('does not claim every failure is a bad passphrase', () {
      expect(
        PassphraseRecoveryService.isWrongPassphrase(StateError('disk I/O')),
        isFalse,
      );
    });
  });
}
