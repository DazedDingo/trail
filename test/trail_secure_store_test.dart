import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// The wire contract between `TrailSecureStore` and
/// `TrailSecureStorePlugin.kt`. Nothing here can exercise AndroidKeyStore,
/// so what it pins is the part a Dart change can silently break: the
/// channel name, the method names, the argument map shape, and — most
/// importantly — which failures are allowed to be swallowed.
///
/// The one rule worth stating out loud: [TrailSecureStore.read] must
/// **throw** when the native side reports an error. "Nothing is stored"
/// and "there is something stored that I cannot decrypt" are the two
/// states `KeystoreKey.getOrCreate` branches on, and collapsing them into
/// `null` is how a fresh key gets minted over a perfectly good log.
class _FakeNative {
  _FakeNative(this.channelName);

  final String channelName;
  final List<MethodCall> calls = [];
  final Map<String, String> entries = {};

  /// When set, the named method fails with this exception class name.
  final Map<String, String> failures = {};

  bool aliasExists = true;

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
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return entries[key];
      case 'write':
        entries[key!] = args['value']! as String;
        return null;
      case 'delete':
        entries.remove(key);
        return null;
      case 'containsKey':
        return entries.containsKey(key);
      case 'readAll':
        return Map<String, String>.from(entries);
      case 'deleteAll':
        entries.clear();
        return null;
      case 'status':
        return <String, Object?>{
          'aliasExists': aliasExists,
          'entryCount': entries.length,
        };
      default:
        return null;
    }
  }

  int callsTo(String method) => calls.where((c) => c.method == method).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late TrailSecureStore store;

  setUp(() {
    native = _FakeNative('trail/secure_store_unit_test')..install();
    store = TrailSecureStore(channel: native.channel);
  });

  tearDown(() => native.uninstall());

  group('the channel', () {
    test('the production channel name is trail/secure_store', () {
      // Pinned: the Kotlin side hard-codes it, and a rename would look
      // like "every secret vanished" rather than like a bug.
      expect(TrailSecureStore.channel.name, 'trail/secure_store');
    });

    test('the default constructor uses it', () {
      expect(const TrailSecureStore(), isA<TrailSecureStore>());
    });
  });

  group('read', () {
    test('returns the stored value', () async {
      native.entries['k'] = 'v';
      expect(await store.read(key: 'k'), 'v');
    });

    test('returns null when nothing is stored', () async {
      expect(await store.read(key: 'k'), isNull);
    });

    test('sends the key in the argument map', () async {
      await store.read(key: 'trail_db_passphrase_v1');
      final args = (native.calls.single.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'trail_db_passphrase_v1');
    });

    test('THROWS on a native error — never a silent null', () async {
      native.failures['read'] = 'AEADBadTagException';
      await expectLater(
        store.read(key: 'k'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'AEADBadTagException')),
      );
    });

    test('throws MissingPluginException in an engine with no handler',
        () async {
      final orphan = const TrailSecureStore(
        channel: MethodChannel('trail/secure_store_absent'),
      );
      await expectLater(
        orphan.read(key: 'k'),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('write', () {
    test('round-trips a value', () async {
      await store.write(key: 'k', value: 'v');
      expect(await store.read(key: 'k'), 'v');
    });

    test('sends key and value', () async {
      await store.write(key: 'k', value: 'v');
      final args = (native.calls.first.arguments as Map).cast<String, Object?>();
      expect(args['key'], 'k');
      expect(args['value'], 'v');
    });

    test('a null value deletes, exactly like flutter_secure_storage',
        () async {
      // Call sites were moved verbatim off the old plugin; the null
      // contract has to move with them.
      native.entries['k'] = 'v';
      await store.write(key: 'k', value: null);
      expect(native.entries, isEmpty);
      expect(native.callsTo('write'), 0);
      expect(native.callsTo('delete'), 1);
    });

    test('an empty string is a value, not a delete', () async {
      await store.write(key: 'k', value: '');
      expect(native.entries['k'], '');
      expect(native.callsTo('delete'), 0);
    });

    test('overwrites', () async {
      await store.write(key: 'k', value: 'one');
      await store.write(key: 'k', value: 'two');
      expect(await store.read(key: 'k'), 'two');
    });

    test('a native failure propagates', () async {
      native.failures['write'] = 'KeyStoreException';
      await expectLater(
        store.write(key: 'k', value: 'v'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('delete / deleteAll / containsKey', () {
    test('delete removes one entry', () async {
      native.entries.addAll({'a': '1', 'b': '2'});
      await store.delete(key: 'a');
      expect(native.entries.keys, ['b']);
    });

    test('delete is idempotent on an absent key', () async {
      await expectLater(store.delete(key: 'nope'), completes);
    });

    test('containsKey is true only for stored keys', () async {
      native.entries['a'] = '1';
      expect(await store.containsKey(key: 'a'), isTrue);
      expect(await store.containsKey(key: 'b'), isFalse);
    });

    test('containsKey degrades to false on a null answer', () async {
      final quiet = TrailSecureStore(
        channel: const MethodChannel('trail/secure_store_quiet'),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('trail/secure_store_quiet'),
        (_) async => null,
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('trail/secure_store_quiet'),
          null,
        ),
      );
      expect(await quiet.containsKey(key: 'a'), isFalse);
    });

    test('deleteAll empties the store', () async {
      native.entries.addAll({'a': '1', 'b': '2'});
      await store.deleteAll();
      expect(native.entries, isEmpty);
    });
  });

  group('readAll', () {
    test('returns every entry', () async {
      native.entries.addAll({'a': '1', 'b': '2'});
      expect(await store.readAll(), {'a': '1', 'b': '2'});
    });

    test('an empty store is an empty map, not null', () async {
      expect(await store.readAll(), isEmpty);
    });
  });

  group('status', () {
    test('reports the alias and the entry count', () async {
      native.entries.addAll({'a': '1', 'b': '2'});
      final status = await store.status();
      expect(status.aliasExists, isTrue);
      expect(status.entryCount, 2);
      expect(status.error, isNull);
    });

    test('the unreadable-store shape: entries but no alias', () async {
      native
        ..aliasExists = false
        ..entries['a'] = '1';
      final status = await store.status();
      expect(status.aliasExists, isFalse);
      expect(status.entryCount, 1);
    });

    test('NEVER throws — a platform failure becomes .error', () async {
      // Diagnostics has to render something even when the store is the
      // broken part; same contract as `KeyEscrow.status`.
      native.failures['status'] = 'KeyStoreException';
      final status = await store.status();
      expect(status.error, contains('KeyStoreException'));
      expect(status.aliasExists, isFalse);
      expect(status.entryCount, 0);
    });

    test('no handler at all reads as MissingPluginException', () async {
      const orphan = TrailSecureStore(
        channel: MethodChannel('trail/secure_store_absent'),
      );
      expect((await orphan.status()).error, 'MissingPluginException');
    });
  });

  group('describeStoreError', () {
    test('a PlatformException reads as code: message', () {
      expect(
        describeStoreError(
          PlatformException(code: 'AEADBadTagException', message: 'bad tag'),
        ),
        'AEADBadTagException: bad tag',
      );
    });

    test('a message-less PlatformException is just the code', () {
      expect(
        describeStoreError(PlatformException(code: 'KeyStoreException')),
        'KeyStoreException',
      );
    });

    test('a missing handler is named explicitly', () {
      expect(
        describeStoreError(MissingPluginException('no impl')),
        'MissingPluginException',
      );
    });
  });
}
