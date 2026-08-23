import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/secure_storage_rescue.dart';

/// Stand-in for `SecureStorageRescuePlugin.kt`. Models the three native
/// methods closely enough to pin the wire contract: `rescue` gives back
/// `{ok, method, values, attempts}`, `setAside` `{stamp, movedFiles,
/// deletedAliases}`, `status` the four on-disk facts, and every failure
/// comes back as `result.error(<exception simple name>, message, null)`.
const _channelName = 'trail/secure_storage_rescue_test';

class _FakeRescueNative {
  final List<MethodCall> calls = [];

  /// Per-method canned reply. `null` models a native `success(null)`.
  final Map<String, Object?> replies = {};

  /// When set, the named method fails with this exception class name.
  final Map<String, String> failures = {};

  static const channel = MethodChannel(_channelName);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final failure = failures[call.method];
    if (failure != null) {
      throw PlatformException(code: failure, message: 'simulated $failure');
    }
    return replies[call.method];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRescueNative native;
  late SecureStorageRescue rescue;

  setUp(() {
    native = _FakeRescueNative()..install();
    rescue = const SecureStorageRescue(channel: _FakeRescueNative.channel);
  });

  tearDown(() {
    native.uninstall();
    SecureStorageRescue.setInstanceForTest(null);
  });

  group('rescue()', () {
    test('parses a successful unwrap into typed fields', () async {
      native.replies['rescue'] = <Object?, Object?>{
        'ok': true,
        'method': 'decrypt OAEP SHA-256/MGF1-SHA1',
        'values': <Object?, Object?>{
          'trail_db_passphrase_v1': 'the-key',
          'trail_github_pat_v1': 'ghp_x',
        },
        'attempts': <Object?>[
          'decrypt OAEP SHA-256/MGF1-SHA1 → ok',
        ],
      };
      final result = await rescue.rescue();
      expect(result.ok, isTrue);
      expect(result.method, 'decrypt OAEP SHA-256/MGF1-SHA1');
      expect(result.values, {
        'trail_db_passphrase_v1': 'the-key',
        'trail_github_pat_v1': 'ghp_x',
      });
      expect(result.attempts, hasLength(1));
      expect(result.error, isNull);
    });

    test('a failed unwrap keeps every attempt — that is the bug report',
        () async {
      native.replies['rescue'] = <Object?, Object?>{
        'ok': false,
        'attempts': <Object?>[
          'decrypt OAEP SHA-256/MGF1-SHA1 → KeyStoreException',
          'unwrap OAEP SHA-256/MGF1-SHA1 → InvalidKeyException',
        ],
      };
      final result = await rescue.rescue();
      expect(result.ok, isFalse);
      expect(result.method, isNull);
      expect(result.values, isEmpty);
      expect(result.attempts, [
        'decrypt OAEP SHA-256/MGF1-SHA1 → KeyStoreException',
        'unwrap OAEP SHA-256/MGF1-SHA1 → InvalidKeyException',
      ]);
    });

    test('a platform throw becomes an error, never an exception', () async {
      // Total by contract: this runs after the user has already unlocked
      // their log, and a throw here would undo nothing but the good news.
      native.failures['rescue'] = 'KeyStoreException';
      final result = await rescue.rescue();
      expect(result.ok, isFalse);
      expect(result.error, contains('KeyStoreException'));
      expect(result.values, isEmpty);
    });

    test('no handler at all (wrong isolate) degrades to an error', () async {
      const absent = SecureStorageRescue(
        channel: MethodChannel('trail/secure_storage_rescue_absent'),
      );
      final result = await absent.rescue();
      expect(result.ok, isFalse);
      expect(result.error, 'MissingPluginException');
    });

    test('a null reply is an error, not a silent success', () async {
      native.replies['rescue'] = null;
      final result = await rescue.rescue();
      expect(result.ok, isFalse);
      expect(result.error, 'no result');
    });

    test('missing / malformed fields default to empty, never throw',
        () async {
      native.replies['rescue'] = <Object?, Object?>{'ok': true};
      final result = await rescue.rescue();
      expect(result.ok, isTrue);
      expect(result.values, isEmpty);
      expect(result.attempts, isEmpty);
      expect(result.method, isNull);
    });
  });

  group('setAside()', () {
    test('parses the moved files and deleted aliases', () async {
      native.replies['setAside'] = <Object?, Object?>{
        'stamp': '20260823-1030',
        'movedFiles': <Object?>[
          'FlutterSecureStorage.broken-20260823-1030.xml',
          'FlutterSecureStorageConfiguration.broken-20260823-1030.xml',
        ],
        'deletedAliases': <Object?>[
          'com.dazeddingo.trail.FlutterSecureStoragePluginKeyOAEP',
        ],
      };
      final result = await rescue.setAside();
      expect(result.ok, isTrue);
      expect(result.stamp, '20260823-1030');
      expect(result.movedFiles, hasLength(2));
      expect(result.deletedAliases, hasLength(1));
    });

    test('a platform throw is reported, not raised', () async {
      native.failures['setAside'] = 'IOException';
      final result = await rescue.setAside();
      expect(result.ok, isFalse);
      expect(result.error, contains('IOException'));
      expect(result.movedFiles, isEmpty);
    });

    test('a null reply is not "it worked"', () async {
      native.replies['setAside'] = null;
      final result = await rescue.setAside();
      expect(result.ok, isFalse);
    });

    test('is never called as a side-effect of rescue()', () async {
      native.replies['rescue'] = <Object?, Object?>{'ok': false};
      await rescue.rescue();
      expect(native.calls.map((c) => c.method), ['rescue'],
          reason: 'rescue() is read-only; only the recovery flow may '
              'order the destructive step');
    });
  });

  group('status()', () {
    test('parses the four on-disk facts', () async {
      native.replies['status'] = <Object?, Object?>{
        'storeFileExists': true,
        'wrappedKeyPresent': true,
        'aliasExists': false,
        'brokenCopies': <Object?>['FlutterSecureStorage.broken-20260823-1030.xml'],
      };
      final status = await rescue.status();
      expect(status.storeFileExists, isTrue);
      expect(status.wrappedKeyPresent, isTrue);
      expect(status.aliasExists, isFalse);
      expect(status.brokenCopies, hasLength(1));
      expect(status.error, isNull);
    });

    test('defaults everything to false on an empty map', () async {
      native.replies['status'] = <Object?, Object?>{};
      final status = await rescue.status();
      expect(status.storeFileExists, isFalse);
      expect(status.wrappedKeyPresent, isFalse);
      expect(status.aliasExists, isFalse);
      expect(status.brokenCopies, isEmpty);
    });

    test('a platform throw becomes an error line', () async {
      native.failures['status'] = 'KeyStoreException';
      final status = await rescue.status();
      expect(status.error, contains('KeyStoreException'));
      expect(status.storeFileExists, isFalse);
    });
  });

  group('the instance seam', () {
    test('setInstanceForTest swaps it and null restores the default', () {
      const swapped = SecureStorageRescue(channel: _FakeRescueNative.channel);
      SecureStorageRescue.setInstanceForTest(swapped);
      expect(SecureStorageRescue.instance, same(swapped));
      SecureStorageRescue.setInstanceForTest(null);
      expect(SecureStorageRescue.instance, isNot(same(swapped)));
    });
  });
}
