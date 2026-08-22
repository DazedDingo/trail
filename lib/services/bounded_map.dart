import 'dart:math' as math;

/// `Future.wait`-style parallel map with at most [maxConcurrent] calls to
/// [fn] in flight at once. Results come back in [items] order.
///
/// Implemented as a small worker pool: `min(maxConcurrent, items.length)`
/// workers each pull the next index off a shared counter until the list
/// is exhausted, so a slow item never blocks the others and there is no
/// per-chunk barrier (plain chunked `Future.wait` idles the whole pool
/// on the slowest member of every chunk).
///
/// An error thrown by [fn] propagates from the returned future; the
/// other workers keep draining (there's no cancellation), so callers
/// that care should make [fn] non-throwing.
Future<List<R>> mapBounded<T, R>(
  List<T> items,
  Future<R> Function(T item) fn, {
  required int maxConcurrent,
}) async {
  assert(maxConcurrent > 0, 'maxConcurrent must be > 0');
  if (items.isEmpty) return const [];
  final results = List<R?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      results[i] = await fn(items[i]);
    }
  }

  final workers = math.min(maxConcurrent, items.length);
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  return List<R>.generate(items.length, (i) => results[i] as R);
}
