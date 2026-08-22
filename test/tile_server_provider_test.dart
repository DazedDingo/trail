import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/providers/mbtiles_provider.dart';
import 'package:trail/providers/tile_server_provider.dart';
import 'package:trail/services/local_tile_server.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tiles/tile_schema.dart';

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

/// Absolute — `sqflite` resolves relative DB paths against its own
/// databases dir, not the process CWD.
String _fixture(String name) =>
    '${Directory.current.path}/test/fixtures/$name';

/// World coverage, z0–z2.
final String kWorld = _fixture('mini.mbtiles');

/// North-east quadrant only, z1–z3.
final String kQuadrant = _fixture('mini_b.mbtiles');

TilesRegion _archive(String path, TileRole role) => TilesRegion(
      name: path.split('/').last,
      path: path,
      bytes: 1,
      role: role,
    );

void main() {
  final server = LocalTileServer.instance;
  late DatabaseFactory ffi;

  setUpAll(() {
    sqfliteFfiInit();
    ffi = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  setUp(() {
    LocalTileServer.databaseFactoryOverride = ffi;
  });

  tearDown(() async {
    await server.stop();
    LocalTileServer.databaseFactoryOverride = null;
  });

  /// A container whose `servedArchivesProvider` yields exactly [served],
  /// so the provider under test is exercised without touching prefs or
  /// the app documents dir.
  ProviderContainer containerWith(List<TilesRegion> served) {
    final container = ProviderContainer(
      overrides: [
        servedArchivesProvider.overrideWith((ref) async => served),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('serves the archive list in order and returns the bound port',
      () async {
    final container = containerWith([
      _archive(kQuadrant, TileRole.coverage),
      _archive(kWorld, TileRole.overview),
    ]);

    final state = await container.read(tileServerProvider.future);

    expect(state, isNotNull);
    expect(state!.port, server.port);
    // Priority order is preserved end-to-end: the coverage pack is
    // asked for a tile before the world overview.
    expect(server.servedPaths, [kQuadrant, kWorld]);
    expect(state.servedPaths, [kQuadrant, kWorld]);
  });

  test('carries the zoom union the style has to be re-ranged to',
      () async {
    // mini_b is z1–3, mini is z0–2: one style source, one range, so it
    // has to be the union or MapLibre never asks for the z3 tiles.
    final container = containerWith([
      _archive(kQuadrant, TileRole.coverage),
      _archive(kWorld, TileRole.overview),
    ]);

    final state = await container.read(tileServerProvider.future);

    expect(state!.minZoom, 0);
    expect(state.maxZoom, 3);
  });

  test('fixtures declare no schema marker, so the style defaults to '
      'Protomaps', () async {
    // Both fixtures carry a single `water` vector layer — recognisable
    // as neither schema. `pickStyleSchema` then falls back to the new
    // default rather than guessing (the per-branch cases live in
    // test/tile_schema_test.dart, which needs no fixtures).
    final container = containerWith([
      _archive(kQuadrant, TileRole.coverage),
      _archive(kWorld, TileRole.overview),
    ]);

    final state = await container.read(tileServerProvider.future);

    expect(server.servedSchemas,
        {kQuadrant: TileSchema.unknown, kWorld: TileSchema.unknown});
    expect(state!.schema, TileSchema.protomaps);
    // One schema (even an unrecognised one) is not a mixed library.
    expect(state.mixedSchemas, isFalse);
  });

  test('schemaFor answers only for archives that are open', () async {
    final container = containerWith([_archive(kWorld, TileRole.overview)]);
    await container.read(tileServerProvider.future);

    expect(server.schemaFor(kWorld), TileSchema.unknown);
    expect(server.schemaFor(kQuadrant), isNull);
  });

  test('an empty archive list stops the server and returns null', () async {
    // Start it first so "stops" is actually observable.
    await server.start([kWorld]);
    expect(server.port, isNotNull);

    final container = containerWith(const []);
    final state = await container.read(tileServerProvider.future);

    expect(state, isNull);
    expect(server.port, isNull);
    expect(server.servedPaths, isEmpty);
  });

  test('the diagnostic sentinel never starts the server', () async {
    // Diagnostic mode renders the public Protomaps demo over the real
    // internet; there is nothing local to serve.
    final container = containerWith([
      const TilesRegion(
        name: 'Remote demo (diagnostic)',
        path: TilesService.diagnosticRemoteSentinel,
        bytes: 0,
      ),
    ]);

    final state = await container.read(tileServerProvider.future);

    expect(state, isNull);
    expect(server.port, isNull);
    expect(server.servedPaths, isEmpty);
  });

  test('a sentinel alongside real archives still bypasses the server',
      () async {
    final container = containerWith([
      _archive(kWorld, TileRole.coverage),
      const TilesRegion(
        name: 'Remote demo (diagnostic)',
        path: TilesService.diagnosticRemoteSentinel,
        bytes: 0,
      ),
    ]);

    expect(await container.read(tileServerProvider.future), isNull);
    expect(server.port, isNull);
  });

  test('re-deriving with a different list rebinds on a fresh port',
      () async {
    var served = [_archive(kWorld, TileRole.overview)];
    final container = ProviderContainer(
      overrides: [
        servedArchivesProvider.overrideWith((ref) async => served),
      ],
    );
    addTearDown(container.dispose);

    final first = await container.read(tileServerProvider.future);
    expect(first, isNotNull);

    served = [
      _archive(kQuadrant, TileRole.coverage),
      _archive(kWorld, TileRole.overview),
    ];
    container.invalidate(servedArchivesProvider);
    final second = await container.read(tileServerProvider.future);

    // A fresh port is the ONLY cache invalidation available to us —
    // tiles are served `immutable` and MapLibre keys its cache on URL.
    expect(second, isNotNull);
    expect(second!.port, isNot(first!.port));
    expect(second, isNot(first));
    expect(server.servedPaths, [kQuadrant, kWorld]);
  });

  test('an unchanged list keeps the same port across a re-derive',
      () async {
    final served = [_archive(kWorld, TileRole.region)];
    final container = ProviderContainer(
      overrides: [
        servedArchivesProvider.overrideWith((ref) async => served),
      ],
    );
    addTearDown(container.dispose);

    final first = await container.read(tileServerProvider.future);
    container.invalidate(servedArchivesProvider);
    final second = await container.read(tileServerProvider.future);

    // Value equality, not identity: the panel keys its platform view on
    // this, and an unchanged archive set must not remount the map.
    expect(second!.port, first!.port);
    expect(second, first);
    expect(second.hashCode, first.hashCode);
  });

  test('returns null when no archive in the list can be opened', () async {
    final container = containerWith([
      _archive('/tmp/trail-no-such-archive.mbtiles', TileRole.region),
    ]);

    // StateError from the server is swallowed — one corrupt sideload
    // must not throw on the map's build path.
    expect(await container.read(tileServerProvider.future), isNull);
    expect(server.port, isNull);
  });

  test('skips the unreadable archives and serves the rest', () async {
    final container = containerWith([
      _archive('/tmp/trail-no-such-archive.mbtiles', TileRole.coverage),
      _archive(kWorld, TileRole.overview),
    ]);

    final state = await container.read(tileServerProvider.future);
    expect(state, isNotNull);
    expect(server.servedPaths, [kWorld]);
    // The path that never opened is not claimed as served, and its
    // (absent) schema doesn't make the library look mixed.
    expect(state!.servedPaths, [kWorld]);
    expect(state.mixedSchemas, isFalse);
  });

  group('TileServerState', () {
    TileServerState state({
      int port = 1,
      List<String> paths = const ['/a'],
      TileSchema schema = TileSchema.protomaps,
      bool mixed = false,
      int? maxZoom = 14,
    }) =>
        TileServerState(
          port: port,
          servedPaths: paths,
          minZoom: 0,
          maxZoom: maxZoom,
          schema: schema,
          mixedSchemas: mixed,
        );

    test('equal on port + paths + schema', () {
      expect(state(), state());
      expect(state().hashCode, state().hashCode);
    });

    test('a different port, path list or schema is a different state', () {
      expect(state(port: 2), isNot(state()));
      expect(state(paths: const ['/a', '/b']), isNot(state()));
      expect(state(paths: const ['/b']), isNot(state()));
      expect(state(schema: TileSchema.openmaptiles), isNot(state()));
    });

    test('the derived + advisory fields stay out of the identity', () {
      // Both follow from the archive set, which is already in the key;
      // including them would remount the map for nothing.
      expect(state(mixed: true), state());
      expect(state(maxZoom: null), state());
    });

    test('the served path list is unmodifiable', () {
      final paths = ['/a'];
      final s = state(paths: paths);
      paths.add('/b');
      expect(s.servedPaths, ['/a']);
      expect(() => s.servedPaths.add('/c'), throwsUnsupportedError);
    });
  });
}
