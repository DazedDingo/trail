import 'dart:math' as math;

/// Pure planning rules for the "auto-fetch map detail" feature
/// (Phase C, `docs/TIMELINE_IMPORT.md` §3).
///
/// This file is a Dart port of `tools/coverage/coverage_lib.py`'s
/// clustering pipeline — greedy centroid clustering → pad each cluster
/// bbox → merge overlaps → drop what an installed archive already
/// covers. Keeping it dependency-free (no prefs, no `dart:io`, no
/// Flutter) means every rule is unit-testable without a server, a disk
/// or a plugin, exactly like `SchedulerPolicy`.
///
/// The VPS tool and the app MUST agree on the slug/filename format:
/// a coverage pack named `coverage-<slug>-z7-14-<date>.pmtiles` is
/// tagged [TileRole.coverage] by `inferRoleFromFileName` purely because
/// the name contains "coverage", and the slug is how a human matches a
/// file on disk back to a place.

const double earthRadiusKm = 6371.0088;

/// Degrees of latitude per kilometre, the same constant the Python tool
/// uses (`KM_PER_DEG_LAT`). Good to ~0.1 % for our purposes.
const double kmPerDegLat = 111.32;

/// A single lat/lon the planner should make sure has detailed tiles.
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  @override
  String toString() => 'GeoPoint($lat, $lon)';
}

/// A WGS84 bounding box in `pmtiles --bbox` order: west, south, east,
/// north (i.e. minLon, minLat, maxLon, maxLat).
class CoverageBox {
  const CoverageBox({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  /// Builds a box from `[west, south, east, north]` — the shape
  /// `ServedArchiveSummary.bounds` and the archive metadata use.
  /// Returns `null` for a missing or malformed list rather than
  /// throwing: an archive that doesn't declare bounds must not blow up
  /// the planner.
  static CoverageBox? fromBounds(List<double>? bounds) {
    if (bounds == null || bounds.length != 4) return null;
    for (final v in bounds) {
      if (v.isNaN || v.isInfinite) return null;
    }
    return CoverageBox(
      west: math.min(bounds[0], bounds[2]),
      south: math.min(bounds[1], bounds[3]),
      east: math.max(bounds[0], bounds[2]),
      north: math.max(bounds[1], bounds[3]),
    );
  }

  final double west;
  final double south;
  final double east;
  final double north;

  List<double> toBounds() => [west, south, east, north];

  bool contains(double lat, double lon) =>
      lon >= west && lon <= east && lat >= south && lat <= north;

  /// Degrees². Only ever compared against other boxes (biggest-first
  /// ordering in a plan), never converted to km².
  double get area => (east - west).abs() * (north - south).abs();

  double get centerLat => (south + north) / 2;
  double get centerLon => (west + east) / 2;

  /// `lat+51.38_lon-002.36` — the bbox centre, matching
  /// `coverage_lib.slug_for_bbox` byte for byte so a file built by the
  /// VPS tool and one fetched in-app for the same place collide on
  /// name instead of piling up two copies.
  String get slug => 'lat${_fmtDeg(centerLat, 2)}_lon${_fmtDeg(centerLon, 3)}';

  /// `W,S,E,N` for the server's `?bbox=` query parameter.
  String get bboxParam => [west, south, east, north].map(_fmtNum).join(',');

  bool overlaps(CoverageBox other) =>
      west <= other.east &&
      other.west <= east &&
      south <= other.north &&
      other.south <= north;

  CoverageBox union(CoverageBox other) => CoverageBox(
        west: math.min(west, other.west),
        south: math.min(south, other.south),
        east: math.max(east, other.east),
        north: math.max(north, other.north),
      );

  @override
  String toString() => 'CoverageBox($bboxParam)';

  @override
  bool operator ==(Object other) =>
      other is CoverageBox &&
      other.west == west &&
      other.south == south &&
      other.east == east &&
      other.north == north;

  @override
  int get hashCode => Object.hash(west, south, east, north);
}

/// What one installed archive covers — the planner's view of
/// `ServedArchiveSummary`. Kept as its own tiny type so the planner
/// stays free of `dart:io` (and so the worker isolate can rebuild it
/// from prefs JSON without opening a single archive).
class ArchiveExtent {
  const ArchiveExtent({
    required this.path,
    required this.minZoom,
    required this.maxZoom,
    this.bounds,
  });

  final String path;
  final int minZoom;
  final int maxZoom;

  /// `null` when the archive declares no bounds. Treated as "covers
  /// nothing" — see [isCoveredInDetail].
  final CoverageBox? bounds;
}

/// Great-circle distance in km.
double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dPhi = _rad(lat2 - lat1);
  final dLambda = _rad(lon2 - lon1);
  final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dLambda / 2) * math.sin(dLambda / 2);
  return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Pads [box] by [padKm] on every side, converting km→deg at [atLat]
/// (defaults to the box's own mid-latitude, like the Python tool).
/// Near the poles `cos(lat)` collapses, so the longitude pad is clamped
/// to a half-world rather than exploding to infinity.
CoverageBox padBoxKm(CoverageBox box, double padKm, {double? atLat}) {
  final lat = atLat ?? box.centerLat;
  final dLat = padKm / kmPerDegLat;
  final cosLat = math.cos(_rad(lat));
  final dLon = cosLat > 1e-9 ? padKm / (kmPerDegLat * cosLat) : 180.0;
  return CoverageBox(
    west: box.west - dLon,
    south: box.south - dLat,
    east: box.east + dLon,
    north: box.north + dLat,
  );
}

/// The full pipeline: greedy centroid clustering at [clusterKm] → pad
/// each cluster's raw bbox by [padKm] → merge overlapping boxes →
/// drop any box all of whose points already sit inside a [covered] box.
///
/// Order-dependent by design (a point joins the FIRST cluster whose
/// running centroid is within [clusterKm]), matching
/// `coverage_lib.cluster_fixes`. The result is sorted SMALLEST box
/// first: the auto path's byte budget then buys the largest number of
/// places before the cap bites, and the manual path shows the same set
/// either way.
List<CoverageBox> planCoverage(
  List<GeoPoint> points, {
  double clusterKm = 15,
  double padKm = 3,
  List<CoverageBox> covered = const [],
}) {
  if (points.isEmpty) return const [];

  // 1. Greedy centroid clustering.
  final clusters = <_Cluster>[];
  for (final p in points) {
    if (p.lat.isNaN || p.lon.isNaN) continue;
    if (p.lat < -90 || p.lat > 90 || p.lon < -180 || p.lon > 180) continue;
    var placed = false;
    for (final c in clusters) {
      if (haversineKm(p.lat, p.lon, c.centroidLat, c.centroidLon) <= clusterKm) {
        c.add(p);
        placed = true;
        break;
      }
    }
    if (!placed) clusters.add(_Cluster(p));
  }
  if (clusters.isEmpty) return const [];

  // 2. Pad each cluster's raw bbox.
  var items = clusters
      .map((c) => _Boxed(c.points, padBoxKm(c.rawBox, padKm)))
      .toList();

  // 3. Merge overlapping boxes, repeatedly, until nothing overlaps.
  //    Merging unions both the point lists and the boxes (never a
  //    re-pad from the combined points — that would grow without
  //    bound across iterations).
  var changed = true;
  while (changed) {
    changed = false;
    outer:
    for (var i = 0; i < items.length; i++) {
      for (var j = i + 1; j < items.length; j++) {
        if (items[i].box.overlaps(items[j].box)) {
          final merged = _Boxed(
            [...items[i].points, ...items[j].points],
            items[i].box.union(items[j].box),
          );
          items = [
            for (var k = 0; k < items.length; k++)
              if (k != i && k != j) items[k],
            merged,
          ];
          changed = true;
          break outer;
        }
      }
    }
  }

  // 4. Drop boxes whose every point is already inside a covered box.
  final kept = <_Boxed>[];
  for (final item in items) {
    final allCovered = item.points.every(
      (p) => covered.any((c) => c.contains(p.lat, p.lon)),
    );
    if (!allCovered) kept.add(item);
  }

  kept.sort((a, b) => a.box.area.compareTo(b.box.area));
  return kept.map((e) => e.box).toList(growable: false);
}

/// Zoom at or above which an archive counts as "detailed". z12 is the
/// point where streets and building footprints appear in both bundled
/// schemas; a z0–6 world overview is deliberately below it.
const int defaultMinDetailZoom = 12;

/// True when some [archives] entry already renders `(lat, lon)` at
/// street detail — i.e. reaches [minDetailZoom] AND declares bounds
/// containing the point.
///
/// An archive with `bounds == null` counts as covering NOTHING. That is
/// the safe direction: the failure mode is re-fetching ~2 MB for a town
/// we may already have, versus a permanently blank map at high zoom.
bool isCoveredInDetail(
  double lat,
  double lon,
  Iterable<ArchiveExtent> archives, {
  int minDetailZoom = defaultMinDetailZoom,
}) {
  for (final a in archives) {
    if (a.maxZoom < minDetailZoom) continue;
    final b = a.bounds;
    if (b == null) continue;
    if (b.contains(lat, lon)) return true;
  }
  return false;
}

/// `coverage-<slug>-z<min>-<max>-<date>.pmtiles`, matching
/// `coverage_lib.coverage_filename`. The "coverage" prefix is load-
/// bearing: `inferRoleFromFileName` reads the role straight off it.
String coverageFileName(
  CoverageBox box, {
  int minzoom = 7,
  int maxzoom = 14,
  required String date,
}) =>
    'coverage-${box.slug}-z$minzoom-$maxzoom-$date.pmtiles';

/// Whether the app-open / resume path may spend network on map detail
/// right now. Pure truth table, same shape as
/// `SchedulerPolicy.shouldAutoFetchPhotos`:
///
///   * feature off → never;
///   * `wifi` / `ethernet` → always (unmetered);
///   * `mobile` → only when the user has cleared Wi-Fi-only;
///   * `none` / `unknown` / `null` → never (we don't know it's safe).
bool shouldAutoFetchNow({
  required bool enabled,
  required bool wifiOnly,
  required String? networkState,
}) {
  if (!enabled) return false;
  switch (networkState) {
    case 'wifi':
    case 'ethernet':
      return true;
    case 'mobile':
      return !wifiOnly;
    default:
      return false;
  }
}

// --- internals --------------------------------------------------------

double _rad(double deg) => deg * math.pi / 180.0;

class _Cluster {
  _Cluster(GeoPoint first) : points = [first];

  final List<GeoPoint> points;

  double get centroidLat =>
      points.fold<double>(0, (a, p) => a + p.lat) / points.length;

  double get centroidLon =>
      points.fold<double>(0, (a, p) => a + p.lon) / points.length;

  CoverageBox get rawBox {
    var w = points.first.lon;
    var e = points.first.lon;
    var s = points.first.lat;
    var n = points.first.lat;
    for (final p in points) {
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
    }
    return CoverageBox(west: w, south: s, east: e, north: n);
  }

  void add(GeoPoint p) => points.add(p);
}

class _Boxed {
  _Boxed(this.points, this.box);
  final List<GeoPoint> points;
  final CoverageBox box;
}

/// `+51.38` / `-002.36` — sign, then zero-padded `int_digits.2f`.
String _fmtDeg(double value, int intDigits) {
  final sign = value >= 0 ? '+' : '-';
  final body = value.abs().toStringAsFixed(2);
  final dot = body.indexOf('.');
  final whole = body.substring(0, dot).padLeft(intDigits, '0');
  return '$sign$whole${body.substring(dot)}';
}

/// 6 dp (~11 cm) with trailing zeros trimmed — padded/merged boxes are
/// computed floats, and a tidy `bbox=` parameter is easier to eyeball
/// in a log than `-2.3999999999999999`.
String _fmtNum(double x) {
  var s = double.parse(x.toStringAsFixed(6)).toString();
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  if (s == '-0') s = '0';
  return s;
}
