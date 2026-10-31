import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/secure_storage.dart';
import 'package:trail/services/secure_storage_migration.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// [secureStorage] is the ONE handle every Trail secret goes through.
///
/// Until 0.17.10 this file also pinned the `AndroidOptions` of a second,
/// legacy `flutter_secure_storage` handle that existed purely so the
/// one-shot migration could read the old store once (namespace / prefix /
/// cipher all had to match 9.2.4's byte for byte, or the migration would
/// silently read an empty prefs file and report every secret — **the
/// SQLCipher key** included — as missing). The migration is done and the
/// dependency is gone, so those assertions went with it; what is left is
/// the identity of the app-wide handle and the canonical key list.
void main() {
  test('the app-wide handle is Trail\'s own store, nothing else', () {
    // No wrapper, no legacy fallback, no `flutter_secure_storage` on the
    // other side of it (gotcha 39).
    expect(secureStorage, isA<TrailSecureStore>());
    expect(secureStorage.runtimeType, TrailSecureStore,
        reason: 'the migrating wrapper is gone — this is the raw store');
  });

  test('knownKeys is the one canonical secret list', () {
    expect(trailSecretKeys, SecureStorageMigration.knownKeys);
    expect(trailSecretKeys.first, 'trail_db_passphrase_v1',
        reason: 'the SQLCipher key leads the list it is most important in');
  });

  group('describeSecureStore (0.17.10)', () {
    test('null status reads as "reading…"', () {
      expect(describeSecureStore(null), 'Trail secure store: reading…');
    });

    test('a read error is reported verbatim, not swallowed into "0 entries"',
        () {
      expect(
        describeSecureStore(
          const SecureStoreStatus(error: 'MissingPluginException'),
        ),
        'Trail secure store: unavailable (MissingPluginException)',
      );
    });

    test('a healthy store reports entry count + alias state', () {
      expect(
        describeSecureStore(
          const SecureStoreStatus(aliasExists: true, entryCount: 5),
        ),
        'Trail secure store: 5 entries · Keystore alias present',
      );
    });

    test('singular "entry" for a count of exactly one', () {
      expect(
        describeSecureStore(
          const SecureStoreStatus(aliasExists: true, entryCount: 1),
        ),
        'Trail secure store: 1 entry · Keystore alias present',
      );
    });

    test('a missing alias with existing entries is called out — this is '
        'the "everything will throw on write" state', () {
      expect(
        describeSecureStore(
          const SecureStoreStatus(aliasExists: false, entryCount: 3),
        ),
        'Trail secure store: 3 entries · alias MISSING',
      );
    });
  });
}
