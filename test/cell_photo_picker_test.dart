import 'package:flutter_test/flutter_test.dart';

import 'package:trail/models/area_photo.dart';
import 'package:trail/services/cell_photo_picker.dart';

AreaPhoto _ap(int i) => AreaPhoto(
      cellLat: 0,
      cellLon: 0,
      uri: 'p$i.jpg',
      attribution: '',
      license: '',
      discoveredAt: DateTime.utc(2026),
    );

List<String> _uris(List<AreaPhoto> l) => l.map((p) => p.uri).toList();

void main() {
  group('quantizeCellLat / quantizeCellLon', () {
    test('rounds to 3 decimals (~110 m at the equator)', () {
      expect(kCellDecimals, 3);
      expect(quantizeCellLat(51.51234), 51.512);
      expect(quantizeCellLon(-0.12678), -0.127);
    });

    test('nearby coords collapse to the same cell', () {
      // ~50 m at the equator: same cell.
      expect(quantizeCellLat(51.5100), quantizeCellLat(51.5104));
      expect(quantizeCellLon(-0.1000), quantizeCellLon(-0.1004));
    });

    test('coords ~150 m apart land in different cells', () {
      // 0.0015° at the equator ≈ 167 m — should split cells.
      expect(quantizeCellLat(51.5100) == quantizeCellLat(51.5115), isFalse);
    });

    test('NaN + Infinity collapse to 0.0 (defensive)', () {
      expect(quantizeCellLat(double.nan), 0.0);
      expect(quantizeCellLat(double.infinity), 0.0);
      expect(quantizeCellLon(double.negativeInfinity), 0.0);
    });

    test('pure: same input → same output across runs', () {
      for (var i = 0; i < 100; i++) {
        expect(quantizeCellLat(40.7128), 40.713);
        expect(quantizeCellLon(-74.0060), -74.006);
      }
    });
  });

  group('pickRotatedPhotos', () {
    final pool = [for (var i = 0; i < 10; i++) _ap(i)];

    test('empty pool → empty result', () {
      expect(pickRotatedPhotos(allCellPhotos: const [], pingId: 1, k: 5),
          isEmpty);
    });

    test('k <= 0 → empty result', () {
      expect(pickRotatedPhotos(allCellPhotos: pool, pingId: 1, k: 0), isEmpty);
      expect(pickRotatedPhotos(allCellPhotos: pool, pingId: 1, k: -3),
          isEmpty);
    });

    test('determinism: same (pingId, salt) → same picks across calls', () {
      final a = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 42, k: 5, salt: 0);
      final b = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 42, k: 5, salt: 0);
      expect(_uris(a), _uris(b));
    });

    test('variety: different pingId at same cell → different slice', () {
      final ids = [for (var i = 1; i <= 50; i++) i];
      final firstPicks = {
        for (final id in ids)
          id: pickRotatedPhotos(
              allCellPhotos: pool, pingId: id, k: 1, salt: 0).single.uri
      };
      final distinct = firstPicks.values.toSet();
      // With 10-photo pool and 50 pings, the first-pick URIs should
      // cover at least ~half of the pool. (Exact distribution depends
      // on the hash mixer.)
      expect(distinct.length, greaterThanOrEqualTo(5));
    });

    test('rotation salt re-permutes deterministically', () {
      final s0 = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 7, k: 5, salt: 0);
      final s1 = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 7, k: 5, salt: 1);
      expect(_uris(s0), isNot(_uris(s1)));
      // Re-running at salt=1 still yields the same picks.
      final s1again = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 7, k: 5, salt: 1);
      expect(_uris(s1), _uris(s1again));
    });

    test('k > pool.length → returns whole pool (no duplicates)', () {
      final r = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 1, k: 99, salt: 0);
      expect(r.length, pool.length);
      expect(_uris(r).toSet().length, pool.length);
    });

    test('output is contiguous slice from rotation start', () {
      final r = pickRotatedPhotos(
          allCellPhotos: pool, pingId: 7, k: 5, salt: 0);
      // Find the index of the first picked photo and check the next
      // k-1 wrap consecutively.
      final firstIdx = pool.indexWhere((p) => p.uri == r.first.uri);
      expect(firstIdx, greaterThanOrEqualTo(0));
      for (var i = 0; i < r.length; i++) {
        expect(r[i].uri, pool[(firstIdx + i) % pool.length].uri);
      }
    });
  });
}
