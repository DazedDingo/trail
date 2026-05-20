import 'package:shared_preferences/shared_preferences.dart';

/// Cross-render denylist of photo URLs that `cached_network_image` has
/// reported as failed to load. Persisted via SharedPreferences so the
/// failure survives an app restart — without that, a broken Wikimedia
/// URL would re-render the gray "broken image" icon every time the
/// user opened the gallery or scrubbed the slideshow.
///
/// The denylist is *additive* and *manual to clear* (see [clearAll]).
/// We don't auto-retry failed URLs: Wikimedia's typical failure mode
/// (hotlink protection, 404, corrupt file) is persistent, so retrying
/// just costs bandwidth + re-shows the broken icon for one frame
/// before failing again.
///
/// The set is preloaded at app start by [preload] so the hot-path
/// [isFailed] check is sync (image error callbacks can't await).
class FailedPhotoUris {
  static const _key = 'trail_failed_photo_uris_v1';

  /// Cap the denylist so a degenerate cellular outage can't grow the
  /// SharedPreferences blob unbounded. 2 000 entries × ~150 char URL
  /// is ~300 KB — well under the SP per-key budget.
  static const _capacity = 2000;

  static Set<String> _cache = <String>{};
  static bool _loaded = false;

  /// Read the persisted denylist into memory. Idempotent; safe to call
  /// from multiple bootstrap paths. Must be awaited before [isFailed]
  /// returns reliable results — but the caller is allowed to skip
  /// preload in tests; [isFailed] just returns false in that case.
  static Future<void> preload() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    _cache = (p.getStringList(_key) ?? const <String>[]).toSet();
    _loaded = true;
  }

  /// Synchronous failure check. Returns false when not preloaded — the
  /// caller will see one frame of broken-image before the async
  /// [register] call below catches it and persists.
  static bool isFailed(String? uri) {
    if (uri == null || uri.isEmpty) return false;
    return _cache.contains(uri);
  }

  /// Record [uri] as failed. Persists on the same call so the failure
  /// survives a restart. Idempotent; duplicate registers are cheap.
  static Future<void> register(String uri) async {
    if (uri.isEmpty || _cache.contains(uri)) return;
    _cache.add(uri);
    // Cap by dropping the oldest. Insertion order in a LinkedHashSet
    // gives us the right semantics for free.
    if (_cache.length > _capacity) {
      final overflow = _cache.length - _capacity;
      final iter = _cache.iterator;
      final toDrop = <String>[];
      for (var i = 0; i < overflow && iter.moveNext(); i++) {
        toDrop.add(iter.current);
      }
      _cache.removeAll(toDrop);
    }
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, _cache.toList(growable: false));
  }

  /// Used by Settings "Retry broken photos" — clears the denylist so
  /// the next render re-attempts every URL. New genuine failures will
  /// re-populate the set, so it's safe to clear; the cost is one
  /// failed network attempt per previously-broken URL.
  static Future<void> clearAll() async {
    _cache.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  /// Diagnostic snapshot for tests + the Settings "N broken photos
  /// remembered" line.
  static int get count => _cache.length;
}
