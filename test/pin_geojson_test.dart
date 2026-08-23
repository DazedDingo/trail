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
  PingSource source = PingSource.scheduled,
}) =>
    Ping(
      id: id,
      timestampUtc: ts,
      lat: lat,
      lon: lon,
      source: source,
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

    test('stamps the source flag: 0 for live rows, 1 for imports', () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0)),
        _fix(id: 2, ts: _t(1), source: PingSource.imported),
        _fix(id: 3, ts: _t(2), source: PingSource.panic),
        _fix(id: 4, ts: _t(3), source: PingSource.boot),
      ]);
      expect(snap.cols.srcs, [
        kPinSourceLive,
        kPinSourceImported,
        kPinSourceLive,
        kPinSourceLive,
      ]);
    });

    test('srcs stays aligned with ids after coordinate-less rows drop out',
        () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0), lat: null, source: PingSource.imported),
        _fix(id: 2, ts: _t(1), source: PingSource.imported),
        _fix(id: 3, ts: _t(2)),
      ]);
      expect(snap.cols.ids, [2, 3]);
      expect(snap.cols.srcs, [kPinSourceImported, kPinSourceLive]);
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

    test('one Feature per fix with [lon, lat] order and id/ts/i/s properties',
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
      expect(f0['properties'], {'id': 7, 'ts': 1000, 'i': 0, 's': 0});

      final f1 = features[1] as Map<String, dynamic>;
      expect(f1['id'], 8);
      expect((f1['geometry'] as Map)['coordinates'], [1.0, 52.25]);
      expect(f1['properties'], {'id': 8, 'ts': 2000, 'i': 1, 's': 0});
    });

    test('properties carry nothing but id, ts, i and s', () {
      final json = buildPinsGeoJson(_cols([1, 2, 3]));
      final features = (jsonDecode(json) as Map)['features'] as List;
      for (final f in features) {
        expect(((f as Map)['properties'] as Map).keys,
            unorderedEquals(['id', 'ts', 'i', 's']));
      }
    });

    test('s defaults to live when the columns do not spell it out', () {
      final features =
          (jsonDecode(buildPinsGeoJson(_cols([1, 2]))) as Map)['features']
              as List;
      for (final f in features) {
        expect(((f as Map)['properties'] as Map)['s'], kPinSourceLive);
      }
    });

    test('s is 1 for imported fixes and 0 for live ones, per feature', () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0)),
        _fix(id: 2, ts: _t(1), source: PingSource.imported),
        _fix(id: 3, ts: _t(2), source: PingSource.imported),
        _fix(id: 4, ts: _t(3), source: PingSource.panic),
      ]);
      final features =
          (jsonDecode(buildPinsGeoJson(snap.cols)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['s']),
        [0, 1, 1, 0],
      );
      // Small ints, so they survive maplibre-android's float32 narrowing
      // (unlike a ts literal) and the ['==', ['get','s'], 1] branch in
      // buildPinStyle matches exactly.
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['s']),
        everyElement(isA<int>()),
      );
    });

    test('the id and i properties are untouched by the s addition', () {
      final snap = buildPinSnapshot([
        _fix(id: 41, ts: _t(0), source: PingSource.imported),
        _fix(id: 42, ts: _t(1)),
      ]);
      final features =
          (jsonDecode(buildPinsGeoJson(snap.cols)) as Map)['features'] as List;
      expect(features.map((f) => (f as Map)['id']), [41, 42]);
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['id']),
        [41, 42],
      );
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['i']),
        [0, 1],
      );
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
        expect((f['properties'] as Map)['i'], i);
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

    test('segment properties are unchanged by the pins s flag', () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0), source: PingSource.imported),
        _fix(id: 2, ts: _t(1), source: PingSource.imported),
      ]);
      final features =
          (jsonDecode(buildSegmentsGeoJson(snap.cols)) as Map)['features']
              as List;
      expect(features.length, 1);
      expect(((features.first as Map)['properties'] as Map).keys,
          unorderedEquals(['ts', 'i']));
    });

    test('each segment carries the ts AND the index i of its LATER endpoint',
        () {
      final c = _cols([100, 200, 300, 400]);
      final features =
          (jsonDecode(buildSegmentsGeoJson(c)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['ts']),
        [200, 300, 400],
      );
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['i']),
        [1, 2, 3],
      );
      // windowFilter(n) keeps segments with i <= n-1: at n = 3 (fixes
      // 0..2 visible) the segments into fix 1 and fix 2 show, the one
      // into fix 3 does not.
      final visibleAtN3 = features
          .where((f) => ((f as Map)['properties'] as Map)['i'] <= 2)
          .length;
      expect(visibleAtN3, 2);
      // So the same `<= sliderMax` filter hides the segment INTO a future
      // pin while keeping the one into the head.
      final visibleAt300 = features
          .where((f) => ((f as Map)['properties'] as Map)['ts'] <= 300)
          .length;
      expect(visibleAt300, 2);
    });
  });

  group('ordinal i (the float32-safe window key)', () {
    test('buildPinsGeoJson stamps i = 0..N-1 in chrono order', () {
      final snap = buildPinSnapshot([
        for (var h = 0; h < 12; h++) _fix(id: 1000 + h * 7, ts: _t(h)),
      ]);
      final features =
          (jsonDecode(buildPinsGeoJson(snap.cols)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['i']),
        [for (var i = 0; i < 12; i++) i],
      );
      // i indexes `chrono`, so feature i resolves to chrono[i].
      for (var i = 0; i < 12; i++) {
        final f = features[i] as Map;
        expect((f['properties'] as Map)['id'], snap.chrono[i].id);
      }
    });

    test('i survives null-coordinate exclusion (dense, no holes)', () {
      final snap = buildPinSnapshot([
        _fix(id: 1, ts: _t(0)),
        _fix(id: 2, ts: _t(1), lat: null),
        _fix(id: 3, ts: _t(2)),
        Ping(id: 4, timestampUtc: _t(3), source: PingSource.noFix),
        _fix(id: 5, ts: _t(4)),
      ]);
      final features =
          (jsonDecode(buildPinsGeoJson(snap.cols)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['i']),
        [0, 1, 2],
      );
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['id']),
        [1, 3, 5],
      );
    });

    test('segments carry the later endpoint i, 1..N-1', () {
      final c = _cols([for (var i = 0; i < 6; i++) i * 10]);
      final features =
          (jsonDecode(buildSegmentsGeoJson(c)) as Map)['features'] as List;
      expect(
        features.map((f) => ((f as Map)['properties'] as Map)['i']),
        [1, 2, 3, 4, 5],
      );
    });
  });

  group('windowFilter', () {
    test('n = 0 hides everything (no feature has i <= -1)', () {
      expect(windowFilter(0), [
        '<=',
        ['get', 'i'],
        -1,
      ]);
    });

    test('n = 1 shows only the first fix', () {
      expect(windowFilter(1), [
        '<=',
        ['get', 'i'],
        0,
      ]);
    });

    test('literal shape for a multi-year range', () {
      expect(windowFilter(7200), [
        '<=',
        ['get', 'i'],
        7199,
      ]);
    });

    test('jsonEncodes to what the platform channel sends', () {
      expect(jsonEncode(windowFilter(7200)), '["<=",["get","i"],7199]');
    });

    test('visibleCount is the filter input, so duplicates at the cursor '
        'are all shown and the HUD count equals the map', () {
      final ts = Int64List.fromList([10, 20, 20, 20, 30]);
      final n = visibleCount(ts, 20);
      expect(n, 4);
      expect(windowFilter(n), [
        '<=',
        ['get', 'i'],
        3,
      ]);
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
    const base = '#00ff00';
    const dim = '#003300';
    PinStyle style(int n) =>
        buildPinStyle(visibleN: n, baseHex: base, dimHex: dim);

    final isImported = [
      '==',
      ['get', 's'],
      1,
    ];

    test('n = 0 ⇒ plain literals, constant colour, imported branch only', () {
      final s = style(0);
      expect(s.radius, kPinRadius);
      expect(s.strokeOpacity, 0.6);
      expect(s.color, base);
      expect(s.opacity, ['case', isImported, kImportedPinOpacity, 1]);
      expect(s.strokeWidth,
          ['case', isImported, kImportedPinStrokeWidth, 0.5]);
      expect(s.strokeColor, ['case', isImported, base, kLivePinStrokeHex]);
    });

    test('n = 1 ⇒ head at i == 0, constant colour (ramp needs n-1 > 0, '
        'interpolate stops must be strictly ascending)', () {
      final s = style(1);
      final isHead = [
        '==',
        ['get', 'i'],
        0,
      ];
      expect(s.radius, ['case', isHead, kHeadPinRadius, kPinRadius]);
      expect(s.color, ['case', isHead, kHeadPinHex, base]);
      expect(s.strokeOpacity, ['case', isHead, 0.95, 0.6]);
      // Head first, imported second — an imported head pin stays solid.
      expect(s.opacity,
          ['case', isHead, 1, isImported, kImportedPinOpacity, 1]);
      expect(s.strokeWidth,
          ['case', isHead, 1, isImported, kImportedPinStrokeWidth, 0.5]);
      expect(s.strokeColor, [
        'case',
        isHead,
        kLivePinStrokeHex,
        isImported,
        base,
        kLivePinStrokeHex,
      ]);
    });

    test('n = 2 ⇒ head i == 1, previous i == 0, ramp over 0..1', () {
      final s = style(2);
      final isHead = [
        '==',
        ['get', 'i'],
        1,
      ];
      final isPrev = [
        '==',
        ['get', 'i'],
        0,
      ];
      expect(s.radius, ['case', isHead, kHeadPinRadius, kPinRadius]);
      expect(s.strokeOpacity, ['case', isHead, 0.95, isPrev, 0.95, 0.6]);
      expect(s.strokeWidth, [
        'case',
        isHead,
        1,
        isPrev,
        1,
        isImported,
        kImportedPinStrokeWidth,
        0.5,
      ]);
      expect(s.opacity, [
        'case',
        isHead,
        1,
        isPrev,
        1,
        isImported,
        kImportedPinOpacity,
        1,
      ]);
      expect(s.color, [
        'case',
        isHead,
        kHeadPinHex,
        isPrev,
        kPrevPinHex,
        [
          'interpolate',
          ['linear'],
          ['get', 'i'],
          0,
          dim,
          1,
          base,
        ],
      ]);
    });

    test('n = 7200 ⇒ head 7199, previous 7198, ramp 0..7199', () {
      final s = style(7200);
      final color = s.color as List;
      expect(color[0], 'case');
      expect(color[1], [
        '==',
        ['get', 'i'],
        7199,
      ]);
      expect(color[3], [
        '==',
        ['get', 'i'],
        7198,
      ]);
      expect(color[5], [
        'interpolate',
        ['linear'],
        ['get', 'i'],
        0,
        dim,
        7199,
        base,
      ]);
      expect((s.radius as List)[1], color[1]);
    });

    test('imported pins are hollow: faint fill, ramp-coloured ring', () {
      final s = style(7200);
      final opacity = s.opacity as List;
      // ['case', isHead, 1, isPrev, 1, isImported, 0.15, 1]
      expect(opacity[5], isImported);
      expect(opacity[6], kImportedPinOpacity);
      expect(opacity.last, 1);
      final strokeWidth = s.strokeWidth as List;
      expect(strokeWidth[5], isImported);
      expect(strokeWidth[6], kImportedPinStrokeWidth);
      expect(strokeWidth.last, 0.5);
      final strokeColor = s.strokeColor as List;
      expect(strokeColor[5], isImported);
      // The ring is the same teal ramp the fill would have used.
      expect(strokeColor[6], (s.color as List)[5]);
      expect(strokeColor.last, kLivePinStrokeHex);
    });

    test('the s branch keys on the property, never on i', () {
      for (final n in [0, 1, 2, 7200]) {
        final s = style(n);
        for (final e in [s.opacity, s.strokeWidth, s.strokeColor]) {
          expect(jsonEncode(e), contains('["get","s"]'), reason: 'n=$n');
        }
      }
    });

    test('head and previous emphasis is identical for live and imported '
        'pins — an imported head pin must not fade to 15%', () {
      for (final n in [1, 2, 7200]) {
        final s = style(n);
        final opacity = s.opacity as List;
        // The head (and, from n = 2, the previous) branch is evaluated
        // before the imported one, so the cursor pin is always solid.
        expect(opacity[1], (s.radius as List)[1],
            reason: 'n=$n: head condition must come first');
        expect(opacity[2], 1, reason: 'n=$n: head opacity');
        final strokeColor = s.strokeColor as List;
        expect(strokeColor[2], kLivePinStrokeHex, reason: 'n=$n');
        final importedIdx = opacity.indexOf(kImportedPinOpacity);
        expect(importedIdx, greaterThan(2),
            reason: 'n=$n: imported branch must come after head/prev');
      }
    });

    test('never keys on ts or id — only i and s are float32-safe at any N',
        () {
      for (final n in [0, 1, 2, 7200]) {
        final s = style(n);
        for (final e in [
          s.radius,
          s.color,
          s.opacity,
          s.strokeWidth,
          s.strokeOpacity,
          s.strokeColor,
        ]) {
          final json = jsonEncode(e);
          expect(json, isNot(contains('"ts"')), reason: 'n=$n: $json');
          expect(json, isNot(contains('"id"')), reason: 'n=$n: $json');
        }
      }
    });

    test('every expression jsonEncodes (what setLayerProperties ships)', () {
      final s = style(52600);
      for (final e in [
        s.radius,
        s.color,
        s.opacity,
        s.strokeWidth,
        s.strokeOpacity,
        s.strokeColor,
      ]) {
        expect(() => jsonEncode(e), returnsNormally);
      }
    });
  });

  group('float32 safety', () {
    // maplibre-android's Expression.Converter.convertToValue narrows
    // every JSON number with JsonPrimitive.getAsFloat() (android-sdk-
    // opengl 13.0.2, Expression.java ~4893-4905) before it reaches the
    // renderer, so anything we compare or interpolate on must survive a
    // double → float32 → double round trip unchanged.
    bool exact(num v) => v == Float32List.fromList([v.toDouble()])[0];
    double narrowed(num v) => Float32List.fromList([v.toDouble()])[0];

    Iterable<num> literals(Object? e) sync* {
      if (e is num) {
        yield e;
      } else if (e is List) {
        for (final x in e) {
          yield* literals(x);
        }
      }
    }

    test('every integer literal emitted by windowFilter / buildPinStyle is '
        'float32-exact for realistic and extreme n', () {
      for (final n in [0, 1, 2, 7200, 52600, (1 << 24) - 1]) {
        final s = buildPinStyle(visibleN: n, baseHex: '#00ff00', dimHex: '#003300');
        final all = [
          ...literals(windowFilter(n)),
          ...literals(s.radius),
          ...literals(s.color),
          ...literals(s.opacity),
          ...literals(s.strokeWidth),
          ...literals(s.strokeOpacity),
          ...literals(s.strokeColor),
        ];
        expect(all, isNotEmpty);
        for (final v in all) {
          if (v is int) {
            // Indices, comparison operands, interpolate stops: must be
            // bit-exact or the head/previous match and the window edge
            // land on the wrong pin.
            expect(exact(v), isTrue,
                reason: 'n=$n: integer literal $v is not float32-exact');
          } else {
            // Opacities / widths (0.5, 0.6, 0.95): a sub-1e-6 wobble is
            // invisible; the renderer stores them as float anyway.
            expect((narrowed(v) - v).abs(), lessThan(1e-6),
                reason: 'n=$n: literal $v narrows badly');
          }
        }
      }
    });

    test('the source flag literals (0 / 1) are float32-exact', () {
      expect(exact(kPinSourceLive), isTrue);
      expect(exact(kPinSourceImported), isTrue);
      expect((narrowed(kImportedPinOpacity) - kImportedPinOpacity).abs(),
          lessThan(1e-6));
      expect(
          (narrowed(kImportedPinStrokeWidth) - kImportedPinStrokeWidth).abs(),
          lessThan(1e-6));
    });

    test('an epoch-ms literal is NOT float32-exact — why the window is an '
        'ordinal, not a ts bound', () {
      final ms = DateTime.utc(2025, 10, 1, 12, 34, 56, 789)
          .millisecondsSinceEpoch; // ~1.76e12, float32 ulp = 131 072
      expect(exact(ms), isFalse);
      expect((narrowed(ms) - ms).abs(), greaterThan(1000),
          reason: 'the error is seconds, not milliseconds');
      // And even seconds-relative does not help over multi-year ranges.
      const threeYearsSeconds = 3 * 365 * 24 * 3600; // ~9.5e7 > 2^24
      expect(threeYearsSeconds, greaterThan(1 << 24));
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

  group('buildHeatmapProperties', () {
    // Same float32 round-trip check as the "float32 safety" group above —
    // maplibre-android narrows every numeric literal in a style
    // expression, so an interpolate stop must survive it exactly.
    bool exact(num v) => v == Float32List.fromList([v.toDouble()])[0];

    Iterable<Object?> flatten(Object? e) sync* {
      if (e is List) {
        for (final x in e) {
          yield* flatten(x);
        }
      } else {
        yield e;
      }
    }

    test('pinned radius / weight / intensity / opacity', () {
      final props = buildHeatmapProperties(r: 77, g: 182, b: 172);
      expect(props.heatmapRadius, 30);
      expect(props.heatmapWeight, 1);
      expect(props.heatmapIntensity, 1);
      expect(props.heatmapOpacity, 0.7);
    });

    test('the colour ramp uses ONLY expression-form colours — no CSS '
        'strings anywhere (the 0.27.0 regression)', () {
      final color = buildHeatmapProperties(r: 77, g: 182, b: 172).heatmapColor
          as List;
      final allowedStrings = {
        'interpolate',
        'linear',
        'heatmap-density',
        'rgba',
        'rgb',
      };
      for (final v in flatten(color)) {
        if (v is String) {
          expect(allowedStrings, contains(v),
              reason: 'unexpected string literal in ramp: $v');
        }
      }
    });

    test('stops are ascending 0 → 1: transparent, 40% tint, solid tint, '
        'white', () {
      final color = buildHeatmapProperties(r: 77, g: 182, b: 172).heatmapColor
          as List;
      // ['interpolate', ['linear'], ['heatmap-density'], stop, colour, ...]
      final stops = <double>[];
      for (var i = 3; i < color.length; i += 2) {
        stops.add((color[i] as num).toDouble());
      }
      expect(stops, [0.0, 0.2, 0.6, 1.0]);
      expect(color[4], ['rgba', 77, 182, 172, 0]);
      expect(color[6], ['rgba', 77, 182, 172, 0.4]);
      expect(color[8], ['rgb', 77, 182, 172]);
      expect(color[10], ['rgb', 255, 255, 255]);
    });

    test('r/g/b are echoed verbatim into every colour stop that carries '
        'them', () {
      final color = buildHeatmapProperties(r: 1, g: 2, b: 3).heatmapColor
          as List;
      expect(color[4], ['rgba', 1, 2, 3, 0]);
      expect(color[6], ['rgba', 1, 2, 3, 0.4]);
      expect(color[8], ['rgb', 1, 2, 3]);
    });

    test('integer literals (r/g/b, alpha 0, density stops) are '
        'float32-exact; the fractional alpha/stop is within a visually '
        'invisible tolerance', () {
      // Same split as the "float32 safety" group above: whole numbers used
      // as r/g/b channels or comparison-adjacent stops must be bit-exact,
      // but a fractional alpha/density like 0.4 is only ever blended into
      // a continuous interpolation — a sub-1e-6 wobble is imperceptible,
      // same tolerance the pin-style ramp opacities use.
      final color = buildHeatmapProperties(r: 77, g: 182, b: 172).heatmapColor
          as List;
      for (final v in flatten(color)) {
        if (v is int) {
          expect(exact(v), isTrue, reason: 'literal $v is not float32-exact');
        } else if (v is double) {
          final narrowed = Float32List.fromList([v])[0];
          expect((narrowed - v).abs(), lessThan(1e-6),
              reason: 'literal $v narrows badly');
        }
      }
    });

    test('jsonEncodes cleanly (what addHeatmapLayer ships)', () {
      final props = buildHeatmapProperties(r: 77, g: 182, b: 172);
      expect(() => jsonEncode(props.toJson()), returnsNormally);
    });
  });
}
