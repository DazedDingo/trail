import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/services/photo_shuffle_prefs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default salt is 0', () async {
    expect(await PhotoShufflePrefs.getSalt(), 0);
  });

  test('bumpSalt increments and persists', () async {
    expect(await PhotoShufflePrefs.bumpSalt(), 1);
    expect(await PhotoShufflePrefs.bumpSalt(), 2);
    expect(await PhotoShufflePrefs.getSalt(), 2);
  });

  test('survives across read after write', () async {
    await PhotoShufflePrefs.bumpSalt();
    await PhotoShufflePrefs.bumpSalt();
    await PhotoShufflePrefs.bumpSalt();
    expect(await PhotoShufflePrefs.getSalt(), 3);
  });
}
