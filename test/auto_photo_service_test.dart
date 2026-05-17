import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/services/auto_photo_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AutoPhotoService', () {
    test('isEnabled returns true on a clean install (default ON)', () async {
      expect(await AutoPhotoService().isEnabled(), isTrue);
    });

    test('setEnabled(false) round-trips through isEnabled()', () async {
      await AutoPhotoService().setEnabled(false);
      expect(await AutoPhotoService().isEnabled(), isFalse);
    });

    test('setEnabled(true) round-trips through isEnabled()', () async {
      await AutoPhotoService().setEnabled(false);
      await AutoPhotoService().setEnabled(true);
      expect(await AutoPhotoService().isEnabled(), isTrue);
    });

    test('hasExplicitChoice is false on a clean install', () async {
      expect(await AutoPhotoService().hasExplicitChoice(), isFalse);
    });

    test('hasExplicitChoice flips true after setEnabled (either value)',
        () async {
      await AutoPhotoService().setEnabled(false);
      expect(await AutoPhotoService().hasExplicitChoice(), isTrue);
    });
  });
}
