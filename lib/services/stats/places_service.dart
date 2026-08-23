/// Places the user's Google Timeline import recorded — the read side of
/// the `gmaps:visit:<TYPE>:<placeId>` rows (CLAUDE.md gotcha 35).
///
/// `timeline_mappers.dart` writes TWO ping rows per Timeline `visit`
/// element: a `visitStart` at the segment's start time and a `visitEnd`
/// at its end time, both carrying the SAME note and the SAME coordinates
/// (the place location). Everything here rebuilds visits out of that
/// pair-of-rows shape and rolls them up per place.
///
/// Pure + top-level so it is unit-testable without a widget tree or a DB
/// (CLAUDE.md gotcha 18) — see `test/places_service_test.dart`. The one
/// I/O step, `PingDao.importedVisits()`, happens in
/// `lib/providers/places_provider.dart`.
library;

import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../date_labels.dart';

/// One row of `PingDao.importedVisits()` — a single `visitStart` or
/// `visitEnd` ping.
typedef VisitRow = ({int tsUtcMs, double lat, double lon, String note});

/// Note prefix every visit row carries (`timeline_mappers.dart`).
const String kVisitNotePrefix = 'gmaps:visit:';

/// Default spatial merge radius for [buildPlaces], in metres.
///
/// Timeline splits ONE real place into several keys two ways: a visit
/// without a `placeId` is keyed on its coordinates (4 dp ≈ 11 m, so the
/// jitter Google itself carries makes new keys), and Google re-issues a
/// different `placeId` for the same spot over the years. 120 m is wider
/// than both — and than a building footprint — while staying narrower
/// than the gap between two shops a user would want listed apart.
const double kPlaceClusterM = 120;

/// Default radius for [mergeByLabel], in km. Two rows the geocoder gave
/// the same name inside a kilometre are the same neighbourhood to the
/// user; beyond that "High Street" really is two different towns.
const double kPlaceLabelMergeKm = 1;

/// Separator inside [PlaceSummary.visitsKey]. A control character on
/// purpose: a Timeline place id is URL-safe base64 and a coordinate key
/// is digits, dots, commas and a minus, so neither can contain it.
const String kPlaceKeySep = '\u0001';

/// `3 Jan 2024` — the first/last dates on a place row. Explicit pattern
/// rather than a locale skeleton, same reasoning as `date_labels.dart`.
final DateFormat kPlaceDateFormat = DateFormat('d MMM yyyy');

/// `14:05` — the end of a visit that started on the same local day.
final DateFormat kVisitClockFormat = DateFormat('HH:mm');

/// One stay at a place. [endMs] is null when the import only carried the
/// start row (a truncated export, or an `visitEnd` that lost its
/// coordinates and so never reached the DB) — the visit still counts,
/// its duration is just unknown.
class Visit {
  final int startMs;
  final int? endMs;

  const Visit({required this.startMs, this.endMs});

  /// Known duration, or `null` for an unpaired start. Never negative —
  /// the DAO reads in `ts_utc` order, but a hand-built row shouldn't be
  /// able to produce a negative total.
  Duration? get duration {
    final end = endMs;
    if (end == null) return null;
    final ms = end - startMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  @override
  String toString() => 'Visit($startMs → ${endMs ?? '?'})';
}

/// Every visit to one place, rolled up.
class PlaceSummary {
  /// Stable identity — the SEED key of the place: `pid:<placeId>` when
  /// Timeline gave its first visit a place id, otherwise
  /// `at:<lat>,<lon>` at 4 dp (~11 m, the same resolution `geocodeKey`
  /// uses). See [placeKeyFor] and [memberKeys].
  final String key;

  /// Every key rolled into this place, merge order, seed first — one
  /// entry per original place [buildPlaces] merged in spatially and
  /// [mergeByLabel] merged in by name. Empty means "never merged",
  /// which [memberCount] reads as one.
  final List<String> memberKeys;

  /// Human labels for Timeline's `semanticType` (`Home`, `Work`,
  /// `Home (inferred)`, `Work (inferred)`), most frequent member first.
  /// Everything else (`UNKNOWN`, `SEARCHED_ADDRESS`, a missing token)
  /// contributes nothing — those carry no meaning worth a badge, and
  /// the empty list is what "no type" looks like. A merged place holds
  /// the union of its members' types; the UI chips them all.
  final List<String> semanticTypes;

  /// Coordinates of the first row seen for the SEED place. Both rows of
  /// a pair share them; separate visits to the same `placeId` share
  /// them too (Timeline reports the place location, not a fix). Merging
  /// never moves them — the running centroid decides who merges, the
  /// seed's own coordinates stay the row's identity for geocoding.
  final double lat;
  final double lon;

  /// Number of visits (pairs + unpaired starts), NOT the row count.
  final int visitCount;

  /// Start of the earliest / latest visit, epoch ms UTC.
  final int firstMs;
  final int lastMs;

  /// Sum of the KNOWN visit durations; [Duration.zero] when every visit
  /// was unpaired.
  final Duration totalDuration;

  /// Longest known visit; [Duration.zero] when none is known.
  final Duration longestVisit;

  const PlaceSummary({
    required this.key,
    required this.semanticTypes,
    required this.lat,
    required this.lon,
    required this.visitCount,
    required this.firstMs,
    required this.lastMs,
    required this.totalDuration,
    required this.longestVisit,
    this.memberKeys = const [],
  });

  /// The one type worth a badge when only one fits: the most frequent
  /// of [semanticTypes], or `null` when no member carried one.
  String? get semanticType =>
      semanticTypes.isEmpty ? null : semanticTypes.first;

  /// How many original places this row rolls up — 1 when it stands
  /// alone. Drives the "×3 spots" hint.
  int get memberCount => memberKeys.isEmpty ? 1 : memberKeys.length;

  /// Family argument for `placeVisitsProvider`: every member key, so a
  /// merged row's sheet lists the visits of all of them. See
  /// [visitsForPlaceKeys].
  String get visitsKey =>
      memberKeys.isEmpty ? key : memberKeys.join(kPlaceKeySep);
}

/// Ordering offered by the Places screen's segmented control.
enum PlaceSort {
  /// Most visits first (ties broken by most recent).
  visits,

  /// Most recently visited first.
  recent,

  /// Most time spent first.
  longest,
}

/// Identity for the place a visit row belongs to.
///
/// Timeline's `placeId` is the good key — the same café keeps it across
/// years. When the export had none the mapper writes `-`, and the place
/// location itself becomes the key at 4 dp; visits to an unnamed place
/// sit on identical coordinates (the location comes from Google, not
/// from a GPS fix), so rounding is about float formatting, not jitter.
String placeKeyFor(VisitRow row) {
  final id = visitPlaceId(row.note);
  if (id != null) return 'pid:$id';
  return 'at:${row.lat.toStringAsFixed(4)},${row.lon.toStringAsFixed(4)}';
}

/// `gmaps:visit:HOME:ChIJ…` → `ChIJ…`; `null` for the mapper's `-`
/// placeholder, an empty token or a note that isn't a visit note.
String? visitPlaceId(String note) {
  if (!note.startsWith(kVisitNotePrefix)) return null;
  final parts = note.split(':');
  if (parts.length < 4) return null;
  final id = parts[3];
  if (id.isEmpty || id == '-') return null;
  return id;
}

/// `gmaps:visit:INFERRED_HOME:-` → `Home (inferred)`.
///
/// Same four labels `import_provenance.dart` gives the pin detail sheet;
/// everything else is `null` here (see [PlaceSummary.semanticType]).
String? visitTypeLabel(String note) {
  if (!note.startsWith(kVisitNotePrefix)) return null;
  final parts = note.split(':');
  if (parts.length < 3) return null;
  switch (parts[2].toUpperCase()) {
    case 'HOME':
      return 'Home';
    case 'WORK':
      return 'Work';
    case 'INFERRED_HOME':
      return 'Home (inferred)';
    case 'INFERRED_WORK':
      return 'Work (inferred)';
  }
  return null;
}

/// Rolls `PingDao.importedVisits()` rows up into one entry per place,
/// most-visited first (ties → most recent first).
///
/// [rows] must be in the DAO's chronological (oldest-first) order; the
/// pairing walks it once and treats the next row of the same place as
/// the end of the open visit, which is exactly the shape
/// `timeline_mappers.dart` writes. A row for a place with no visit open
/// starts one; whatever is still open at the end of the walk becomes a
/// visit of unknown duration.
///
/// Places are then merged spatially: seeded in first-visit order, each
/// place joins the FIRST already-seen place whose running centroid is
/// within [clusterM] metres (the same greedy rule `planCoverage` uses,
/// at street scale). The merged row keeps the seed's key and
/// coordinates, lists every member in [PlaceSummary.memberKeys],
/// concatenates the visits and recomputes every number over the union.
/// `clusterM: 0` turns merging off and reproduces the pre-0.17.5
/// one-row-per-key behaviour.
List<PlaceSummary> buildPlaces(
  List<VisitRow> rows, {
  double clusterM = kPlaceClusterM,
}) =>
    sortPlaces(
      [for (final c in _clusters(rows, clusterM)) c.summary],
      PlaceSort.visits,
    );

/// Every visit to one place, oldest-first. Same pairing and the same
/// spatial merge as [buildPlaces], so [key] may be the merged place's
/// [PlaceSummary.key] or any of its [PlaceSummary.memberKeys]. Unknown
/// key → empty.
List<Visit> visitsForPlace(
  List<VisitRow> rows,
  String key, {
  double clusterM = kPlaceClusterM,
}) =>
    visitsForPlaceKeys(rows, [key], clusterM: clusterM);

/// [visitsForPlace] over several keys at once: the union of every
/// merged place any of [keys] belongs to, oldest-first.
///
/// This is what a row merged by [mergeByLabel] needs — its members are
/// separate spatial clusters, and the sheet must list all their visits
/// or the count on the row wouldn't match the list under it.
List<Visit> visitsForPlaceKeys(
  List<VisitRow> rows,
  Iterable<String> keys, {
  double clusterM = kPlaceClusterM,
}) {
  final wanted = keys.toSet();
  if (wanted.isEmpty) return const [];
  final out = <Visit>[];
  for (final c in _clusters(rows, clusterM)) {
    if (c.memberKeys.any(wanted.contains)) out.addAll(c.visits);
  }
  out.sort(_byStartMs);
  return out;
}

/// Collapses rows the reverse geocoder gave the SAME name and whose
/// centres sit within [maxKm] of each other.
///
/// [buildPlaces] can only merge what is physically close: two doors of
/// the same district are 300 m apart and Google keeps separate place
/// ids for them. Once both rows read "Redcliffe, Bristol" they are one
/// place to the user, so the screen re-runs this every time a label
/// lands. Places whose label hasn't resolved (missing, `null` or blank
/// in [labelsByKey], which is keyed on [PlaceSummary.key]) are never
/// merged — "no name yet" is not a name two rows can share.
///
/// Pure and order-preserving: the first row of a group keeps its
/// position, its key and its coordinates, every number is recomputed
/// over the group, and the caller re-sorts with [sortPlaces].
List<PlaceSummary> mergeByLabel(
  List<PlaceSummary> places,
  Map<String, String?> labelsByKey, {
  double maxKm = kPlaceLabelMergeKm,
}) {
  final groups = <_LabelGroup>[];
  for (final place in places) {
    final label = _normaliseLabel(labelsByKey[place.key]);
    _LabelGroup? target;
    if (label != null && maxKm > 0) {
      for (final g in groups) {
        if (g.label != label) continue;
        final m = _haversineM(
          place.lat,
          place.lon,
          g.centroidLat,
          g.centroidLon,
        );
        if (m <= maxKm * 1000) {
          target = g;
          break;
        }
      }
    }
    if (target == null) {
      groups.add(_LabelGroup(label, place));
    } else {
      target.add(place);
    }
  }
  return [for (final g in groups) g.summary];
}

/// Re-orders a [buildPlaces] result. Returns a new list; the input is
/// left alone (the provider caches it).
List<PlaceSummary> sortPlaces(List<PlaceSummary> places, PlaceSort sort) {
  final out = [...places];
  switch (sort) {
    case PlaceSort.visits:
      out.sort((a, b) {
        final byCount = b.visitCount.compareTo(a.visitCount);
        return byCount != 0 ? byCount : b.lastMs.compareTo(a.lastMs);
      });
    case PlaceSort.recent:
      out.sort((a, b) {
        final byLast = b.lastMs.compareTo(a.lastMs);
        return byLast != 0 ? byLast : b.visitCount.compareTo(a.visitCount);
      });
    case PlaceSort.longest:
      out.sort((a, b) {
        final byTotal = b.totalDuration.compareTo(a.totalDuration);
        return byTotal != 0 ? byTotal : b.lastMs.compareTo(a.lastMs);
      });
  }
  return out;
}

/// `2 d 3 h`, `12 h 30 m`, `45 m`, `< 1 m`. Days appear above 24 h — a
/// "Home" place holds thousands of hours and `8760 h` is unreadable.
String formatPlaceDuration(Duration d) {
  if (d.inMinutes < 1) return '< 1 m';
  if (d.inHours < 1) return '${d.inMinutes} m';
  if (d.inDays < 1) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} h' : '${d.inHours} h $m m';
  }
  final h = d.inHours % 24;
  return h == 0 ? '${d.inDays} d' : '${d.inDays} d $h h';
}

/// `12 visits · 3 Jan 2024 – 8 May 2026 · total 12 h 30 m` — the place
/// row's second line. The date collapses to one when every visit landed
/// on the same local day, and the total is dropped when no visit had a
/// known end.
String formatPlaceSubtitle(PlaceSummary place) {
  final first = DateTime.fromMillisecondsSinceEpoch(place.firstMs).toLocal();
  final last = DateTime.fromMillisecondsSinceEpoch(place.lastMs).toLocal();
  final dates = _sameLocalDay(first, last)
      ? kPlaceDateFormat.format(first)
      : '${kPlaceDateFormat.format(first)} – ${kPlaceDateFormat.format(last)}';
  final parts = [
    '${place.visitCount} visit${place.visitCount == 1 ? '' : 's'}',
    dates,
    if (place.totalDuration > Duration.zero)
      'total ${formatPlaceDuration(place.totalDuration)}',
  ];
  return parts.join(' · ');
}

/// `3 Jan 2024 14:05 – 15:20` (same day), `3 Jan 2024 23:40 – 4 Jan 2024
/// 07:15` (across midnight), or just the start for an unpaired visit.
String formatVisitRange(Visit visit) {
  final start = DateTime.fromMillisecondsSinceEpoch(visit.startMs).toLocal();
  final startLabel = formatHudTime(start);
  final endMs = visit.endMs;
  if (endMs == null) return startLabel;
  final end = DateTime.fromMillisecondsSinceEpoch(endMs).toLocal();
  final endLabel = _sameLocalDay(start, end)
      ? kVisitClockFormat.format(end)
      : formatHudTime(end);
  return '$startLabel – $endLabel';
}

/// `2 h 15 m`, or the honest "duration unknown" for an unpaired start.
String formatVisitDuration(Visit visit) {
  final d = visit.duration;
  return d == null ? 'duration unknown' : formatPlaceDuration(d);
}

/// `×3 spots` — the hint on a row that rolled several nearby places
/// into one. `null` for a place that stands alone (nothing to explain).
String? formatSpotsHint(PlaceSummary place) =>
    place.memberCount > 1 ? '×${place.memberCount} spots' : null;

/// `3 places within 1 km` — the detail sheet's header note for a merged
/// row. `null` for a place that stands alone.
///
/// [maxKm] is the widest merge the caller applied ([kPlaceLabelMergeKm]
/// by default, the radius the screen passes [mergeByLabel]); the
/// spatial merge in [buildPlaces] is far tighter, so the sentence stays
/// true for a row merged either way.
String? formatMergedPlaces(
  PlaceSummary place, {
  double maxKm = kPlaceLabelMergeKm,
}) =>
    place.memberCount > 1
        ? '${place.memberCount} places within ${_formatKm(maxKm)}'
        : null;

/// `1 km`, `2.5 km`, `500 m` — a merge radius as prose. Sub-kilometre
/// radii read as metres; a whole number never shows a `.0`.
String _formatKm(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  final rounded = (km * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? '${rounded.toInt()} km'
      : '$rounded km';
}

bool _sameLocalDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Mutable per-place accumulator used while walking the rows.
class _PlaceAcc {
  final double lat;
  final double lon;
  String? semanticType;
  final List<Visit> visits = [];

  /// Start time of the visit still waiting for its end row, if any.
  int? openStartMs;

  _PlaceAcc({required this.lat, required this.lon, this.semanticType});
}

/// The one walk both public entry points share: rows → visits per key.
Map<String, _PlaceAcc> _visitsByKey(List<VisitRow> rows) {
  final byKey = <String, _PlaceAcc>{};
  for (final row in rows) {
    if (!row.note.startsWith(kVisitNotePrefix)) continue;
    final key = placeKeyFor(row);
    final acc = byKey.putIfAbsent(
      key,
      () => _PlaceAcc(
        lat: row.lat,
        lon: row.lon,
        semanticType: visitTypeLabel(row.note),
      ),
    );
    // First typed row wins: one visit to a place may be UNKNOWN while
    // another names it HOME, and "we know it's home" is the useful bit.
    acc.semanticType ??= visitTypeLabel(row.note);
    final open = acc.openStartMs;
    if (open == null) {
      acc.openStartMs = row.tsUtcMs;
    } else {
      acc.visits.add(Visit(startMs: open, endMs: row.tsUtcMs));
      acc.openStartMs = null;
    }
  }
  for (final acc in byKey.values) {
    final open = acc.openStartMs;
    if (open != null) {
      acc.visits.add(Visit(startMs: open));
      acc.openStartMs = null;
    }
  }
  return byKey;
}

/// One merged place while the greedy walk runs: the seed plus every
/// place pulled into it. The centroid is RUNNING — each member shifts
/// it — exactly like `planCoverage`'s clustering, which this mirrors at
/// street scale.
class _Cluster {
  _Cluster(String seedKey, _PlaceAcc seed)
      : lat = seed.lat,
        lon = seed.lon,
        centroidLat = seed.lat,
        centroidLon = seed.lon {
    memberKeys.add(seedKey);
    types.add(seed.semanticType);
    visits.addAll(seed.visits);
  }

  final List<String> memberKeys = [];
  final List<String?> types = [];
  final List<Visit> visits = [];

  /// The seed's coordinates — see [PlaceSummary.lat].
  final double lat;
  final double lon;

  double centroidLat;
  double centroidLon;

  String get key => memberKeys.first;

  void add(String memberKey, _PlaceAcc acc) {
    final n = memberKeys.length;
    centroidLat = (centroidLat * n + acc.lat) / (n + 1);
    centroidLon = (centroidLon * n + acc.lon) / (n + 1);
    memberKeys.add(memberKey);
    types.add(acc.semanticType);
    visits.addAll(acc.visits);
  }

  PlaceSummary get summary {
    var total = Duration.zero;
    var longest = Duration.zero;
    var firstMs = visits.first.startMs;
    var lastMs = visits.first.startMs;
    for (final v in visits) {
      if (v.startMs < firstMs) firstMs = v.startMs;
      if (v.startMs > lastMs) lastMs = v.startMs;
      final d = v.duration;
      if (d == null) continue;
      total += d;
      if (d > longest) longest = d;
    }
    return PlaceSummary(
      key: key,
      memberKeys: List.unmodifiable(memberKeys),
      semanticTypes: _rankTypes(types),
      lat: lat,
      lon: lon,
      visitCount: visits.length,
      firstMs: firstMs,
      lastMs: lastMs,
      totalDuration: total,
      longestVisit: longest,
    );
  }
}

/// Rows → merged places. Seeds are walked in first-visit order (ties by
/// key) so the result never depends on `Map` iteration luck or on the
/// order the DAO happened to return equal timestamps in.
List<_Cluster> _clusters(List<VisitRow> rows, double clusterM) {
  final seeds = _visitsByKey(rows).entries.toList()
    ..sort((a, b) {
      final byFirst = _firstStartMs(a.value).compareTo(_firstStartMs(b.value));
      return byFirst != 0 ? byFirst : a.key.compareTo(b.key);
    });
  final clusters = <_Cluster>[];
  for (final seed in seeds) {
    _Cluster? target;
    // `clusterM <= 0` means "no merging at all" — not even for two keys
    // that sit on identical coordinates, which is what the pre-0.17.5
    // behaviour did with a placeId place and a coordinate place.
    if (clusterM > 0) {
      for (final c in clusters) {
        final m = _haversineM(
          seed.value.lat,
          seed.value.lon,
          c.centroidLat,
          c.centroidLon,
        );
        if (m <= clusterM) {
          target = c;
          break;
        }
      }
    }
    if (target == null) {
      clusters.add(_Cluster(seed.key, seed.value));
    } else {
      target.add(seed.key, seed.value);
    }
  }
  return clusters;
}

/// One group of same-named places while [mergeByLabel] runs.
class _LabelGroup {
  _LabelGroup(this.label, PlaceSummary seed)
      : centroidLat = seed.lat,
        centroidLon = seed.lon {
    members.add(seed);
  }

  /// Normalised label, or `null` for a row whose name hasn't resolved —
  /// such a group never takes a second member.
  final String? label;
  final List<PlaceSummary> members = [];

  double centroidLat;
  double centroidLon;

  void add(PlaceSummary place) {
    final n = members.length;
    centroidLat = (centroidLat * n + place.lat) / (n + 1);
    centroidLon = (centroidLon * n + place.lon) / (n + 1);
    members.add(place);
  }

  PlaceSummary get summary {
    final seed = members.first;
    // A group of one is the row itself — same instance, so an unmerged
    // list survives `mergeByLabel` untouched.
    if (members.length == 1) return seed;
    var visitCount = 0;
    var firstMs = seed.firstMs;
    var lastMs = seed.lastMs;
    var total = Duration.zero;
    var longest = Duration.zero;
    final keys = <String>[];
    final types = <String>[];
    for (final m in members) {
      visitCount += m.visitCount;
      if (m.firstMs < firstMs) firstMs = m.firstMs;
      if (m.lastMs > lastMs) lastMs = m.lastMs;
      total += m.totalDuration;
      if (m.longestVisit > longest) longest = m.longestVisit;
      keys.addAll(m.memberKeys.isEmpty ? [m.key] : m.memberKeys);
      for (final t in m.semanticTypes) {
        if (!types.contains(t)) types.add(t);
      }
    }
    return PlaceSummary(
      key: seed.key,
      memberKeys: List.unmodifiable(keys),
      semanticTypes: List.unmodifiable(types),
      lat: seed.lat,
      lon: seed.lon,
      visitCount: visitCount,
      firstMs: firstMs,
      lastMs: lastMs,
      totalDuration: total,
      longestVisit: longest,
    );
  }
}

/// Distinct non-null types, most frequent member first, ties by first
/// seen — a place Google called HOME on four visits and left UNKNOWN on
/// a fifth still badges as Home.
List<String> _rankTypes(List<String?> types) {
  final counts = <String, int>{};
  final firstSeen = <String, int>{};
  for (var i = 0; i < types.length; i++) {
    final t = types[i];
    if (t == null) continue;
    counts.update(t, (v) => v + 1, ifAbsent: () => 1);
    firstSeen.putIfAbsent(t, () => i);
  }
  final out = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  return List.unmodifiable(out);
}

/// Earliest visit start of one accumulator. Rows arrive oldest-first in
/// production, but the walk must not depend on it.
int _firstStartMs(_PlaceAcc acc) {
  var first = acc.visits.first.startMs;
  for (final v in acc.visits) {
    if (v.startMs < first) first = v.startMs;
  }
  return first;
}

int _byStartMs(Visit a, Visit b) => a.startMs.compareTo(b.startMs);

/// Trimmed, case-folded label; `null` for "no name yet".
String? _normaliseLabel(String? label) {
  final trimmed = label?.trim().toLowerCase();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// Great-circle distance in metres — the metre-scale twin of
/// `coverage_planner.haversineKm`, re-implemented here so this file
/// keeps its "pure maths, no app imports" shape.
double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusM = 6371008.8;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dPhi = (lat2 - lat1) * math.pi / 180;
  final dLambda = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(p1) *
          math.cos(p2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}
