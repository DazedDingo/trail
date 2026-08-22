import '../mbtiles_service.dart' show TileRole, TilesRegion;

/// Which vector-tile schema an archive holds — i.e. what its layers are
/// called. A style only draws the schema it was written against, so the
/// app bundles one style per schema and picks by what is being served
/// (`docs/TIMELINE_IMPORT.md` §3, decided 2026-08-22).
///
///   * [openmaptiles] — planetiler's OpenMapTiles profile, as
///     `docs/TILES.md` builds regions today (`transportation`, `place`,
///     `landuse`, …). Drawn by `assets/maptiles/style.json` (OSM
///     Liberty).
///   * [protomaps] — the Protomaps basemap build (`roads`, `places`,
///     `earth`, …). Drawn by `assets/maptiles/protomaps-dark.json`.
///   * [unknown] — the archive declares no `vector_layers`, or none we
///     recognise. Raster packs and hand-rolled test fixtures land here.
enum TileSchema {
  openmaptiles('OpenMapTiles'),
  protomaps('Protomaps'),
  unknown('Unknown');

  const TileSchema(this.label);

  /// Human-readable name for the regions screen.
  final String label;
}

/// Classifies an archive from the `vector_layers` list in its metadata.
///
/// One discriminating layer id per schema is enough and stays cheap:
/// OpenMapTiles is the only one of the two with `transportation`, and
/// Protomaps is the only one with `roads` / `places`. A `null` or empty
/// list (raster archive, metadata-less fixture) is [TileSchema.unknown]
/// — never a guess, because guessing wrong renders a blank map.
TileSchema detectTileSchema(List<dynamic>? vectorLayers) {
  if (vectorLayers == null) return TileSchema.unknown;
  final ids = <String>{};
  for (final layer in vectorLayers) {
    if (layer is Map) {
      final id = layer['id'];
      if (id != null) ids.add(id.toString());
    }
  }
  if (ids.contains('transportation')) return TileSchema.openmaptiles;
  if (ids.contains('roads') || ids.contains('places')) {
    return TileSchema.protomaps;
  }
  return TileSchema.unknown;
}

/// The schema the style should be built for, given the archives the
/// loopback is serving (in priority order) and each one's schema.
///
/// Precedence mirrors what the user is looking at:
///   1. the **active region**'s schema — the big archive whose detail
///      dominates the view — when it is served and recognised;
///   2. otherwise the first served archive with a recognised schema
///      (coverage packs come first in [servedInOrder], overviews last);
///   3. otherwise [TileSchema.protomaps], the default for new archives.
///
/// Only one style can be live at a time (one source, one glyph set), so
/// a mixed library draws fully in the chosen schema and partially in
/// the other — the regions screen says so.
TileSchema pickStyleSchema(
  List<TilesRegion> servedInOrder,
  Map<String, TileSchema> byPath,
) {
  for (final region in servedInOrder) {
    if (region.role != TileRole.region) continue;
    final schema = byPath[region.path];
    if (schema != null && schema != TileSchema.unknown) return schema;
    break;
  }
  for (final region in servedInOrder) {
    final schema = byPath[region.path];
    if (schema != null && schema != TileSchema.unknown) return schema;
  }
  return TileSchema.protomaps;
}
