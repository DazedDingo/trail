import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/services/tiles/tile_archive.dart';

/// Isolate-side sqlite3 loader. Must be a TOP-LEVEL function so it can be
/// sent across the `Isolate.spawn` boundary inside `sqflite_common_ffi`'s
/// FFI factory (a closure would fail to serialize) — same pattern as
/// `ping_dao_test.dart`, see gotcha 8.
void _ffiInit() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      for (final candidate in const [
        'libsqlite3.so.0',
        '/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      ]) {
        try {
          return DynamicLibrary.open(candidate);
        } on ArgumentError {
          // Try next candidate.
        }
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
}

/// Fixture paths are absolute on purpose: `sqflite`'s factories resolve a
/// *relative* database path against their own databases directory, not the
/// process CWD. Production only ever passes absolute app-documents paths.
String _fixture(String name) =>
    '${Directory.current.path}/test/fixtures/$name';

/// `test/fixtures/mini.mbtiles` + `mini.pmtiles`: world coverage, z0–z2,
/// bounds -180,-85.0511,180,85.0511, one `water` vector layer, every tile
/// a distinct hand-built gzipped MVT (see `test/fixtures/make_fixtures.py`).
final String kMiniMbtiles = _fixture('mini.mbtiles');
final String kMiniPmtiles = _fixture('mini.pmtiles');

/// `test/fixtures/mini_b.mbtiles`: north-east quadrant only (bounds
/// 0,0,180,85.0511), z1–z3, one `land` vector layer.
final String kMiniBMbtiles = _fixture('mini_b.mbtiles');

void main() {
  late DatabaseFactory ffi;

  setUpAll(() {
    sqfliteFfiInit();
    ffi = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  test('every fixture exists and stays tiny enough to commit', () {
    for (final path in [kMiniMbtiles, kMiniPmtiles, kMiniBMbtiles]) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path missing');
      expect(f.lengthSync(), lessThan(20 * 1024), reason: '$path too big');
    }
  });

  group('TileArchive.open', () {
    test('picks MbtilesArchive for .mbtiles (case-insensitively)', () async {
      final a = await TileArchive.open(kMiniMbtiles, dbFactory: ffi);
      addTearDown(a.close);
      expect(a, isA<MbtilesArchive>());
      expect(a.path, kMiniMbtiles);
    });

    test('picks PmtilesArchive for .pmtiles', () async {
      final a = await TileArchive.open(kMiniPmtiles);
      addTearDown(a.close);
      expect(a, isA<PmtilesArchive>());
      expect(a.path, kMiniPmtiles);
    });

    test('throws ArgumentError for any other extension', () {
      expect(
        () => TileArchive.open('/tmp/region.sqlite', dbFactory: ffi),
        throwsArgumentError,
      );
    });

    test('rethrows for a missing file rather than yielding a dead archive',
        () async {
      await expectLater(
        TileArchive.open('/tmp/definitely-not-here.pmtiles'),
        throwsA(isA<Exception>()),
      );
    });
  });

  // Both fixtures describe the same tileset, so the same expectations run
  // against both readers — that equivalence is the whole point of the
  // abstraction.
  for (final variant in [
    ('MbtilesArchive', kMiniMbtiles),
    ('PmtilesArchive', kMiniPmtiles),
  ]) {
    group(variant.$1, () {
      late TileArchive archive;

      setUp(() async {
        archive = await TileArchive.open(variant.$2, dbFactory: ffi);
      });

      tearDown(() async => archive.close());

      test('reports the fixture zoom range', () {
        expect(archive.minZoom, 0);
        expect(archive.maxZoom, 2);
      });

      test('reports the fixture bounds', () {
        expect(archive.bounds, isNotNull);
        expect(archive.bounds![0], closeTo(-180.0, 1e-4));
        expect(archive.bounds![1], closeTo(-85.0511, 1e-4));
        expect(archive.bounds![2], closeTo(180.0, 1e-4));
        expect(archive.bounds![3], closeTo(85.0511, 1e-4));
      });

      test('exposes vector_layers from metadata', () {
        expect(archive.vectorLayers, isNotNull);
        expect(archive.vectorLayers, hasLength(1));
        expect((archive.vectorLayers!.first as Map)['id'], 'water');
      });

      test('reports pbf as the tile format', () {
        expect(archive.format, 'pbf');
      });

      test('an exact hit returns the stored gzipped bytes', () async {
        final bytes = await archive.tile(0, 0, 0);
        expect(bytes, isNotNull);
        expect(bytes!.length, greaterThan(2));
        expect(bytes.sublist(0, 2), [0x1f, 0x8b], reason: 'stored gzipped');
      });

      test('distinct tiles return distinct blobs (y is not flipped twice)',
          () async {
        final nw = await archive.tile(1, 0, 0);
        final se = await archive.tile(1, 1, 1);
        expect(nw, isNotNull);
        expect(se, isNotNull);
        expect(nw, isNot(equals(se)));
      });

      test('a zoom the archive does not hold returns null, not a throw',
          () async {
        expect(await archive.tile(6, 12, 20), isNull);
      });

      test('out-of-range coordinates return null', () async {
        expect(await archive.tile(1, 2, 0), isNull);
        expect(await archive.tile(1, 0, -1), isNull);
        expect(await archive.tile(-1, 0, 0), isNull);
      });

      test('mayContain is true inside the zoom range and bounds', () {
        expect(archive.mayContain(0, 0, 0), isTrue);
        expect(archive.mayContain(2, 1, 2), isTrue);
      });

      test('mayContain is false outside the zoom range', () {
        expect(archive.mayContain(3, 0, 0), isFalse);
      });

      test('mayContain is false for coordinates off the tile grid', () {
        expect(archive.mayContain(1, 2, 0), isFalse);
        expect(archive.mayContain(1, 0, 2), isFalse);
      });

      test('close is idempotent', () async {
        await archive.close();
        await archive.close();
      });
    });
  }

  group('MbtilesArchive (fixture B — partial coverage)', () {
    late TileArchive archive;

    setUp(() async {
      archive = await TileArchive.open(kMiniBMbtiles, dbFactory: ffi);
    });

    tearDown(() async => archive.close());

    test('reports its own zoom range, bounds and layer', () {
      expect(archive.minZoom, 1);
      expect(archive.maxZoom, 3);
      expect(archive.bounds![0], closeTo(0.0, 1e-6));
      expect(archive.bounds![1], closeTo(0.0, 1e-6));
      expect((archive.vectorLayers!.first as Map)['id'], 'land');
    });

    test('mayContain rejects tiles outside the north-east quadrant', () {
      expect(archive.mayContain(1, 1, 0), isTrue, reason: 'NE quadrant');
      expect(archive.mayContain(1, 0, 0), isFalse, reason: 'NW quadrant');
      expect(archive.mayContain(1, 0, 1), isFalse, reason: 'SW quadrant');
      expect(archive.mayContain(1, 1, 1), isFalse, reason: 'SE quadrant');
    });

    test('mayContain rejects z0 — below the archive minZoom', () {
      expect(archive.mayContain(0, 0, 0), isFalse);
    });

    test('holds the z3 tile the world fixture does not', () async {
      expect(await archive.tile(3, 4, 0), isNotNull);
      expect(await archive.tile(3, 0, 0), isNull);
    });

    test('its blobs differ from the world fixture at the same tile',
        () async {
      final world = await TileArchive.open(kMiniMbtiles, dbFactory: ffi);
      addTearDown(world.close);
      expect(await archive.tile(1, 1, 0), isNot(await world.tile(1, 1, 0)));
    });
  });

  group('tileIntersectsBounds', () {
    test('z1 north-west tile overlaps the north-west box', () {
      expect(tileIntersectsBounds(1, 0, 0, [-180, 0, 0, 85]), isTrue);
    });

    test('z1 north-west tile misses the south-east box', () {
      expect(tileIntersectsBounds(1, 0, 0, [0, -85, 180, 0]), isFalse);
    });

    test('the z0 tile overlaps any box', () {
      expect(tileIntersectsBounds(0, 0, 0, [-0.5, 51.2, 0.3, 51.7]), isTrue);
      expect(tileIntersectsBounds(0, 0, 0, [174.0, -41.5, 175.0, -41.0]),
          isTrue);
    });

    test('edge contact alone does not count as overlap', () {
      // z1 x=0 spans lon [-180, 0]; a box starting exactly at 0 is the
      // neighbour's business.
      expect(tileIntersectsBounds(1, 0, 0, [0, 0, 10, 10]), isFalse);
      expect(tileIntersectsBounds(1, 1, 0, [-10, 0, 0, 10]), isFalse);
    });

    test('a box inside a single tile only matches that tile', () {
      const london = [-0.5, 51.2, 0.3, 51.7];
      expect(tileIntersectsBounds(1, 0, 0, london), isTrue);
      expect(tileIntersectsBounds(1, 1, 0, london), isTrue,
          reason: 'the box straddles the prime meridian');
      expect(tileIntersectsBounds(1, 0, 1, london), isFalse);
      expect(tileIntersectsBounds(1, 1, 1, london), isFalse);
    });

    test('bounds given corner-swapped are normalised', () {
      expect(tileIntersectsBounds(1, 0, 0, [0, 85, -180, 0]), isTrue);
    });

    test('a malformed box is treated as "could be anywhere"', () {
      expect(tileIntersectsBounds(1, 1, 1, [1, 2]), isTrue);
    });
  });

  group('unionBounds', () {
    test('a single box comes back unchanged', () {
      expect(unionBounds([
        [-1.0, 50.0, 1.0, 52.0],
      ]), [-1.0, 50.0, 1.0, 52.0]);
    });

    test('two disjoint boxes union to the enclosing box', () {
      expect(
        unionBounds([
          [-1.0, 50.0, 1.0, 52.0],
          [10.0, 40.0, 12.0, 41.0],
        ]),
        [-1.0, 40.0, 12.0, 52.0],
      );
    });

    test('a contained box does not shrink the union', () {
      expect(
        unionBounds([
          [-10.0, -10.0, 10.0, 10.0],
          [-1.0, -1.0, 1.0, 1.0],
        ]),
        [-10.0, -10.0, 10.0, 10.0],
      );
    });

    test('corner-swapped inputs are normalised before unioning', () {
      expect(
        unionBounds([
          [1.0, 52.0, -1.0, 50.0],
        ]),
        [-1.0, 50.0, 1.0, 52.0],
      );
    });

    test('malformed entries are skipped', () {
      expect(
        unionBounds([
          [1.0, 2.0],
          [-1.0, 50.0, 1.0, 52.0],
        ]),
        [-1.0, 50.0, 1.0, 52.0],
      );
    });

    test('throws when nothing usable is supplied', () {
      expect(() => unionBounds(const []), throwsArgumentError);
      expect(
        () => unionBounds([
          [1.0, 2.0],
        ]),
        throwsArgumentError,
      );
    });
  });

  group('parseBoundsCsv', () {
    test('parses the MBTiles metadata form', () {
      expect(parseBoundsCsv('-180.0,-85.0511,180.0,85.0511'),
          [-180.0, -85.0511, 180.0, 85.0511]);
    });

    test('tolerates surrounding whitespace', () {
      expect(parseBoundsCsv(' -1.0 , 50.0 , 1.0 , 52.0 '),
          [-1.0, 50.0, 1.0, 52.0]);
    });

    test('returns null for absent, short or unparseable input', () {
      expect(parseBoundsCsv(null), isNull);
      expect(parseBoundsCsv(''), isNull);
      expect(parseBoundsCsv('1,2,3'), isNull);
      expect(parseBoundsCsv('a,b,c,d'), isNull);
      expect(parseBoundsCsv('1,2,3,4,5'), isNull);
    });
  });
}
