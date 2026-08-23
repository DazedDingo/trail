import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secure_storage.dart';
import 'coverage_planner.dart';

/// Cross-isolate storage for the map-detail (coverage) feature.
///
/// Everything here is plain [SharedPreferences] for the same reason
/// `WorkerRunLog` is (CLAUDE.md gotcha 11): the WorkManager dispatcher
/// runs in its own Dart VM with no access to UI providers or the
/// encrypted DB, but it can read and write prefs, and prefs take an
/// in-process lock per access so concurrent writes from both isolates
/// are safe. Nothing is cached on either side.
///
///   * [extentsKey] — what the installed archives cover. Written by the
///     UI isolate (after probing), read by the worker so
///     [CoverageService.noteFixInWorker] can answer "is this place
///     already detailed?" without opening a single archive.
///   * [pendingKey] — places seen by the worker that have no detail
///     yet, waiting for the app to be opened on a suitable network.
///   * [settingsKey] — the two user toggles.
///   * [lastFetchKey] / [noticeKey] — what the Settings tile shows.
///   * [lastRefreshKey] — when the stale-pack refresh pass last ran, so
///     it happens weekly rather than on every resume.
///   * [serverUrlKey] — the user's own extract server. Not a secret.
///
/// The bearer token is the one value that does NOT live here: it goes
/// into Keystore-backed [secureStorage] next to the GitHub PAT. That
/// also means the worker isolate can't read it — deliberate, since the
/// worker never touches the network for this feature.
///
/// Every read tolerates malformed JSON by returning the empty/default
/// value rather than throwing; garbage in prefs must not brick a
/// settings screen or a background tick.
class CoveragePrefs {
  static const extentsKey = 'trail_coverage_extents_v1';
  static const pendingKey = 'trail_coverage_pending_v1';
  static const settingsKey = 'trail_coverage_settings_v1';
  static const lastFetchKey = 'trail_coverage_last_fetch_v1';
  static const lastRefreshKey = 'trail_coverage_last_refresh_v1';
  static const serverUrlKey = 'trail_coverage_server_url_v1';
  static const noticeKey = 'trail_coverage_notice_v1';
  static const tokenKey = 'trail_coverage_token_v1';

  /// A new pending point within this distance of one already queued is
  /// dropped — a stationary phone would otherwise queue one entry per
  /// tick, and the planner's own clustering (15 km) would collapse them
  /// anyway. 5 km is well inside a single town extract.
  static const pendingDedupeKm = 5.0;

  /// Hard cap on the queue. Oldest entries are evicted first; 200 pins
  /// is far more than the 20 MB auto budget can ever fetch in one go,
  /// so the cap only ever trims a queue the user has been ignoring.
  static const pendingMax = 200;

  // --- extents ---------------------------------------------------------

  /// What the installed archives cover, as last written by the UI
  /// isolate. `[]` when never written (fresh install) or unparseable.
  static Future<List<ArchiveExtent>> readExtents() async {
    final prefs = await SharedPreferences.getInstance();
    return decodeExtents(prefs.getString(extentsKey));
  }

  static Future<void> writeExtents(List<ArchiveExtent> extents) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(extentsKey, encodeExtents(extents));
  }

  /// Pure encoder, exposed for tests.
  static String encodeExtents(List<ArchiveExtent> extents) => jsonEncode([
        for (final e in extents)
          {
            'path': e.path,
            'minZoom': e.minZoom,
            'maxZoom': e.maxZoom,
            'bounds': e.bounds?.toBounds(),
          }
      ]);

  /// Pure decoder, exposed for tests. Skips individual malformed
  /// entries instead of dropping the whole list.
  static List<ArchiveExtent> decodeExtents(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <ArchiveExtent>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final path = e['path'];
        final minZoom = e['minZoom'];
        final maxZoom = e['maxZoom'];
        if (path is! String || minZoom is! int || maxZoom is! int) continue;
        final rawBounds = e['bounds'];
        List<double>? bounds;
        if (rawBounds is List && rawBounds.length == 4) {
          bounds = [
            for (final v in rawBounds) (v is num) ? v.toDouble() : double.nan
          ];
          if (bounds.any((v) => v.isNaN)) bounds = null;
        }
        out.add(ArchiveExtent(
          path: path,
          minZoom: minZoom,
          maxZoom: maxZoom,
          bounds: CoverageBox.fromBounds(bounds),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // --- pending queue ---------------------------------------------------

  /// Queues `(lat, lon)` for the next app open. No-op when a queued
  /// point is already within [pendingDedupeKm]. Evicts oldest entries
  /// past [pendingMax].
  static Future<void> addPending(double lat, double lon, {DateTime? now}) async {
    if (lat.isNaN || lon.isNaN) return;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = decodePending(prefs.getString(pendingKey));
    for (final p in existing) {
      if (haversineKm(lat, lon, p.lat, p.lon) <= pendingDedupeKm) return;
    }
    final next = <PendingPoint>[
      ...existing,
      PendingPoint(
        lat: lat,
        lon: lon,
        tsMs: (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
      ),
    ];
    final trimmed = next.length <= pendingMax
        ? next
        : next.sublist(next.length - pendingMax);
    await prefs.setString(pendingKey, encodePending(trimmed));
  }

  static Future<List<PendingPoint>> readPending() async {
    final prefs = await SharedPreferences.getInstance();
    return decodePending(prefs.getString(pendingKey));
  }

  static Future<int> pendingCount() async => (await readPending()).length;

  /// Reads and clears the queue in one step. The caller owns the points
  /// from here — if the fetch is refused (cap, offline, error) it must
  /// put them back with [addPendingAll].
  static Future<List<PendingPoint>> takePending() async {
    final prefs = await SharedPreferences.getInstance();
    final points = decodePending(prefs.getString(pendingKey));
    await prefs.remove(pendingKey);
    return points;
  }

  /// Re-queues points a run declined to fetch, preserving their
  /// original timestamps and re-applying the dedupe + cap rules.
  static Future<void> addPendingAll(List<PendingPoint> points) async {
    for (final p in points) {
      await addPending(
        p.lat,
        p.lon,
        now: DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true),
      );
    }
  }

  static Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingKey);
  }

  static String encodePending(List<PendingPoint> points) => jsonEncode([
        for (final p in points) {'lat': p.lat, 'lon': p.lon, 'tsMs': p.tsMs}
      ]);

  static List<PendingPoint> decodePending(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <PendingPoint>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final lat = e['lat'];
        final lon = e['lon'];
        final ts = e['tsMs'];
        if (lat is! num || lon is! num) continue;
        out.add(PendingPoint(
          lat: lat.toDouble(),
          lon: lon.toDouble(),
          tsMs: ts is num ? ts.toInt() : 0,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // --- settings --------------------------------------------------------

  /// Defaults: enabled ON, Wi-Fi only ON. The feature still can't do
  /// anything until the user supplies a server URL + token, so "on by
  /// default" only means "start queueing places once you configure it".
  static Future<CoverageSettings> readSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return decodeSettings(prefs.getString(settingsKey));
  }

  static Future<void> writeSettings(CoverageSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      settingsKey,
      jsonEncode({'enabled': settings.enabled, 'wifiOnly': settings.wifiOnly}),
    );
  }

  static CoverageSettings decodeSettings(String? raw) {
    if (raw == null || raw.isEmpty) return const CoverageSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const CoverageSettings();
      final enabled = decoded['enabled'];
      final wifiOnly = decoded['wifiOnly'];
      return CoverageSettings(
        enabled: enabled is bool ? enabled : true,
        wifiOnly: wifiOnly is bool ? wifiOnly : true,
      );
    } catch (_) {
      return const CoverageSettings();
    }
  }

  // --- last fetch / notice ---------------------------------------------

  static Future<DateTime?> readLastFetch() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(lastFetchKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  static Future<void> setLastFetch(DateTime when) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(lastFetchKey, when.toUtc().millisecondsSinceEpoch);
  }

  /// When the weekly stale-coverage-pack refresh pass last spent
  /// network. `null` until the first pass runs.
  static Future<DateTime?> readLastRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(lastRefreshKey);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  static Future<void> setLastRefresh(DateTime when) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(lastRefreshKey, when.toUtc().millisecondsSinceEpoch);
  }

  /// One-line status the Settings tile shows — e.g. why an auto run
  /// left points pending. `null` clears it.
  static Future<String?> readNotice() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(noticeKey);
    return (s == null || s.isEmpty) ? null : s;
  }

  static Future<void> writeNotice(String? notice) async {
    final prefs = await SharedPreferences.getInstance();
    if (notice == null || notice.isEmpty) {
      await prefs.remove(noticeKey);
    } else {
      await prefs.setString(noticeKey, notice);
    }
  }

  // --- server URL + token ----------------------------------------------

  static Future<String?> readServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(serverUrlKey);
    return (s == null || s.isEmpty) ? null : s;
  }

  static Future<void> writeServerUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(serverUrlKey);
    } else {
      await prefs.setString(serverUrlKey, _stripTrailingSlash(trimmed));
    }
  }

  /// Token lives in Keystore-backed secure storage, exactly like the
  /// GitHub PAT (`GithubPatService`). Reads return `null` — never
  /// throw — when the platform channel is unavailable (unit tests, or
  /// the worker isolate, which has no business reading it anyway).
  static Future<String?> readToken() async {
    try {
      final t = await secureStorage.read(key: tokenKey);
      return (t == null || t.isEmpty) ? null : t;
    } catch (e) {
      debugPrint('[coverage] token read failed: $e');
      return null;
    }
  }

  static Future<void> writeToken(String token) =>
      secureStorage.write(key: tokenKey, value: token.trim());

  static Future<void> clearToken() => secureStorage.delete(key: tokenKey);

  /// Attempts to persist [token], returning `null` on success or a
  /// concise description of the failure otherwise.
  ///
  /// [writeToken] can throw — the secure store's Keystore alias can fail
  /// to generate (a real-device incident: 0.17.10) — and the Settings
  /// tile used to leave that Future unhandled, so the subtitle silently
  /// stayed "Not set" with no indication anything went wrong. Exposed as
  /// a pure function so that failure path is unit-testable without
  /// mounting the Settings screen.
  static Future<String?> trySaveToken(String token) async {
    try {
      await writeToken(token);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// As [trySaveToken], for [clearToken].
  static Future<String?> tryClearToken() async {
    try {
      await clearToken();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// As [trySaveToken], for [writeServerUrl]. The URL itself lives in
  /// plain prefs (not the secure store), but the write can still fail
  /// (disk full, a broken prefs backend) and the Settings tile should
  /// report that rather than silently keep the old value.
  static Future<String?> trySaveServerUrl(String? url) async {
    try {
      await writeServerUrl(url);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// "abcd…wxyz" so the tile can show that a token is configured
  /// without revealing it. Same rule as `GithubPatService.mask`.
  static String maskToken(String token) {
    if (token.length < 8) return '****';
    return '${token.substring(0, 4)}…${token.substring(token.length - 4)}';
  }

  static String _stripTrailingSlash(String url) {
    var s = url;
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// A place the worker saw that has no detailed tiles yet.
class PendingPoint {
  const PendingPoint({
    required this.lat,
    required this.lon,
    required this.tsMs,
  });

  final double lat;
  final double lon;
  final int tsMs;

  GeoPoint toGeoPoint() => GeoPoint(lat, lon);

  @override
  String toString() => 'PendingPoint($lat, $lon, $tsMs)';
}

/// The two user toggles for auto-fetch.
class CoverageSettings {
  const CoverageSettings({this.enabled = true, this.wifiOnly = true});

  final bool enabled;
  final bool wifiOnly;

  CoverageSettings copyWith({bool? enabled, bool? wifiOnly}) =>
      CoverageSettings(
        enabled: enabled ?? this.enabled,
        wifiOnly: wifiOnly ?? this.wifiOnly,
      );
}
