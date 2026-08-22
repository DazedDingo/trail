import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/secure_storage.dart';

/// The shared handle must carry the exact options every former
/// per-class instance used; a drift in `encryptedSharedPreferences`
/// would read a different preferences file and report every stored
/// value (onboarding flag, panic prefs, PAT) as missing.
void main() {
  test('secureStorage uses EncryptedSharedPreferences on Android', () {
    expect(
      secureStorage.aOptions.toMap()['encryptedSharedPreferences'],
      'true',
    );
  });
}
