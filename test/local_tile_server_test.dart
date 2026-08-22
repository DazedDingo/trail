import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/services/local_tile_server.dart';
import 'package:trail/services/tiles/tile_archive.dart';

/// Isolate-side sqlite3 loader (gotcha 8) — top-level so it survives the
/// `Isolate.spawn` inside `sqflite_common_ffi`'s factory.
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

/// World coverage, z0–z2, `water` layer (see `test/fixtures/`).
final String kWorld = _fixture('mini.mbtiles');

/// The same tileset converted to PMTiles by `go-pmtiles convert`.
final String kWorldPmtiles = _fixture('mini.pmtiles');

/// North-east quadrant only, z1–z3, `land` layer. Overlaps [kWorld] at
/// z1/1/0 and z2, and holds one z3 tile the world pack does not.
final String kQuadrant = _fixture('mini_b.mbtiles');

class _Response {
  _Response(this.status, this.body, this.contentEncoding, this.contentType);
  final int status;
  final Uint8List body;
  final String? contentEncoding;
  final String? contentType;
}

/// Raw GET against the loopback server. `autoUncompress: false` so the
/// test sees the bytes actually on the wire — the whole point of the
/// gzip passthrough is that we never touch them.
Future<_Response> _get(int port, String path) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final res = await req.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return _Response(
      res.statusCode,
      builder.takeBytes(),
      res.headers.value('content-encoding'),
      res.headers.contentType?.mimeType,
    );
  } finally {
    client.close(force: true);
  }
}

bool _isGzip(List<int> b) =>
    b.length >= 2 && b[0] == 0x1f && b[1] == 0x8b;

void main() {
  final server = LocalTileServer.instance;
  late DatabaseFactory ffi;

  setUpAll(() {
    sqfliteFfiInit();
    ffi = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() {
    LocalTileServer.databaseFactoryOverride = ffi;
    server.clearAssetCache();
    server.assetLoader = null;
  });

  tearDown(() async {
    await server.stop();
    server.assetLoader = null;
    server.clearAssetCache();
    LocalTileServer.databaseFactoryOverride = null;
  });

  /// Reads a tile straight out of an archive so the test can assert
  /// *which* archive the server answered from.
  Future<Uint8List> tileOf(String path, int z, int x, int y) async {
    final archive = await TileArchive.open(path, dbFactory: ffi);
    try {
      final bytes = await archive.tile(z, x, y);
      expect(bytes, isNotNull, reason: 'fixture $path is missing $z/$x/$y');
      return bytes!;
    } finally {
      await archive.close();
    }
  }

  group('start', () {
    test('an empty list stops the server and throws ArgumentError',
        () async {
      await server.start([kWorld]);
      expect(server.port, isNotNull);
      await expectLater(server.start(const []), throwsArgumentError);
      expect(server.port, isNull);
      expect(server.servedPaths, isEmpty);
    });

    test('an identical path list returns the running port untouched',
        () async {
      final first = await server.start([kWorld, kQuadrant]);
      final second = await server.start([kWorld, kQuadrant]);
      expect(second, first);
    });

    test('a different path list rebinds on a fresh port', () async {
      final first = await server.start([kWorld]);
      final second = await server.start([kWorld, kQuadrant]);
      expect(second, isNot(first),
          reason: 'the port change is how MapLibre\'s URL cache is busted');
      final third = await server.start([kQuadrant, kWorld]);
      expect(third, isNot(second), reason: 'order is part of the identity');
    });

    test('an unreadable archive is skipped, not fatal', () async {
      await server.start(['/tmp/trail-does-not-exist.mbtiles', kWorld]);
      expect(server.servedPaths, [kWorld]);
      final res = await _get(server.port!, '/0/0/0.pbf');
      expect(res.status, 200);
    });

    test('throws StateError when nothing opens', () async {
      await expectLater(
        server.start(['/tmp/trail-does-not-exist.mbtiles']),
        throwsStateError,
      );
      expect(server.port, isNull);
    });

    test('the deprecated activePath still names the first archive',
        () async {
      await server.start([kWorld, kQuadrant]);
      // ignore: deprecated_member_use_from_same_package
      expect(server.activePath, kWorld);
      await server.stop();
      // ignore: deprecated_member_use_from_same_package
      expect(server.activePath, isNull);
    });
  });

  group('tile routing', () {
    test('the first archive holding a tile wins', () async {
      final worldTile = await tileOf(kWorld, 1, 1, 0);
      final quadrantTile = await tileOf(kQuadrant, 1, 1, 0);
      expect(worldTile, isNot(quadrantTile), reason: 'fixtures must differ');

      var port = await server.start([kWorld, kQuadrant]);
      expect((await _get(port, '/1/1/0.pbf')).body, worldTile);

      port = await server.start([kQuadrant, kWorld]);
      expect((await _get(port, '/1/1/0.pbf')).body, quadrantTile);
    });

    test('falls through to a later archive when the first cannot help',
        () async {
      // z3 is above the world pack's maxzoom; only the quadrant pack has it.
      final port = await server.start([kWorld, kQuadrant]);
      final res = await _get(port, '/3/4/0.pbf');
      expect(res.status, 200);
      expect(res.body, await tileOf(kQuadrant, 3, 4, 0));
    });

    test('serves stored gzip verbatim with the MVT content type', () async {
      final port = await server.start([kWorld]);
      final res = await _get(port, '/0/0/0.pbf');
      expect(res.status, 200);
      expect(res.contentEncoding, 'gzip');
      expect(res.contentType, 'application/vnd.mapbox-vector-tile');
      expect(_isGzip(res.body), isTrue);
    });

    test('reads PMTiles archives too, byte-identical to the MBTiles twin',
        () async {
      final port = await server.start([kWorldPmtiles]);
      final res = await _get(port, '/2/1/2.pbf');
      expect(res.status, 200);
      expect(res.body, await tileOf(kWorld, 2, 1, 2));
    });

    test('mixes archive formats in one priority list', () async {
      final port = await server.start([kWorldPmtiles, kQuadrant]);
      expect((await _get(port, '/0/0/0.pbf')).body,
          await tileOf(kWorldPmtiles, 0, 0, 0));
      expect((await _get(port, '/3/4/0.pbf')).body,
          await tileOf(kQuadrant, 3, 4, 0));
    });

    test('a repeat request is served from the tile cache', () async {
      final port = await server.start([kWorld]);
      final first = await _get(port, '/1/0/0.pbf');
      expect(server.lastTileStatus, isNot(contains('200 cached')));
      final second = await _get(port, '/1/0/0.pbf');
      expect(second.body, first.body);
      expect(server.lastTileStatus, contains('200 cached'));
      expect(server.tileRequestCount, 2);
    });

    test('clearTileCache forces the next request back to the archive',
        () async {
      final port = await server.start([kWorld]);
      await _get(port, '/1/0/0.pbf');
      server.clearTileCache();
      await _get(port, '/1/0/0.pbf');
      expect(server.lastTileStatus, isNot(contains('200 cached')));
    });

    test('404s when no archive covers the tile and there is no ancestor',
        () async {
      // The quadrant pack starts at z1 and covers the NE quadrant only, so
      // the SW quadrant tile has neither a hit nor an ancestor to fall
      // back on.
      final port = await server.start([kQuadrant]);
      final res = await _get(port, '/1/0/1.pbf');
      expect(res.status, 404);
      expect(server.lastTileStatus, contains('404'));
    });

    test('404s for a route that is not a tile', () async {
      final port = await server.start([kWorld]);
      expect((await _get(port, '/not-a-route')).status, 404);
    });
  });

  group('overzoom', () {
    test('synthesises a tile above the deepest stored zoom', () async {
      final port = await server.start([kWorld]);
      // World pack stops at z2; z3 must come from its z2 parent.
      final res = await _get(port, '/3/0/0.pbf');
      expect(res.status, 200);
      expect(res.contentEncoding, 'gzip');
      expect(_isGzip(res.body), isTrue, reason: 'overzoom output is gzipped');
      expect(gzip.decode(res.body), isNotEmpty);
      expect(server.lastTileStatus, contains('overzoomed'));
    });

    test('walks up several levels to find an ancestor', () async {
      final port = await server.start([kWorld]);
      // z6 is four levels above the stored maximum.
      final res = await _get(port, '/6/3/3.pbf');
      expect(res.status, 200);
      expect(gzip.decode(res.body), isNotEmpty);
    });

    test('an overzoomed tile is cached like a stored one', () async {
      final port = await server.start([kWorld]);
      final first = await _get(port, '/4/5/5.pbf');
      final second = await _get(port, '/4/5/5.pbf');
      expect(second.body, first.body);
      expect(server.lastTileStatus, contains('200 cached'));
    });

    test('takes the ancestor from the highest-priority archive that has one',
        () async {
      // z4 is above both packs. In the NE quadrant both could supply a
      // parent, so priority decides — and the two packs carry different
      // layers, so the bytes differ.
      var port = await server.start([kWorld, kQuadrant]);
      final worldFirst = await _get(port, '/4/9/3.pbf');
      port = await server.start([kQuadrant, kWorld]);
      final quadrantFirst = await _get(port, '/4/9/3.pbf');
      expect(worldFirst.status, 200);
      expect(quadrantFirst.status, 200);
      expect(worldFirst.body, isNot(quadrantFirst.body));
    });

    test('a wildly out-of-range zoom 404s instead of throwing', () async {
      final port = await server.start([kWorld]);
      final res = await _get(port, '/99/0/0.pbf');
      expect(res.status, 404);
    });
  });

  group('served metadata', () {
    test('min/max zoom and bounds are the union across archives', () async {
      await server.start([kWorld, kQuadrant]);
      expect(server.servedMinZoom, 0, reason: 'world pack starts at z0');
      expect(server.servedMaxZoom, 3, reason: 'quadrant pack stores z3');
      final bounds = server.servedBounds!;
      expect(bounds[0], closeTo(-180.0, 1e-4));
      expect(bounds[1], closeTo(-85.0511, 1e-4));
      expect(bounds[2], closeTo(180.0, 1e-4));
      expect(bounds[3], closeTo(85.0511, 1e-4));
    });

    test('are null while stopped', () async {
      await server.stop();
      expect(server.servedMinZoom, isNull);
      expect(server.servedMaxZoom, isNull);
      expect(server.servedBounds, isNull);
      expect(server.servedPaths, isEmpty);
    });

    test('tilejson describes the union and merges vector_layers by id',
        () async {
      final port = await server.start([kWorld, kQuadrant]);
      final res = await _get(port, '/tilejson.json');
      expect(res.status, 200);
      final doc = jsonDecode(utf8.decode(res.body)) as Map<String, dynamic>;

      expect(doc['tiles'], ['http://127.0.0.1:$port/{z}/{x}/{y}.pbf']);
      expect(doc['minzoom'], 0);
      expect(doc['maxzoom'], 3);
      expect((doc['bounds'] as List).first, closeTo(-180.0, 1e-4));
      final ids = (doc['vector_layers'] as List)
          .map((l) => (l as Map)['id'])
          .toList();
      expect(ids, ['water', 'land']);
    });

    test('tilejson keeps the first archive\'s copy of a duplicated layer id',
        () async {
      final port = await server.start([kWorld, kWorldPmtiles]);
      final res = await _get(port, '/tilejson.json');
      final doc = jsonDecode(utf8.decode(res.body)) as Map<String, dynamic>;
      final ids = (doc['vector_layers'] as List)
          .map((l) => (l as Map)['id'])
          .toList();
      expect(ids, ['water'], reason: 'both packs declare the same layer');
    });
  });

  group('probe', () {
    test('summarises an mbtiles region without keeping it open', () async {
      final s = await LocalTileServer.probe(kWorld);
      expect(s.path, kWorld);
      expect(s.minZoom, 0);
      expect(s.maxZoom, 2);
      expect(s.format, 'pbf');
      expect(s.sizeBytes, File(kWorld).lengthSync());
      expect(s.bounds![0], closeTo(-180.0, 1e-4));
      expect(server.port, isNull, reason: 'probe never starts the server');
    });

    test('summarises a pmtiles region', () async {
      final s = await LocalTileServer.probe(kWorldPmtiles);
      expect(s.minZoom, 0);
      expect(s.maxZoom, 2);
      expect(s.format, 'pbf');
      expect(s.sizeBytes, File(kWorldPmtiles).lengthSync());
    });

    test('rejects an unsupported extension', () {
      expect(() => LocalTileServer.probe('/tmp/x.sqlite'), throwsArgumentError);
    });
  });

  group('glyph + sprite assets', () {
    late List<String> loads;

    setUp(() {
      loads = <String>[];
      server.assetLoader = (key) async {
        loads.add(key);
        if (!key.contains('osm-liberty') && !key.contains('Roboto')) {
          throw Exception('Unable to load asset: $key');
        }
        return ByteData.view(
          Uint8List.fromList(utf8.encode('bytes-for:$key')).buffer,
        );
      };
    });

    test('a glyph range is loaded once and memoised thereafter', () async {
      final port = await server.start([kWorld]);
      const url = '/glyphs/Roboto%20Regular/0-255.pbf';
      final first = await _get(port, url);
      final second = await _get(port, url);

      expect(first.status, 200);
      expect(second.body, first.body);
      expect(loads, ['assets/maptiles/glyphs/Roboto Regular/0-255.pbf'],
          reason: 'rootBundle.load is not cached by CachingAssetBundle');
      expect(server.assetCacheSize, 1);
      expect(first.contentType, 'application/x-protobuf');
    });

    test('the memo survives a restart on a new port', () async {
      var port = await server.start([kWorld]);
      await _get(port, '/glyphs/Roboto%20Medium/0-255.pbf');
      port = await server.start([kWorld, kQuadrant]);
      await _get(port, '/glyphs/Roboto%20Medium/0-255.pbf');
      expect(loads, hasLength(1));
    });

    test('sprite variants map to distinct asset keys', () async {
      final port = await server.start([kWorld]);
      await _get(port, '/sprites/osm-liberty.json');
      await _get(port, '/sprites/osm-liberty@2x.png');
      expect(loads, [
        'assets/maptiles/sprites/osm-liberty.json',
        'assets/maptiles/sprites/osm-liberty@2x.png',
      ]);
      expect(server.assetCacheSize, 2);
    });

    test('a missing asset 404s and is not memoised', () async {
      final port = await server.start([kWorld]);
      final res = await _get(port, '/sprites/nope.png');
      expect(res.status, 404);
      expect(server.assetCacheSize, 0);
      await _get(port, '/sprites/nope.png');
      expect(loads, hasLength(2), reason: 'failures must stay retryable');
    });
  });
}
