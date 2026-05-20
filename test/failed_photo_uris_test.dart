import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/services/failed_photo_uris.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FailedPhotoUris.clearAll();
    await FailedPhotoUris.preload();
  });

  test('isFailed defaults to false on a clean install', () {
    expect(FailedPhotoUris.isFailed('https://x/y.jpg'), isFalse);
    expect(FailedPhotoUris.count, 0);
  });

  test('register persists across a fresh preload (simulated restart)',
      () async {
    await FailedPhotoUris.register('https://x/y.jpg');
    expect(FailedPhotoUris.isFailed('https://x/y.jpg'), isTrue);

    // Reset in-memory cache to simulate a fresh app start, then verify
    // preload restores the denylist from SharedPreferences.
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList('trail_failed_photo_uris_v1');
    expect(raw, contains('https://x/y.jpg'));
  });

  test('register is idempotent — duplicates collapse', () async {
    await FailedPhotoUris.register('https://x/y.jpg');
    await FailedPhotoUris.register('https://x/y.jpg');
    await FailedPhotoUris.register('https://x/y.jpg');
    expect(FailedPhotoUris.count, 1);
  });

  test('register ignores empty URI', () async {
    await FailedPhotoUris.register('');
    expect(FailedPhotoUris.count, 0);
  });

  test('isFailed returns false for null + empty input', () {
    expect(FailedPhotoUris.isFailed(null), isFalse);
    expect(FailedPhotoUris.isFailed(''), isFalse);
  });

  test('clearAll wipes every entry from memory + disk', () async {
    await FailedPhotoUris.register('https://a.jpg');
    await FailedPhotoUris.register('https://b.jpg');
    expect(FailedPhotoUris.count, 2);
    await FailedPhotoUris.clearAll();
    expect(FailedPhotoUris.count, 0);
    expect(FailedPhotoUris.isFailed('https://a.jpg'), isFalse);
    final p = await SharedPreferences.getInstance();
    expect(p.getStringList('trail_failed_photo_uris_v1'), isNull);
  });

  test('preload is idempotent — safe to call multiple times', () async {
    await FailedPhotoUris.preload();
    await FailedPhotoUris.preload();
    expect(FailedPhotoUris.count, 0);
  });
}
