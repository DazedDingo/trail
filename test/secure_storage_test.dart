import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/secure_storage.dart';

/// The shared handle must carry the exact options every former
/// per-class instance used; a drift in namespace / prefix / cipher would
/// read a different preferences file and report every stored value
/// (onboarding flag, panic prefs, PAT, **the SQLCipher key**) as missing.
///
/// Every option is pinned here rather than trusted to the package's
/// defaults, because `flutter_secure_storage` 10.0.0 changed several of
/// them — most dangerously `resetOnError`, which defaults to `true`
/// ("wipe everything on any decrypt error") in both 10.x and 11.x.
void main() {
  late Map<String, String> options;

  setUp(() {
    options = secureStorage.aOptions.toMap();
  });

  test('the deprecated Jetpack flag is gone — release B is on 11.x', () {
    // 11.0.0 removed `encryptedSharedPreferences` (and every branch that
    // could read 9.2.4's Jetpack store) along with `sharedPreferencesName`.
    // Their absence from the option map is what proves this build is the
    // one the `notMigrated` startup gate exists for.
    expect(options.containsKey('encryptedSharedPreferences'), isFalse);
    expect(options.containsKey('sharedPreferencesName'), isFalse);
  });

  test('migrateOnAlgorithmChange survives into 11.x and stays on', () {
    // Still the only non-destructive answer if the saved algorithm
    // markers ever disagree with the pair below; without it 11.x's
    // key-mismatch handler has nothing left but deleteAll().
    expect(options['migrateOnAlgorithmChange'], 'true');
  });

  test('resetOnError is FALSE — never wipe the SQLCipher key', () {
    // The single most important line in this file. 10.x and 11.x default
    // this to true; with the DB key in secure storage that would turn a
    // transient Keystore hiccup into permanent loss of the location log.
    expect(options['resetOnError'], 'false');
  });

  test('ciphers are the pair flutter_secure_storage 11 still ships', () {
    expect(
      options['keyCipherAlgorithm'],
      KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding.name,
    );
    expect(
      options['storageCipherAlgorithm'],
      StorageCipherAlgorithm.AES_GCM_NoPadding.name,
    );
  });

  test('migrateWithBackup stays off — our marker is the safety net', () {
    // It routes through a separate, less-travelled migration path;
    // verify-and-rewrite plus the marker is what we actually test.
    expect(options['migrateWithBackup'], 'false');
  });

  test('no biometric gate — the background isolate must read unattended',
      () {
    // The WorkManager dispatcher reads the DB key with no UI attached; a
    // biometric-bound key would fail every scheduled ping.
    expect(options['enforceBiometrics'], 'false');
  });

  test('prefs file + key prefix are left at the 9.2.4 defaults', () {
    // Changing either orphans every installed user's stored values —
    // 11.x reads the same "FlutterSecureStorage" file with the same
    // prefix only while these stay empty.
    expect(options['preferencesKeyPrefix'], '');
    expect(options['storageNamespace'], '');
  });
}
