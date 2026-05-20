import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trail/models/ping.dart';
import 'package:trail/models/ping_photo.dart';
import 'package:trail/services/failed_photo_uris.dart';
import 'package:trail/widgets/slideshow_view.dart';

Ping _p(int id, int hour) => Ping(
      id: id,
      timestampUtc: DateTime.utc(2026, 5, 17, hour),
      lat: 1,
      lon: 2,
      source: PingSource.scheduled,
    );

PingPhoto _photo(int pingId, {int ord = 0, String? uri, String? thumb}) =>
    PingPhoto(
      pingId: pingId,
      uri: uri ?? 'https://example/p$pingId-$ord.jpg',
      thumbUri: thumb ?? 'https://example/p$pingId-$ord-thumb.jpg',
      source: PingPhotoSource.wikimedia,
      fetchedAt: DateTime.utc(2026, 5, 17),
      ordinal: ord,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FailedPhotoUris.clearAll();
  });

  group('pickSlideshowPing', () {
    final fixes = [_p(1, 9), _p(2, 11), _p(3, 14)];

    test('returns the latest fix at-or-before sliderMax', () {
      final out = pickSlideshowPing(fixes, DateTime.utc(2026, 5, 17, 12));
      expect(out!.id, 2);
    });

    test('exact-timestamp match picks that ping', () {
      final out = pickSlideshowPing(fixes, DateTime.utc(2026, 5, 17, 11));
      expect(out!.id, 2);
    });

    test('sliderMax before every fix → null', () {
      final out = pickSlideshowPing(fixes, DateTime.utc(2026, 5, 17, 7));
      expect(out, isNull);
    });

    test('sliderMax after every fix → the last one', () {
      final out = pickSlideshowPing(fixes, DateTime.utc(2026, 5, 17, 23));
      expect(out!.id, 3);
    });

    test('empty fixes returns null', () {
      expect(pickSlideshowPing(const [], DateTime.utc(2026, 5, 17)),
          isNull);
    });
  });

  group('pickPhotoForPing — backfills from earlier fixes', () {
    test("returns the current ping's first photo when present", () {
      final fixes = [_p(1, 9), _p(2, 11)];
      final cache = {
        1: [_photo(1)],
        2: [_photo(2)],
      };
      final out = pickPhotoForPing(fixes[1], fixes, cache);
      expect(out!.pingId, 2);
    });

    test('walks back to an earlier ping when the current has none', () {
      final fixes = [_p(1, 9), _p(2, 11), _p(3, 14)];
      final cache = {
        1: [_photo(1)],
        2: <PingPhoto>[],
        3: <PingPhoto>[],
      };
      final out = pickPhotoForPing(fixes[2], fixes, cache);
      expect(out!.pingId, 1, reason: 'walks back from 3 → 2 → 1');
    });

    test('returns null when no earlier ping has a photo either', () {
      final fixes = [_p(1, 9), _p(2, 11)];
      final cache = {1: <PingPhoto>[], 2: <PingPhoto>[]};
      final out = pickPhotoForPing(fixes[1], fixes, cache);
      expect(out, isNull);
    });

    test('ping not in visibleFixes still falls back to its own cache entry',
        () {
      final orphan = _p(99, 12);
      final out = pickPhotoForPing(orphan, const [], {
        99: [_photo(99)],
      });
      expect(out!.pingId, 99);
    });

    test('ping with null id and empty cache → null', () {
      final p = Ping(
        timestampUtc: DateTime.utc(2026, 5, 17),
        lat: 1,
        lon: 2,
        source: PingSource.scheduled,
      );
      final out = pickPhotoForPing(p, const [], const {});
      expect(out, isNull);
    });
  });

  group('classifyEmptyState (0.13.5 — disambiguates "no photo" message)', () {
    test('returns allFailed when at least one ping has photo rows', () {
      final fixes = [_p(1, 9), _p(2, 11)];
      final cache = {
        1: <PingPhoto>[],
        2: [_photo(2)], // exists but assumed denylisted upstream
      };
      expect(
        classifyEmptyState(fixes, cache),
        EmptySlideshowReason.allFailed,
      );
    });

    test('returns noPhotosFetched when every ping has zero photo rows', () {
      final fixes = [_p(1, 9), _p(2, 11)];
      final cache = {1: <PingPhoto>[], 2: <PingPhoto>[]};
      expect(
        classifyEmptyState(fixes, cache),
        EmptySlideshowReason.noPhotosFetched,
      );
    });

    test('returns noPhotosFetched on empty fixes', () {
      expect(
        classifyEmptyState(const [], const {}),
        EmptySlideshowReason.noPhotosFetched,
      );
    });

    test('ignores pings with null id (defensive)', () {
      final orphan = Ping(
        timestampUtc: DateTime.utc(2026, 5, 17),
        lat: 1,
        lon: 2,
        source: PingSource.scheduled,
      );
      expect(
        classifyEmptyState([orphan], const {}),
        EmptySlideshowReason.noPhotosFetched,
      );
    });
  });

  group('renderableUriFor (0.13.5)', () {
    test('shrinks 512 px Wikimedia thumb to slideshow width', () {
      final p = _photo(1,
          thumb:
              'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/512px-X.jpg');
      expect(
        renderableUriFor(p),
        'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/320px-X.jpg',
      );
    });

    test('falls back to full uri when thumb is null', () {
      final p = PingPhoto(
        pingId: 1,
        uri: 'https://cdn.example/photo.jpg',
        source: PingPhotoSource.wikimedia,
        fetchedAt: DateTime.utc(2026),
        ordinal: 0,
      );
      expect(renderableUriFor(p), 'https://cdn.example/photo.jpg');
    });
  });

  group('renderableUriFor + denylist (0.13.8 — permanent gray screen)', () {
    test('returns shrunk thumb when not denylisted', () {
      final p = _photo(1,
          thumb:
              'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/512px-X.jpg');
      expect(
        renderableUriFor(p),
        'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/320px-X.jpg',
      );
    });

    test('falls back to full URI when shrunk thumb is denylisted',
        () async {
      await FailedPhotoUris.preload();
      final p = _photo(1,
          uri: 'https://upload.wikimedia.org/wikipedia/commons/0/0a/X.jpg',
          thumb:
              'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/512px-X.jpg');
      await FailedPhotoUris.register(
        'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/X.jpg/320px-X.jpg',
      );
      expect(
        renderableUriFor(p),
        'https://upload.wikimedia.org/wikipedia/commons/0/0a/X.jpg',
      );
    });

    test(
        'pickPhotoForPing skips photos whose 320 px form is denylisted '
        '(was loop-forever on 0.13.7)', () async {
      // Repro: a photo whose 512 px thumb URL is in the DB but whose
      // *shrunk* 320 px URL has already been registered as failed.
      // Pre-0.13.8 the picker checked `isFailed(p.thumbUri)` (the 512
      // form) which never matched the registered 320 form, so the
      // picker kept clearing the photo, the renderer kept shrinking
      // to the same broken 320 URL, the user saw a permanent gray
      // surface. Now the picker uses `renderableUriFor` which falls
      // back to the full URI when the shrunk thumb is denylisted —
      // and the full URI here is *also* denylisted, so the photo
      // should be skipped entirely.
      await FailedPhotoUris.preload();
      final p1 = _photo(1,
          uri: 'https://upload.wikimedia.org/wikipedia/commons/0/0a/A.jpg',
          thumb:
              'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/A.jpg/512px-A.jpg');
      final p2 = _photo(1,
          ord: 1,
          uri: 'https://upload.wikimedia.org/wikipedia/commons/0/0b/B.jpg',
          thumb:
              'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0b/B.jpg/512px-B.jpg');
      // p1 fully dead, p2 still alive — picker should pick p2.
      await FailedPhotoUris.register(
        'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/A.jpg/320px-A.jpg',
      );
      await FailedPhotoUris.register(
        'https://upload.wikimedia.org/wikipedia/commons/0/0a/A.jpg',
      );
      final fixes = [_p(1, 9)];
      final cache = {
        1: [p1, p2],
      };
      final out = pickPhotoForPing(fixes[0], fixes, cache);
      expect(out, isNotNull);
      expect(out!.ordinal, 1, reason: 'falls through to the second photo');
    });
  });

  group('pickPhotoForPing — failed-URL denylist (0.13.4)', () {
    test('skips a failed thumb to a sibling photo on the same ping',
        () async {
      await FailedPhotoUris.preload();
      final fixes = [_p(1, 9)];
      final cache = {
        1: [
          _photo(1, ord: 0), // will be denylisted
          _photo(1, ord: 1),
        ],
      };
      await FailedPhotoUris.register(
          'https://example/p1-0-thumb.jpg');
      // Also blacklist the full URI so the fallback check catches it too.
      await FailedPhotoUris.register('https://example/p1-0.jpg');
      final out = pickPhotoForPing(fixes[0], fixes, cache);
      expect(out!.ordinal, 1);
    });

    test('skips a fully-failed ping and walks back to a working earlier one',
        () async {
      await FailedPhotoUris.preload();
      final fixes = [_p(1, 9), _p(2, 11)];
      final cache = {
        1: [_photo(1)],
        2: [_photo(2)],
      };
      await FailedPhotoUris.register('https://example/p2-0-thumb.jpg');
      await FailedPhotoUris.register('https://example/p2-0.jpg');
      final out = pickPhotoForPing(fixes[1], fixes, cache);
      expect(out!.pingId, 1);
    });

    test('returns null when every candidate is denylisted', () async {
      await FailedPhotoUris.preload();
      final fixes = [_p(1, 9)];
      final cache = {
        1: [_photo(1)],
      };
      await FailedPhotoUris.register('https://example/p1-0-thumb.jpg');
      await FailedPhotoUris.register('https://example/p1-0.jpg');
      final out = pickPhotoForPing(fixes[0], fixes, cache);
      expect(out, isNull);
    });
  });
}
