/// Element -> [ImportCandidate] mappers for the Google Maps Timeline
/// import (docs/TIMELINE_IMPORT.md "Mapping -> pings").
///
/// Google publishes no schema and the shape drifts between exports, so
/// every function here is permissive and total: it never throws, it
/// skips what it cannot read, and it records why in [ImportCounts] so
/// the import preview can say "N elements skipped" instead of silently
/// dropping half a file.
///
/// [ImportCounts] stays exact: `counts.candidates` always equals the
/// number of candidates returned. An element that can only be mapped
/// half-way (a visit missing its end time, say) is counted as malformed
/// and contributes nothing.
library;

import 'timeline_models.dart';

/// `rawSignals[].position` above this accuracy is dropped
/// (docs/TIMELINE_IMPORT.md "Mapping -> pings").
const double kRawMaxAccuracyM = 100;

/// Longest note token; also the cap in [sanitizeNoteToken].
const int kNoteTokenMaxLength = 64;

/// Maps one `semanticSegments[]` element.
///
/// `timelinePath` yields one [ImportKind.path] candidate per point,
/// `visit` a start/end pair at the place location, `activity` a
/// start/end pair at its endpoints. `timelineMemory` and anything
/// unrecognised bump [ImportCounts.ignoredElements].
List<ImportCandidate> mapSemanticSegment(
  Map<String, dynamic> element,
  ImportCounts counts,
) {
  final out = <ImportCandidate>[];
  try {
    var recognised = false;

    final path = element['timelinePath'];
    if (path is List) {
      recognised = true;
      for (final raw in path) {
        if (raw is! Map) {
          counts.malformedElements++;
          continue;
        }
        final at = parseLatLng(raw['point']);
        final ts = parseIsoUtcMs(raw['time']);
        if (at == null || ts == null) {
          counts.malformedElements++;
          continue;
        }
        out.add(ImportCandidate(
          tsUtcMs: ts,
          lat: at.lat,
          lon: at.lon,
          kind: ImportKind.path,
          note: 'gmaps:path',
        ));
        counts.pathPoints++;
      }
    }

    final visit = element['visit'];
    if (visit is Map) {
      recognised = true;
      final top = visit['topCandidate'];
      final at = top is Map ? _placeLatLng(top['placeLocation']) : null;
      final startMs = parseIsoUtcMs(element['startTime']);
      final endMs = parseIsoUtcMs(element['endTime']);
      if (at == null || startMs == null || endMs == null) {
        counts.malformedElements++;
      } else {
        final type =
            _token(top is Map ? top['semanticType'] : null, 'UNKNOWN');
        final placeId = _token(
          top is Map ? (top['placeId'] ?? top['placeID']) : null,
          '-',
        );
        final note = 'gmaps:visit:$type:$placeId';
        out.add(ImportCandidate(
          tsUtcMs: startMs,
          lat: at.lat,
          lon: at.lon,
          kind: ImportKind.visitStart,
          note: note,
        ));
        out.add(ImportCandidate(
          tsUtcMs: endMs,
          lat: at.lat,
          lon: at.lon,
          kind: ImportKind.visitEnd,
          note: note,
        ));
        counts.visits++;
      }
    }

    final activity = element['activity'];
    if (activity is Map) {
      recognised = true;
      final from = _placeLatLng(activity['start']);
      final to = _placeLatLng(activity['end']);
      final startMs = parseIsoUtcMs(element['startTime']);
      final endMs = parseIsoUtcMs(element['endTime']);
      if (from == null || to == null || startMs == null || endMs == null) {
        counts.malformedElements++;
      } else {
        final top = activity['topCandidate'];
        final type = _token(top is Map ? top['type'] : null, 'UNKNOWN');
        final metres = _toDouble(activity['distanceMeters']);
        final note =
            'gmaps:activity:$type:${metres == null ? '-' : metres.round()}m';
        out.add(ImportCandidate(
          tsUtcMs: startMs,
          lat: from.lat,
          lon: from.lon,
          kind: ImportKind.activityStart,
          note: note,
        ));
        out.add(ImportCandidate(
          tsUtcMs: endMs,
          lat: to.lat,
          lon: to.lon,
          kind: ImportKind.activityEnd,
          note: note,
        ));
        counts.activities++;
      }
    }

    if (!recognised) counts.ignoredElements++;
  } catch (_) {
    counts.malformedElements++;
  }
  return out;
}

/// Maps one `rawSignals[]` element. Only `position` carries coordinates
/// (and the only accuracy/altitude/speed in the whole export);
/// `wifiScan` / `activityRecord` / future shapes are ignored.
List<ImportCandidate> mapRawSignal(
  Map<String, dynamic> element,
  ImportCounts counts,
) {
  try {
    final position = element['position'];
    if (position is! Map) {
      counts.ignoredElements++;
      return const <ImportCandidate>[];
    }
    // The Android export spells it `LatLng`; be liberal about the case.
    final at = parseLatLng(position['LatLng'] ??
        position['latLng'] ??
        position['latlng']);
    final ts = parseIsoUtcMs(position['timestamp']);
    if (at == null || ts == null) {
      counts.malformedElements++;
      return const <ImportCandidate>[];
    }
    final accuracy = _toDouble(position['accuracyMeters']);
    if (accuracy != null && accuracy > kRawMaxAccuracyM) {
      counts.rawRejectedAccuracy++;
      return const <ImportCandidate>[];
    }
    counts.rawPositions++;
    return <ImportCandidate>[
      ImportCandidate(
        tsUtcMs: ts,
        lat: at.lat,
        lon: at.lon,
        kind: ImportKind.raw,
        note: 'gmaps:raw:${_token(position['source'], 'UNKNOWN')}',
        accuracyM: accuracy,
        altitudeM: _toDouble(position['altitudeMeters']),
        speedMps: _toDouble(position['speedMetersPerSecond']),
      ),
    ];
  } catch (_) {
    counts.malformedElements++;
    return const <ImportCandidate>[];
  }
}

/// Maps `userLocationProfile` -> the optional "set home location from
/// Google" list. Entries without usable coordinates are dropped.
List<ImportFrequentPlace> mapUserLocationProfile(Map<String, dynamic> element) {
  final out = <ImportFrequentPlace>[];
  try {
    final places = element['frequentPlaces'];
    if (places is! List) return out;
    for (final raw in places) {
      if (raw is! Map) continue;
      final at = _placeLatLng(raw['placeLocation']);
      if (at == null) continue;
      final label = raw['label'];
      out.add(ImportFrequentPlace(
        label: label is String && label.trim().isNotEmpty
            ? label.trim()
            : 'UNKNOWN',
        lat: at.lat,
        lon: at.lon,
      ));
    }
  } catch (_) {
    return out;
  }
  return out;
}

final RegExp _kPair = RegExp(
  r'^\s*([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s*°?\s*,'
  r'\s*([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s*°?\s*$',
);

/// Parses every coordinate spelling the exports use: the Android
/// `"51.5074°, -0.1278°"` (the degree sign is bytes `C2 B0` and may be
/// absent, spaces optional), the iOS `"geo:51.5,-0.12"`, and
/// `{latitude, longitude}` / `{lat, lng}` maps whose values may be
/// numbers or strings.
///
/// Returns null for anything unparseable, for NaN/infinity, for
/// |lat| > 90 or |lon| > 180, and for exactly (0, 0) — the null island
/// is a missing fix, not a place anyone has been.
({double lat, double lon})? parseLatLng(Object? value) {
  if (value is Map) {
    final lat = _toDouble(value['latitude'] ?? value['lat']);
    final lon =
        _toDouble(value['longitude'] ?? value['lng'] ?? value['lon']);
    if (lat == null || lon == null) return null;
    return _validated(lat, lon);
  }
  if (value is! String) return null;
  var s = value.trim();
  if (s.length > 4 && s.substring(0, 4).toLowerCase() == 'geo:') {
    s = s.substring(4);
    final params = s.indexOf(';');
    if (params >= 0) s = s.substring(0, params);
  }
  final m = _kPair.firstMatch(s);
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!);
  final lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null) return null;
  return _validated(lat, lon);
}

({double lat, double lon})? _validated(double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  if (lat == 0 && lon == 0) return null;
  return (lat: lat, lon: lon);
}

// Validates as it matches: DateTime.parse happily normalises `T99:99`
// into a date four days later, which is not something an export should
// be trusted to have meant.
final RegExp _kIso = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt ]([01]\d|2[0-3]):([0-5]\d)'
  r'(?::([0-5]\d|60)(?:[.,]\d+)?)?'
  r'(?:([Zz])|([+-])([01]\d|2[0-3])(?::?([0-5]\d))?)?$',
);

/// ISO-8601 -> epoch milliseconds UTC, honouring the offset in the
/// string (`2026-03-01T10:00:00.000+01:00` is 09:00 UTC). `Z`,
/// lower-case `t`/`z` and fraction-less forms are accepted; a string
/// with no zone at all is read as UTC so the result never depends on
/// the device time zone.
///
/// Returns null for anything that is not a valid date *and* time —
/// including a bare `2026-03-01`, whose meaning would be ambiguous,
/// and impossible values such as `2026-02-31` or `T25:00`.
int? parseIsoUtcMs(Object? value) {
  if (value is! String) return null;
  var s = value.trim();
  final m = _kIso.firstMatch(s);
  if (m == null) return null;

  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final probe = DateTime.utc(year, month, day);
  if (probe.month != month || probe.day != day) return null;

  // DateTime.parse wants an upper-case separator and an explicit zone.
  if (s.codeUnitAt(10) == 0x74) {
    s = '${s.substring(0, 10)}T${s.substring(11)}';
  }
  if (m.group(7) == null && m.group(8) == null) s = '${s}Z';
  try {
    return DateTime.parse(s).toUtc().millisecondsSinceEpoch;
  } on FormatException {
    return null;
  }
}

/// Strips everything but `[A-Za-z0-9_-]` and caps the result at
/// [kNoteTokenMaxLength], so a place id or an enum spelling out of a
/// future export cannot inject `:` into a `gmaps:…` note and break the
/// prefix matching that "undo last import" relies on.
String sanitizeNoteToken(String raw) {
  final buf = StringBuffer();
  for (var i = 0; i < raw.length && buf.length < kNoteTokenMaxLength; i++) {
    final c = raw.codeUnitAt(i);
    final ok = (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F ||
        c == 0x2D;
    if (ok) buf.writeCharCode(c);
  }
  return buf.toString();
}

String _token(Object? value, String fallback) {
  if (value == null) return fallback;
  final token = sanitizeNoteToken(value.toString());
  return token.isEmpty ? fallback : token;
}

/// `{latLng: "…"}` wrappers (visit `placeLocation`, activity
/// `start`/`end`) plus the bare string / bare map spellings.
({double lat, double lon})? _placeLatLng(Object? value) {
  if (value is Map) {
    final inner = value['latLng'] ?? value['LatLng'] ?? value['latlng'];
    if (inner != null) {
      final at = parseLatLng(inner);
      if (at != null) return at;
    }
  }
  return parseLatLng(value);
}

double? _toDouble(Object? value) {
  final d = switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s.trim()),
    _ => null,
  };
  if (d == null || !d.isFinite) return null;
  return d;
}
