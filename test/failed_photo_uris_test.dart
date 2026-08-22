import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/services/failed_photo_uris.dart';

const _key = 'trail_failed_photo_uris_v1';

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
    final raw = p.getStringList(_key);
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
    expect(p.getStringList(_key), isNull);
  });

  test('preload is idempotent — safe to call multiple times', () async {
    await FailedPhotoUris.preload();
    await FailedPhotoUris.preload();
    expect(FailedPhotoUris.count, 0);
  });

  group('deferred preload (0.14.1 — no longer awaited in main)', () {
    setUp(() {
      FailedPhotoUris.resetForTest();
      SharedPreferences.setMockInitialValues({
        _key: <String>['https://persisted/old.jpg'],
      });
    });

    test('isFailed is sync-safe before preload: answers "not failed"', () {
      expect(FailedPhotoUris.isFailed('https://persisted/old.jpg'), isFalse);
      expect(FailedPhotoUris.count, 0);
    });

    test('preload then surfaces the persisted entries', () async {
      await FailedPhotoUris.preload();
      expect(FailedPhotoUris.isFailed('https://persisted/old.jpg'), isTrue);
      expect(FailedPhotoUris.count, 1);
    });

    test(
        'register before preload merges into the persisted set, '
        'never clobbers it', () async {
      await FailedPhotoUris.register('https://new/fail.jpg');
      expect(FailedPhotoUris.isFailed('https://persisted/old.jpg'), isTrue);
      expect(FailedPhotoUris.isFailed('https://new/fail.jpg'), isTrue);
      final p = await SharedPreferences.getInstance();
      expect(
        p.getStringList(_key),
        containsAll(['https://persisted/old.jpg', 'https://new/fail.jpg']),
      );
    });

    test('concurrent preloads share one read and do not duplicate',
        () async {
      await Future.wait([
        FailedPhotoUris.preload(),
        FailedPhotoUris.preload(),
        FailedPhotoUris.preload(),
      ]);
      expect(FailedPhotoUris.count, 1);
    });

    test('clearAll before preload wins over the in-flight read', () async {
      // Kick off the preload but do not await it, then clear: the stale
      // list the read returns must not resurrect the wiped entries.
      final loading = FailedPhotoUris.preload();
      await FailedPhotoUris.clearAll();
      await loading;
      expect(FailedPhotoUris.count, 0);
      expect(FailedPhotoUris.isFailed('https://persisted/old.jpg'), isFalse);
    });
  });

  group('file:// URIs — user photos are session-only (0.14.1)', () {
    const fileUri = 'file:///data/user/0/dev.trail/cache/a.jpg';

    test('register(file://) is remembered in memory but never persisted',
        () async {
      await FailedPhotoUris.register(fileUri);
      expect(FailedPhotoUris.isFailed(fileUri), isTrue);
      expect(FailedPhotoUris.count, 1);
      final p = await SharedPreferences.getInstance();
      expect(
        p.getStringList(_key) ?? const <String>[],
        isNot(contains(fileUri)),
      );
    });

    test('a mixed batch persists only the non-file entries', () async {
      await FailedPhotoUris.register(fileUri);
      await FailedPhotoUris.register('https://x/dead.jpg');
      final p = await SharedPreferences.getInstance();
      expect(p.getStringList(_key), ['https://x/dead.jpg']);
      expect(FailedPhotoUris.count, 2);
    });

    test('persisted file:// entries (pre-0.14.1 Image.asset bug) are purged '
        'on preload and the list rewritten once', () async {
      FailedPhotoUris.resetForTest();
      SharedPreferences.setMockInitialValues({
        _key: <String>[fileUri, 'https://x/dead.jpg', 'file:///b.jpg'],
      });
      await FailedPhotoUris.preload();
      expect(FailedPhotoUris.isFailed(fileUri), isFalse);
      expect(FailedPhotoUris.isFailed('file:///b.jpg'), isFalse);
      expect(FailedPhotoUris.isFailed('https://x/dead.jpg'), isTrue);
      expect(FailedPhotoUris.count, 1);
      final p = await SharedPreferences.getInstance();
      expect(p.getStringList(_key), ['https://x/dead.jpg']);
    });

    test('clearAll forgets session-only file:// entries too', () async {
      await FailedPhotoUris.register(fileUri);
      await FailedPhotoUris.clearAll();
      expect(FailedPhotoUris.isFailed(fileUri), isFalse);
      expect(FailedPhotoUris.count, 0);
    });
  });
}
