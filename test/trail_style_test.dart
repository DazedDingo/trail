import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/trail_style.dart';

void main() {
  group('TrailStyle.substituteRegionPath', () {
    test('PMTiles paths get pmtiles://file:// prefix', () {
      // Regression: 0.8.0+29 shipped without `file://` and rendered
      // tile-less white. MapLibre Native 11.7+ docs require
      // `pmtiles://file://<path>` for local PMTiles.
      const raw = '"url": "pmtiles://__TRAIL_ACTIVE_REGION__"';
      const path = '/data/user/0/com.dazeddingo.trail/files/tiles/gb.pmtiles';

      final out = TrailStyle.substituteRegionPath(raw, path);

      expect(
        out,
        contains('pmtiles://file:///data/user/0/com.dazeddingo.trail/'
            'files/tiles/gb.pmtiles'),
      );
      expect(out, isNot(contains('__TRAIL_ACTIVE_REGION__')));
    });

    test('MBTiles paths fall back to bare mbtiles:// when no port given', () {
      // No tile-server port = the broken native path; kept for
      // parity in case the upstream fix lands.
      const raw = '"url": "pmtiles://__TRAIL_ACTIVE_REGION__"';
      const path = '/data/user/0/com.dazeddingo.trail/files/tiles/gb.mbtiles';

      final out = TrailStyle.substituteRegionPath(raw, path);

      expect(
        out,
        contains('mbtiles:///data/user/0/com.dazeddingo.trail/'
            'files/tiles/gb.mbtiles'),
      );
      expect(out, isNot(contains('__TRAIL_ACTIVE_REGION__')));
    });

    test('MBTiles paths route through the localhost loopback when port set',
        () {
      // 0.8.0+40 workaround: native local-file rendering broken on
      // Android, so the active MBTiles is served via LocalTileServer
      // and MapLibre fetches as a regular HTTP source. As of 0.8.0+46
      // the substitution writes a per-tile URL template (not a
      // tilejson URL) — the bundled style was switched to a
      // `tiles[]` array source so MapLibre fetches MVT directly,
      // skipping the TileJSON round-trip.
      const raw = '"tiles": ["pmtiles://__TRAIL_ACTIVE_REGION__"]';
      final out = TrailStyle.substituteRegionPath(
        raw,
        '/x/gb.mbtiles',
        tileServerPort: 8327,
      );
      expect(out, contains('http://127.0.0.1:8327/{z}/{x}/{y}.pbf'));
      expect(out, isNot(contains('mbtiles://')));
      expect(out, isNot(contains('__TRAIL_ACTIVE_REGION__')));
    });

    test('PMTiles paths ignore the tile-server port (server only handles '
        'MBTiles)', () {
      const raw = '"url": "pmtiles://__TRAIL_ACTIVE_REGION__"';
      final out = TrailStyle.substituteRegionPath(
        raw,
        '/x/gb.pmtiles',
        tileServerPort: 8327,
      );
      expect(out, contains('pmtiles://file:///x/gb.pmtiles'));
      expect(out, isNot(contains('http://127.0.0.1')));
    });

    test('extension match is case-insensitive', () {
      const raw = '"url": "pmtiles://__TRAIL_ACTIVE_REGION__"';
      expect(
        TrailStyle.substituteRegionPath(raw, '/x.MBTILES'),
        contains('mbtiles:///x.MBTILES'),
      );
      expect(
        TrailStyle.substituteRegionPath(raw, '/x.PMTiles'),
        contains('pmtiles://file:///x.PMTiles'),
      );
    });

    test('leaves a style without the placeholder unchanged', () {
      const raw = '{"layers":[]}';
      expect(TrailStyle.substituteRegionPath(raw, '/x.pmtiles'), raw);
    });

    test('replaces every occurrence (multiple sources, defensively)', () {
      const raw = 'a pmtiles://__TRAIL_ACTIVE_REGION__ b '
          'pmtiles://__TRAIL_ACTIVE_REGION__ c';
      final out = TrailStyle.substituteRegionPath(raw, '/r.pmtiles');
      expect(
        out,
        'a pmtiles://file:///r.pmtiles b pmtiles://file:///r.pmtiles c',
      );
    });
  });
}
