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
/// them — most dangerously `resetOnError`, which now defaults to `true`
/// ("wipe everything on any decrypt error").
void main() {
  late Map<String, String> options;

  setUp(() {
    options = secureStorage.aOptions.toMap();
  });

  test('still asks 10.x to migrate the 9.2.4 Jetpack store', () {
    // Deprecated upstream, removed in 11 — but it is the flag that tells
    // 10.x there may be EncryptedSharedPreferences data to pick up.
    expect(options['encryptedSharedPreferences'], 'true');
    expect(options['migrateOnAlgorithmChange'], 'true');
  });

  test('resetOnError is FALSE — never wipe the SQLCipher key', () {
    // The single most important line in this file. 10.x defaults this to
    // true; with the DB key in secure storage that would turn a transient
    // Keystore hiccup into permanent loss of the user's location log.
    expect(options['resetOnError'], 'false');
  });

  test('ciphers are the pair that survives into flutter_secure_storage 11',
      () {
    expect(
      options['keyCipherAlgorithm'],
      KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding.name,
    );
    expect(
      options['storageCipherAlgorithm'],
      StorageCipherAlgorithm.AES_GCM_NoPadding.name,
    );
  });

  test('no biometric gate — the background isolate must read unattended',
      () {
    // The WorkManager dispatcher reads the DB key with no UI attached; a
    // biometric-bound key would fail every scheduled ping.
    expect(options['enforceBiometrics'], 'false');
  });

  test('prefs file + key prefix are left at the 9.2.4 defaults', () {
    // Changing either orphans every installed user's stored values —
    // 10.x reads the same "FlutterSecureStorage" file with the same
    // prefix only while these stay empty.
    expect(options['sharedPreferencesName'], '');
    expect(options['preferencesKeyPrefix'], '');
    expect(options['storageNamespace'], '');
  });
}
