import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import 'tiles/tile_schema.dart';

/// Builds the MapLibre style JSON for the offline map viewer.
///
/// There are two bundled styles, one per tile schema — OSM Liberty for
/// OpenMapTiles archives and Protomaps dark for Protomaps-basemap ones
/// — because a style only draws the layer names it was written against
/// (`docs/TIMELINE_IMPORT.md` §3). The caller says which via
/// [TileSchema]; `pickStyleSchema` derives it from the served archives.
///
/// Both ship placeholders instead of real URLs — the loopback tile
/// server binds a random port at every launch, so nothing about the
/// source URL is known at build time. [substituteTileServer] rewrites
/// them to `http://127.0.0.1:<port>/…` and re-ranges the vector source
/// to whatever the served archives actually hold.
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

  /// OSM Liberty — draws the OpenMapTiles schema (source `openmaptiles`).
  static const _openMapTilesAsset = 'assets/maptiles/style.json';

  /// Protomaps basemap, dark flavour — draws the Protomaps schema
  /// (source `protomaps`). Regenerate with
  /// `tools/style/gen_protomaps_style.mjs`.
  static const _protomapsAsset = 'assets/maptiles/protomaps-dark.json';

  /// The bundled asset that draws [schema]. [TileSchema.unknown] keeps
  /// the historical default (OSM Liberty); in practice it never gets
  /// here — `pickStyleSchema` resolves it to a real schema first.
  static String assetFor(TileSchema schema) => switch (schema) {
        TileSchema.protomaps => _protomapsAsset,
        TileSchema.openmaptiles || TileSchema.unknown => _openMapTilesAsset,
      };

  /// Sentinel path used by the Regions screen's diagnostic-mode button
  /// to flip the renderer to the public Protomaps demo PMTiles URL.
  static const _diagnosticRemoteSentinel = '__remote_demo__';
  static const diagnosticRemoteSentinel = _diagnosticRemoteSentinel;

  /// Loaded + substituted styles, keyed on
  /// `port|minZoom|maxZoom|schema`.
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
  /// [schema] selects which bundled style is loaded — see [assetFor].
  ///
  /// Nullable return purely so call sites can keep a single
  /// `FutureBuilder<String?>`; this never returns `null` in practice.
  static Future<String?> loadForServer({
    required int port,
    required TileSchema schema,
    int? minZoom,
    int? maxZoom,
  }) async {
    final key = '$port|$minZoom|$maxZoom|${schema.name}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final raw = await rootBundle.loadString(assetFor(schema));
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
    final raw = await rootBundle.loadString(_openMapTilesAsset);
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
  /// Schema-agnostic: both bundled styles use the same placeholders and
  /// name exactly one vector source, so nothing here knows or cares
  /// which one it was handed.
  ///
  ///   * tiles → `http://127.0.0.1:<port>/{z}/{x}/{y}.pbf` (a per-tile
  ///     template, not a TileJSON URL: skips a round-trip, 0.8.0+46);
  ///   * `__TRAIL_GLYPHS__` / `__TRAIL_SPRITES__` → the same loopback.
  ///     maplibre_gl on Android cannot read `asset://flutter_assets/…`
  ///     (confirmed by the +48 log capture: "Could not read asset" for
  ///     every Roboto fontstack), and a missing-glyphs failure cascades
  ///     — maplibre cancels in-flight tile requests and renders nothing.
  ///     The style keeps the sprite *sheet* name after the placeholder
  ///     (`__TRAIL_SPRITES__/osm-liberty`, `…/protomaps-dark`) so one
  ///     substitution serves both;
  ///   * every vector source's `minzoom`/`maxzoom`, when [minZoom] /
  ///     [maxZoom] are supplied.
  static String substituteTileServer(
    String rawStyleJson, {
    required int port,
    int? minZoom,
    int? maxZoom,
  }) {
    final substituted = rawStyleJson
        .replaceAll(_placeholder, 'http://127.0.0.1:$port/{z}/{x}/{y}.pbf')
        .replaceAll('__TRAIL_GLYPHS__', 'http://127.0.0.1:$port/glyphs')
        .replaceAll('__TRAIL_SPRITES__', 'http://127.0.0.1:$port/sprites');
    if (minZoom == null && maxZoom == null) return substituted;
    return _rewriteSourceZooms(
      substituted,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
  }

  /// Re-encodes the style with every vector source's zoom range
  /// replaced. A decode + encode of 74–170 KB is a few ms and only
  /// happens on a port/range change (then it's memoised) — cheaper to
  /// reason about than a regex over JSON. Anything that isn't a style
  /// object with a vector source comes back untouched, so a caller can
  /// hand this a fragment (tests do) without it throwing.
  ///
  /// Every `type: "vector"` source rather than one id: the two bundled
  /// styles name theirs differently (`openmaptiles` / `protomaps`) and
  /// both hold exactly one, so "all of them" is both correct and one
  /// less constant to keep in sync with an asset.
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
      var touched = false;
      for (final source in sources.values) {
        if (source is! Map) continue;
        if (source['type'] != 'vector') continue;
        if (minZoom != null) source['minzoom'] = minZoom;
        if (maxZoom != null) source['maxzoom'] = maxZoom;
        touched = true;
      }
      if (!touched) return styleJson;
      return jsonEncode(decoded);
    } catch (e) {
      debugPrint('TrailStyle: source zoom-range rewrite skipped — $e');
      return styleJson;
    }
  }
}
