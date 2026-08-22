/// Shared value types for the Google Maps Timeline import (0.16.0).
///
/// Everything here is plain Dart so the splitter, mappers, thinning engine
/// and the isolate pipeline can all be unit-tested without Flutter. See
/// docs/TIMELINE_IMPORT.md for the format and the rules these encode.
library;

/// Where a candidate row came from inside the export. Drives the
/// provenance `note` prefix and the "always keep" rules in thinning.
enum ImportKind {
  /// `semanticSegments[].timelinePath[]` breadcrumb.
  path,

  /// `semanticSegments[].visit` start (placeLocation at `startTime`).
  visitStart,

  /// `semanticSegments[].visit` end (placeLocation at `endTime`).
  visitEnd,

  /// `semanticSegments[].activity.start` at `startTime`.
  activityStart,

  /// `semanticSegments[].activity.end` at `endTime`.
  activityEnd,

  /// `rawSignals[].position` (the only records with accuracy/alt/speed).
  raw,
}

/// One point that *may* become a `pings` row. Immutable, compact.
class ImportCandidate {
  const ImportCandidate({
    required this.tsUtcMs,
    required this.lat,
    required this.lon,
    required this.kind,
    required this.note,
    this.accuracyM,
    this.altitudeM,
    this.speedMps,
  });

  /// Epoch milliseconds, UTC (the ISO offset has already been applied).
  final int tsUtcMs;
  final double lat;
  final double lon;
  final ImportKind kind;

  /// Provenance, greppable and undoable. Fixed prefixes:
  /// `gmaps:path`, `gmaps:visit:<semanticType>:<placeId>`,
  /// `gmaps:activity:<type>:<distanceM>m`, `gmaps:raw:<source>`.
  final String note;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;

  /// Visit endpoints are never thinned away (they are the semantically
  /// meaningful points); everything else competes on time/distance.
  bool get alwaysKeep =>
      kind == ImportKind.visitStart || kind == ImportKind.visitEnd;

  @override
  String toString() =>
      'ImportCandidate($kind ts=$tsUtcMs $lat,$lon acc=$accuracyM note=$note)';
}

/// Thinning presets (docs/TIMELINE_IMPORT.md "Thinning"). Keep a candidate
/// when Δt ≥ [minGap] OR distance ≥ [minDistanceM] from the last kept row.
/// [full] keeps everything (the UI warns above 50 000 projected rows).
enum ImportPreset {
  normal(Duration(minutes: 15), 250),
  coarse(Duration(hours: 1), 1000),
  full(Duration.zero, 0);

  const ImportPreset(this.minGap, this.minDistanceM);
  final Duration minGap;
  final double minDistanceM;

  bool get isFull => this == ImportPreset.full;

  String get label => switch (this) {
        ImportPreset.normal => 'Normal · 15 min / 250 m',
        ImportPreset.coarse => 'Coarse · 60 min / 1 km',
        ImportPreset.full => 'Full · keep every point',
      };
}

/// Per-section parse accounting, reported to the user so silent format
/// drift shows up as "N elements skipped" instead of a blank import.
class ImportCounts {
  int pathPoints = 0;
  int visits = 0;
  int activities = 0;
  int rawPositions = 0;

  /// Elements whose shape we did not recognise (wifiScan, activityRecord,
  /// timelineMemory, future sections) — expected, not an error.
  int ignoredElements = 0;

  /// Elements we tried to map and failed (bad JSON, bad coordinates,
  /// missing timestamps). Never fatal for the file.
  int malformedElements = 0;

  /// Raw positions dropped for accuracy > 100 m.
  int rawRejectedAccuracy = 0;

  int get candidates => pathPoints + visits * 2 + activities * 2 + rawPositions;

  Map<String, int> toJson() => {
        'pathPoints': pathPoints,
        'visits': visits,
        'activities': activities,
        'rawPositions': rawPositions,
        'ignoredElements': ignoredElements,
        'malformedElements': malformedElements,
        'rawRejectedAccuracy': rawRejectedAccuracy,
      };

  void addAll(ImportCounts other) {
    pathPoints += other.pathPoints;
    visits += other.visits;
    activities += other.activities;
    rawPositions += other.rawPositions;
    ignoredElements += other.ignoredElements;
    malformedElements += other.malformedElements;
    rawRejectedAccuracy += other.rawRejectedAccuracy;
  }
}

/// A frequent place from `userLocationProfile.frequentPlaces[]` —
/// the optional "set home location from Google" feature.
class ImportFrequentPlace {
  const ImportFrequentPlace({required this.label, required this.lat, required this.lon});
  final String label; // HOME | WORK | …
  final double lat;
  final double lon;
}
