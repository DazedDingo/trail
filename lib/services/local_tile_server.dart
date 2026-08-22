import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite_sqlcipher/sqflite.dart' show DatabaseFactory;

import 'tiles/mvt_overzoom.dart';
import 'tiles/tile_archive.dart';
import 'tiles/tile_schema.dart';

/// Byte budget for the in-process tile LRU. 16 MB (0.14.1, down from
/// 50 MB) still holds a few hundred z13–z14 vector tiles (20–100 KB
/// gzipped each) — several viewports of panning — and it sits *behind*
/// MapLibre's own native tile cache, so it only ever serves re-fetches
/// the renderer itself evicted. Misses fall through to the archive
/// read; the cache is dropped wholesale on memory pressure
/// (`memory_pressure.dart`).
const int kTileCacheMaxBytes = 16 * 1024 * 1024;

/// How many *decompressed* parent tiles the overzoom path keeps around.
/// Panning across an area the archives only cover at low zoom asks for
/// dozens of children of the same parent in a row; four entries covers
/// a viewport straddling a 2×2 parent block without holding more than a
/// few hundred KB of plain MVT.
const int kParentTileCacheEntries = 4;

/// Serves vector tiles from one or more local `.mbtiles` / `.pmtiles`
/// archives over a localhost HTTP loopback so MapLibre Native (which
/// silently fails to render tiles via `mbtiles://file://` and
/// `pmtiles://file://` on Android in the 13.0.x SDKs we depend on) can
/// fetch them as a regular vector source. Verified workaround used by
/// other Flutter map projects with the same constraint.
///
/// One `LocalTileServer` per process. [start] takes an ordered list of
/// archives — **first match wins** — so a small high-zoom city pack can
/// sit in front of a coarse country pack. Format differences (MBTiles'
/// TMS y-axis, PMTiles' Hilbert directory) are [TileArchive]'s problem;
/// the routes below are pure XYZ.
///
/// Endpoints (all under `http://127.0.0.1:<port>/`):
///   - `/tilejson.json` — TileJSON describing the *union* of the served
///     archives, with `vector_layers` merged by id so the renderer can
///     look up source layers by name.
///   - `/{z}/{x}/{y}.pbf` — the tile, from the first archive that has
///     it; failing that, re-projected from the nearest ancestor tile
///     (see [_overzoom]); failing that, 404.
///   - `/glyphs/<fontstack>/<range>.pbf`, `/sprites/<name>[@2x][.json|.png]`
///     — bundled assets, memoised after first load.
class LocalTileServer {
  LocalTileServer._();
  static final LocalTileServer instance = LocalTileServer._();

  HttpServer? _server;
  final List<TileArchive> _archives = [];
  List<String> _requestedPaths = const [];
  List<String> _servedPaths = const [];
  int _tileRequestCount = 0;
  String _lastTileStatus = '—';
  final TileCache _tileCache = TileCache(maxBytes: kTileCacheMaxBytes);

  /// Glyph/sprite bytes, memoised. `rootBundle.load` is NOT cached by
  /// `CachingAssetBundle` (only `loadString`/`loadStructuredData` are),
  /// so without this every glyph range re-read its asset off disk on
  /// every pan — ~1.4 MB of immutable bytes re-decoded for nothing
  /// (`docs/PERF_PLAN.md` §3 #10).
  final Map<String, Uint8List> _assetCache = {};

  /// Decompressed parent tiles for the overzoom path, LRU-ordered.
  final LinkedHashMap<String, Uint8List> _parentCache = LinkedHashMap();

  /// Asset reader seam; `null` means `rootBundle.load`. Tests swap in a
  /// counting stub so the memoisation can be asserted without a real
  /// asset bundle (gotcha 18 — pure seams over platform mounts). Left
  /// nullable rather than defaulted so constructing the singleton never
  /// touches `rootBundle` (and therefore never needs a binding).
  @visibleForTesting
  Future<ByteData> Function(String key)? assetLoader;

  /// Injected `.mbtiles` database factory. `null` (production) means
  /// `sqflite_sqlcipher`'s; tests set `databaseFactoryFfi` because the
  /// SQLCipher plugin has no platform channel under `flutter test`
  /// (gotcha 3).
  @visibleForTesting
  static DatabaseFactory? databaseFactoryOverride;

  /// Returns the bound port, or `null` if the server isn't running.
  int? get port => _server?.port;

  /// Paths of the archives actually open, in priority order. Excludes
  /// any path from the last [start] call that failed to open.
  List<String> get servedPaths => _servedPaths;

  /// The tile schema of the open archive at [path], or `null` when that
  /// path isn't being served.
  TileSchema? schemaFor(String path) {
    for (final archive in _archives) {
      if (archive.path == path) return archive.schema;
    }
    return null;
  }

  /// Every open archive's schema, keyed by path. Feeds
  /// [pickStyleSchema] — which style the map is built with.
  Map<String, TileSchema> get servedSchemas => {
        for (final archive in _archives) archive.path: archive.schema,
      };

  /// Lowest zoom any served archive claims, or `null` when stopped.
  int? get servedMinZoom => _archives.isEmpty
      ? null
      : _archives.map((a) => a.minZoom).reduce(math.min);

  /// Highest zoom any served archive claims, or `null` when stopped.
  /// Note this is the *stored* maximum — the server itself answers
  /// beyond it by overzooming.
  int? get servedMaxZoom => _archives.isEmpty
      ? null
      : _archives.map((a) => a.maxZoom).reduce(math.max);

  /// Union of every served archive's bounds, or `null` when none of
  /// them declares any.
  List<double>? get servedBounds {
    final known = _archives
        .map((a) => a.bounds)
        .whereType<List<double>>()
        .toList(growable: false);
    if (known.isEmpty) return null;
    return unionBounds(known);
  }

  /// The highest-priority served archive path.
  @Deprecated('Use servedPaths — the server can serve several archives')
  String? get activePath => _servedPaths.isEmpty ? null : _servedPaths.first;

  /// Number of /{z}/{x}/{y}.pbf requests received since `start`.
  int get tileRequestCount => _tileRequestCount;

  /// Last tile-request status, e.g. "z=13 x=4011 y=2702 → 200 (78B)" or
  /// "404" or "503: no archive".
  String get lastTileStatus => _lastTileStatus;

  /// Drops every cached tile blob; the server keeps running and the
  /// next request for each tile re-reads it from its archive. Called on
  /// memory pressure and on `stop`. Bundled glyph/sprite bytes are NOT
  /// dropped — they're immutable and re-requested immediately.
  void clearTileCache() {
    _tileCache.clear();
    _parentCache.clear();
  }

  /// The live cache, for tests that need to seed / inspect it.
  @visibleForTesting
  TileCache get tileCache => _tileCache;

  /// Number of memoised glyph/sprite blobs.
  @visibleForTesting
  int get assetCacheSize => _assetCache.length;

  /// Drops the memoised glyph/sprite bytes.
  @visibleForTesting
  void clearAssetCache() => _assetCache.clear();

  /// Starts (or restarts) the server over [archivePaths], **in priority
  /// order** — the first archive holding a tile wins.
  ///
  /// Idempotent for an identical list: the running port comes straight
  /// back. Any other list rebinds on a *fresh* port, which is
  /// deliberate: tiles are served `Cache-Control: immutable` and
  /// MapLibre keys its native cache on the URL, so a new port is the
  /// only cache invalidation available to us. The replacement socket is
  /// bound before the old one closes precisely so the OS can't hand
  /// back the same number.
  ///
  /// Archives that fail to open are skipped with a `debugPrint` — one
  /// corrupt sideloaded region must not blank the map. Throws
  /// [StateError] only when *none* of them opens, and [ArgumentError]
  /// on an empty list (call [stop] for "serve nothing").
  Future<int> start(List<String> archivePaths) async {
    if (archivePaths.isEmpty) {
      await stop();
      throw ArgumentError.value(
        archivePaths,
        'archivePaths',
        'at least one archive path is required (use stop() to serve nothing)',
      );
    }
    final requested = List<String>.unmodifiable(archivePaths);
    final live = _server;
    if (live != null && _sameOrder(_requestedPaths, requested)) {
      return live.port;
    }

    final socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final opened = <TileArchive>[];
    for (final path in requested) {
      try {
        opened.add(
          await TileArchive.open(path, dbFactory: databaseFactoryOverride),
        );
      } catch (e) {
        debugPrint('LocalTileServer: skipping unreadable archive $path — $e');
      }
    }
    if (opened.isEmpty) {
      await socket.close(force: true);
      await stop();
      throw StateError(
        'LocalTileServer: none of ${requested.length} archive(s) could be '
        'opened: ${requested.join(', ')}',
      );
    }

    await stop();
    _server = socket;
    _archives.addAll(opened);
    _requestedPaths = requested;
    _servedPaths =
        List<String>.unmodifiable(opened.map((a) => a.path).toList());
    _tileRequestCount = 0;
    _lastTileStatus = '—';
    socket.listen(_handle, onError: (Object _) {});
    return socket.port;
  }

  /// Cheap metadata read for the regions screen: opens [path], pulls its
  /// zoom range / bounds / format, closes it again. Throws whatever the
  /// underlying open throws (unsupported extension, corrupt file) so the
  /// caller can show a real error.
  static Future<ServedArchiveSummary> probe(String path) async {
    final archive =
        await TileArchive.open(path, dbFactory: databaseFactoryOverride);
    try {
      return ServedArchiveSummary(
        path: path,
        minZoom: archive.minZoom,
        maxZoom: archive.maxZoom,
        bounds: archive.bounds,
        format: archive.format,
        schema: archive.schema,
        sizeBytes: await File(path).length(),
      );
    } finally {
      await archive.close();
    }
  }

  /// Stops the server and closes every archive. Idempotent.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {/* server already closing */}
    }
    final archives = List<TileArchive>.of(_archives);
    _archives.clear();
    for (final a in archives) {
      await a.close();
    }
    _requestedPaths = const [];
    _servedPaths = const [];
    clearTileCache();
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
      await _closeQuietly(req.response);
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {/* headers already sent */}
      await _closeQuietly(req.response);
    }
  }

  Future<void> _serveAsset(
    HttpRequest req,
    String assetKey,
    ContentType contentType,
  ) async {
    var bytes = _assetCache[assetKey];
    if (bytes == null) {
      final ByteData data;
      try {
        data = await (assetLoader ?? rootBundle.load)(assetKey);
      } catch (_) {
        req.response.statusCode = HttpStatus.notFound;
        await _closeQuietly(req.response);
        return;
      }
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      _assetCache[assetKey] = bytes;
    }
    req.response.headers.contentType = contentType;
    req.response.headers.set('Cache-Control', 'public, max-age=31536000');
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await _closeQuietly(req.response);
  }

  Future<void> _serveTileJson(HttpRequest req) async {
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.write(jsonEncode(buildTileJson()));
    await _closeQuietly(req.response);
  }

  /// The TileJSON document for the current archive set. Exposed for
  /// tests; the HTTP handler is a one-line wrapper around it.
  @visibleForTesting
  Map<String, dynamic> buildTileJson() {
    final p = _server?.port ?? 0;
    final tilejson = <String, dynamic>{
      'tilejson': '2.2.0',
      'name': 'trail',
      'tiles': ['http://127.0.0.1:$p/{z}/{x}/{y}.pbf'],
      'minzoom': servedMinZoom ?? 0,
      'maxzoom': servedMaxZoom ?? 14,
    };
    final bounds = servedBounds;
    if (bounds != null) tilejson['bounds'] = bounds;
    // Merge vector_layers by id, first archive wins — same precedence as
    // the tile lookup, so the layer description matches whichever pack
    // actually answers for a given source layer.
    final seen = <String>{};
    final merged = <dynamic>[];
    for (final archive in _archives) {
      for (final layer in archive.vectorLayers ?? const <dynamic>[]) {
        final id = layer is Map ? layer['id']?.toString() : null;
        if (id == null) {
          merged.add(layer);
          continue;
        }
        if (seen.add(id)) merged.add(layer);
      }
    }
    if (merged.isNotEmpty) tilejson['vector_layers'] = merged;
    return tilejson;
  }

  Future<void> _serveTile(HttpRequest req, int z, int x, int y) async {
    _tileRequestCount++;
    final cacheKey = '$z/$x/$y';
    // Hot-path cache: panning back over an already-fetched viewport
    // is the common case; re-reading the archive (and, for overzoomed
    // tiles, re-running the reprojection) every time is wasted work.
    final cached = _tileCache.get(cacheKey);
    if (cached != null) {
      await _writeTileResponse(req, cached);
      _lastTileStatus = 'z=$z x=$x y=$y → 200 cached (${cached.length}B)';
      return;
    }
    if (_archives.isEmpty) {
      _lastTileStatus = 'z=$z x=$x y=$y → 503 (no archive)';
      req.response.statusCode = HttpStatus.serviceUnavailable;
      await _closeQuietly(req.response);
      return;
    }

    for (final archive in _archives) {
      if (!archive.mayContain(z, x, y)) continue;
      final blob = await archive.tile(z, x, y);
      if (blob == null) continue;
      _tileCache.put(cacheKey, blob);
      await _writeTileResponse(req, blob);
      final isGz = _isGzip(blob);
      _lastTileStatus =
          'z=$z x=$x y=$y → 200 (${blob.length}B gz=$isGz, cached)';
      return;
    }

    final overzoomed = await _overzoom(z, x, y);
    if (overzoomed != null) {
      _tileCache.put(cacheKey, overzoomed);
      await _writeTileResponse(req, overzoomed);
      _lastTileStatus =
          'z=$z x=$x y=$y → 200 (${overzoomed.length}B overzoomed)';
      return;
    }

    _lastTileStatus = 'z=$z x=$x y=$y → 404 (no tile)';
    req.response.statusCode = HttpStatus.notFound;
    await _closeQuietly(req.response);
  }

  /// Synthesises `(z, x, y)` by clipping + rescaling the nearest
  /// ancestor tile any archive holds, and returns it **gzipped** so the
  /// response shape matches a stored tile exactly.
  ///
  /// Walks parents nearest-first (dz = 1, 2, …) and, at each level, the
  /// archives in priority order — so the answer comes from the same
  /// pack that would have answered for a real tile. Stops once the
  /// parent zoom drops below the shallowest archive's `minZoom`; there
  /// is nothing to find below that. Returns `null` when no ancestor
  /// exists anywhere, which the caller turns into a 404.
  Future<Uint8List?> _overzoom(int z, int x, int y) async {
    if (z <= 0 || _archives.isEmpty) return null;
    final floor = _archives.map((a) => a.minZoom).reduce(math.min);
    for (var dz = 1; dz <= z; dz++) {
      final parentZ = z - dz;
      if (parentZ < floor) break;
      // `overzoomMvt` refuses more than 30 levels (the scale factor stops
      // fitting in a tile coordinate), and a 2^30 magnification is not a
      // map anyway. Bail rather than let a bogus `/99/0/0.pbf` throw.
      if (dz > 30) break;
      final parentX = x >> dz;
      final parentY = y >> dz;
      for (final archive in _archives) {
        if (!archive.mayContain(parentZ, parentX, parentY)) continue;
        final parent =
            await _parentMvt(archive, parentZ, parentX, parentY);
        if (parent == null) continue;
        // Reprojection is real CPU work (full MVT decode + geometry
        // rewrite); keep it off the UI isolate. The exact-hit path above
        // deliberately does NOT pay this hop.
        final child = await Isolate.run(
          () => overzoomMvt(
            parent,
            parentZ: parentZ,
            parentX: parentX,
            parentY: parentY,
            childZ: z,
            childX: x,
            childY: y,
          ),
        );
        return Uint8List.fromList(gzip.encode(child));
      }
    }
    return null;
  }

  /// Decompressed MVT bytes for a parent tile, memoised in a tiny LRU.
  /// Without this, panning across an area only covered at z6 gunzips the
  /// same parent once per child tile — 64× at z9.
  Future<Uint8List?> _parentMvt(
    TileArchive archive,
    int z,
    int x,
    int y,
  ) async {
    final key = '${archive.path}|$z/$x/$y';
    final hit = _parentCache.remove(key);
    if (hit != null) {
      _parentCache[key] = hit; // bump to MRU
      return hit;
    }
    final raw = await archive.tile(z, x, y);
    if (raw == null) return null;
    Uint8List plain;
    try {
      plain = _isGzip(raw) ? Uint8List.fromList(gzip.decode(raw)) : raw;
    } catch (e) {
      debugPrint('LocalTileServer: parent $z/$x/$y gunzip failed — $e');
      return null;
    }
    _parentCache[key] = plain;
    while (_parentCache.length > kParentTileCacheEntries) {
      _parentCache.remove(_parentCache.keys.first);
    }
    return plain;
  }

  /// Writes the tile response with the headers maplibre-native expects
  /// for MVT vector tiles. Archives store tiles gzipped; we ship the
  /// bytes verbatim with `Content-Encoding: gzip` so OkHttp on Android
  /// transparently decompresses (same delivery shape as the remote
  /// PMTiles demo that proved the pipeline in 0.8.0+35). Cache-Control
  /// is long because the URL embeds the tile-server's random port,
  /// which changes on every start — within a session it's effectively a
  /// fresh origin so revalidation is wasted work.
  Future<void> _writeTileResponse(HttpRequest req, List<int> blob) async {
    req.response.headers.contentType = ContentType(
      'application',
      'vnd.mapbox-vector-tile',
    );
    req.response.headers.set(
      'Cache-Control',
      'public, max-age=31536000, immutable',
    );
    if (_isGzip(blob)) {
      req.response.headers.set('Content-Encoding', 'gzip');
    }
    req.response.headers.contentLength = blob.length;
    req.response.add(blob);
    await _closeQuietly(req.response);
  }

  static bool _isGzip(List<int> blob) =>
      blob.length >= 2 && blob[0] == 0x1f && blob[1] == 0x8b;

  /// `HttpResponse.close()` throws if the client already hung up — a
  /// routine event when MapLibre cancels tiles for an off-screen
  /// viewport. Awaiting it (rather than firing and forgetting) keeps
  /// the handler's error handling honest; swallowing the throw keeps a
  /// cancelled request from surfacing as a server error.
  static Future<void> _closeQuietly(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {/* client gone */}
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

/// What a region file says about itself, without keeping it open.
/// Cheap enough to call for every installed region on the regions
/// screen.
class ServedArchiveSummary {
  const ServedArchiveSummary({
    required this.path,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds,
    required this.format,
    required this.schema,
    required this.sizeBytes,
  });

  final String path;
  final int minZoom;
  final int maxZoom;

  /// WGS84 `[west, south, east, north]`, or `null` if undeclared.
  final List<double>? bounds;

  /// `pbf`, `png`, … as the archive declares it; `null` if unknown.
  final String? format;

  /// Which vector-tile schema the archive holds — i.e. which bundled
  /// style can draw it. See `tiles/tile_schema.dart`.
  final TileSchema schema;

  /// Size of the archive file on disk.
  final int sizeBytes;
}

/// Per-process LRU cache for served tile blobs. Insertion order in a
/// `LinkedHashMap` IS the LRU order — `get` re-inserts to bump
/// recency, `put` evicts oldest entries until the byte budget is
/// satisfied. Reset on `LocalTileServer.stop` so a region swap never
/// serves stale tiles from a previous file, and on memory pressure.
///
/// Public (not `_TileCache`) purely so the eviction maths is unit-
/// testable; only [LocalTileServer] constructs one in production.
class TileCache {
  TileCache({required this.maxBytes});

  final int maxBytes;
  final LinkedHashMap<String, List<int>> _entries = LinkedHashMap();
  int _bytes = 0;

  /// Bytes currently held.
  int get bytes => _bytes;

  /// Entries currently held.
  int get length => _entries.length;

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
