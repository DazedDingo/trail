import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/db/database.dart';
import 'package:trail/services/key_escrow.dart';

/// A [KeyEscrow] whose two primitives are recorded, so the real
/// [KeyEscrow.mirrorAfterOpen] logic (fingerprint compare, then store)
/// runs unchanged.
///
/// `_openWithKey` itself cannot be exercised under `flutter test`:
/// `sqflite_sqlcipher` hardcodes its own `databaseFactory` (no setter, so
/// `sqflite_common_ffi` cannot take over) and SQLCipher has no platform
/// channel here (gotcha 3). [TrailDatabase.escrowKeyAfterOpen] is the
/// seam the open path calls once `openDatabase` has returned.
class _FakeEscrow extends KeyEscrow {
  _FakeEscrow({this.existingKey, this.statusError})
      : super(channel: const MethodChannel('trail/key_escrow_db_test'));

  String? existingKey;
  final String? statusError;

  final List<String> stored = [];
  final List<String> statusCalls = [];
  bool storeThrows = false;

  final Completer<void> firstStore = Completer<void>();

  @override
  Future<EscrowStatus> status() async {
    statusCalls.add('status');
    if (statusError != null) return EscrowStatus(error: statusError);
    final key = existingKey;
    return EscrowStatus(
      present: key != null,
      aliasExists: key != null,
      storedAt: key == null ? null : DateTime(2026, 8, 23),
      keySha256: key == null ? null : KeyEscrow.fingerprintOf(key),
    );
  }

  @override
  Future<void> store(String key) async {
    if (storeThrows) {
      throw PlatformException(code: 'KeyStoreException', message: 'nope');
    }
    stored.add(key);
    existingKey = key;
    if (!firstStore.isCompleted) firstStore.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => KeyEscrow.setInstanceForTest(null));

  group('TrailDatabase.escrowKeyAfterOpen', () {
    test('mirrors the key into the escrow after a successful open',
        () async {
      final escrow = _FakeEscrow();
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('the-verified-key');
      await escrow.firstStore.future;

      expect(escrow.stored, ['the-verified-key']);
    });

    test('does not re-store a key the escrow already holds', () async {
      final escrow = _FakeEscrow(existingKey: 'the-verified-key');
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('the-verified-key');
      await pumpEventQueue();

      expect(escrow.stored, isEmpty,
          reason: 'every DB open would otherwise pay a Keystore write');
      expect(escrow.statusCalls, hasLength(1));
    });

    test('re-stores after a rekey (the escrowed key differs)', () async {
      final escrow = _FakeEscrow(existingKey: 'pre-rekey-key');
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('post-rekey-key');
      await escrow.firstStore.future;

      expect(escrow.stored, ['post-rekey-key']);
    });

    test('returns synchronously — the open path never awaits the escrow',
        () async {
      final escrow = _FakeEscrow();
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('k');
      expect(escrow.stored, isEmpty,
          reason: 'fire-and-forget: nothing has run yet on this turn');

      await escrow.firstStore.future;
      expect(escrow.stored, ['k']);
    });

    test('a throwing store never surfaces on the open path', () async {
      final escrow = _FakeEscrow()..storeThrows = true;
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('k');
      await pumpEventQueue();

      expect(escrow.stored, isEmpty);
    });

    test('a status the escrow cannot read is skipped, not guessed at',
        () async {
      // MissingPluginException is the WorkManager isolate's answer — our
      // channel handler lives in MainActivity, which that isolate has no
      // instance of. Storing blind there would be a Keystore write per
      // cadence tick with no way to verify it.
      final escrow = _FakeEscrow(statusError: 'MissingPluginException');
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('k');
      await pumpEventQueue();

      expect(escrow.stored, isEmpty);
    });

    test('an empty key is never escrowed', () async {
      final escrow = _FakeEscrow();
      KeyEscrow.setInstanceForTest(escrow);

      TrailDatabase.escrowKeyAfterOpen('');
      await pumpEventQueue();

      expect(escrow.stored, isEmpty);
      expect(escrow.statusCalls, isEmpty);
    });
  });
}
