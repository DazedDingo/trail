import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:pmtiles/pmtiles.dart' as pmt;
import 'package:sqflite_sqlcipher/sqflite.dart';

/// A read-only offline tile archive — one sideloaded `.mbtiles` or
/// `.pmtiles` region file.
///
/// [LocalTileServer] holds an ordered list of these and asks each in
/// turn for a tile, so a user can stack a small high-zoom city pack on
/// top of a coarse country-wide pack and get the best of both. The
/// abstraction exists so the server never has to care which container
/// format a region happens to use:
///
///   * **MBTiles** is SQLite with a TMS y-axis (origin south). The
///     y-flip is [MbtilesArchive]'s problem, not the server's.
///   * **PMTiles** is a single-file Hilbert-ordered archive with an XYZ
///     addressing scheme (origin north) — no flip.
///
/// [tile] returns the bytes **as stored**, which for both formats is
/// normally gzip; the caller sniffs the `1f 8b` magic and decides
/// whether to set `Content-Encoding: gzip` or gunzip for reprojection.
/// Handing back the compressed blob is what lets the common path serve
/// a tile without ever touching its contents.
abstract class TileArchive {
  /// Absolute path of the backing file.
  String get path;

  /// Lowest zoom the archive claims to hold.
  int get minZoom;

  /// Highest zoom the archive claims to hold.
  int get maxZoom;

  /// WGS84 bounds as `[west, south, east, north]`; `null` when the
  /// archive doesn't declare any (treated as "could be anywhere").
  List<double>? get bounds;

  /// The `vector_layers` list out of the archive metadata, if present.
  /// Merged into the served TileJSON so MapLibre can resolve
  /// `source-layer` names.
  List<dynamic>? get vectorLayers;

  /// Tile format as the archive declares it (`pbf`, `png`, …), or
  /// `null` when unknown.
  String? get format;

  /// Cheap pre-check, no I/O: is `(z, x, y)` inside this archive's
  /// zoom range *and* its bounds? A `false` here saves a SQLite query
  /// or a PMTiles directory walk per archive per tile, which is the
  /// whole point of ordering multiple archives behind one server.
  ///
  /// `true` is only "maybe" — the archive can still be missing the
  /// individual tile (sparse packs are the norm).
  bool mayContain(int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return false;
    if (z < 0 || x < 0 || y < 0) return false;
    final side = 1 << z;
    if (x >= side || y >= side) return false;
    final b = bounds;
    if (b == null) return true;
    return tileIntersectsBounds(z, x, y, b);
  }

  /// The stored bytes for `(z, x, y)` in XYZ addressing, or `null` on a
  /// miss. Never throws for a missing tile — and never throws for a
  /// corrupt/closed archive either; unreadable is just another miss, so
  /// one bad region can't take the map down.
  Future<Uint8List?> tile(int z, int x, int y);

  /// Releases the file handle / database. Idempotent.
  Future<void> close();

  /// Opens [path] as the archive type its extension implies.
  ///
  /// [dbFactory] is only consulted for `.mbtiles` and defaults to
  /// `sqflite_sqlcipher`'s factory (which behaves like plain sqflite
  /// when no password is passed). Tests inject `databaseFactoryFfi`
  /// because the SQLCipher plugin has no platform channel under
  /// `flutter test` (gotcha 3).
  static Future<TileArchive> open(
    String path, {
    DatabaseFactory? dbFactory,
  }) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mbtiles')) {
      return MbtilesArchive.open(path, dbFactory: dbFactory);
    }
    if (lower.endsWith('.pmtiles')) {
      return PmtilesArchive.open(path);
    }
    throw ArgumentError.value(
      path,
      'path',
      'not a supported tile archive (expected .mbtiles or .pmtiles)',
    );
  }
}

/// An `.mbtiles` region: SQLite, `tiles(zoom_level, tile_column,
/// tile_row, tile_data)` in TMS orientation plus a `metadata(name,
/// value)` key/value table.
class MbtilesArchive extends TileArchive {
  MbtilesArchive._(
    this._db, {
    required this.path,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds,
    required this.vectorLayers,
    required this.format,
  });

  /// Opens the file read-only.
  ///
  /// `singleInstance: false` gives us a per-call native handle so
  /// closing this archive can't bleed into any other plugin-tracked
  /// database (the encrypted Trail DB in particular) — same convention
  /// as `database.dart`.
  static Future<MbtilesArchive> open(
    String path, {
    DatabaseFactory? dbFactory,
  }) async {
    final db = await (dbFactory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final meta = await _readMetadata(db);
      var minZoom = int.tryParse(meta['minzoom']?.toString() ?? '');
      var maxZoom = int.tryParse(meta['maxzoom']?.toString() ?? '');
      if (minZoom == null || maxZoom == null) {
        // Some producers (and every hand-rolled pack) omit the zoom
        // metadata. Derive it from the tiles table rather than guessing
        // 0..14 — a wrong maxzoom silently disables overzoom.
        final rows = await db.rawQuery(
          'SELECT MIN(zoom_level) AS mn, MAX(zoom_level) AS mx FROM tiles',
        );
        final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
        minZoom ??= (row['mn'] as num?)?.toInt() ?? 0;
        maxZoom ??= (row['mx'] as num?)?.toInt() ?? minZoom;
      }
      return MbtilesArchive._(
        db,
        path: path,
        minZoom: minZoom,
        maxZoom: math.max(minZoom, maxZoom),
        bounds: parseBoundsCsv(meta['bounds']?.toString()),
        vectorLayers: _vectorLayersFromJsonBlob(meta['json']?.toString()),
        format: meta['format']?.toString(),
      );
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  final Database _db;

  @override
  final String path;
  @override
  final int minZoom;
  @override
  final int maxZoom;
  @override
  final List<double>? bounds;
  @override
  final List<dynamic>? vectorLayers;
  @override
  final String? format;

  @override
  Future<Uint8List?> tile(int z, int x, int y) async {
    if (z < 0 || x < 0 || y < 0) return null;
    final side = 1 << z;
    if (x >= side || y >= side) return null;
    // MBTiles is TMS (origin south); the wire protocol is XYZ.
    final tmsY = side - 1 - y;
    final List<Map<String, Object?>> rows;
    try {
      rows = await _db.query(
        'tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, tmsY],
        limit: 1,
      );
    } catch (e) {
      debugPrint('MbtilesArchive($path): read $z/$x/$y failed — $e');
      return null;
    }
    if (rows.isEmpty) return null;
    final blob = rows.first['tile_data'];
    if (blob is Uint8List) return blob;
    if (blob is List<int>) return Uint8List.fromList(blob);
    return null;
  }

  @override
  Future<void> close() async {
    try {
      await _db.close();
    } catch (_) {/* already closed */}
  }

  static Future<Map<String, dynamic>> _readMetadata(Database db) async {
    final rows = await db.query('metadata', columns: ['name', 'value']);
    final m = <String, dynamic>{};
    for (final r in rows) {
      final name = r['name'] as String?;
      if (name == null) continue;
      m[name] = r['value'];
    }
    return m;
  }

  static List<dynamic>? _vectorLayersFromJsonBlob(String? blob) {
    if (blob == null || blob.isEmpty) return null;
    try {
      final decoded = jsonDecode(blob);
      if (decoded is Map<String, dynamic>) {
        final layers = decoded['vector_layers'];
        if (layers is List) return layers;
      }
    } catch (_) {/* malformed metadata json — treat as absent */}
    return null;
  }
}

/// A `.pmtiles` region. Addressing is XYZ (no y-flip) and tiles are
/// stored gzipped in every archive `planetiler` / `go-pmtiles` produce,
/// so [tile] hands back `compressedBytes()` untouched in that case.
class PmtilesArchive extends TileArchive {
  PmtilesArchive._(
    this._archive, {
    required this.path,
    required this.bounds,
    required this.vectorLayers,
    required this.format,
  });

  /// Opens the archive; the header alone gives us zooms + bounds, and
  /// one extra read pulls the JSON metadata for `vector_layers`.
  static Future<PmtilesArchive> open(String path) async {
    final archive = await pmt.PmTilesArchive.fromFile(File(path));
    try {
      List<dynamic>? vectorLayers;
      try {
        final meta = await archive.metadata;
        if (meta is Map) {
          final layers = meta['vector_layers'];
          if (layers is List) vectorLayers = layers;
        }
      } catch (e) {
        debugPrint('PmtilesArchive($path): metadata unreadable — $e');
      }
      return PmtilesArchive._(
        archive,
        path: path,
        bounds: _headerBounds(archive),
        vectorLayers: vectorLayers,
        format: _formatFor(archive.tileType),
      );
    } catch (_) {
      await archive.close();
      rethrow;
    }
  }

  final pmt.PmTilesArchive _archive;

  @override
  final String path;
  @override
  final List<double>? bounds;
  @override
  final List<dynamic>? vectorLayers;
  @override
  final String? format;

  @override
  int get minZoom => _archive.minZoom;

  @override
  int get maxZoom => _archive.maxZoom;

  @override
  Future<Uint8List?> tile(int z, int x, int y) async {
    if (z < 0 || z > pmt.ZXY.maxAllowedZoom || x < 0 || y < 0) return null;
    final side = 1 << z;
    if (x >= side || y >= side) return null;
    try {
      final t = await _archive.tile(pmt.ZXY(z, x, y).toTileId());
      // Serving the stored gzip verbatim keeps the fast path
      // allocation-free; only the overzoom path needs plain MVT.
      final bytes = _archive.tileCompression == pmt.Compression.gzip
          ? t.compressedBytes()
          : t.bytes();
      return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    } on pmt.TileNotFoundException {
      return null;
    } catch (e) {
      debugPrint('PmtilesArchive($path): read $z/$x/$y failed — $e');
      return null;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _archive.close();
    } catch (_) {/* already closed */}
  }

  static List<double>? _headerBounds(pmt.PmTilesArchive archive) {
    final min = archive.minPosition;
    final max = archive.maxPosition;
    final west = min.longitude;
    final south = min.latitude;
    final east = max.longitude;
    final north = max.latitude;
    // An archive with no declared bounds writes zeroes; a degenerate box
    // would make `mayContain` reject every tile, so report "unknown".
    if (west == east || south == north) return null;
    return <double>[west, south, east, north];
  }

  static String? _formatFor(pmt.TileType type) => switch (type) {
        pmt.TileType.mvt => 'pbf',
        pmt.TileType.png => 'png',
        pmt.TileType.jpeg => 'jpg',
        pmt.TileType.webp => 'webp',
        pmt.TileType.avif => 'avif',
        // Wildcard on purpose: pubspec.lock is gitignored, so CI resolves
        // whatever `pmtiles` 2.x is newest (2.2.0 added `mlt`), and an
        // exhaustive switch broke the 0.15.0+97 build. Anything we don't
        // name is "unknown" for display; it changes nothing about serving.
        _ => null,
      };
}

/// Parses an MBTiles-style `"west,south,east,north"` metadata string.
/// Returns `null` for absent or malformed input rather than throwing —
/// a region with unparseable bounds is served as "bounds unknown", not
/// as broken.
List<double>? parseBoundsCsv(String? csv) {
  if (csv == null || csv.isEmpty) return null;
  final parts = csv
      .split(',')
      .map((s) => double.tryParse(s.trim()))
      .whereType<double>()
      .toList(growable: false);
  if (parts.length != 4) return null;
  if (parts.any((v) => v.isNaN || v.isInfinite)) return null;
  return parts;
}

/// Does XYZ tile `(z, x, y)` overlap the WGS84 box
/// `[west, south, east, north]`?
///
/// Web-Mercator tile → lon/lat maths, with edge contact deliberately
/// counting as *no* overlap: a bounds box that stops exactly on a tile
/// seam contributes nothing to the neighbouring tile, and letting it
/// count would make every archive "maybe contain" a ring of empty
/// tiles around its real coverage.
bool tileIntersectsBounds(int z, int x, int y, List<double> bounds) {
  if (bounds.length < 4) return true;
  final west = _tileToLon(x, z);
  final east = _tileToLon(x + 1, z);
  // y grows southward, so y is the *north* edge and y+1 the south one.
  final north = _tileToLat(y, z);
  final south = _tileToLat(y + 1, z);

  final bWest = math.min(bounds[0], bounds[2]);
  final bEast = math.max(bounds[0], bounds[2]);
  final bSouth = math.min(bounds[1], bounds[3]);
  final bNorth = math.max(bounds[1], bounds[3]);

  if (east <= bWest || west >= bEast) return false;
  if (north <= bSouth || south >= bNorth) return false;
  return true;
}

/// Smallest box containing every box in [all].
///
/// Throws [ArgumentError] when nothing usable is supplied — callers
/// (the server's `servedBounds`) filter out archives with unknown
/// bounds first, and silently inventing a world-sized box here would
/// hide that mistake.
List<double> unionBounds(Iterable<List<double>> all) {
  double? west, south, east, north;
  for (final b in all) {
    if (b.length < 4) continue;
    final w = math.min(b[0], b[2]);
    final e = math.max(b[0], b[2]);
    final s = math.min(b[1], b[3]);
    final n = math.max(b[1], b[3]);
    west = west == null ? w : math.min(west, w);
    east = east == null ? e : math.max(east, e);
    south = south == null ? s : math.min(south, s);
    north = north == null ? n : math.max(north, n);
  }
  if (west == null) {
    throw ArgumentError.value(all, 'all', 'no well-formed bounds to union');
  }
  return <double>[west, south!, east!, north!];
}

double _tileToLon(int x, int z) => x / (1 << z) * 360.0 - 180.0;

double _tileToLat(int y, int z) {
  final n = math.pi - 2 * math.pi * y / (1 << z);
  return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}
