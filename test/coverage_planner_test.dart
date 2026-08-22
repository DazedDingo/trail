import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/coverage/coverage_planner.dart';

/// Ports the Python coverage-tool's test cases
/// (`tools/coverage/test_coverage_lib.py`) so the app and the VPS job
/// cluster, pad, merge and name identically — a coverage pack built by
/// either side must land on the same file name for the same place.
void main() {
  // Bath-ish cluster of 3, Lisbon-ish cluster of 2, one London singleton.
  const bath = [
    GeoPoint(51.375, -2.360),
    GeoPoint(51.380, -2.365),
    GeoPoint(51.385, -2.355),
  ];
  const lisbon = [
    GeoPoint(38.715, -9.140),
    GeoPoint(38.720, -9.135),
  ];
  const london = GeoPoint(51.5074, -0.1278);

  // Approximate UK bbox, matching `coverage_lib.PRESETS['uk']`.
  const ukBox = CoverageBox(west: -8.7, south: 49.8, east: 1.9, north: 60.9);

  group('haversineKm', () {
    test('Bath to London is ~156 km', () {
      expect(haversineKm(51.38, -2.36, 51.5074, -0.1278), closeTo(156, 3));
    });

    test('zero distance', () {
      expect(haversineKm(51.38, -2.36, 51.38, -2.36), 0);
    });
  });

  group('planCoverage clustering', () {
    test('Bath + Lisbon + London are three boxes at 15 km', () {
      final boxes = planCoverage([...bath, ...lisbon, london], clusterKm: 15);
      expect(boxes.length, 3);
    });

    test('Bath + London merge into one cluster at 200 km, Lisbon stays', () {
      final boxes = planCoverage([...bath, ...lisbon, london], clusterKm: 200);
      expect(boxes.length, 2);
      // The Bath+London box must span both longitudes.
      final wide = boxes.firstWhere((b) => b.west < -2 && b.east > -0.2);
      expect(wide.contains(51.5074, -0.1278), isTrue);
      expect(wide.contains(51.380, -2.365), isTrue);
    });

    test('empty input plans nothing', () {
      expect(planCoverage(const []), isEmpty);
    });

    test('out-of-range and NaN points are dropped, not clustered', () {
      final boxes = planCoverage([
        const GeoPoint(double.nan, 0),
        const GeoPoint(0, 999),
        const GeoPoint(91, 0),
      ]);
      expect(boxes, isEmpty);
    });

    test('boxes come back smallest-area first', () {
      // A tight Bath cluster and a wide two-point cluster 400 km apart.
      final boxes = planCoverage([
        ...bath,
        const GeoPoint(48.0, 2.0),
        const GeoPoint(48.2, 2.4),
      ], clusterKm: 60);
      expect(boxes.length, 2);
      expect(boxes.first.area, lessThan(boxes.last.area));
    });
  });

  group('padBoxKm', () {
    test('3 km at lat 51 is ~0.027 deg lat / ~0.043 deg lon', () {
      const point = CoverageBox(west: 0, south: 51, east: 0, north: 51);
      final padded = padBoxKm(point, 3);
      expect(padded.north - 51.0, closeTo(0.027, 0.001));
      expect(padded.east - 0.0, closeTo(0.043, 0.001));
      expect(51.0 - padded.south, closeTo(0.027, 0.001));
      expect(0.0 - padded.west, closeTo(0.043, 0.001));
    });

    test('at the pole the longitude pad clamps to a half-world', () {
      const point = CoverageBox(west: 0, south: 90, east: 0, north: 90);
      expect(padBoxKm(point, 3).east, 180.0);
    });
  });

  group('merge overlaps', () {
    test('two clusters whose padded boxes touch become one box', () {
      // 4 km apart: two 3 km pads overlap.
      final boxes = planCoverage(
        const [GeoPoint(51.40, -2.40), GeoPoint(51.40, -2.343)],
        clusterKm: 1,
        padKm: 3,
      );
      expect(boxes.length, 1);
      expect(boxes.single.contains(51.40, -2.40), isTrue);
      expect(boxes.single.contains(51.40, -2.343), isTrue);
    });

    test('clusters far apart stay separate', () {
      final boxes = planCoverage([...bath, ...lisbon], clusterKm: 15);
      expect(boxes.length, 2);
    });
  });

  group('covered drop', () {
    test('a cluster entirely inside a covered box is dropped', () {
      final boxes = planCoverage(
        [...bath, ...lisbon],
        clusterKm: 15,
        covered: const [ukBox],
      );
      expect(boxes.length, 1);
      // The survivor is Lisbon.
      expect(boxes.single.contains(38.715, -9.140), isTrue);
    });

    test('a cluster with one uncovered point is kept', () {
      final boxes = planCoverage(
        [...bath, const GeoPoint(51.39, -2.35), lisbon.first],
        clusterKm: 15,
        covered: const [ukBox],
      );
      expect(boxes.length, 1);
      expect(boxes.single.contains(38.715, -9.140), isTrue);
    });

    test('no covered boxes keeps everything', () {
      expect(planCoverage([...bath, ...lisbon], clusterKm: 15).length, 2);
    });
  });

  group('isCoveredInDetail', () {
    const inBath = ArchiveExtent(
      path: '/t/coverage-bath.pmtiles',
      minZoom: 7,
      maxZoom: 13,
      bounds: CoverageBox(west: -2.5, south: 51.3, east: -2.2, north: 51.5),
    );
    const worldOverview = ArchiveExtent(
      path: '/t/overview.pmtiles',
      minZoom: 0,
      maxZoom: 6,
      bounds: CoverageBox(west: -180, south: -85, east: 180, north: 85),
    );
    const noBounds = ArchiveExtent(
      path: '/t/mystery.pmtiles',
      minZoom: 0,
      maxZoom: 14,
    );

    test('a z13 archive containing the point covers it', () {
      expect(isCoveredInDetail(51.38, -2.36, const [inBath]), isTrue);
    });

    test('a z6 world overview never counts as detail', () {
      expect(isCoveredInDetail(51.38, -2.36, const [worldOverview]), isFalse);
    });

    test('a detailed archive elsewhere does not cover the point', () {
      expect(isCoveredInDetail(38.72, -9.14, const [inBath]), isFalse);
    });

    test('an archive with no declared bounds covers nothing', () {
      expect(isCoveredInDetail(51.38, -2.36, const [noBounds]), isFalse);
    });

    test('no archives at all means nothing is covered', () {
      expect(isCoveredInDetail(51.38, -2.36, const []), isFalse);
    });

    test('minDetailZoom is configurable', () {
      expect(
        isCoveredInDetail(0, 0, const [worldOverview], minDetailZoom: 6),
        isTrue,
      );
    });
  });

  group('slug + filename', () {
    test('slug matches coverage_lib.slug_for_bbox', () {
      const box = CoverageBox(west: -2.5, south: 51.0, east: -2.0, north: 51.5);
      expect(box.slug, 'lat+51.25_lon-002.25');
    });

    test('negative latitude and positive longitude', () {
      const box = CoverageBox(west: 2.0, south: -38.5, east: 2.5, north: -38.0);
      expect(box.slug, 'lat-38.25_lon+002.25');
    });

    test('file name carries the coverage- prefix the role sniffer needs', () {
      const box = CoverageBox(west: -2.5, south: 51.0, east: -2.0, north: 51.5);
      expect(
        coverageFileName(box, date: '20260822'),
        'coverage-lat+51.25_lon-002.25-z7-14-20260822.pmtiles',
      );
      expect(
        coverageFileName(box, minzoom: 10, maxzoom: 15, date: '20260101'),
        'coverage-lat+51.25_lon-002.25-z10-15-20260101.pmtiles',
      );
    });

    test('bboxParam is W,S,E,N with trailing zeros trimmed', () {
      const box = CoverageBox(west: -2.5, south: 51.0, east: -2.0, north: 51.5);
      expect(box.bboxParam, '-2.5,51,-2,51.5');
    });
  });

  group('CoverageBox', () {
    test('contains is inclusive on the edges', () {
      const box = CoverageBox(west: -1, south: 50, east: 1, north: 52);
      expect(box.contains(50, -1), isTrue);
      expect(box.contains(52, 1), isTrue);
      expect(box.contains(49.9, 0), isFalse);
      expect(box.contains(51, 1.1), isFalse);
    });

    test('fromBounds normalises order and rejects malformed input', () {
      final b = CoverageBox.fromBounds([1, 52, -1, 50]);
      expect(b, const CoverageBox(west: -1, south: 50, east: 1, north: 52));
      expect(CoverageBox.fromBounds(null), isNull);
      expect(CoverageBox.fromBounds([1, 2, 3]), isNull);
      expect(CoverageBox.fromBounds([1, 2, 3, double.nan]), isNull);
    });
  });

  group('shouldAutoFetchNow', () {
    test('truth table', () {
      const cases = <(bool, bool, String?, bool)>[
        // enabled, wifiOnly, network, expected
        (true, true, 'wifi', true),
        (true, true, 'ethernet', true),
        (true, true, 'mobile', false),
        (true, false, 'mobile', true),
        (true, false, 'wifi', true),
        (true, true, 'none', false),
        (true, true, 'unknown', false),
        (true, false, 'none', false),
        (true, true, null, false),
        (false, false, 'wifi', false),
        (false, true, 'wifi', false),
      ];
      for (final (enabled, wifiOnly, network, expected) in cases) {
        expect(
          shouldAutoFetchNow(
            enabled: enabled,
            wifiOnly: wifiOnly,
            networkState: network,
          ),
          expected,
          reason: 'enabled=$enabled wifiOnly=$wifiOnly network=$network',
        );
      }
    });
  });
}
