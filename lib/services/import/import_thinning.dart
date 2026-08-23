/// Pure thinning + dedupe engine for the Google Maps Timeline import.
///
/// Everything here is plain Dart (no Flutter, no DB, no IO) so the whole
/// pipeline can be exercised in unit tests and run inside the import
/// isolate. See docs/TIMELINE_IMPORT.md "Mapping → pings" for the rules
/// these functions encode.
library;

import 'dart:math' as math;

import 'timeline_models.dart';

/// Radius used by [haversineMeters]. `HomeLocation.distanceMetersTo` uses
/// the same value, but it is an instance method on a stored preference
/// object rather than a pure function, so the import engine carries its
/// own copy.
const double _earthRadiusM = 6371000.0;

/// Candidates whose timestamps fall inside this window of the group's
/// first timestamp compete as one group (the raw-vs-path dedupe).
/// Boundary is inclusive: exactly 60 000 ms after the anchor still joins.
const int kImportGroupWindowMs = 60 * 1000;

/// An activity endpoint is redundant when another kept candidate lies
/// within this window of it. Boundary is inclusive.
const int kImportActivityWindowMs = 5 * 60 * 1000;

/// Above this many projected rows the import screen warns the user
/// (docs/TIMELINE_IMPORT.md "Thinning").
const int kImportWarnRowThreshold = 50000;

/// Great-circle distance in metres between two WGS-84 points.
///
/// Haversine, accurate to ~0.5 % — far more than thinning needs.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return _earthRadiusM * c;
}

double _toRad(double deg) => deg * (math.pi / 180);

/// Thins [sorted] (ascending `tsUtcMs`) down to the rows that should be
/// inserted, applying three passes in order:
///
/// 1. **60-second raw-vs-path dedupe** (every preset). Walking the list,
///    candidates within [kImportGroupWindowMs] of the group's first
///    timestamp form one group; the group emits the best single
///    candidate — a non-null `accuracyM` (a raw signal) beats a null one,
///    ties go to the earliest. Candidates with `alwaysKeep` (visit
///    endpoints) never compete and are always emitted in addition.
/// 2. **Gap/distance thinning** (skipped for [ImportPreset.full]). A
///    candidate is kept when `Δt ≥ preset.minGap` **or** it is at least
///    `preset.minDistanceM` from the last kept candidate. `alwaysKeep`
///    candidates are kept unconditionally and become the new "last kept".
///    The first candidate is always kept.
/// 3. **Activity endpoints.** An `activityStart`/`activityEnd` candidate
///    survives only when no *other* candidate kept by steps 1–2 lies
///    within [kImportActivityWindowMs] of it. The check runs against the
///    step-2 list simultaneously for every activity point, so two
///    activity endpoints within five minutes of each other drop each
///    other (the decision does not depend on iteration order).
///
/// Output stays sorted by `tsUtcMs` ascending.
///
/// Throws [ArgumentError] if [sorted] is not sorted ascending.
List<ImportCandidate> thinCandidates(
  List<ImportCandidate> sorted,
  ImportPreset preset,
) {
  _requireSortedCandidates(sorted, 'sorted');
  if (sorted.isEmpty) return <ImportCandidate>[];

  final grouped = _dedupeSixtySecondGroups(sorted);
  final thinned = preset.isFull ? grouped : _thinByGapDistance(grouped, preset);
  return _dropRedundantActivityEndpoints(thinned);
}

/// Pass 1 — the 60-second raw-vs-path dedupe.
List<ImportCandidate> _dedupeSixtySecondGroups(List<ImportCandidate> sorted) {
  final out = <ImportCandidate>[];
  var i = 0;
  while (i < sorted.length) {
    final anchorTs = sorted[i].tsUtcMs;
    var end = i;
    while (end < sorted.length &&
        sorted[end].tsUtcMs - anchorTs <= kImportGroupWindowMs) {
      end++;
    }

    // Best of the competing (non-alwaysKeep) members: prefer a non-null
    // accuracy — raw over path — then the earliest.
    var bestIndex = -1;
    for (var k = i; k < end; k++) {
      final c = sorted[k];
      if (c.alwaysKeep) continue;
      if (bestIndex == -1) {
        bestIndex = k;
      } else if (sorted[bestIndex].accuracyM == null && c.accuracyM != null) {
        bestIndex = k;
      }
    }

    // Emit in timestamp order: every visit endpoint plus the winner.
    for (var k = i; k < end; k++) {
      if (sorted[k].alwaysKeep || k == bestIndex) out.add(sorted[k]);
    }
    i = end;
  }
  return out;
}

/// Pass 2 — gap/distance thinning against the last kept candidate.
List<ImportCandidate> _thinByGapDistance(
  List<ImportCandidate> input,
  ImportPreset preset,
) {
  if (input.isEmpty) return <ImportCandidate>[];
  final minGapMs = preset.minGap.inMilliseconds;
  var last = input.first;
  final out = <ImportCandidate>[last];
  for (var i = 1; i < input.length; i++) {
    final c = input[i];
    if (c.alwaysKeep ||
        c.tsUtcMs - last.tsUtcMs >= minGapMs ||
        haversineMeters(last.lat, last.lon, c.lat, c.lon) >=
            preset.minDistanceM) {
      out.add(c);
      last = c;
    }
  }
  return out;
}

/// Pass 3 — drop activity endpoints that duplicate a nearby kept point.
///
/// [kept] is sorted, so the closest *other* candidate in time is always an
/// immediate neighbour; checking both neighbours is enough (and keeps the
/// pass O(n)).
List<ImportCandidate> _dropRedundantActivityEndpoints(
  List<ImportCandidate> kept,
) {
  final out = <ImportCandidate>[];
  for (var i = 0; i < kept.length; i++) {
    final c = kept[i];
    if (c.kind != ImportKind.activityStart &&
        c.kind != ImportKind.activityEnd) {
      out.add(c);
      continue;
    }
    final prevNear = i > 0 &&
        c.tsUtcMs - kept[i - 1].tsUtcMs <= kImportActivityWindowMs;
    final nextNear = i + 1 < kept.length &&
        kept[i + 1].tsUtcMs - c.tsUtcMs <= kImportActivityWindowMs;
    if (!prevNear && !nextNear) out.add(c);
  }
  return out;
}

/// One `(ts_utc, lat, lon)` row already in the `pings` table, loaded for
/// the file's time range so the import can skip points Trail already has.
class ExistingFix {
  const ExistingFix({
    required this.tsUtcMs,
    required this.lat,
    required this.lon,
  });

  final int tsUtcMs;
  final double lat;
  final double lon;

  @override
  String toString() => 'ExistingFix(ts=$tsUtcMs $lat,$lon)';
}

/// Drops candidates that duplicate an existing ping: a candidate is a
/// duplicate when **any** fix in [sortedExisting] within ±[windowMs] of
/// its timestamp is less than [radiusM] away.
///
/// Trail's own fix always wins — imports never overwrite or re-time an
/// existing row (docs/TIMELINE_IMPORT.md "Commander's considerations §1").
///
/// The time window is inclusive, the radius is exclusive (a fix exactly
/// [radiusM] away is not a duplicate). [sortedExisting] is binary-searched
/// for the start of each neighbourhood, so this is O(n log m).
///
/// Both lists must be sorted ascending by timestamp; throws
/// [ArgumentError] otherwise.
({List<ImportCandidate> kept, int duplicates}) dedupeAgainstExisting(
  List<ImportCandidate> sortedKept,
  List<ExistingFix> sortedExisting, {
  int windowMs = 60000,
  double radiusM = 25,
}) {
  _requireSortedCandidates(sortedKept, 'sortedKept');
  _requireSortedFixes(sortedExisting, 'sortedExisting');

  if (sortedExisting.isEmpty || sortedKept.isEmpty) {
    return (kept: List<ImportCandidate>.of(sortedKept), duplicates: 0);
  }

  final kept = <ImportCandidate>[];
  var duplicates = 0;
  for (final c in sortedKept) {
    final from = _lowerBoundTs(sortedExisting, c.tsUtcMs - windowMs);
    final until = c.tsUtcMs + windowMs;
    var isDuplicate = false;
    for (var i = from; i < sortedExisting.length; i++) {
      final e = sortedExisting[i];
      if (e.tsUtcMs > until) break;
      if (haversineMeters(c.lat, c.lon, e.lat, e.lon) < radiusM) {
        isDuplicate = true;
        break;
      }
    }
    if (isDuplicate) {
      duplicates++;
    } else {
      kept.add(c);
    }
  }
  return (kept: kept, duplicates: duplicates);
}

/// First index in [fixes] whose timestamp is >= [targetTs] (`fixes.length`
/// when every fix is older).
int _lowerBoundTs(List<ExistingFix> fixes, int targetTs) {
  var lo = 0;
  var hi = fixes.length;
  while (lo < hi) {
    final mid = lo + ((hi - lo) >> 1);
    if (fixes[mid].tsUtcMs < targetTs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// What an import would do, for the dry-run preview: "N rows after
/// thinning, M duplicates skipped, range X–Y".
class ImportProjection {
  const ImportProjection({
    required this.candidates,
    required this.kept,
    required this.duplicates,
    this.tsMinUtcMs,
    this.tsMaxUtcMs,
  });

  /// Candidates the mappers produced, before thinning.
  final int candidates;

  /// Rows that would actually be inserted.
  final int kept;

  /// Candidates skipped because Trail already has that fix.
  final int duplicates;

  /// Time range of the *kept* rows (what would be written, and what an
  /// undo would delete). Null when nothing would be inserted.
  final int? tsMinUtcMs;
  final int? tsMaxUtcMs;

  /// The import screen warns above this many rows.
  bool get exceedsWarnThreshold => kept > kImportWarnRowThreshold;

  @override
  String toString() => 'ImportProjection(candidates: $candidates, '
      'kept: $kept, duplicates: $duplicates, '
      'range: $tsMinUtcMs..$tsMaxUtcMs)';
}

/// Thin + dedupe [sortedCandidates] and report the counts only — this
/// backs the dry-run preview.
ImportProjection projectImport(
  List<ImportCandidate> sortedCandidates,
  ImportPreset preset,
  List<ExistingFix> sortedExisting,
) {
  final thinned = thinCandidates(sortedCandidates, preset);
  final result = dedupeAgainstExisting(thinned, sortedExisting);
  final kept = result.kept;
  return ImportProjection(
    candidates: sortedCandidates.length,
    kept: kept.length,
    duplicates: result.duplicates,
    tsMinUtcMs: kept.isEmpty ? null : kept.first.tsUtcMs,
    tsMaxUtcMs: kept.isEmpty ? null : kept.last.tsUtcMs,
  );
}

void _requireSortedCandidates(List<ImportCandidate> list, String name) {
  for (var i = 1; i < list.length; i++) {
    if (list[i].tsUtcMs < list[i - 1].tsUtcMs) {
      throw ArgumentError.value(
        list[i].tsUtcMs,
        name,
        'candidates must be sorted by tsUtcMs ascending '
        '(index $i < index ${i - 1})',
      );
    }
  }
}

void _requireSortedFixes(List<ExistingFix> list, String name) {
  for (var i = 1; i < list.length; i++) {
    if (list[i].tsUtcMs < list[i - 1].tsUtcMs) {
      throw ArgumentError.value(
        list[i].tsUtcMs,
        name,
        'existing fixes must be sorted by tsUtcMs ascending '
        '(index $i < index ${i - 1})',
      );
    }
  }
}

/// One calendar year of an import, as the dry-run preview reports it —
/// the answer to "did the export actually contain 2024, or did the
/// import drop it?".
///
/// The year is the **local** calendar year of the timestamp (the same
/// reading as the map, History and the year chips), so an instant at
/// 23:30 UTC on 31 December belongs to the next year in UTC+1.
class ImportYearRow {
  const ImportYearRow({
    required this.year,
    required this.candidatesInFile,
    required this.keptAfterThinning,
    required this.skippedAsDuplicate,
    required this.pathPoints,
    required this.visits,
    required this.activities,
    required this.rawPositions,
    required this.firstTsUtcMs,
    required this.lastTsUtcMs,
  });

  /// Local calendar year.
  final int year;

  /// Candidates the mappers produced for this year, before thinning —
  /// "what the export contained".
  final int candidatesInFile;

  /// Rows that would actually be inserted for this year.
  final int keptAfterThinning;

  /// Candidates thinning kept but the dedupe dropped, because Trail
  /// already had that fix (±60 s, < 25 m).
  final int skippedAsDuplicate;

  /// Per-kind split of [candidatesInFile]. Counted per *candidate*, so a
  /// visit contributes 2 (start + end) and so does an activity; the four
  /// always add up to [candidatesInFile].
  final int pathPoints;
  final int visits;
  final int activities;
  final int rawPositions;

  /// First/last candidate the file has for this year (epoch ms, UTC).
  final int firstTsUtcMs;
  final int lastTsUtcMs;

  /// The bug detector: the export had points for this year, none were
  /// kept and none were duplicates. Thinning always keeps at least the
  /// first candidate of a run, so this should be impossible — when it
  /// shows up on the preview card, the import dropped the year.
  bool get thinnedToNothing =>
      candidatesInFile > 0 && keptAfterThinning == 0 && skippedAsDuplicate == 0;

  @override
  String toString() => 'ImportYearRow($year: inFile=$candidatesInFile '
      'kept=$keptAfterThinning dup=$skippedAsDuplicate '
      'path=$pathPoints visits=$visits activities=$activities '
      'raw=$rawPositions range=$firstTsUtcMs..$lastTsUtcMs)';
}

/// Local calendar year of an epoch-millisecond UTC timestamp.
int importYearOf(int tsUtcMs) =>
    DateTime.fromMillisecondsSinceEpoch(tsUtcMs).year;

/// Per-year accounting for one import: what the file held, what survived
/// thinning + dedupe, and what the dedupe dropped.
///
/// [candidates] is everything the mappers produced, [keptBeforeDedupe]
/// the survivors of [thinCandidates] and [kept] the survivors of
/// [dedupeAgainstExisting] — the three lists the worker has in hand at
/// preview time. Duplicates are `keptBeforeDedupe − kept` per year
/// (the dedupe only ever removes), so the three counts stay consistent
/// with [ImportProjection]'s totals.
///
/// Rows come back newest year first. Years with no candidates at all are
/// absent — a missing 2024 row and a `2024 · 0 · 0 · 0` row mean
/// different things (nothing in the export vs. everything dropped).
List<ImportYearRow> yearBreakdown({
  required List<ImportCandidate> candidates,
  required List<ImportCandidate> keptBeforeDedupe,
  required List<ImportCandidate> kept,
}) {
  final acc = <int, _YearAcc>{};
  _YearAcc bucket(int tsUtcMs) =>
      acc.putIfAbsent(importYearOf(tsUtcMs), () => _YearAcc(tsUtcMs));

  for (final c in candidates) {
    final year = bucket(c.tsUtcMs)..touch(c.tsUtcMs);
    year.inFile++;
    switch (c.kind) {
      case ImportKind.path:
        year.path++;
      case ImportKind.visitStart:
      case ImportKind.visitEnd:
        year.visits++;
      case ImportKind.activityStart:
      case ImportKind.activityEnd:
        year.activities++;
      case ImportKind.raw:
        year.raw++;
    }
  }
  for (final c in keptBeforeDedupe) {
    (bucket(c.tsUtcMs)..touch(c.tsUtcMs)).thinned++;
  }
  for (final c in kept) {
    (bucket(c.tsUtcMs)..touch(c.tsUtcMs)).kept++;
  }

  return <ImportYearRow>[
    for (final entry in acc.entries)
      ImportYearRow(
        year: entry.key,
        candidatesInFile: entry.value.inFile,
        keptAfterThinning: entry.value.kept,
        skippedAsDuplicate: entry.value.thinned - entry.value.kept,
        pathPoints: entry.value.path,
        visits: entry.value.visits,
        activities: entry.value.activities,
        rawPositions: entry.value.raw,
        firstTsUtcMs: entry.value.firstTs,
        lastTsUtcMs: entry.value.lastTs,
      ),
  ]..sort((a, b) => b.year.compareTo(a.year));
}

/// Mutable accumulator behind [yearBreakdown].
class _YearAcc {
  _YearAcc(int ts)
      : firstTs = ts,
        lastTs = ts;

  int inFile = 0;
  int thinned = 0;
  int kept = 0;
  int path = 0;
  int visits = 0;
  int activities = 0;
  int raw = 0;
  int firstTs;
  int lastTs;

  void touch(int ts) {
    if (ts < firstTs) firstTs = ts;
    if (ts > lastTs) lastTs = ts;
  }
}
