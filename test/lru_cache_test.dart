import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/lru_cache.dart';

void main() {
  group('LruCache', () {
    test('miss returns null; put then get hits', () {
      final c = LruCache<String, int>(4);
      expect(c.get('a'), isNull);
      c.put('a', 1);
      expect(c.get('a'), 1);
      expect(c.length, 1);
      expect(c.containsKey('a'), isTrue);
    });

    test('evicts the least-recently-used entry, and a hit refreshes recency',
        () {
      final c = LruCache<String, int>(2);
      c.put('a', 1);
      c.put('b', 2);
      expect(c.get('a'), 1); // a is now MRU; b is LRU
      c.put('c', 3); // over capacity → b goes
      expect(c.get('b'), isNull);
      expect(c.get('a'), 1);
      expect(c.get('c'), 3);
      expect(c.length, 2);
    });

    test('keys iterate from least- to most-recently used', () {
      final c = LruCache<String, int>(3);
      c.put('a', 1);
      c.put('b', 2);
      c.put('c', 3);
      c.get('a');
      expect(c.keys.toList(), ['b', 'c', 'a']);
    });

    test('overwriting a key does not grow the cache and makes it MRU', () {
      final c = LruCache<String, int>(2);
      c.put('a', 1);
      c.put('b', 2);
      c.put('a', 10);
      expect(c.length, 2);
      expect(c.keys.toList(), ['b', 'a']);
      c.put('c', 3); // evicts b, not a
      expect(c.get('b'), isNull);
      expect(c.get('a'), 10);
    });

    test('capacity 1 holds exactly the last entry', () {
      final c = LruCache<int, String>(1);
      c.put(1, 'one');
      c.put(2, 'two');
      expect(c.get(1), isNull);
      expect(c.get(2), 'two');
      expect(c.length, 1);
    });

    test('record keys compare by value', () {
      final c = LruCache<({int a, int b}), String>(4);
      c.put((a: 1, b: 2), 'x');
      expect(c.get((a: 1, b: 2)), 'x');
    });

    test('clear empties the cache', () {
      final c = LruCache<String, int>(2);
      c.put('a', 1);
      c.clear();
      expect(c.isEmpty, isTrue);
      expect(c.get('a'), isNull);
    });

    test('rejects a non-positive capacity', () {
      expect(() => LruCache<String, int>(0), throwsA(isA<AssertionError>()));
    });
  });
}
