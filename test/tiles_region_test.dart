import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/mbtiles_service.dart';

/// Moved out of the deleted `trail_map_test.dart` (the `TrailMap` widget
/// was dead code once Home adopted `FullMapPanel` in 0.10.13).
void main() {
  group('TilesRegion', () {
    test('has a name, path, and byte size', () {
      const region = TilesRegion(
        name: 'gb',
        path: '/data/files/tiles/gb.pmtiles',
        bytes: 511 * 1024 * 1024,
      );
      expect(region.name, 'gb');
      expect(region.path, '/data/files/tiles/gb.pmtiles');
      expect(region.bytes, 511 * 1024 * 1024);
    });
  });
}
