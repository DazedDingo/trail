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

import 'package:intl/intl.dart';

import '../date_labels.dart';

/// One row of `PingDao.importedVisits()` — a single `visitStart` or
/// `visitEnd` ping.
typedef VisitRow = ({int tsUtcMs, double lat, double lon, String note});

/// Note prefix every visit row carries (`timeline_mappers.dart`).
const String kVisitNotePrefix = 'gmaps:visit:';

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
  /// Stable identity — `pid:<placeId>` when Timeline gave the visit a
  /// place id, otherwise `at:<lat>,<lon>` at 4 dp (~11 m, the same
  /// resolution `geocodeKey` uses). See [placeKeyFor].
  final String key;

  /// Human label for Timeline's `semanticType`: `Home`, `Work`,
  /// `Home (inferred)`, `Work (inferred)`. `null` for everything else
  /// (`UNKNOWN`, `SEARCHED_ADDRESS`, a missing token) — those carry no
  /// meaning worth a badge, and "no type" is what the UI branches on.
  final String? semanticType;

  /// Coordinates of the first row seen for this place. Both rows of a
  /// pair share them; separate visits to the same `placeId` share them
  /// too (Timeline reports the place location, not a fix).
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
    required this.semanticType,
    required this.lat,
    required this.lon,
    required this.visitCount,
    required this.firstMs,
    required this.lastMs,
    required this.totalDuration,
    required this.longestVisit,
  });
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
List<PlaceSummary> buildPlaces(List<VisitRow> rows) {
  final visits = _visitsByKey(rows);
  final out = <PlaceSummary>[];
  for (final entry in visits.entries) {
    final acc = entry.value;
    var total = Duration.zero;
    var longest = Duration.zero;
    var firstMs = acc.visits.first.startMs;
    var lastMs = acc.visits.first.startMs;
    for (final v in acc.visits) {
      if (v.startMs < firstMs) firstMs = v.startMs;
      if (v.startMs > lastMs) lastMs = v.startMs;
      final d = v.duration;
      if (d == null) continue;
      total += d;
      if (d > longest) longest = d;
    }
    out.add(PlaceSummary(
      key: entry.key,
      semanticType: acc.semanticType,
      lat: acc.lat,
      lon: acc.lon,
      visitCount: acc.visits.length,
      firstMs: firstMs,
      lastMs: lastMs,
      totalDuration: total,
      longestVisit: longest,
    ));
  }
  return sortPlaces(out, PlaceSort.visits);
}

/// Every visit to one place, oldest-first. Same pairing as
/// [buildPlaces]; the screen's detail sheet reverses it for display.
/// Unknown key → empty.
List<Visit> visitsForPlace(List<VisitRow> rows, String key) =>
    _visitsByKey(rows)[key]?.visits ?? const [];

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
