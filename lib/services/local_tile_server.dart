import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Serves vector tiles from a local `.mbtiles` file over a localhost
/// HTTP loopback so MapLibre Native (which silently fails to render
/// tiles via `mbtiles://file://` and `pmtiles://file://` on Android in
/// the 13.0.x SDKs we depend on) can fetch them as a regular vector
/// source. Verified workaround used by other Flutter map projects with
/// the same constraint.
///
/// One `LocalTileServer` per process. The active MBTiles is opened
/// read-only via `sqflite_sqlcipher` (which acts like plain `sqflite`
/// when no password is passed). MBTiles stores tiles in TMS y-axis
/// orientation; this server converts to XYZ in the URL handler so
/// MapLibre's default scheme works.
///
/// Endpoints (all under `http://127.0.0.1:<port>/`):
///   - `/tilejson.json` — TileJSON with `vector_layers` from the
///     MBTiles `metadata.json` field, so the renderer can look up
///     source layers by name.
///   - `/{z}/{x}/{y}.pbf` — gzipped MVT blob from the `tiles` table.
class LocalTileServer {
  LocalTileServer._();
  static final LocalTileServer instance = LocalTileServer._();

  HttpServer? _server;
  Database? _db;
  Map<String, dynamic> _metadata = const {};
  String? _activePath;
  int _tileRequestCount = 0;
  String _lastTileStatus = '—';
  final _TileCache _tileCache = _TileCache(maxBytes: 50 * 1024 * 1024);

  /// Returns the bound port, or `null` if the server isn't running.
  int? get port => _server?.port;

  /// Returns the path of the MBTiles currently being served.
  String? get activePath => _activePath;

  /// Number of /{z}/{x}/{y}.pbf requests received since `start`.
  int get tileRequestCount => _tileRequestCount;

  /// Last tile-request status, e.g. "z=13 x=4011 y=2702 → 200 (78B)" or
  /// "404" or "503: db closed".
  String get lastTileStatus => _lastTileStatus;

  /// Starts (or restarts) the server pointing at [mbtilesPath]. Idempotent
  /// when called with the same path. Returns the bound port.
  Future<int> start(String mbtilesPath) async {
    if (_server != null && _activePath == mbtilesPath) {
      return _server!.port;
    }
    await stop();
    _db = await openDatabase(
      mbtilesPath,
      readOnly: true,
      // Per-call native handle so close()-on-stop doesn't bleed into
      // any other plugin-tracked DB. Different path from the encrypted
      // Trail DB so this is mostly belt-and-braces, but the cost is
      // zero and the convention is set in `database.dart`.
      singleInstance: false,
    );
    _metadata = await _readMetadata(_db!);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _activePath = mbtilesPath;
    _tileRequestCount = 0;
    _lastTileStatus = '—';
    _server!.listen(_handle, onError: (Object _) {});
    return _server!.port;
  }

  /// Stops the server and closes the underlying DB. Idempotent.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {/* server already closing */}
    }
    final d = _db;
    _db = null;
    if (d != null) {
      try {
        await d.close();
      } catch (_) {/* already closed */}
    }
    _activePath = null;
    _metadata = const {};
    _tileCache.clear();
  }

  Future<Map<String, dynamic>> _readMetadata(Database db) async {
    final rows = await db.query('metadata', columns: ['name', 'value']);
    final m = <String, dynamic>{};
    for (final r in rows) {
      final name = r['name'] as String?;
      if (name == null) continue;
      m[name] = r['value'];
    }
    return m;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    try {
      if (path == '/tilejson.json') {
        await _serveTileJson(req);
        return;
      }
      final tileMatch = _tilePathRegex.firstMatch(path);
      if (tileMatch != null) {
        await _serveTile(
          req,
          int.parse(tileMatch.group(1)!),
          int.parse(tileMatch.group(2)!),
          int.parse(tileMatch.group(3)!),
        );
        return;
      }
      // Glyphs: /glyphs/<fontstack>/<range>.pbf — fontstack may
      // contain spaces (e.g. "Roboto Regular"), MapLibre URL-encodes
      // them as `%20`. Decode by handing the path to Uri.decodeFull.
      final glyphMatch = _glyphPathRegex.firstMatch(Uri.decodeFull(path));
      if (glyphMatch != null) {
        await _serveAsset(
          req,
          'assets/maptiles/glyphs/${glyphMatch.group(1)}/${glyphMatch.group(2)}.pbf',
          ContentType('application', 'x-protobuf'),
        );
        return;
      }
      // Sprites: /sprites/<name>(@2x)?(.json|.png)
      // Group 1 = base name (e.g. "osm-liberty"),
      // Group 2 = "@2x" or null,
      // Group 3 = ".json" or ".png" or null.
      // The asset key needs ALL THREE (the previous `.png`/`.json`
      // suffix wasn't being concatenated, which 404'd every @2x
      // request — see the +49 log).
      final spriteMatch = _spritePathRegex.firstMatch(path);
      if (spriteMatch != null) {
        final ext = spriteMatch.group(3) ?? '';
        final isJson = ext == '.json';
        final assetKey =
            'assets/maptiles/sprites/${spriteMatch.group(1)}'
            '${spriteMatch.group(2) ?? ''}$ext';
        await _serveAsset(
          req,
          assetKey,
          isJson ? ContentType.json : ContentType('image', 'png'),
        );
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {/* response already gone */}
    }
  }

  Future<void> _serveAsset(
    HttpRequest req,
    String assetKey,
    ContentType contentType,
  ) async {
    final ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    req.response.headers.contentType = contentType;
    req.response.headers.set('Cache-Control', 'public, max-age=31536000');
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _serveTileJson(HttpRequest req) async {
    final m = _metadata;
    final p = _server!.port;
    final tilejson = <String, dynamic>{
      'tilejson': '2.2.0',
      'name': m['name']?.toString() ?? 'trail',
      'tiles': ['http://127.0.0.1:$p/{z}/{x}/{y}.pbf'],
      'minzoom': int.tryParse(m['minzoom']?.toString() ?? '') ?? 0,
      'maxzoom': int.tryParse(m['maxzoom']?.toString() ?? '') ?? 14,
    };
    final boundsRaw = m['bounds']?.toString();
    if (boundsRaw != null) {
      final parts = boundsRaw
          .split(',')
          .map((s) => double.tryParse(s.trim()))
          .whereType<double>()
          .toList(growable: false);
      if (parts.length == 4) tilejson['bounds'] = parts;
    }
    final centerRaw = m['center']?.toString();
    if (centerRaw != null) {
      final parts = centerRaw
          .split(',')
          .map((s) => double.tryParse(s.trim()))
          .whereType<double>()
          .toList(growable: false);
      if (parts.length == 3) tilejson['center'] = parts;
    }
    // The MBTiles `json` metadata blob holds vector_layers (and sometimes
    // tilestats). Inline it so MapLibre can map style layers to source
    // layer ids.
    final jsonBlob = m['json']?.toString();
    if (jsonBlob != null && jsonBlob.isNotEmpty) {
      try {
        final extra = jsonDecode(jsonBlob);
        if (extra is Map<String, dynamic>) {
          tilejson.addAll(extra);
        }
      } catch (_) {/* malformed metadata json — skip */}
    }
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.write(jsonEncode(tilejson));
    await req.response.close();
  }

  Future<void> _serveTile(HttpRequest req, int z, int x, int y) async {
    _tileRequestCount++;
    final cacheKey = '$z/$x/$y';
    // Hot-path cache: panning back over an already-fetched viewport
    // is the common case; reading from the SQLite + gunzip path
    // every time is wasted work. ~50 MB LRU cap holds 1000+ typical
    // vector tiles; eviction is invisible to the user since misses
    // just fall through to the original SQL query.
    final cached = _tileCache.get(cacheKey);
    if (cached != null) {
      _writeTileResponse(req, cached);
      _lastTileStatus = 'z=$z x=$x y=$y → 200 cached (${cached.length}B)';
      return;
    }
    final db = _db;
    if (db == null) {
      _lastTileStatus = 'z=$z x=$x y=$y → 503 (db closed)';
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await req.response.close();
      return;
    }
    // MBTiles stores tiles with TMS y-axis (origin at south); MapLibre
    // requests with XYZ (origin at north). Flip y here so we can keep
    // the simpler XYZ scheme on the wire.
    final tmsY = (1 << z) - 1 - y;
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        'tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, tmsY],
        limit: 1,
      );
    } catch (e) {
      _lastTileStatus = 'z=$z x=$x y=$y → 500 ($e)';
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
      return;
    }
    if (rows.isEmpty) {
      _lastTileStatus = 'z=$z x=$x y=$y → 404 (no tile)';
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final blob = rows.first['tile_data'];
    if (blob is! List<int>) {
      _lastTileStatus = 'z=$z x=$x y=$y → 404 (bad blob)';
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    _tileCache.put(cacheKey, blob);
    _writeTileResponse(req, blob);
    final isGz = blob.length >= 2 && blob[0] == 0x1f && blob[1] == 0x8b;
    _lastTileStatus =
        'z=$z x=$x y=$y → 200 (${blob.length}B gz=$isGz, cached)';
  }

  /// Writes the tile response with the headers maplibre-native expects
  /// for MVT vector tiles. MBTiles stores tiles gzipped; we ship the
  /// bytes verbatim with `Content-Encoding: gzip` so OkHttp on Android
  /// transparently decompresses (same delivery shape as the remote
  /// PMTiles demo that proved the pipeline in 0.8.0+35). Cache-Control
  /// is long because the URL embeds the tile-server's random port,
  /// which changes on every app launch — within a session it's
  /// effectively a fresh origin so revalidation is wasted work.
  void _writeTileResponse(HttpRequest req, List<int> blob) {
    final isGz = blob.length >= 2 && blob[0] == 0x1f && blob[1] == 0x8b;
    req.response.headers.contentType = ContentType(
      'application',
      'vnd.mapbox-vector-tile',
    );
    req.response.headers.set(
      'Cache-Control',
      'public, max-age=31536000, immutable',
    );
    if (isGz) {
      req.response.headers.set('Content-Encoding', 'gzip');
    }
    req.response.headers.contentLength = blob.length;
    req.response.add(blob);
    req.response.close();
  }

  static final RegExp _tilePathRegex =
      RegExp(r'^/(\d+)/(\d+)/(\d+)\.pbf$');
  // Fontstack may have spaces — assume the URL is already
  // percent-decoded by the caller before matching.
  static final RegExp _glyphPathRegex =
      RegExp(r'^/glyphs/([^/]+)/([^/.]+)\.pbf$');
  static final RegExp _spritePathRegex =
      RegExp(r'^/sprites/([^/.]+)(@2x)?(\.json|\.png)?$');
}

/// Per-process LRU cache for served tile blobs. Insertion order in a
/// `LinkedHashMap` IS the LRU order — `get` re-inserts to bump
/// recency, `put` evicts oldest entries until the byte budget is
/// satisfied. Reset on `LocalTileServer.stop` so a region swap never
/// serves stale tiles from a previous file.
class _TileCache {
  _TileCache({required this.maxBytes});

  final int maxBytes;
  final LinkedHashMap<String, List<int>> _entries = LinkedHashMap();
  int _bytes = 0;

  List<int>? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value; // move to MRU end
    return value;
  }

  void put(String key, List<int> value) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.length;
    _entries[key] = value;
    _bytes += value.length;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final lruKey = _entries.keys.first;
      final lru = _entries.remove(lruKey)!;
      _bytes -= lru.length;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
