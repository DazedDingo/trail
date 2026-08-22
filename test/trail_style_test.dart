import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tiles/tile_schema.dart';
import 'package:trail/services/trail_style.dart';

/// The one vector source out of a style JSON string, whatever its id
/// (`openmaptiles` in OSM Liberty, `protomaps` in the dark style).
Map<String, dynamic> _source(String styleJson, [String? id]) {
  final decoded = jsonDecode(styleJson) as Map<String, dynamic>;
  final sources = decoded['sources'] as Map<String, dynamic>;
  if (id != null) return sources[id] as Map<String, dynamic>;
  return sources.values
      .cast<Map<String, dynamic>>()
      .firstWhere((s) => s['type'] == 'vector');
}

void main() {
  late String rawStyle;
  late String rawDarkStyle;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrailStyle.clearCache();
    rawStyle = await rootBundle.loadString('assets/maptiles/style.json');
    rawDarkStyle =
        await rootBundle.loadString('assets/maptiles/protomaps-dark.json');
  });

  group('TrailStyle.substituteTileServer', () {
    test('tiles URL becomes the loopback per-tile template', () {
      // 0.8.0+46: a per-tile template, not a TileJSON URL — MapLibre
      // fetches MVT directly and skips the round-trip.
      const raw = '"tiles": ["pmtiles://__TRAIL_ACTIVE_REGION__"]';
      final out = TrailStyle.substituteTileServer(raw, port: 8327);
      expect(out, contains('http://127.0.0.1:8327/{z}/{x}/{y}.pbf'));
      expect(out, isNot(contains('__TRAIL_ACTIVE_REGION__')));
      expect(out, isNot(contains('pmtiles://')));
    });

    test('glyph + sprite placeholders rewrite to the same loopback', () {
      // Regression: 0.8.0+47 logged "Could not read asset" for every
      // Roboto fontstack on Android — asset://flutter_assets/... is
      // unreachable from maplibre-native's Android asset source, and a
      // missing-glyphs failure cancels the in-flight tile requests too.
      const raw = '"glyphs": "__TRAIL_GLYPHS__/{fontstack}/{range}.pbf",\n'
          '"sprite": "__TRAIL_SPRITES__/osm-liberty"';
      final out = TrailStyle.substituteTileServer(raw, port: 8327);
      expect(
        out,
        contains('http://127.0.0.1:8327/glyphs/{fontstack}/{range}.pbf'),
      );
      expect(out, contains('http://127.0.0.1:8327/sprites/osm-liberty'));
      expect(out, isNot(contains('__TRAIL_GLYPHS__')));
      expect(out, isNot(contains('__TRAIL_SPRITES__')));
    });

    test('the sprite substitution is sheet-name agnostic', () {
      // One placeholder for both styles: the sheet name stays in the
      // asset, so nothing here knows which style it was handed.
      const raw = '"sprite": "__TRAIL_SPRITES__/protomaps-dark"';
      expect(
        TrailStyle.substituteTileServer(raw, port: 9),
        '"sprite": "http://127.0.0.1:9/sprites/protomaps-dark"',
      );
    });

    test('rewrites the Protomaps style\'s source, not just OSM Liberty\'s',
        () {
      // The two bundled styles name their vector source differently
      // (`openmaptiles` / `protomaps`); the rewrite keys on the type.
      final out = TrailStyle.substituteTileServer(
        rawDarkStyle,
        port: 9100,
        minZoom: 1,
        maxZoom: 14,
      );
      final source = _source(out, 'protomaps');
      expect(source['minzoom'], 1);
      expect(source['maxzoom'], 14);
      expect((source['tiles'] as List).single,
          'http://127.0.0.1:9100/{z}/{x}/{y}.pbf');
      expect(out, contains('http://127.0.0.1:9100/sprites/protomaps-dark'));
      expect(
        out,
        contains('http://127.0.0.1:9100/glyphs/{fontstack}/{range}.pbf'),
      );
    });

    test('rewrites the source zoom range when one is supplied', () {
      final out = TrailStyle.substituteTileServer(
        rawStyle,
        port: 9000,
        minZoom: 2,
        maxZoom: 12,
      );
      final source = _source(out);
      expect(source['minzoom'], 2);
      expect(source['maxzoom'], 12);
      expect((source['tiles'] as List).single,
          'http://127.0.0.1:9000/{z}/{x}/{y}.pbf');
    });

    test('honours a maxzoom above the bundled 13 (coverage packs go to 14)',
        () {
      // With one style source there is ONE zoom range. Leaving the
      // bundled 13 in place would stop MapLibre ever asking for the z14
      // tiles a coverage extract holds (docs/TIMELINE_IMPORT.md §3).
      expect(_source(rawStyle)['maxzoom'], 13);
      final out = TrailStyle.substituteTileServer(
        rawStyle,
        port: 9000,
        minZoom: 0,
        maxZoom: 14,
      );
      expect(_source(out)['maxzoom'], 14);
    });

    test('leaves the bundled zoom range alone when none is supplied', () {
      final out = TrailStyle.substituteTileServer(rawStyle, port: 9000);
      final source = _source(out);
      expect(source['minzoom'], 0);
      expect(source['maxzoom'], 13);
    });

    test('one bound rewrites without disturbing the other', () {
      final maxOnly = TrailStyle.substituteTileServer(
        rawStyle,
        port: 9000,
        maxZoom: 6,
      );
      expect(_source(maxOnly)['minzoom'], 0);
      expect(_source(maxOnly)['maxzoom'], 6);
      final minOnly = TrailStyle.substituteTileServer(
        rawStyle,
        port: 9000,
        minZoom: 4,
      );
      expect(_source(minOnly)['minzoom'], 4);
      expect(_source(minOnly)['maxzoom'], 13);
    });

    test('a fragment that is not a style object survives the rewrite', () {
      // Defensive: the zoom rewrite JSON-decodes, so it has to no-op
      // rather than throw on anything that isn't the bundled style.
      const raw = '"tiles": ["pmtiles://__TRAIL_ACTIVE_REGION__"]';
      final out = TrailStyle.substituteTileServer(
        raw,
        port: 1,
        minZoom: 0,
        maxZoom: 14,
      );
      expect(out, '"tiles": ["http://127.0.0.1:1/{z}/{x}/{y}.pbf"]');
    });

    test('leaves a style without any placeholder unchanged', () {
      const raw = '{"layers":[]}';
      expect(TrailStyle.substituteTileServer(raw, port: 1), raw);
    });
  });

  group('TrailStyle.loadForServer', () {
    test('memoises on (port, minZoom, maxZoom)', () async {
      final a = await TrailStyle.loadForServer(
          port: 1, maxZoom: 14, schema: TileSchema.openmaptiles);
      final b = await TrailStyle.loadForServer(
          port: 1, maxZoom: 14, schema: TileSchema.openmaptiles);
      expect(identical(a, b), isTrue);
      final other = await TrailStyle.loadForServer(
          port: 2, maxZoom: 14, schema: TileSchema.openmaptiles);
      expect(identical(a, other), isFalse);
      final otherRange = await TrailStyle.loadForServer(
          port: 1, maxZoom: 13, schema: TileSchema.openmaptiles);
      expect(identical(a, otherRange), isFalse);
      expect(_source(otherRange!)['maxzoom'], 13);
    });

    test('the memo key includes the schema', () async {
      // Same port + range, different style: the second call must not
      // hand back the first style's JSON.
      final omt = await TrailStyle.loadForServer(
          port: 7, schema: TileSchema.openmaptiles);
      final pm = await TrailStyle.loadForServer(
          port: 7, schema: TileSchema.protomaps);
      expect(identical(omt, pm), isFalse);
      expect(jsonDecode(omt!)['name'], 'OSM Liberty');
      expect(jsonDecode(pm!)['name'], 'Trail · Protomaps dark');
      // …and each is still memoised on its own key.
      expect(
        identical(
          await TrailStyle.loadForServer(
              port: 7, schema: TileSchema.protomaps),
          pm,
        ),
        isTrue,
      );
    });

    test('loads the OSM Liberty asset for the OpenMapTiles schema',
        () async {
      final out = await TrailStyle.loadForServer(
        port: 4242,
        schema: TileSchema.openmaptiles,
        minZoom: 0,
        maxZoom: 13,
      );
      final decoded = jsonDecode(out!) as Map<String, dynamic>;
      expect((decoded['sources'] as Map).keys, contains('openmaptiles'));
      expect(decoded['sprite'], 'http://127.0.0.1:4242/sprites/osm-liberty');
      expect(out, isNot(contains('__TRAIL_')));
    });

    test('loads the Protomaps dark asset for the Protomaps schema',
        () async {
      final out = await TrailStyle.loadForServer(
        port: 4243,
        schema: TileSchema.protomaps,
        minZoom: 0,
        maxZoom: 15,
      );
      final decoded = jsonDecode(out!) as Map<String, dynamic>;
      expect((decoded['sources'] as Map).keys, contains('protomaps'));
      expect(
          decoded['sprite'], 'http://127.0.0.1:4243/sprites/protomaps-dark');
      expect(decoded['glyphs'],
          'http://127.0.0.1:4243/glyphs/{fontstack}/{range}.pbf');
      expect(_source(out, 'protomaps')['maxzoom'], 15);
      expect(out, isNot(contains('__TRAIL_')));
    });

    test('an unknown schema keeps the historical OSM Liberty default',
        () async {
      // pickStyleSchema never yields `unknown`; this pins the fallback
      // so a future caller can't land on a null asset key.
      expect(TrailStyle.assetFor(TileSchema.unknown),
          'assets/maptiles/style.json');
      final out = await TrailStyle.loadForServer(
          port: 5, schema: TileSchema.unknown);
      expect(jsonDecode(out!)['name'], 'OSM Liberty');
    });

    test('clearCache forces a rebuild', () async {
      final a = await TrailStyle.loadForServer(
          port: 1, schema: TileSchema.openmaptiles);
      TrailStyle.clearCache();
      final b = await TrailStyle.loadForServer(
          port: 1, schema: TileSchema.openmaptiles);
      expect(identical(a, b), isFalse);
      expect(a, b);
    });

    test('caps the cache at 4 entries, oldest out first', () async {
      final first = await TrailStyle.loadForServer(
          port: 1, schema: TileSchema.openmaptiles);
      for (var port = 2; port <= 5; port++) {
        await TrailStyle.loadForServer(
            port: port, schema: TileSchema.openmaptiles);
      }
      // Port 1 fell out of the window; port 5 is still resident.
      expect(
        identical(
          await TrailStyle.loadForServer(
              port: 1, schema: TileSchema.openmaptiles),
          first,
        ),
        isFalse,
      );
      final fifth = await TrailStyle.loadForServer(
          port: 5, schema: TileSchema.openmaptiles);
      expect(
        identical(
          await TrailStyle.loadForServer(
              port: 5, schema: TileSchema.openmaptiles),
          fifth,
        ),
        isTrue,
      );
    });
  });

  group('the bundled assets themselves', () {
    test('the Protomaps style only draws Protomaps-schema layers',
        () async {
      // A style that names a source-layer the archives do not hold
      // renders nothing for it — pin the set the generator emits.
      const known = {
        'boundaries',
        'buildings',
        'earth',
        'landcover',
        'landuse',
        'places',
        'pois',
        'roads',
        'water',
      };
      final decoded = jsonDecode(rawDarkStyle) as Map<String, dynamic>;
      final layers = (decoded['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers, isNotEmpty);
      for (final layer in layers) {
        final sourceLayer = layer['source-layer'];
        if (sourceLayer == null) continue;
        expect(known, contains(sourceLayer), reason: 'layer ${layer['id']}');
        expect(layer['source'], 'protomaps');
      }
    });

    test('both styles carry the placeholders the substitution needs',
        () async {
      for (final raw in [rawStyle, rawDarkStyle]) {
        expect(raw, contains('pmtiles://__TRAIL_ACTIVE_REGION__'));
        expect(raw, contains('__TRAIL_GLYPHS__/{fontstack}/{range}.pbf'));
        expect(raw, contains('__TRAIL_SPRITES__/'));
        // The singular placeholder is gone from both (0.16.0).
        expect(raw, isNot(contains('"__TRAIL_SPRITE__"')));
      }
    });
  });

  group('TrailStyle.loadRemoteDemo', () {
    test('points the source at the public Protomaps archive', () async {
      final out = await TrailStyle.loadRemoteDemo();
      expect(
        out,
        contains('pmtiles://https://demo-bucket.protomaps.com/v4.pmtiles'),
      );
      expect(out, isNot(contains('__TRAIL_ACTIVE_REGION__')));
      // No loopback is running in diagnostic mode — the whole point is
      // to test the renderer against a plain remote source.
      expect(out, isNot(contains('http://127.0.0.1')));
    });

    test('the sentinel constant matches the one TilesService persists', () {
      expect(
        TrailStyle.diagnosticRemoteSentinel,
        TilesService.diagnosticRemoteSentinel,
      );
    });
  });
}
