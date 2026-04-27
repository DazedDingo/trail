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
  /// **Diagnostic mode (0.8.0+35):** if the active region's name is the
  /// literal string `__remote_demo__` (set by the Regions screen's
  /// hidden "Use remote demo PMTiles" toggle), substitute a public
  /// Protomaps demo URL instead of the local file path. Lets us
  /// distinguish "renderer is broken" from "local-PMTiles-on-Android
  /// is broken in this package" without writing native code.
  static Future<String?> loadForRegion(String? activeRegionPath) async {
    if (activeRegionPath == null) return null;
    final raw = await rootBundle.loadString(_styleAsset);
    if (activeRegionPath == _diagnosticRemoteSentinel) {
      return raw.replaceAll(
        _placeholder,
        'pmtiles://https://demo-bucket.protomaps.com/v4.pmtiles',
      );
    }
    return substituteRegionPath(raw, activeRegionPath);
  }

  /// Sentinel path used to flip the renderer into the remote-PMTiles
  /// diagnostic mode. The Regions screen's "Use remote demo PMTiles"
  /// action stores this string as the active region path.
  static const _diagnosticRemoteSentinel = '__remote_demo__';
  static const diagnosticRemoteSentinel = _diagnosticRemoteSentinel;

  /// Performs the placeholder substitution without touching the asset
  /// bundle — split out so unit tests can pin the exact URL format
  /// without spinning up a `WidgetTester`.
  ///
  /// The PMTiles URL form on Android is `pmtiles://file://<abs-path>`
  /// per the MapLibre Native Android 11.7+ docs — the bare
  /// `pmtiles://<abs-path>` form does *not* resolve on Android and
  /// silently renders as a tile-less white background. The conventional
  /// triple-slash arises because Android documents-dir paths begin with
  /// `/`, so `file://` + `/data/...` becomes `file:///data/...`.
  static String substituteRegionPath(String rawStyleJson, String activeRegionPath) =>
      rawStyleJson.replaceAll(_placeholder, 'pmtiles://file://$activeRegionPath');
}
