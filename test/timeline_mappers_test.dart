import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/timeline_mappers.dart';
import 'package:trail/services/import/timeline_models.dart';
import 'package:trail/services/import/timeline_splitter.dart';

/// A map that blows up on one key, to exercise the "never throw, keep
/// what was already mapped" contract without needing a corrupt file.
class _ExplodingMap extends MapView<String, dynamic> {
  _ExplodingMap(super.map, this.boobyTrap);

  final String boobyTrap;

  @override
  dynamic operator [](Object? key) {
    if (key == boobyTrap) throw StateError('boom');
    return super[key];
  }
}

String fixturePath(String name) =>
    '${Directory.current.path}/test/fixtures/timeline/$name';

int utcMs(int y, int m, int d, int hh, int mm) =>
    DateTime.utc(y, m, d, hh, mm).millisecondsSinceEpoch;

Map<String, dynamic> pathSegment(List<Map<String, dynamic>> points) =>
    <String, dynamic>{'timelinePath': points};

Map<String, dynamic> visitSegment({
  Object? latLng = '51.5°, -0.1°',
  Object? startTime = '2026-03-01T11:00:00.000+01:00',
  Object? endTime = '2026-03-01T12:30:00.000+01:00',
  Object? semanticType = 'HOME',
  Object? placeId = 'ChIJ_test',
}) =>
    <String, dynamic>{
      if (startTime != null) 'startTime': startTime,
      if (endTime != null) 'endTime': endTime,
      'visit': <String, dynamic>{
        'topCandidate': <String, dynamic>{
          if (semanticType != null) 'semanticType': semanticType,
          if (placeId != null) 'placeId': placeId,
          'placeLocation': <String, dynamic>{
            if (latLng != null) 'latLng': latLng,
          },
        },
      },
    };

Map<String, dynamic> activitySegment({
  Object? start = '51.5°, -0.1°',
  Object? end = '51.52°, -0.09°',
  Object? startTime = '2026-03-01T13:00:00.000+01:00',
  Object? endTime = '2026-03-01T13:40:00.000+01:00',
  Object? type = 'WALKING',
  Object? distanceMeters = 2345.6,
}) =>
    <String, dynamic>{
      if (startTime != null) 'startTime': startTime,
      if (endTime != null) 'endTime': endTime,
      'activity': <String, dynamic>{
        'start': <String, dynamic>{if (start != null) 'latLng': start},
        'end': <String, dynamic>{if (end != null) 'latLng': end},
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
        if (type != null) 'topCandidate': <String, dynamic>{'type': type},
      },
    };

Map<String, dynamic> rawPosition({
  String key = 'LatLng',
  Object? latLng = '51.5074°, -0.1278°',
  Object? timestamp = '2026-03-01T10:05:00.000+01:00',
  Object? accuracy = 20,
  Object? altitude = 35.5,
  Object? speed = 1.4,
  Object? source = 'GPS',
}) =>
    <String, dynamic>{
      'position': <String, dynamic>{
        if (latLng != null) key: latLng,
        if (timestamp != null) 'timestamp': timestamp,
        if (accuracy != null) 'accuracyMeters': accuracy,
        if (altitude != null) 'altitudeMeters': altitude,
        if (speed != null) 'speedMetersPerSecond': speed,
        if (source != null) 'source': source,
      },
    };

void main() {
  group('parseLatLng', () {
    test('reads the Android degree-sign spelling', () {
      expect(parseLatLng('51.5074°, -0.1278°'),
          (lat: 51.5074, lon: -0.1278));
      expect(parseLatLng('51.5074°,-0.1278°'), (lat: 51.5074, lon: -0.1278));
      expect(parseLatLng('  51.5074°  ,  -0.1278°  '),
          (lat: 51.5074, lon: -0.1278));
    });

    test('reads the same pair without degree signs', () {
      expect(parseLatLng('51.5074, -0.1278'), (lat: 51.5074, lon: -0.1278));
      expect(parseLatLng('51,-0.1278'), (lat: 51.0, lon: -0.1278));
      expect(parseLatLng('+51.5,+0.1'), (lat: 51.5, lon: 0.1));
    });

    test('reads the iOS geo: spelling, with or without parameters', () {
      expect(parseLatLng('geo:51.5,-0.12'), (lat: 51.5, lon: -0.12));
      expect(parseLatLng('GEO:51.5,-0.12'), (lat: 51.5, lon: -0.12));
      expect(parseLatLng('geo:51.5,-0.12;u=35'), (lat: 51.5, lon: -0.12));
    });

    test('reads map spellings, numeric or string valued', () {
      expect(parseLatLng(<String, dynamic>{'latitude': 51.5, 'longitude': -0.1}),
          (lat: 51.5, lon: -0.1));
      expect(parseLatLng(<String, dynamic>{'lat': 51.5, 'lng': -0.1}),
          (lat: 51.5, lon: -0.1));
      expect(parseLatLng(<String, dynamic>{'lat': '51.5', 'lng': '-0.1'}),
          (lat: 51.5, lon: -0.1));
      expect(parseLatLng(<String, dynamic>{'lat': 51.5}), isNull);
    });

    test('rejects out-of-range, NaN, null island and garbage', () {
      expect(parseLatLng('90.1°, 0°'), isNull);
      expect(parseLatLng('-90.1°, 0°'), isNull);
      expect(parseLatLng('0°, 180.1°'), isNull);
      expect(parseLatLng('0°, -180.1°'), isNull);
      expect(parseLatLng('0°, 0°'), isNull);
      expect(parseLatLng('0, 0'), isNull);
      expect(parseLatLng(<String, dynamic>{'lat': double.nan, 'lng': 1.0}),
          isNull);
      expect(
          parseLatLng(
              <String, dynamic>{'lat': 1.0, 'lng': double.infinity}),
          isNull);
      expect(parseLatLng(null), isNull);
      expect(parseLatLng(''), isNull);
      expect(parseLatLng('not a coordinate'), isNull);
      expect(parseLatLng('51.5'), isNull);
      expect(parseLatLng('51.5, -0.1, 12'), isNull);
      expect(parseLatLng(42), isNull);
    });

    test('keeps the extremes that are legal', () {
      expect(parseLatLng('90, 180'), (lat: 90.0, lon: 180.0));
      expect(parseLatLng('-90, -180'), (lat: -90.0, lon: -180.0));
    });
  });

  group('parseIsoUtcMs', () {
    test('honours the offset in the string', () {
      expect(parseIsoUtcMs('2026-03-01T10:00:00.000+01:00'),
          utcMs(2026, 3, 1, 9, 0));
      expect(parseIsoUtcMs('2026-03-01T10:00:00.000-04:00'),
          utcMs(2026, 3, 1, 14, 0));
      expect(parseIsoUtcMs('2026-03-01T10:00:00.000-0400'),
          utcMs(2026, 3, 1, 14, 0));
    });

    test('accepts Z, fraction-less and lower-case forms', () {
      expect(parseIsoUtcMs('2026-03-01T10:00:00Z'), utcMs(2026, 3, 1, 10, 0));
      expect(parseIsoUtcMs('2026-03-01T10:00:00.000Z'),
          utcMs(2026, 3, 1, 10, 0));
      expect(parseIsoUtcMs('2026-03-01t10:00:00z'), utcMs(2026, 3, 1, 10, 0));
      expect(parseIsoUtcMs('  2026-03-01T10:00:00Z  '),
          utcMs(2026, 3, 1, 10, 0));
    });

    test('reads a zone-less timestamp as UTC, not device local', () {
      expect(parseIsoUtcMs('2026-03-01T10:00:00'), utcMs(2026, 3, 1, 10, 0));
      expect(parseIsoUtcMs('2026-03-01T10:00'), utcMs(2026, 3, 1, 10, 0));
    });

    test('rejects garbage, date-only and non-strings', () {
      expect(parseIsoUtcMs('2026-03-01'), isNull);
      expect(parseIsoUtcMs('yesterday'), isNull);
      expect(parseIsoUtcMs(''), isNull);
      expect(parseIsoUtcMs('2026-03-01T99:99:99Z'), isNull);
      expect(parseIsoUtcMs(null), isNull);
      expect(parseIsoUtcMs(1772000000000), isNull);
    });

    test('rejects impossible clock and calendar values', () {
      expect(parseIsoUtcMs('2026-03-01T25:00:00Z'), isNull);
      expect(parseIsoUtcMs('2026-03-01T10:60:00Z'), isNull);
      expect(parseIsoUtcMs('2026-02-31T10:00:00Z'), isNull);
      expect(parseIsoUtcMs('2026-13-01T10:00:00Z'), isNull);
      expect(parseIsoUtcMs('2026-00-10T10:00:00Z'), isNull);
      expect(parseIsoUtcMs('2026-03-01T10:00:00+25:00'), isNull);
      // A leap day that does exist still parses.
      expect(parseIsoUtcMs('2028-02-29T10:00:00Z'), utcMs(2028, 2, 29, 10, 0));
    });
  });

  group('sanitizeNoteToken', () {
    test('keeps only [A-Za-z0-9_-]', () {
      expect(sanitizeNoteToken('ChIJ_place-123'), 'ChIJ_place-123');
      expect(sanitizeNoteToken('a:b:c'), 'abc');
      expect(sanitizeNoteToken('gmaps:raw:GPS'), 'gmapsrawGPS');
      expect(sanitizeNoteToken('drop spaces, é and °'), 'dropspacesand');
      expect(sanitizeNoteToken(''), '');
      expect(sanitizeNoteToken(':::'), '');
    });

    test('caps the result at 64 characters', () {
      expect(sanitizeNoteToken('x' * 200).length, kNoteTokenMaxLength);
      expect(sanitizeNoteToken('::::${'y' * 70}').length,
          kNoteTokenMaxLength);
    });
  });

  group('mapSemanticSegment · timelinePath', () {
    test('yields one path candidate per point', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(
        pathSegment(<Map<String, dynamic>>[
          <String, dynamic>{
            'point': '51.5074°, -0.1278°',
            'time': '2026-03-01T10:00:00.000+01:00',
          },
          <String, dynamic>{
            'point': '51.5080°, -0.1270°',
            'time': '2026-03-01T10:10:00.000+01:00',
          },
        ]),
        counts,
      );
      expect(got.length, 2);
      expect(got.every((c) => c.kind == ImportKind.path), isTrue);
      expect(got.every((c) => c.note == 'gmaps:path'), isTrue);
      expect(got.every((c) => c.accuracyM == null), isTrue);
      expect(got.first.tsUtcMs, utcMs(2026, 3, 1, 9, 0));
      expect(got.first.lat, 51.5074);
      expect(got.first.lon, -0.1278);
      expect(counts.pathPoints, 2);
      expect(counts.candidates, 2);
      expect(counts.malformedElements, 0);
    });

    test('keeps the good points when one is unparseable', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(
        pathSegment(<Map<String, dynamic>>[
          <String, dynamic>{
            'point': '51.5°, -0.1°',
            'time': '2026-03-01T10:00:00.000+01:00',
          },
          <String, dynamic>{'point': 'rubbish', 'time': 'also rubbish'},
          <String, dynamic>{'point': '51.6°, -0.2°'},
          <String, dynamic>{
            'point': '0°, 0°',
            'time': '2026-03-01T10:20:00.000+01:00',
          },
          <String, dynamic>{
            'point': '51.7°, -0.3°',
            'time': '2026-03-01T10:30:00.000+01:00',
          },
        ]),
        counts,
      );
      expect(got.length, 2);
      expect(counts.pathPoints, 2);
      expect(counts.malformedElements, 3);
      expect(counts.candidates, 2);
    });

    test('an empty path is recognised but yields nothing', () {
      final counts = ImportCounts();
      expect(mapSemanticSegment(pathSegment(const []), counts), isEmpty);
      expect(counts.ignoredElements, 0);
      expect(counts.malformedElements, 0);
    });
  });

  group('mapSemanticSegment · visit', () {
    test('yields a start/end pair at the place location', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(visitSegment(), counts);
      expect(got.length, 2);
      expect(got[0].kind, ImportKind.visitStart);
      expect(got[1].kind, ImportKind.visitEnd);
      expect(got[0].tsUtcMs, utcMs(2026, 3, 1, 10, 0));
      expect(got[1].tsUtcMs, utcMs(2026, 3, 1, 11, 30));
      expect(got[0].lat, 51.5);
      expect(got[1].lon, -0.1);
      expect(got[0].note, 'gmaps:visit:HOME:ChIJ_test');
      expect(got[1].note, got[0].note);
      expect(got.every((c) => c.alwaysKeep), isTrue);
      expect(counts.visits, 1);
      expect(counts.candidates, 2);
    });

    test('falls back to UNKNOWN / - for missing note parts', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(
        visitSegment(semanticType: null, placeId: null),
        counts,
      );
      expect(got.first.note, 'gmaps:visit:UNKNOWN:-');
      expect(counts.visits, 1);
    });

    test('sanitises note tokens so they cannot inject separators', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(
        visitSegment(semanticType: 'HO:ME', placeId: 'a:b c:d'),
        counts,
      );
      expect(got.first.note, 'gmaps:visit:HOME:abcd');
    });

    test('accepts the iOS placeID spelling and a bare-string location', () {
      final counts = ImportCounts();
      final segment = visitSegment(placeId: null, latLng: 'geo:40.71,-74.00');
      (segment['visit']['topCandidate'] as Map<String, dynamic>)['placeID'] =
          'ChIJ_ios';
      final got = mapSemanticSegment(segment, counts);
      expect(got.first.note, 'gmaps:visit:HOME:ChIJ_ios');
      expect(got.first.lat, 40.71);
    });

    test('is malformed, and yields nothing, when a half is missing', () {
      for (final broken in <Map<String, dynamic>>[
        visitSegment(endTime: null),
        visitSegment(startTime: null),
        visitSegment(latLng: null),
        visitSegment(latLng: '0°, 0°'),
        visitSegment(startTime: 'not a time'),
      ]) {
        final counts = ImportCounts();
        expect(mapSemanticSegment(broken, counts), isEmpty);
        expect(counts.malformedElements, 1);
        expect(counts.visits, 0);
        expect(counts.candidates, 0);
      }
    });
  });

  group('mapSemanticSegment · activity', () {
    test('yields start and end candidates at their own endpoints', () {
      final counts = ImportCounts();
      final got = mapSemanticSegment(activitySegment(), counts);
      expect(got.length, 2);
      expect(got[0].kind, ImportKind.activityStart);
      expect(got[1].kind, ImportKind.activityEnd);
      expect(got[0].lat, 51.5);
      expect(got[1].lat, 51.52);
      expect(got[0].tsUtcMs, utcMs(2026, 3, 1, 12, 0));
      expect(got[1].tsUtcMs, utcMs(2026, 3, 1, 12, 40));
      expect(got[0].note, 'gmaps:activity:WALKING:2346m');
      expect(got[1].note, got[0].note);
      expect(got.any((c) => c.alwaysKeep), isFalse);
      expect(counts.activities, 1);
      expect(counts.candidates, 2);
    });

    test('rounds the distance and tolerates a string distance', () {
      final counts = ImportCounts();
      expect(
        mapSemanticSegment(activitySegment(distanceMeters: '1200'), counts)
            .first
            .note,
        'gmaps:activity:WALKING:1200m',
      );
      expect(
        mapSemanticSegment(activitySegment(distanceMeters: 0.4), counts)
            .first
            .note,
        'gmaps:activity:WALKING:0m',
      );
    });

    test('falls back for a missing type or distance', () {
      final counts = ImportCounts();
      expect(
        mapSemanticSegment(
                activitySegment(type: null, distanceMeters: null), counts)
            .first
            .note,
        'gmaps:activity:UNKNOWN:-m',
      );
      expect(
        mapSemanticSegment(activitySegment(distanceMeters: 'far'), counts)
            .first
            .note,
        'gmaps:activity:WALKING:-m',
      );
    });

    test('is malformed, and yields nothing, when an endpoint is missing', () {
      for (final broken in <Map<String, dynamic>>[
        activitySegment(start: null),
        activitySegment(end: null),
        activitySegment(startTime: null),
        activitySegment(endTime: null),
      ]) {
        final counts = ImportCounts();
        expect(mapSemanticSegment(broken, counts), isEmpty);
        expect(counts.malformedElements, 1);
        expect(counts.activities, 0);
      }
    });
  });

  group('mapSemanticSegment · ignored and malformed', () {
    test('timelineMemory is ignored, not malformed', () {
      final counts = ImportCounts();
      expect(
        mapSemanticSegment(
          <String, dynamic>{
            'timelineMemory': <String, dynamic>{'label': 'Weekend'},
          },
          counts,
        ),
        isEmpty,
      );
      expect(counts.ignoredElements, 1);
      expect(counts.malformedElements, 0);
    });

    test('unknown and empty shapes are ignored', () {
      final counts = ImportCounts();
      mapSemanticSegment(<String, dynamic>{}, counts);
      mapSemanticSegment(<String, dynamic>{'somethingNew2027': 1}, counts);
      mapSemanticSegment(
          <String, dynamic>{'timelinePath': 'not a list'}, counts);
      expect(counts.ignoredElements, 3);
      expect(counts.candidates, 0);
    });

    test('a throwing element keeps what was already mapped', () {
      final counts = ImportCounts();
      final segment = _ExplodingMap(<String, dynamic>{
        ...pathSegment(<Map<String, dynamic>>[
          <String, dynamic>{
            'point': '51.5°, -0.1°',
            'time': '2026-03-01T10:00:00.000+01:00',
          },
        ]),
        ...visitSegment(),
      }, 'visit');
      final got = mapSemanticSegment(segment, counts);
      expect(got.length, 1);
      expect(got.single.kind, ImportKind.path);
      expect(counts.pathPoints, 1);
      expect(counts.malformedElements, 1);
      expect(counts.visits, 0);
    });

    test('one bad element in a list does not lose the others', () {
      final counts = ImportCounts();
      final out = <ImportCandidate>[];
      for (final element in <Map<String, dynamic>>[
        visitSegment(),
        <String, dynamic>{'visit': 'not a map at all'},
        visitSegment(latLng: null),
        <String, dynamic>{'timelineMemory': <String, dynamic>{}},
        activitySegment(),
      ]) {
        out.addAll(mapSemanticSegment(element, counts));
      }
      expect(out.length, 4);
      expect(counts.visits, 1);
      expect(counts.activities, 1);
      expect(counts.malformedElements, 1);
      expect(counts.ignoredElements, 2);
      expect(counts.candidates, out.length);
    });
  });

  group('mapRawSignal', () {
    test('maps a position with its sensor columns', () {
      final counts = ImportCounts();
      final got = mapRawSignal(rawPosition(), counts);
      expect(got.length, 1);
      final c = got.single;
      expect(c.kind, ImportKind.raw);
      expect(c.note, 'gmaps:raw:GPS');
      expect(c.tsUtcMs, utcMs(2026, 3, 1, 9, 5));
      expect(c.lat, 51.5074);
      expect(c.lon, -0.1278);
      expect(c.accuracyM, 20);
      expect(c.altitudeM, 35.5);
      expect(c.speedMps, 1.4);
      expect(counts.rawPositions, 1);
      expect(counts.candidates, 1);
    });

    test('accepts LatLng, latLng and latlng', () {
      for (final key in <String>['LatLng', 'latLng', 'latlng']) {
        final counts = ImportCounts();
        expect(mapRawSignal(rawPosition(key: key), counts).length, 1,
            reason: 'key $key');
      }
    });

    test('rejects accuracy over 100 m, keeps the boundary', () {
      final counts = ImportCounts();
      expect(mapRawSignal(rawPosition(accuracy: 150), counts), isEmpty);
      expect(mapRawSignal(rawPosition(accuracy: 100.1), counts), isEmpty);
      expect(counts.rawRejectedAccuracy, 2);
      expect(counts.malformedElements, 0);

      expect(mapRawSignal(rawPosition(accuracy: 100), counts).length, 1);
      expect(mapRawSignal(rawPosition(accuracy: '99.5'), counts).length, 1);
      expect(counts.rawPositions, 2);
      expect(counts.rawRejectedAccuracy, 2);
    });

    test('keeps a position with no accuracy at all', () {
      final counts = ImportCounts();
      final got = mapRawSignal(
        rawPosition(accuracy: null, altitude: null, speed: null),
        counts,
      );
      expect(got.single.accuracyM, isNull);
      expect(got.single.altitudeM, isNull);
      expect(got.single.speedMps, isNull);
      expect(counts.rawPositions, 1);
    });

    test('falls back to UNKNOWN for a missing or unusable source', () {
      final counts = ImportCounts();
      expect(mapRawSignal(rawPosition(source: null), counts).single.note,
          'gmaps:raw:UNKNOWN');
      expect(mapRawSignal(rawPosition(source: ':::'), counts).single.note,
          'gmaps:raw:UNKNOWN');
      expect(mapRawSignal(rawPosition(source: 'WIFI'), counts).single.note,
          'gmaps:raw:WIFI');
    });

    test('ignores wifiScan, activityRecord and unknown shapes', () {
      final counts = ImportCounts();
      for (final element in <Map<String, dynamic>>[
        <String, dynamic>{'wifiScan': <String, dynamic>{'devicesRecords': []}},
        <String, dynamic>{'activityRecord': <String, dynamic>{}},
        <String, dynamic>{'somethingNew2027': 1},
        <String, dynamic>{},
        <String, dynamic>{'position': 'not a map'},
      ]) {
        expect(mapRawSignal(element, counts), isEmpty);
      }
      expect(counts.ignoredElements, 5);
      expect(counts.malformedElements, 0);
      expect(counts.rawRejectedAccuracy, 0);
    });

    test('counts a position with bad coordinates or time as malformed', () {
      final counts = ImportCounts();
      expect(mapRawSignal(rawPosition(latLng: null), counts), isEmpty);
      expect(mapRawSignal(rawPosition(latLng: '0°, 0°'), counts), isEmpty);
      expect(mapRawSignal(rawPosition(latLng: '91°, 0°'), counts), isEmpty);
      expect(mapRawSignal(rawPosition(timestamp: null), counts), isEmpty);
      expect(mapRawSignal(rawPosition(timestamp: 'soon'), counts), isEmpty);
      expect(counts.malformedElements, 5);
      expect(counts.rawPositions, 0);
    });

    test('never throws on a hostile element', () {
      final counts = ImportCounts();
      expect(
        mapRawSignal(_ExplodingMap(rawPosition(), 'position'), counts),
        isEmpty,
      );
      expect(counts.malformedElements, 1);
    });
  });

  group('mapUserLocationProfile', () {
    test('reads HOME and WORK from frequentPlaces', () {
      final places = mapUserLocationProfile(<String, dynamic>{
        'frequentPlaces': <Map<String, dynamic>>[
          <String, dynamic>{
            'placeLocation': '51.5000°, -0.1000°',
            'label': 'HOME',
          },
          <String, dynamic>{
            'placeLocation': '51.5300°, -0.0800°',
            'label': 'WORK',
          },
        ],
      });
      expect(places.map((p) => p.label).toList(), <String>['HOME', 'WORK']);
      expect(places.first.lat, 51.5);
      expect(places.first.lon, -0.1);
    });

    test('skips entries without usable coordinates', () {
      final places = mapUserLocationProfile(<String, dynamic>{
        'frequentPlaces': <Object>[
          <String, dynamic>{'placeLocation': 'nowhere', 'label': 'HOME'},
          <String, dynamic>{'label': 'WORK'},
          <String, dynamic>{'placeLocation': '0°, 0°', 'label': 'HOME'},
          'not a map',
          <String, dynamic>{'placeLocation': '51.5°, -0.1°'},
        ],
      });
      expect(places.length, 1);
      expect(places.single.label, 'UNKNOWN');
    });

    test('returns empty for a missing or unusable profile', () {
      expect(mapUserLocationProfile(<String, dynamic>{}), isEmpty);
      expect(
        mapUserLocationProfile(
            <String, dynamic>{'frequentPlaces': 'not a list'}),
        isEmpty,
      );
    });

    test('never throws on a hostile element', () {
      expect(
        mapUserLocationProfile(
            _ExplodingMap(<String, dynamic>{}, 'frequentPlaces')),
        isEmpty,
      );
    });
  });

  group('end to end over the fixtures', () {
    test('the Android fixture maps to exactly the expected candidates',
        () async {
      final counts = ImportCounts();
      final candidates = <ImportCandidate>[];
      final places = <ImportFrequentPlace>[];

      await for (final element
          in splitTimelineFile(fixturePath('android_small.json'))) {
        final decoded = decodeElement(element) as Map<String, dynamic>;
        switch (element.section) {
          case 'semanticSegments':
            candidates.addAll(mapSemanticSegment(decoded, counts));
          case 'rawSignals':
            candidates.addAll(mapRawSignal(decoded, counts));
          case 'userLocationProfile':
            places.addAll(mapUserLocationProfile(decoded));
        }
      }

      expect(counts.pathPoints, 6);
      expect(counts.visits, 1);
      expect(counts.activities, 1);
      expect(counts.rawPositions, 1);
      expect(counts.rawRejectedAccuracy, 1);
      // timelineMemory + wifiScan.
      expect(counts.ignoredElements, 2);
      expect(counts.malformedElements, 0);
      expect(counts.candidates, 11);
      expect(candidates.length, counts.candidates);

      expect(
        candidates.map((c) => c.note).toSet(),
        <String>{
          'gmaps:path',
          'gmaps:visit:HOME:ChIJ_fixture-123',
          'gmaps:activity:WALKING:2346m',
          'gmaps:raw:GPS',
        },
      );
      expect(candidates.where((c) => c.kind == ImportKind.raw).single.altitudeM,
          35.5);
      expect(places.map((p) => p.label).toList(), <String>['HOME', 'WORK']);
    });

    test('the iOS fixture maps its geo: visits and activities', () async {
      final counts = ImportCounts();
      final candidates = <ImportCandidate>[];
      await for (final element
          in splitTimelineFile(fixturePath('ios_small.json'))) {
        expect(element.section, kTimelineRootSection);
        candidates.addAll(mapSemanticSegment(
          decodeElement(element) as Map<String, dynamic>,
          counts,
        ));
      }

      expect(counts.visits, 1);
      expect(counts.activities, 1);
      // iOS path points carry durationMinutesOffsetFromStartTime, not
      // `time`, so they cannot be placed yet — see OPEN in the handoff.
      expect(counts.pathPoints, 0);
      expect(counts.malformedElements, 2);
      expect(
        candidates.map((c) => c.note).toSet(),
        <String>{
          'gmaps:visit:WORK:ChIJ_ios_fixture',
          'gmaps:activity:IN_PASSENGER_VEHICLE:1200m',
        },
      );
      expect(candidates.first.lat, 40.713);
      expect(candidates.first.tsUtcMs, utcMs(2026, 4, 2, 13, 0));
    });
  });
}
