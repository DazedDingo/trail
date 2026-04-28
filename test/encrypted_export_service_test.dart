import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/encrypted_export_service.dart';

void main() {
  group('EncryptedExportService.validatePassphrase', () {
    test('rejects empty + short, accepts >=8 chars', () {
      expect(EncryptedExportService.validatePassphrase(''), isNotNull);
      expect(EncryptedExportService.validatePassphrase(null), isNotNull);
      expect(EncryptedExportService.validatePassphrase('abc'), isNotNull);
      expect(EncryptedExportService.validatePassphrase('exactly8'), isNull);
      expect(
        EncryptedExportService.validatePassphrase('a much longer phrase'),
        isNull,
      );
    });
  });

  // The encrypt path is delegated to the native EncryptedZipPlugin
  // (zip4j MethodChannel) and produces a standard AES-256 encrypted
  // zip — opens with 7-Zip / macOS Archive Utility / Linux `7z`.
  // Round-tripping it from a pure-Dart unit test would mean
  // re-implementing AES-256 zip extraction in test code; instrumented
  // tests on a real device are the only meaningful coverage and are
  // out of scope for `flutter test`.
}
