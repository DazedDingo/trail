import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/local_tile_server.dart';

List<int> _blob(int n) => List<int>.filled(n, 1);

void main() {
  test('tile cache budget is 16 MB (0.14.1, down from 50 MB)', () {
    expect(kTileCacheMaxBytes, 16 * 1024 * 1024);
  });

  group('TileCache', () {
    test('put + get round-trip with byte + entry accounting', () {
      final c = TileCache(maxBytes: 1000);
      expect(c.get('1/2/3'), isNull);
      c.put('1/2/3', _blob(100));
      expect(c.get('1/2/3'), hasLength(100));
      expect(c.bytes, 100);
      expect(c.length, 1);
    });

    test('evicts least-recently-used first when over budget', () {
      final c = TileCache(maxBytes: 300);
      c.put('a', _blob(100));
      c.put('b', _blob(100));
      c.put('c', _blob(100));
      expect(c.bytes, 300);
      // Touch `a` so `b` becomes the LRU entry.
      expect(c.get('a'), isNotNull);
      c.put('d', _blob(100));
      expect(c.get('b'), isNull, reason: 'b was least recently used');
      expect(c.get('a'), isNotNull, reason: 'a was bumped to MRU by get');
      expect(c.get('c'), isNotNull);
      expect(c.get('d'), isNotNull);
      expect(c.bytes, 300);
      expect(c.length, 3);
    });

    test('re-putting a key replaces it without double counting', () {
      final c = TileCache(maxBytes: 1000);
      c.put('a', _blob(100));
      c.put('a', _blob(250));
      expect(c.bytes, 250);
      expect(c.length, 1);
      expect(c.get('a'), hasLength(250));
    });

    test('a single blob larger than the budget is not retained', () {
      final c = TileCache(maxBytes: 300);
      c.put('huge', _blob(301));
      expect(c.length, 0);
      expect(c.bytes, 0);
      expect(c.get('huge'), isNull);
    });

    test('evicts as many entries as needed in one put', () {
      final c = TileCache(maxBytes: 300);
      c.put('a', _blob(100));
      c.put('b', _blob(100));
      c.put('c', _blob(100));
      // 300 + 250 = 550 → evict a (450) → b (350) → c (250 ≤ 300).
      c.put('big', _blob(250));
      expect(c.get('a'), isNull);
      expect(c.get('b'), isNull);
      expect(c.get('c'), isNull, reason: 'c + big would still be 350');
      expect(c.get('big'), isNotNull);
      expect(c.bytes, 250);
      expect(c.length, 1);
    });

    test('clear resets both bytes and entries', () {
      final c = TileCache(maxBytes: 1000);
      c.put('a', _blob(100));
      c.put('b', _blob(100));
      c.clear();
      expect(c.bytes, 0);
      expect(c.length, 0);
      expect(c.get('a'), isNull);
    });
  });

  test('LocalTileServer.clearTileCache drops the live cache', () {
    final server = LocalTileServer.instance;
    server.tileCache.put('14/1/1', _blob(512));
    expect(server.tileCache.bytes, 512);
    server.clearTileCache();
    expect(server.tileCache.bytes, 0);
  });
}
