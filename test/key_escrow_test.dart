import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/key_escrow.dart';

/// Stand-in for `KeyEscrowPlugin.kt`. Models the four native methods
/// closely enough to pin the wire contract: `store` takes a `bytes`
/// byte-array, `load` gives it back (or null), `status` reports the
/// prefs triple plus the plaintext fingerprint, and every failure comes
/// back as `result.error(<exception simple name>, message, null)`.
class _FakeEscrowNative {
  _FakeEscrowNative(this.channelName);

  final String channelName;
  final List<MethodCall> calls = [];

  Uint8List? blob;
  int? storedAtMs;
  String? sha256Hex;
  bool aliasExists = true;

  /// When set, the named method fails with this exception class name.
  final Map<String, String> failures = {};

  MethodChannel get channel => MethodChannel(channelName);

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
    switch (call.method) {
      case 'store':
        final args = (call.arguments as Map).cast<String, Object?>();
        final bytes = args['bytes'] as Uint8List;
        blob = bytes;
        sha256Hex = KeyEscrow.fingerprintOf(utf8.decode(bytes));
        storedAtMs ??= 1755900000000; // idempotent: first store wins
        aliasExists = true;
        return null;
      case 'load':
        if (!aliasExists) return null;
        return blob;
      case 'clear':
        blob = null;
        storedAtMs = null;
        sha256Hex = null;
        aliasExists = false;
        return null;
      case 'status':
        return <String, Object?>{
          'present': blob != null,
          'storedAt': storedAtMs,
          'aliasExists': aliasExists,
          'keySha256': sha256Hex,
        };
      default:
        return null;
    }
  }

  int callsTo(String method) => calls.where((c) => c.method == method).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEscrowNative native;
  late KeyEscrow escrow;

  setUp(() {
    native = _FakeEscrowNative('trail/key_escrow_test')..install();
    escrow = KeyEscrow(channel: native.channel);
  });

  tearDown(() => native.uninstall());

  group('KeyEscrow.store / load', () {
    test('round trips the key through the native side', () async {
      await escrow.store('a-256-bit-base64url-key');
      final result = await escrow.load();
      expect(result.key, 'a-256-bit-base64url-key');
      expect(result.error, isNull);
    });

    test('sends the key as UTF-8 bytes under `bytes`', () async {
      await escrow.store('key-ünicode');
      final args =
          (native.calls.single.arguments as Map).cast<String, Object?>();
      expect(args['bytes'], isA<Uint8List>());
      expect(utf8.decode(args['bytes'] as Uint8List), 'key-ünicode');
    });

    test('round trips a non-ASCII key without corruption', () async {
      await escrow.store('clé-de-chiffrement-æøå');
      expect((await escrow.load()).key, 'clé-de-chiffrement-æøå');
    });

    test('load with nothing stored is (null, null) — not an error',
        () async {
      final result = await escrow.load();
      expect(result.key, isNull);
      expect(result.error, isNull);
      expect(result.isEmpty, isTrue);
    });

    test('load returns (null, null) when the alias is gone and native '
        'answers null', () async {
      await escrow.store('k');
      native.aliasExists = false;
      final result = await escrow.load();
      expect(result.key, isNull);
      expect(result.error, isNull);
    });

    test('a platform error sets `error` to code + message, never key',
        () async {
      native.failures['load'] = 'AEADBadTagException';
      final result = await escrow.load();
      expect(result.key, isNull);
      expect(result.error, 'AEADBadTagException: simulated AEADBadTagException');
      expect(result.isEmpty, isFalse,
          reason: '"unreadable" must not look like "nothing stored"');
    });

    test('a KeyPermanentlyInvalidated error surfaces the class name',
        () async {
      native.failures['load'] = 'KeyPermanentlyInvalidatedException';
      final result = await escrow.load();
      expect(result.error, startsWith('KeyPermanentlyInvalidatedException'));
    });

    test('no handler at all (the WorkManager isolate) is an error, not a '
        'key', () async {
      // No MainActivity → no channel handler → MissingPluginException.
      // load() must absorb it: the DB read path calls this unguarded.
      final orphan = const KeyEscrow(
        channel: MethodChannel('trail/key_escrow_unregistered'),
      );
      final result = await orphan.load();
      expect(result.key, isNull);
      expect(result.error, 'MissingPluginException');
    });

    test('store surfaces platform errors to its caller', () async {
      native.failures['store'] = 'IllegalArgumentException';
      await expectLater(escrow.store('k'), throwsA(isA<PlatformException>()));
    });
  });

  group('KeyEscrow.clear', () {
    test('invokes the native clear', () async {
      await escrow.store('k');
      await escrow.clear();
      expect(native.callsTo('clear'), 1);
      expect((await escrow.load()).key, isNull);
    });
  });

  group('KeyEscrow.status', () {
    test('reports nothing stored on a fresh install', () async {
      final status = await escrow.status();
      expect(status.present, isFalse);
      expect(status.storedAt, isNull);
      expect(status.keySha256, isNull);
      expect(status.error, isNull);
    });

    test('reports present + storedAt + fingerprint after a store', () async {
      await escrow.store('the-key');
      final status = await escrow.status();
      expect(status.present, isTrue);
      expect(status.aliasExists, isTrue);
      expect(status.storedAt,
          DateTime.fromMillisecondsSinceEpoch(1755900000000));
      expect(status.keySha256, KeyEscrow.fingerprintOf('the-key'));
    });

    test('a platform error yields present:false with an error, not a throw',
        () async {
      native.failures['status'] = 'KeyStoreException';
      final status = await escrow.status();
      expect(status.present, isFalse);
      expect(status.error, startsWith('KeyStoreException'));
    });
  });

  group('KeyEscrow.mirrorAfterOpen', () {
    test('stores when nothing is escrowed yet', () async {
      await escrow.mirrorAfterOpen('fresh-key');
      expect(native.callsTo('store'), 1);
      expect((await escrow.load()).key, 'fresh-key');
    });

    test('is a no-op when the same key is already escrowed', () async {
      await escrow.store('same-key');
      native.calls.clear();
      await escrow.mirrorAfterOpen('same-key');
      expect(native.callsTo('store'), 0,
          reason: 'fingerprint compare must avoid a Keystore round trip');
      expect(native.callsTo('load'), 0, reason: 'and avoid a decrypt');
    });

    test('re-stores when the escrowed key differs (rekey / passphrase '
        'change)', () async {
      await escrow.store('old-key');
      native.calls.clear();
      await escrow.mirrorAfterOpen('new-key');
      expect(native.callsTo('store'), 1);
      expect((await escrow.load()).key, 'new-key');
    });

    test('re-stores when the blob is present but the alias is gone',
        () async {
      await escrow.store('k');
      native.aliasExists = false;
      native.calls.clear();
      await escrow.mirrorAfterOpen('k');
      expect(native.callsTo('store'), 1);
    });

    test('does nothing and does not throw when status fails', () async {
      native.failures['status'] = 'KeyStoreException';
      await escrow.mirrorAfterOpen('k');
      expect(native.callsTo('store'), 0);
    });

    test('swallows a failing store — the open path must never see it',
        () async {
      native.failures['store'] = 'ProviderException';
      await expectLater(escrow.mirrorAfterOpen('k'), completes);
    });

    test('swallows MissingPluginException (WorkManager isolate)', () async {
      final orphan = const KeyEscrow(
        channel: MethodChannel('trail/key_escrow_unregistered'),
      );
      await expectLater(orphan.mirrorAfterOpen('k'), completes);
    });

    test('refuses to escrow an empty key', () async {
      await escrow.mirrorAfterOpen('');
      expect(native.calls, isEmpty);
    });
  });

  group('KeyEscrow.fingerprintOf', () {
    test('is hex SHA-256 of the UTF-8 bytes (matches Kotlin sha256Hex)',
        () async {
      expect(
        KeyEscrow.fingerprintOf('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('different keys give different fingerprints', () {
      expect(KeyEscrow.fingerprintOf('a'),
          isNot(KeyEscrow.fingerprintOf('b')));
    });
  });

  group('KeyEscrow.instance seam', () {
    test('setInstanceForTest swaps and null restores the default', () {
      final fake = KeyEscrow(channel: native.channel);
      KeyEscrow.setInstanceForTest(fake);
      expect(identical(KeyEscrow.instance, fake), isTrue);
      KeyEscrow.setInstanceForTest(null);
      expect(identical(KeyEscrow.instance, fake), isFalse);
    });
  });

  group('describeKeyEscrow', () {
    test('present + a read that came from secure storage', () {
      final line = describeKeyEscrow(
        status: EscrowStatus(
          present: true,
          aliasExists: true,
          storedAt: DateTime(2026, 8, 23, 12),
        ),
        lastReadSource: 'secure storage',
      );
      expect(line,
          'Key escrow: present since 23 Aug 2026 · last read from: '
          'secure storage');
    });

    test('present + a read that fell through to the escrow names the error',
        () {
      final line = describeKeyEscrow(
        status: EscrowStatus(
          present: true,
          aliasExists: true,
          storedAt: DateTime(2026, 8, 23, 12),
        ),
        lastReadSource: 'escrow',
        lastSecureStorageError: 'PlatformException(Exception encountered)',
      );
      expect(
        line,
        'Key escrow: present since 23 Aug 2026 · last read from: escrow '
        '(error: PlatformException(Exception encountered))',
      );
    });

    test('carries the year, never a bare day + month', () {
      // date_labels convention: "23 Aug 2026", never "23 Aug".
      final line = describeKeyEscrow(
        status: EscrowStatus(
          present: true,
          aliasExists: true,
          storedAt: DateTime(2024, 8, 11, 9),
        ),
      );
      expect(line, contains('11 Aug 2024'));
    });

    test('nothing stored yet', () {
      expect(
        describeKeyEscrow(status: const EscrowStatus()),
        'Key escrow: not stored yet · last read from: not read yet',
      );
    });

    test('blob present but the alias is gone is called out', () {
      final line = describeKeyEscrow(
        status: EscrowStatus(
          present: true,
          storedAt: DateTime(2026, 8, 23),
        ),
        lastReadSource: 'secure storage',
      );
      expect(line, contains('Keystore alias is gone'));
    });

    test('a status that could not be read says unavailable, with why', () {
      final line = describeKeyEscrow(
        status: const EscrowStatus(error: 'MissingPluginException'),
      );
      expect(line, startsWith('Key escrow: unavailable '
          '(MissingPluginException)'));
    });

    test('present with no storedAt still renders', () {
      expect(
        describeKeyEscrow(
          status: const EscrowStatus(present: true, aliasExists: true),
        ),
        'Key escrow: present · last read from: not read yet',
      );
    });
  });
}
