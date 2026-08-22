/// Minimal bounded LRU cache.
///
/// Backed by a `LinkedHashMap`: iteration order is insertion order, and a
/// hit re-inserts the entry so it moves to the most-recently-used end.
/// When [capacity] is exceeded the least-recently-used entry (the head)
/// is dropped. Synchronous, single-isolate, no timers — exactly what a
/// "don't re-hit the platform geocoder on every widget remount" cache
/// needs and nothing more.
///
/// `null` is not a storable value: [get] returns `null` for a miss, so a
/// stored `null` would be indistinguishable from one. Callers cache only
/// positive results (a `null` lookup is usually "offline right now" and
/// should be retried anyway).
class LruCache<K, V extends Object> {
  LruCache(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  /// Maximum number of entries held. Exceeding it evicts the LRU entry.
  final int capacity;

  final _map = <K, V>{};

  int get length => _map.length;
  bool get isEmpty => _map.isEmpty;

  /// Keys from least- to most-recently used. Exposed for tests and
  /// diagnostics; don't mutate through it.
  Iterable<K> get keys => _map.keys;

  bool containsKey(K key) => _map.containsKey(key);

  /// Returns the cached value and marks it most-recently used, or `null`
  /// on a miss.
  V? get(K key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v;
    return v;
  }

  /// Inserts or overwrites; the entry becomes most-recently used. Evicts
  /// the least-recently-used entry if the cache is now over [capacity].
  void put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    if (_map.length > capacity) _map.remove(_map.keys.first);
  }

  void clear() => _map.clear();
}
