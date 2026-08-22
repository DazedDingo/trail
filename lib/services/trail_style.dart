import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// Builds the MapLibre style JSON for the offline map viewer.
///
/// The bundled OSM Liberty `style.json` ships placeholders instead of
/// real URLs — the loopback tile server binds a random port at every
/// launch, so nothing about the source URL is known at build time.
/// [substituteTileServer] rewrites them to `http://127.0.0.1:<port>/…`
/// and re-ranges the vector source to whatever the served archives
/// actually hold.
///
/// There is no local-file branch any more: `mbtiles://<path>` and
/// `pmtiles://file://<path>` silently render nothing on MapLibre Native
/// 13.0.x under Android (CLAUDE.md gotcha 17), so **every** archive goes
/// over the loopback. The one exception is the regions screen's
/// diagnostic sentinel, which points the renderer at the public
/// Protomaps demo over the real internet ([loadRemoteDemo]) to tell
/// "renderer broken" apart from "local archive broken".
class TrailStyle {
  static const _placeholder = 'pmtiles://__TRAIL_ACTIVE_REGION__';
  static const _styleAsset = 'assets/maptiles/style.json';

  /// Id of the vector source in the bundled style whose URL + zoom
  /// range we rewrite. Must match `assets/maptiles/style.json`.
  static const _sourceId = 'openmaptiles';

  /// Sentinel path used by the Regions screen's diagnostic-mode button
  /// to flip the renderer to the public Protomaps demo PMTiles URL.
  static const _diagnosticRemoteSentinel = '__remote_demo__';
  static const diagnosticRemoteSentinel = _diagnosticRemoteSentinel;

  /// Loaded + substituted styles, keyed on `port|minZoom|maxZoom`.
  ///
  /// `rootBundle.loadString` memoises the raw asset, but the
  /// substitution does not come free: a 74 KB JSON decode + re-encode
  /// per call, and the panel rebuilds its style future on every
  /// port/range change (`docs/PERF_PLAN.md` §3 #11). Bounded to
  /// [_cacheLimit] entries, evicting oldest-first — the live port plus a
  /// couple of stale ones is all anyone ever asks for.
  static final Map<String, String> _cache = <String, String>{};
  static const _cacheLimit = 4;

  /// Returns the bundled style pointed at the running loopback server.
  ///
  /// [minZoom] / [maxZoom] are `LocalTileServer.servedMinZoom` /
  /// `servedMaxZoom` — the union over every served archive. Passing
  /// them matters: with one style source there is one zoom range, and
  /// leaving the bundled `0–13` in place would stop MapLibre asking for
  /// the z14 tiles a coverage pack holds. `null` leaves the bundled
  /// values alone.
  ///
  /// Nullable return purely so call sites can keep a single
  /// `FutureBuilder<String?>`; this never returns `null` in practice.
  static Future<String?> loadForServer({
    required int port,
    int? minZoom,
    int? maxZoom,
  }) async {
    final key = '$port|$minZoom|$maxZoom';
    final cached = _cache[key];
    if (cached != null) return cached;
    final raw = await rootBundle.loadString(_styleAsset);
    final style = substituteTileServer(
      raw,
      port: port,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
    _cache[key] = style;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return style;
  }

  /// The diagnostic style: the bundled JSON with the source pointed at
  /// the public Protomaps demo archive. Glyph/sprite placeholders are
  /// deliberately left as-is — with no loopback running there is
  /// nothing to serve them, and the diagnostic only asks "does the
  /// renderer draw remote vector tiles at all?".
  static Future<String?> loadRemoteDemo() async {
    final raw = await rootBundle.loadString(_styleAsset);
    return raw.replaceAll(
      _placeholder,
      'pmtiles://https://demo-bucket.protomaps.com/v4.pmtiles',
    );
  }

  /// Drops the memoised styles. Tests only — production keys on the
  /// port, which is unique per server start.
  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// Rewrites the bundled style for the loopback server on [port].
  /// Pure — public for unit testing, and used by [loadForServer].
  ///
  ///   * tiles → `http://127.0.0.1:<port>/{z}/{x}/{y}.pbf` (a per-tile
  ///     template, not a TileJSON URL: skips a round-trip, 0.8.0+46);
  ///   * `__TRAIL_GLYPHS__` / `__TRAIL_SPRITE__` → the same loopback.
  ///     maplibre_gl on Android cannot read `asset://flutter_assets/…`
  ///     (confirmed by the +48 log capture: "Could not read asset" for
  ///     every Roboto fontstack), and a missing-glyphs failure cascades
  ///     — maplibre cancels in-flight tile requests and renders nothing;
  ///   * the `openmaptiles` source's `minzoom`/`maxzoom`, when
  ///     [minZoom] / [maxZoom] are supplied.
  static String substituteTileServer(
    String rawStyleJson, {
    required int port,
    int? minZoom,
    int? maxZoom,
  }) {
    final substituted = rawStyleJson
        .replaceAll(_placeholder, 'http://127.0.0.1:$port/{z}/{x}/{y}.pbf')
        .replaceAll('__TRAIL_GLYPHS__', 'http://127.0.0.1:$port/glyphs')
        .replaceAll(
          '__TRAIL_SPRITE__',
          'http://127.0.0.1:$port/sprites/osm-liberty',
        );
    if (minZoom == null && maxZoom == null) return substituted;
    return _rewriteSourceZooms(
      substituted,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  /// Re-encodes the style with the vector source's zoom range replaced.
  /// A decode + encode of 74 KB is a few ms and only happens on a
  /// port/range change (then it's memoised) — cheaper to reason about
  /// than a regex over JSON. Anything that isn't a style object with
  /// that source comes back untouched, so a caller can hand this a
  /// fragment (tests do) without it throwing.
  static String _rewriteSourceZooms(
    String styleJson, {
    int? minZoom,
    int? maxZoom,
  }) {
    try {
      final decoded = jsonDecode(styleJson);
      if (decoded is! Map) return styleJson;
      final sources = decoded['sources'];
      if (sources is! Map) return styleJson;
      final source = sources[_sourceId];
      if (source is! Map) return styleJson;
      if (minZoom != null) source['minzoom'] = minZoom;
      if (maxZoom != null) source['maxzoom'] = maxZoom;
      return jsonEncode(decoded);
    } catch (e) {
      debugPrint('TrailStyle: source zoom-range rewrite skipped — $e');
      return styleJson;
    }
  }
}
