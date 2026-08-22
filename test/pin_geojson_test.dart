import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/map/pin_geojson.dart';

Ping _fix({
  required int id,
  required DateTime ts,
  double? lat = 51.5,
  double? lon = -0.12,
}) =>
    Ping(
      id: id,
      timestampUtc: ts,
      lat: lat,
      lon: lon,
      source: PingSource.scheduled,
    );

DateTime _t(int hour, [int minute = 0]) => DateTime.utc(2026, 8, 1, hour, minute);

PinColumns _cols(List<int> tsMs, {List<int>? ids}) => PinColumns(
      ids: Int64List.fromList(ids ?? [for (var i = 0; i < tsMs.length; i++) i + 1]),
      tsMs: Int64List.fromList(tsMs),
      lats: Float64List.fromList([for (var i = 0; i < tsMs.length; i++) 50.0 + i]),
      lons: Float64List.fromList([for (var i = 0; i < tsMs.length; i++) -1.0 - i]),
    );

/// Brute-force twin of [visibleCount] for the randomised comparison.
int _visibleLinear(Int64List tsMs, int max) {
  var n = 0;
  for (final t in tsMs) {
    if (t <= max) n++;
  }
  return n;
}

void main() {
  group('buildPinSnapshot', () {
    test('excludes null-coordinate rows BEFORE the columns exist', () {
      final pings = [
        _fix(id: 1, ts: _t(0)),
        Ping(id: 2, timestampUtc: _t(1), source: PingSource.noFix),
        _fix(id: 3, ts: _t(2), lat: null),
        _fix(id: 4, ts: _t(3), lon: null),
        _fix(id: 5, ts: _t(4)),
      ];
      final snap = buildPinSnapshot(pings);
      expect(snap.length, 2);
      expect(snap.chrono.map((p) => p.id), [1, 5]);
      expect(snap.cols.ids, [1, 5]);
      expect(snap.cols.tsMs, [
        _t(0).millisecondsSinceEpoch,
        _t(4).millisecondsSinceEpoch,
      ]);
      expect(snap.cols.lats.length, 2);
      expect(snap.cols.lons.length, 2);
      expect(snap.byId.keys, unorderedEquals([1, 5]));
      expect(identical(snap.byId[5], pings[4]), isTrue);
    });

    test('excludes non-finite coordinates (a NaN would poison the upload)',
        () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0), lat: double.nan),
        _fix(id: 2, ts: _t(1), lon: double.infinity),
        _fix(id: 3, ts: _t(2)),
      ]);
      expect(snap.cols.ids, [3]);
    });

    test('empty input → the shared empty snapshot', () {
      final snap = buildPinSnapshot(const []);
      expect(snap.isEmpty, isTrue);
      expect(snap.cols.isEmpty, isTrue);
      expect(identical(snap, PinSnapshot.empty), isTrue);
    });

    test('rows without a rowid get unique negative placeholder ids', () {
      final a = Ping(
          timestampUtc: _t(0), lat: 1, lon: 2, source: PingSource.scheduled);
      final b = Ping(
          timestampUtc: _t(1), lat: 1, lon: 2, source: PingSource.scheduled);
      final snap = buildPinSnapshot([a, b]);
      expect(snap.cols.ids, [-1, -2]);
      expect(identical(snap.byId[-1], a), isTrue);
      expect(identical(snap.byId[-2], b), isTrue);
    });

    test('preserves DAO order (time-ascending) and keeps duplicates', () {
      final dupe = _t(5);
      final snap = buildPinSnapshot([
        _fix(id: 10, ts: _t(4)),
        _fix(id: 11, ts: dupe),
        _fix(id: 12, ts: dupe),
        _fix(id: 13, ts: _t(6)),
      ]);
      expect(snap.cols.ids, [10, 11, 12, 13]);
      expect(snap.cols.tsMs[1], snap.cols.tsMs[2]);
    });
  });

  group('buildPinsGeoJson', () {
    test('empty columns → the literal empty FeatureCollection', () {
      expect(buildPinsGeoJson(PinColumns.empty), emptyFeatureCollection);
      expect(jsonDecode(emptyFeatureCollection),
          {'type': 'FeatureCollection', 'features': []});
    });

    test('one Feature per fix with [lon, lat] order and id/ts properties',
        () {
      final c = PinColumns(
        ids: Int64List.fromList([7, 8]),
        tsMs: Int64List.fromList([1000, 2000]),
        lats: Float64List.fromList([51.5, 52.25]),
        lons: Float64List.fromList([-0.125, 1.0]),
      );
      final json = buildPinsGeoJson(c);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['type'], 'FeatureCollection');
      final features = decoded['features'] as List;
      expect(features.length, 2);

      final f0 = features[0] as Map<String, dynamic>;
      expect(f0['type'], 'Feature');
      expect(f0['id'], 7);
      expect(f0['geometry'], {
        'type': 'Point',
        'coordinates': [-0.125, 51.5],
      });
      expect(f0['properties'], {'id': 7, 'ts': 1000});

      final f1 = features[1] as Map<String, dynamic>;
      expect(f1['id'], 8);
      expect((f1['geometry'] as Map)['coordinates'], [1.0, 52.25]);
      expect(f1['properties'], {'id': 8, 'ts': 2000});
    });

    test('properties carry nothing but id and ts', () {
      final json = buildPinsGeoJson(_cols([1, 2, 3]));
      final features = (jsonDecode(json) as Map)['features'] as List;
      for (final f in features) {
        expect(((f as Map)['properties'] as Map).keys, unorderedEquals(['id', 'ts']));
      }
    });

    test('round-trips through jsonDecode for realistic values', () {
      final ts0 = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch;
      final c = PinColumns(
        ids: Int64List.fromList([123456, 123457, 123458]),
        tsMs: Int64List.fromList([ts0, ts0 + 4 * 3600 * 1000, ts0 + 8 * 3600 * 1000]),
        lats: Float64List.fromList([51.50735, -33.8688, 0.0]),
        lons: Float64List.fromList([-0.12776, 151.2093, -179.999999]),
      );
      final features =
          (jsonDecode(buildPinsGeoJson(c)) as Map)['features'] as List;
      for (var i = 0; i < 3; i++) {
        final f = features[i] as Map;
        final coords = (f['geometry'] as Map)['coordinates'] as List;
        expect(coords[0], c.lons[i]);
        expect(coords[1], c.lats[i]);
        expect((f['properties'] as Map)['ts'], c.tsMs[i]);
        expect((f['properties'] as Map)['id'], c.ids[i]);
        expect(f['id'], c.ids[i]);
      }
    });

    test('negative placeholder ids serialise as integers', () {
      final c = PinColumns(
        ids: Int64List.fromList([-1]),
        tsMs: Int64List.fromList([5]),
        lats: Float64List.fromList([1]),
        lons: Float64List.fromList([2]),
      );
      final f = ((jsonDecode(buildPinsGeoJson(c)) as Map)['features'] as List)
          .single as Map;
      expect(f['id'], -1);
      expect((f['properties'] as Map)['id'], -1);
    });
  });

  group('buildSegmentsGeoJson', () {
    test('n < 2 → empty collection', () {
      expect(buildSegmentsGeoJson(PinColumns.empty), emptyFeatureCollection);
      expect(buildSegmentsGeoJson(_cols([1])), emptyFeatureCollection);
    });

    test('one two-point LineString per consecutive pair', () {
      final c = PinColumns(
        ids: Int64List.fromList([1, 2, 3]),
        tsMs: Int64List.fromList([100, 200, 300]),
        lats: Float64List.fromList([10, 11, 12]),
        lons: Float64List.fromList([20, 21, 22]),
      );
      final features =
          (jsonDecode(buildSegmentsGeoJson(c)) as Map)['features'] as List;
      expect(features.length, 2);
      final s0 = features[0] as Map;
      expect(s0['type'], 'Feature');
      expect(s0['geometry'], {
        'type': 'LineString',
        'coordinates': [
          [20, 10],
          [21, 11],
        ],
      });
      final s1 = features[1] as Map;
      expect((s1['geometry'] as Map)['coordinates'], [
        [21, 11],
        [22, 12],
      ]);
    });

    test('each segment carries the ts of its LATER endpoint', () {
      final c = _cols([100, 200, 300, 400]);
      final features =
          (jsonDecode(buildSegmentsGeoJson(c)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['ts']),
        [200, 300, 400],
      );
      // So the same `<= sliderMax` filter hides the segment INTO a future
      // pin while keeping the one into the head.
      final visibleAt300 = features
          .where((f) => ((f as Map)['properties'] as Map)['ts'] <= 300)
          .length;
      expect(visibleAt300, 2);
    });
  });

  group('tsFilter', () {
    test('literal expression shape', () {
      expect(tsFilter(10, 20), [
        'all',
        [
          '>=',
          ['get', 'ts'],
          10,
        ],
        [
          '<=',
          ['get', 'ts'],
          20,
        ],
      ]);
    });

    test('jsonEncodes to what the platform channel sends', () {
      expect(
        jsonEncode(tsFilter(1700000000000, 1700003600000)),
        '["all",[">=",["get","ts"],1700000000000],'
        '["<=",["get","ts"],1700003600000]]',
      );
    });
  });

  group('visibleCount / indexAtOrBefore / stepIndex', () {
    test('boundaries: before first, on first, on last, after last', () {
      final ts = Int64List.fromList([10, 20, 30]);
      expect(visibleCount(ts, 9), 0);
      expect(visibleCount(ts, 10), 1);
      expect(visibleCount(ts, 15), 1);
      expect(visibleCount(ts, 30), 3);
      expect(visibleCount(ts, 31), 3);
      expect(visibleCount(Int64List(0), 5), 0);
    });

    test('duplicates are all counted when on the boundary', () {
      final ts = Int64List.fromList([10, 20, 20, 20, 30]);
      expect(visibleCount(ts, 20), 4);
      expect(visibleCount(ts, 19), 1);
      expect(indexAtOrBefore(ts, 20), 3);
    });

    test('matches brute force on random ascending inputs with duplicates',
        () {
      final rng = Random(42);
      for (var trial = 0; trial < 300; trial++) {
        final n = rng.nextInt(40);
        var t = 0;
        final list = Int64List(n);
        for (var i = 0; i < n; i++) {
          // Step of 0 keeps duplicates in the mix.
          t += rng.nextInt(4);
          list[i] = t;
        }
        for (var q = -1; q <= t + 1; q++) {
          expect(visibleCount(list, q), _visibleLinear(list, q),
              reason: 'n=$n query=$q list=$list');
        }
      }
    });

    test('indexAtOrBefore is -1 when everything is later', () {
      expect(indexAtOrBefore(Int64List.fromList([5, 6]), 4), -1);
      expect(indexAtOrBefore(Int64List(0), 4), -1);
    });

    test('stepIndex parity with stepSliderTo semantics', () {
      final ts = Int64List.fromList([0, 4, 8, 8, 12, 16]);
      // Standing on the duplicate run, +1 escapes it.
      expect(stepIndex(ts, 8, 1), 4);
      // Clamps at both ends.
      expect(stepIndex(ts, 16, 1), 5);
      expect(stepIndex(ts, 0, -1), 0);
      // ±5 jumps.
      expect(stepIndex(ts, 0, 5), 5);
      expect(stepIndex(ts, 16, -5), 0);
      // Cursor before the first fix pivots on index 0.
      expect(stepIndex(ts, -100, 1), 1);
      // Empty.
      expect(stepIndex(Int64List(0), 5, 1), -1);
    });
  });

  group('effectiveSliderMax', () {
    final chrono = [
      _fix(id: 1, ts: _t(1)),
      _fix(id: 2, ts: _t(5)),
      _fix(id: 3, ts: _t(9)),
    ];

    test('null ⇒ show everything (last fix)', () {
      expect(effectiveSliderMax(null, chrono), _t(9));
    });

    test('explicit value inside the range passes through', () {
      expect(effectiveSliderMax(_t(5), chrono), _t(5));
      expect(effectiveSliderMax(_t(3, 30), chrono), _t(3, 30));
    });

    test('clamps to [first, last]', () {
      expect(effectiveSliderMax(_t(0), chrono), _t(1));
      expect(effectiveSliderMax(_t(23), chrono), _t(9));
    });
  });

  group('visibleBounds', () {
    test('covers only the first count fixes', () {
      final c = PinColumns(
        ids: Int64List.fromList([1, 2, 3]),
        tsMs: Int64List.fromList([1, 2, 3]),
        lats: Float64List.fromList([5, -5, 50]),
        lons: Float64List.fromList([1, 3, -100]),
      );
      final all = visibleBounds(c, 3);
      expect(all, (minLat: -5.0, maxLat: 50.0, minLon: -100.0, maxLon: 3.0));
      final two = visibleBounds(c, 2);
      expect(two, (minLat: -5.0, maxLat: 5.0, minLon: 1.0, maxLon: 3.0));
      final one = visibleBounds(c, 1);
      expect(one, (minLat: 5.0, maxLat: 5.0, minLon: 1.0, maxLon: 1.0));
    });
  });

  group('buildPinStyle', () {
    test('no head ⇒ plain literals + ramp', () {
      final s = buildPinStyle(
        headId: null,
        prevId: null,
        t0Ms: 0,
        t1Ms: 100,
        baseHex: '#00ff00',
        dimHex: '#003300',
      );
      expect(s.radius, kPinRadius);
      expect(s.strokeWidth, 0.5);
      expect(s.strokeOpacity, 0.6);
      expect(s.strokeColor, '#FFFFFF');
      expect(s.color, [
        'interpolate',
        ['linear'],
        ['get', 'ts'],
        0,
        '#003300',
        100,
        '#00ff00',
      ]);
    });

    test('ramp is replaced by a constant when t1 <= t0 (interpolate stops '
        'must be strictly ascending)', () {
      for (final t1 in [0, -1]) {
        final s = buildPinStyle(
          headId: 1,
          prevId: null,
          t0Ms: 0,
          t1Ms: t1,
          baseHex: '#00ff00',
          dimHex: '#003300',
        );
        expect(s.color, ['case', ['==', ['get', 'id'], 1], kHeadPinHex, '#00ff00']);
      }
    });

    test('head only ⇒ two-way case on id', () {
      final s = buildPinStyle(
        headId: 42,
        prevId: null,
        t0Ms: 0,
        t1Ms: 10,
        baseHex: '#00ff00',
        dimHex: '#003300',
      );
      final isHead = ['==', ['get', 'id'], 42];
      expect(s.radius, ['case', isHead, kHeadPinRadius, kPinRadius]);
      expect(s.strokeWidth, ['case', isHead, 1, 0.5]);
      expect(s.strokeOpacity, ['case', isHead, 0.95, 0.6]);
      expect((s.color as List).sublist(0, 3), ['case', isHead, kHeadPinHex]);
      expect((s.color as List)[3], isA<List>()); // the ramp
    });

    test('head + previous ⇒ three-way case on id', () {
      final s = buildPinStyle(
        headId: 42,
        prevId: 41,
        t0Ms: 0,
        t1Ms: 10,
        baseHex: '#00ff00',
        dimHex: '#003300',
      );
      final isHead = ['==', ['get', 'id'], 42];
      final isPrev = ['==', ['get', 'id'], 41];
      expect(s.radius, ['case', isHead, kHeadPinRadius, kPinRadius]);
      expect(s.strokeWidth, ['case', isHead, 1, isPrev, 1, 0.5]);
      expect(s.strokeOpacity, ['case', isHead, 0.95, isPrev, 0.95, 0.6]);
      final color = s.color as List;
      expect(color.sublist(0, 5), ['case', isHead, kHeadPinHex, isPrev, kPrevPinHex]);
      expect(color[5], isA<List>());
    });

    test('every expression jsonEncodes (what setLayerProperties ships)', () {
      final s = buildPinStyle(
        headId: 2,
        prevId: 1,
        t0Ms: 1700000000000,
        t1Ms: 1700003600000,
        baseHex: '#00ff00',
        dimHex: '#003300',
      );
      for (final e in [s.radius, s.color, s.strokeWidth, s.strokeOpacity]) {
        expect(() => jsonEncode(e), returnsNormally);
      }
    });
  });

  group('parsePinId / pinIdOfFeature / pickNearestPinId', () {
    test('accepts int, integral double and numeric string', () {
      expect(parsePinId(7), 7);
      expect(parsePinId(7.0), 7);
      expect(parsePinId('7'), 7);
      expect(parsePinId('7.0'), 7);
      expect(parsePinId(-3), -3);
    });

    test('rejects non-integral, non-finite and garbage', () {
      expect(parsePinId(7.5), isNull);
      expect(parsePinId(double.nan), isNull);
      expect(parsePinId('abc'), isNull);
      expect(parsePinId(null), isNull);
      expect(parsePinId([1]), isNull);
    });

    test('prefers properties.id, falls back to the top-level id', () {
      expect(pinIdOfFeature({'id': '9', 'properties': {'id': 8}}), 8);
      expect(pinIdOfFeature({'id': '9', 'properties': {}}), 9);
      expect(pinIdOfFeature({'id': '9'}), 9);
      expect(pinIdOfFeature({'properties': {'id': 'x'}}), isNull);
    });

    test('picks the feature nearest the tap', () {
      // Shape of what queryRenderedFeatures returns after jsonDecode.
      final features = [
        {
          'type': 'Feature',
          'id': '1',
          'geometry': {
            'type': 'Point',
            'coordinates': [-0.10, 51.50],
          },
          'properties': {'id': 1, 'ts': 1},
        },
        {
          'type': 'Feature',
          'id': '2',
          'geometry': {
            'type': 'Point',
            'coordinates': [-0.12, 51.51],
          },
          'properties': {'id': 2, 'ts': 2},
        },
        {
          'type': 'Feature',
          'id': '3',
          'geometry': {
            'type': 'Point',
            'coordinates': [-0.20, 51.60],
          },
          'properties': {'id': 3, 'ts': 3},
        },
      ];
      expect(pickNearestPinId(features, 51.512, -0.121), 2);
      expect(pickNearestPinId(features, 51.50, -0.10), 1);
      expect(pickNearestPinId(features, 51.59, -0.19), 3);
    });

    test('skips junk entries and returns null when nothing usable', () {
      expect(pickNearestPinId(const [], 0, 0), isNull);
      expect(pickNearestPinId(['nope', 42, null], 0, 0), isNull);
      expect(
        pickNearestPinId([
          {'properties': {'id': 'bad'}},
        ], 0, 0),
        isNull,
      );
      // A valid id with no geometry still wins when it is the only one.
      expect(
        pickNearestPinId([
          {'properties': {'id': 5}},
        ], 0, 0),
        5,
      );
    });
  });
}
