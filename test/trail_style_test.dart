import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/trail_style.dart';

/// The `openmaptiles` source out of a style JSON string.
Map<String, dynamic> _source(String styleJson) {
  final decoded = jsonDecode(styleJson) as Map<String, dynamic>;
  final sources = decoded['sources'] as Map<String, dynamic>;
  return sources['openmaptiles'] as Map<String, dynamic>;
}

void main() {
  late String rawStyle;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrailStyle.clearCache();
    rawStyle = await rootBundle.loadString('assets/maptiles/style.json');
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
          '"sprite": "__TRAIL_SPRITE__"';
      final out = TrailStyle.substituteTileServer(raw, port: 8327);
      expect(
        out,
        contains('http://127.0.0.1:8327/glyphs/{fontstack}/{range}.pbf'),
      );
      expect(out, contains('http://127.0.0.1:8327/sprites/osm-liberty'));
      expect(out, isNot(contains('__TRAIL_GLYPHS__')));
      expect(out, isNot(contains('__TRAIL_SPRITE__')));
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
      final a = await TrailStyle.loadForServer(port: 1, maxZoom: 14);
      final b = await TrailStyle.loadForServer(port: 1, maxZoom: 14);
      expect(identical(a, b), isTrue);
      final other = await TrailStyle.loadForServer(port: 2, maxZoom: 14);
      expect(identical(a, other), isFalse);
      final otherRange = await TrailStyle.loadForServer(port: 1, maxZoom: 13);
      expect(identical(a, otherRange), isFalse);
      expect(_source(otherRange!)['maxzoom'], 13);
    });

    test('clearCache forces a rebuild', () async {
      final a = await TrailStyle.loadForServer(port: 1);
      TrailStyle.clearCache();
      final b = await TrailStyle.loadForServer(port: 1);
      expect(identical(a, b), isFalse);
      expect(a, b);
    });

    test('caps the cache at 4 entries, oldest out first', () async {
      final first = await TrailStyle.loadForServer(port: 1);
      for (var port = 2; port <= 5; port++) {
        await TrailStyle.loadForServer(port: port);
      }
      // Port 1 fell out of the window; port 5 is still resident.
      expect(identical(await TrailStyle.loadForServer(port: 1), first), isFalse);
      final fifth = await TrailStyle.loadForServer(port: 5);
      expect(identical(await TrailStyle.loadForServer(port: 5), fifth), isTrue);
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
