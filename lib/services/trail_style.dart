import 'package:flutter/services.dart' show rootBundle;

/// Builds the MapLibre style JSON for the offline map viewer.
///
/// Loads the bundled OSM Liberty `style.json` (already rewritten to use
/// `asset://` URLs for glyphs and sprites) and substitutes the
/// `__TRAIL_ACTIVE_REGION__` placeholder with the absolute `pmtiles://`
/// URL of the active region's file. The bundled style references no
/// remote resources — fully offline once a region is installed.
class TrailStyle {
  static const _placeholder = 'pmtiles://__TRAIL_ACTIVE_REGION__';
  static const _styleAsset = 'assets/maptiles/style.json';

  /// Returns the style JSON string with the active region's file path
  /// substituted in. Returns `null` when no region is active — caller
  /// must render a placeholder instead of mounting `MapLibreMap`.
  ///
  /// The PMTiles URL form is `pmtiles://<absolute-fs-path>` — the
  /// triple-slash arises naturally because Android documents-dir paths
  /// already begin with `/`.
  static Future<String?> loadForRegion(String? activeRegionPath) async {
    if (activeRegionPath == null) return null;
    final raw = await rootBundle.loadString(_styleAsset);
    return raw.replaceAll(_placeholder, 'pmtiles://$activeRegionPath');
  }
}
