import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'photo_uri.dart';

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
/// **`file://` URIs (the user's own photos) are session-only.** They
/// are remembered in memory so a missing file doesn't re-fail on every
/// rebuild, but never persisted: a picker-cache purge is the only real
/// failure mode and the file may well be back (or the user re-attaches
/// it) by the next launch. Any `file://` entry found in prefs is a
/// leftover of the pre-0.14.1 bug where `Image.asset` failed *every*
/// user photo into this list — [preload] purges them once so those
/// photos render again without the user touching "Retry broken photos".
///
/// The set is loaded by [preload] — kicked off by `main()` right after
/// the first frame since 0.14.1, no longer on the startup critical path
/// — so the hot-path [isFailed] check is sync (image error callbacks
/// can't await). Before the preload lands, [isFailed] answers "not
/// failed" (one placeholder frame at worst) and [register] waits for it
/// so an early failure merges into the persisted set instead of
/// overwriting it.
class FailedPhotoUris {
  static const _key = 'trail_failed_photo_uris_v1';

  /// Cap the denylist so a degenerate cellular outage can't grow the
  /// SharedPreferences blob unbounded. 2 000 entries × ~150 char URL
  /// is ~300 KB — well under the SP per-key budget.
  static const _capacity = 2000;

  /// Set literal == `LinkedHashSet`: insertion order is the eviction
  /// order in [register].
  static final Set<String> _cache = <String>{};

  /// Memoised preload. `null` until the first [preload]; reset on
  /// failure so the next caller retries.
  static Future<void>? _preloading;

  /// Read the persisted denylist into memory. Memoised per isolate:
  /// concurrent callers share one SharedPreferences read and a finished
  /// preload is a free no-op, so every bootstrap path (and [register])
  /// can simply await it.
  static Future<void> preload() => _preloading ??= _load();

  static Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final persisted = p.getStringList(_key) ?? const <String>[];
      final kept = persisted
          .where((u) => !isLocalFileUri(u))
          .toList(growable: false);
      // Merge rather than assign: anything registered while this read
      // was in flight must survive it.
      _cache.addAll(kept);
      if (kept.length != persisted.length) {
        // One-time purge of `file://` entries written by the 0.14.0
        // `Image.asset` bug (see the class doc). Rewritten so it doesn't
        // repeat on every launch.
        await p.setStringList(_key, kept);
      }
    } catch (_) {
      _preloading = null;
      rethrow;
    }
  }

  /// Synchronous failure check. Returns false when not (yet) preloaded —
  /// the caller shows one frame of placeholder before the async
  /// [register] call below catches it and persists.
  static bool isFailed(String? uri) {
    if (uri == null || uri.isEmpty) return false;
    return _cache.contains(uri);
  }

  /// Record [uri] as failed. Persists on the same call so the failure
  /// survives a restart — except `file://` URIs, which are kept in
  /// memory only. Idempotent; duplicate registers are cheap (no prefs
  /// write).
  static Future<void> register(String uri) async {
    if (uri.isEmpty) return;
    await preload();
    if (!_cache.add(uri)) return;
    // Session-only for the user's own photos — see the class doc.
    if (isLocalFileUri(uri)) return;
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
    await _persist();
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      _key,
      _cache.where((u) => !isLocalFileUri(u)).toList(growable: false),
    );
  }

  /// Used by Settings "Retry broken photos" — clears the denylist so
  /// the next render re-attempts every URL. New genuine failures will
  /// re-populate the set, so it's safe to clear; the cost is one
  /// failed network attempt per previously-broken URL.
  static Future<void> clearAll() async {
    // Serialise behind an in-flight preload so its stale read can't
    // re-populate the set we're about to wipe.
    try {
      await preload();
    } catch (_) {/* nothing to merge — clearing anyway */}
    _cache.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }

  /// Diagnostic snapshot for tests + the Settings "N broken photos
  /// remembered" line.
  static int get count => _cache.length;

  /// Forget the in-memory set *and* the preload memo so a test can
  /// exercise the "not yet preloaded" startup window.
  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    _preloading = null;
  }
}
