import 'dart:convert';

import 'package:http/http.dart' as http;

import '../mbtiles_service.dart';
import '../tile_downloader.dart';
import 'coverage_planner.dart';

/// Progress callback for a single archive download: bytes received and
/// the `Content-Length` when the server declared one.
typedef DownloadProgress = void Function(int received, int? total);

/// What [CoverageService] needs from a tile-extract server. An
/// interface rather than the concrete client so the service's tests can
/// hand it a fake without a socket — same reason `GeoClient` exists in
/// front of Geolocator.
abstract class CoverageTileServer {
  Future<({bool ok, String planet, String planetDate})> health();

  Future<({int tiles, int bytes, String planetDate})> dryRun(
    CoverageBox box, {
    int minzoom,
    int maxzoom,
  });

  Future<TilesRegion> downloadExtract(
    CoverageBox box, {
    int minzoom,
    int maxzoom,
    String? planetDate,
    DownloadProgress? onProgress,
    TileDownloadCancelToken? cancelToken,
  });

  void close();
}

/// Talks to the user's own `pmtiles extract` server (Phase C,
/// `docs/TIMELINE_IMPORT.md` §3).
///
/// Contract:
///   * `GET /v1/health` → `{ok, planet, planetDate}` (no auth);
///   * `GET /v1/extract?bbox=W,S,E,N&minzoom=&maxzoom=&dry_run=1` →
///     `{tiles, bytes, planetDate}`;
///   * the same URL without `dry_run` → the archive bytes, with
///     `Content-Length`, `X-Planet-Date` and a `Content-Disposition`
///     file name;
///   * `Authorization: Bearer <token>` on everything but health;
///   * errors are `{"error": …}` with 401/400/413/429/503.
///
/// The two JSON calls go through `package:http` (trivially faked with
/// `MockClient`); the body download goes through [TileDownloader], which
/// already owns the streaming/resume/cancel/atomic-rename behaviour and
/// writes straight into `<docs>/tiles/` where `TilesService.listInstalled`
/// will find it. A file named `coverage-…` is auto-tagged
/// [TileRole.coverage] by `inferRoleFromFileName`, so no extra install
/// step is needed.
class TileServerClient implements CoverageTileServer {
  TileServerClient({
    required String baseUrl,
    required this.token,
    http.Client? client,
  })  : baseUrl = _normalise(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Default zoom window for a coverage extract. z7 is the commander's
  /// locked minzoom (the world overview stops at z6); z14 the locked
  /// cluster detail max.
  static const defaultMinZoom = 7;
  static const defaultMaxZoom = 14;

  /// Anything slower than this and the user is better off on Wi-Fi.
  static const requestTimeout = Duration(seconds: 30);

  final String baseUrl;
  final String? token;
  final http.Client _client;
  final bool _ownsClient;

  Map<String, String> get authHeaders =>
      token == null || token!.isEmpty ? const {} : {'Authorization': 'Bearer $token'};

  Uri healthUri() => Uri.parse('$baseUrl/v1/health');

  /// The extract URL for [box]. `dryRun` adds `dry_run=1`.
  Uri extractUri(
    CoverageBox box, {
    int minzoom = defaultMinZoom,
    int maxzoom = defaultMaxZoom,
    bool dryRun = false,
  }) {
    return Uri.parse('$baseUrl/v1/extract').replace(queryParameters: {
      'bbox': box.bboxParam,
      'minzoom': '$minzoom',
      'maxzoom': '$maxzoom',
      if (dryRun) 'dry_run': '1',
    });
  }

  @override
  Future<({bool ok, String planet, String planetDate})> health() async {
    final json = await _getJson(healthUri(), withAuth: false);
    return (
      ok: json['ok'] == true,
      planet: '${json['planet'] ?? ''}',
      planetDate: '${json['planetDate'] ?? ''}',
    );
  }

  @override
  Future<({int tiles, int bytes, String planetDate})> dryRun(
    CoverageBox box, {
    int minzoom = defaultMinZoom,
    int maxzoom = defaultMaxZoom,
  }) async {
    final json = await _getJson(
      extractUri(box, minzoom: minzoom, maxzoom: maxzoom, dryRun: true),
    );
    final tiles = json['tiles'];
    final bytes = json['bytes'];
    return (
      tiles: tiles is num ? tiles.toInt() : 0,
      bytes: bytes is num ? bytes.toInt() : 0,
      planetDate: '${json['planetDate'] ?? ''}',
    );
  }

  @override
  Future<TilesRegion> downloadExtract(
    CoverageBox box, {
    int minzoom = defaultMinZoom,
    int maxzoom = defaultMaxZoom,
    String? planetDate,
    DownloadProgress? onProgress,
    TileDownloadCancelToken? cancelToken,
  }) {
    // A known planet date gives a deterministic name, so re-fetching the
    // same place on the same planet build overwrites rather than piling
    // up duplicates. Without one we let `Content-Disposition` name it.
    final name = (planetDate == null || planetDate.isEmpty)
        ? null
        : coverageFileName(box,
            minzoom: minzoom, maxzoom: maxzoom, date: planetDate);
    return TileDownloader.download(
      url: extractUri(box, minzoom: minzoom, maxzoom: maxzoom),
      filename: name,
      headers: authHeaders.isEmpty ? null : authHeaders,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _getJson(Uri uri, {bool withAuth = true}) async {
    http.Response resp;
    try {
      resp = await _client
          .get(uri, headers: withAuth ? authHeaders : null)
          .timeout(requestTimeout);
    } catch (e) {
      // Socket failures, DNS, TLS, timeout — all "we couldn't reach it".
      throw TileServerException(0, '$e');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw TileServerException(resp.statusCode, _errorMessage(resp));
    }
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        throw TileServerException(resp.statusCode, 'Unexpected response body');
      }
      return decoded.cast<String, dynamic>();
    } on TileServerException {
      rethrow;
    } catch (_) {
      throw TileServerException(resp.statusCode, 'Malformed JSON response');
    }
  }

  /// Servers answer errors as `{"error": …}`; fall back to the status
  /// line when the body isn't that shape (a proxy's HTML 502 page).
  static String _errorMessage(http.Response resp) {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['error'] != null) {
        return '${decoded['error']}';
      }
    } catch (_) {/* not JSON — fall through */}
    return 'HTTP ${resp.statusCode}';
  }

  static String _normalise(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// Typed failure from the extract server. [status] is the HTTP status,
/// or 0 when the request never got a response (offline, DNS, TLS,
/// timeout) — the UI reads that as "can't reach the server" rather than
/// "the server said no".
class TileServerException implements Exception {
  const TileServerException(this.status, this.message);

  final int status;
  final String message;

  /// The token is missing or wrong.
  bool get isAuth => status == 401 || status == 403;

  /// The requested extract is bigger than the server will serve.
  bool get isTooLarge => status == 413;

  bool get isUnreachable => status == 0;

  @override
  String toString() =>
      status == 0 ? 'Server unreachable: $message' : 'HTTP $status: $message';
}
