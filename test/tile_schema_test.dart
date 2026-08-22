import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tiles/tile_schema.dart';

/// A `vector_layers` list as an archive's metadata carries it.
List<dynamic> _layers(List<String> ids) =>
    [for (final id in ids) <String, dynamic>{'id': id, 'fields': {}}];

TilesRegion _region(String path, TileRole role) =>
    TilesRegion(name: path, path: path, bytes: 1, role: role);

void main() {
  group('detectTileSchema', () {
    test('the OpenMapTiles marker layer wins', () {
      expect(
        detectTileSchema(_layers(
          ['water', 'landuse', 'transportation', 'place'],
        )),
        TileSchema.openmaptiles,
      );
    });

    test('Protomaps is recognised by roads', () {
      expect(
        detectTileSchema(_layers(['earth', 'water', 'roads'])),
        TileSchema.protomaps,
      );
    });

    test('Protomaps is recognised by places alone', () {
      expect(
        detectTileSchema(_layers(['earth', 'places'])),
        TileSchema.protomaps,
      );
    });

    test('OpenMapTiles wins when both markers are present', () {
      // Nothing sane produces this, but a deterministic answer beats
      // whichever id the metadata happened to list first.
      expect(
        detectTileSchema(_layers(['roads', 'transportation'])),
        TileSchema.openmaptiles,
      );
    });

    test('null metadata is unknown, never a guess', () {
      // A wrong guess renders a fully blank map; "unknown" lets
      // pickStyleSchema fall through to something that is known.
      expect(detectTileSchema(null), TileSchema.unknown);
    });

    test('an empty list is unknown', () {
      expect(detectTileSchema(const []), TileSchema.unknown);
    });

    test('layers we recognise nothing in are unknown', () {
      // The test fixtures are exactly this shape: `water` only.
      expect(detectTileSchema(_layers(['water'])), TileSchema.unknown);
    });

    test('non-map and id-less entries are skipped, not thrown on', () {
      expect(
        detectTileSchema(<dynamic>[
          'nonsense',
          <String, dynamic>{'fields': {}},
          <String, dynamic>{'id': 'roads'},
        ]),
        TileSchema.protomaps,
      );
    });

    test('labels are the ones the regions screen shows', () {
      expect(TileSchema.openmaptiles.label, 'OpenMapTiles');
      expect(TileSchema.protomaps.label, 'Protomaps');
    });
  });

  group('pickStyleSchema', () {
    test('the active region wins over the coverage pack in front of it',
        () {
      // Served order is coverage-first, but the region is the archive
      // whose detail dominates the view.
      final served = [
        _region('/cov.pmtiles', TileRole.coverage),
        _region('/uk.pmtiles', TileRole.region),
        _region('/world.pmtiles', TileRole.overview),
      ];
      expect(
        pickStyleSchema(served, {
          '/cov.pmtiles': TileSchema.protomaps,
          '/uk.pmtiles': TileSchema.openmaptiles,
          '/world.pmtiles': TileSchema.protomaps,
        }),
        TileSchema.openmaptiles,
      );
    });

    test('an unknown active region falls through to the first known one',
        () {
      final served = [
        _region('/cov.pmtiles', TileRole.coverage),
        _region('/uk.mbtiles', TileRole.region),
      ];
      expect(
        pickStyleSchema(served, {
          '/cov.pmtiles': TileSchema.protomaps,
          '/uk.mbtiles': TileSchema.unknown,
        }),
        TileSchema.protomaps,
      );
    });

    test('an active region that failed to open is not in the map at all',
        () {
      final served = [
        _region('/cov.pmtiles', TileRole.coverage),
        _region('/corrupt.mbtiles', TileRole.region),
      ];
      expect(
        pickStyleSchema(served, {'/cov.pmtiles': TileSchema.openmaptiles}),
        TileSchema.openmaptiles,
      );
    });

    test('with no active region the first served known schema wins', () {
      final served = [
        _region('/cov.pmtiles', TileRole.coverage),
        _region('/world.pmtiles', TileRole.overview),
      ];
      expect(
        pickStyleSchema(served, {
          '/cov.pmtiles': TileSchema.unknown,
          '/world.pmtiles': TileSchema.openmaptiles,
        }),
        TileSchema.openmaptiles,
      );
    });

    test('nothing recognised falls back to Protomaps, the new default',
        () {
      final served = [_region('/mini.mbtiles', TileRole.region)];
      expect(
        pickStyleSchema(served, {'/mini.mbtiles': TileSchema.unknown}),
        TileSchema.protomaps,
      );
    });

    test('an empty served list is Protomaps too', () {
      expect(pickStyleSchema(const [], const {}), TileSchema.protomaps);
    });
  });
}
