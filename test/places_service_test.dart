import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/stats/places_service.dart';

/// Builds a `PingDao.importedVisits()` row. [ms] is epoch ms UTC.
VisitRow _row(
  int ms, {
  double lat = 51.5,
  double lon = -0.1,
  String type = 'UNKNOWN',
  String placeId = '-',
}) =>
    (tsUtcMs: ms, lat: lat, lon: lon, note: 'gmaps:visit:$type:$placeId');

int _at(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  group('placeKeyFor / visitPlaceId', () {
    test('a real placeId keys the place', () {
      expect(placeKeyFor(_row(1, placeId: 'ChIJabc')), 'pid:ChIJabc');
      expect(visitPlaceId('gmaps:visit:HOME:ChIJabc'), 'ChIJabc');
    });

    test('the same placeId at drifting coordinates is one place', () {
      final a = placeKeyFor(_row(1, lat: 51.5, lon: -0.1, placeId: 'ChIJabc'));
      final b =
          placeKeyFor(_row(2, lat: 52.9, lon: 3.3, placeId: 'ChIJabc'));
      expect(a, b);
    });

    test('placeId `-` falls back to coordinates rounded to 4 dp', () {
      expect(
        placeKeyFor(_row(1, lat: 51.500049, lon: -0.100001)),
        'at:51.5000,-0.1000',
      );
      expect(visitPlaceId('gmaps:visit:UNKNOWN:-'), isNull);
    });

    test('coordinates beyond 4 dp collapse to the same key', () {
      expect(
        placeKeyFor(_row(1, lat: 51.50001, lon: -0.10002)),
        placeKeyFor(_row(2, lat: 51.50004, lon: -0.10001)),
      );
    });

    test('coordinates differing at 4 dp are different places', () {
      expect(
        placeKeyFor(_row(1, lat: 51.5000, lon: -0.1000)),
        isNot(placeKeyFor(_row(2, lat: 51.5002, lon: -0.1000))),
      );
    });

    test('a non-visit note has no place id', () {
      expect(visitPlaceId('gmaps:path'), isNull);
      expect(visitPlaceId('gmaps:activity:WALKING:1200m'), isNull);
    });
  });

  group('visitTypeLabel', () {
    test('HOME / WORK and their inferred variants', () {
      expect(visitTypeLabel('gmaps:visit:HOME:-'), 'Home');
      expect(visitTypeLabel('gmaps:visit:WORK:-'), 'Work');
      expect(visitTypeLabel('gmaps:visit:INFERRED_HOME:-'), 'Home (inferred)');
      expect(visitTypeLabel('gmaps:visit:INFERRED_WORK:-'), 'Work (inferred)');
    });

    test('lowercase spelling still resolves', () {
      expect(visitTypeLabel('gmaps:visit:home:ChIJabc'), 'Home');
    });

    test('anything else → null', () {
      expect(visitTypeLabel('gmaps:visit:UNKNOWN:-'), isNull);
      expect(visitTypeLabel('gmaps:visit:SEARCHED_ADDRESS:x'), isNull);
      expect(visitTypeLabel('gmaps:visit::-'), isNull);
      expect(visitTypeLabel('gmaps:path'), isNull);
    });
  });

  group('buildPlaces — pairing', () {
    test('a start/end pair is one visit with a known duration', () {
      final places = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 11, 30), placeId: 'p1'),
      ]);
      expect(places, hasLength(1));
      final p = places.single;
      expect(p.visitCount, 1);
      expect(p.totalDuration, const Duration(hours: 2, minutes: 30));
      expect(p.longestVisit, const Duration(hours: 2, minutes: 30));
      expect(p.firstMs, _at(2024, 1, 3, 9));
      expect(p.lastMs, _at(2024, 1, 3, 9));
    });

    test('rows of two places interleave without cross-pairing', () {
      final places = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), placeId: 'p2'),
        _row(_at(2024, 1, 3, 11), placeId: 'p1'),
        _row(_at(2024, 1, 3, 12), placeId: 'p2'),
      ]);
      expect(places.map((p) => p.key).toSet(), {'pid:p1', 'pid:p2'});
      for (final p in places) {
        expect(p.visitCount, 1);
        expect(p.totalDuration, const Duration(hours: 2));
      }
    });

    test('an unpaired start is still a visit, with no duration', () {
      final places = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
      ]);
      expect(places.single.visitCount, 1);
      expect(places.single.totalDuration, Duration.zero);
      expect(places.single.longestVisit, Duration.zero);
      expect(visitsForPlace([_row(_at(2024, 1, 3, 9), placeId: 'p1')], 'pid:p1')
          .single
          .duration,
          isNull);
    });

    test('a trailing unpaired start joins earlier complete visits', () {
      final rows = [
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), placeId: 'p1'),
        _row(_at(2024, 1, 4, 9), placeId: 'p1'),
      ];
      final p = buildPlaces(rows).single;
      expect(p.visitCount, 2);
      expect(p.totalDuration, const Duration(hours: 1));
      expect(p.firstMs, _at(2024, 1, 3, 9));
      expect(p.lastMs, _at(2024, 1, 4, 9));

      final visits = visitsForPlace(rows, 'pid:p1');
      expect(visits, hasLength(2));
      expect(visits.first.endMs, _at(2024, 1, 3, 10));
      expect(visits.last.endMs, isNull);
    });

    test('a zero-length visit (same ms start + end) is duration zero', () {
      final p = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
      ]).single;
      expect(p.visitCount, 1);
      expect(p.totalDuration, Duration.zero);
    });

    test('non-visit notes are ignored', () {
      final places = buildPlaces([
        (tsUtcMs: 1, lat: 51.5, lon: -0.1, note: 'gmaps:path'),
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), placeId: 'p1'),
      ]);
      expect(places, hasLength(1));
      expect(places.single.visitCount, 1);
    });

    test('empty in → empty out', () {
      expect(buildPlaces(const []), isEmpty);
      expect(visitsForPlace(const [], 'pid:p1'), isEmpty);
    });

    test('visitsForPlace on an unknown key → empty', () {
      expect(
        visitsForPlace([_row(_at(2024, 1, 3, 9), placeId: 'p1')], 'pid:nope'),
        isEmpty,
      );
    });
  });

  group('buildPlaces — roll-up', () {
    late List<VisitRow> rows;

    setUp(() {
      rows = [
        // p1: three visits — 1 h, 3 h, 30 min.
        _row(_at(2024, 1, 3, 9), placeId: 'p1', type: 'HOME'),
        _row(_at(2024, 1, 3, 10), placeId: 'p1', type: 'HOME'),
        _row(_at(2024, 5, 1, 8), placeId: 'p1', type: 'HOME'),
        _row(_at(2024, 5, 1, 11), placeId: 'p1', type: 'HOME'),
        _row(_at(2025, 2, 2, 8), placeId: 'p1', type: 'HOME'),
        _row(_at(2025, 2, 2, 8, 30), placeId: 'p1', type: 'HOME'),
        // p2: one long visit, more recent.
        _row(_at(2026, 1, 1, 8), placeId: 'p2', type: 'WORK'),
        _row(_at(2026, 1, 2, 8), placeId: 'p2', type: 'WORK'),
      ];
    });

    test('counts, first/last, total and longest', () {
      final byKey = {for (final p in buildPlaces(rows)) p.key: p};
      final p1 = byKey['pid:p1']!;
      expect(p1.visitCount, 3);
      expect(p1.firstMs, _at(2024, 1, 3, 9));
      expect(p1.lastMs, _at(2025, 2, 2, 8));
      expect(p1.totalDuration, const Duration(hours: 4, minutes: 30));
      expect(p1.longestVisit, const Duration(hours: 3));
      expect(p1.semanticType, 'Home');

      final p2 = byKey['pid:p2']!;
      expect(p2.visitCount, 1);
      expect(p2.totalDuration, const Duration(hours: 24));
      expect(p2.semanticType, 'Work');
    });

    test('coordinates come from the first row of the place', () {
      final p = buildPlaces([
        _row(_at(2024, 1, 3, 9), lat: 51.5, lon: -0.1, placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), lat: 51.9, lon: -0.9, placeId: 'p1'),
      ]).single;
      expect(p.lat, 51.5);
      expect(p.lon, -0.1);
    });

    test('the first typed row names the place even if an earlier visit '
        'was UNKNOWN', () {
      final p = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), placeId: 'p1'),
        _row(_at(2024, 1, 4, 9), placeId: 'p1', type: 'HOME'),
        _row(_at(2024, 1, 4, 10), placeId: 'p1', type: 'HOME'),
      ]).single;
      expect(p.semanticType, 'Home');
    });

    test('default order is visits desc, then most recent', () {
      final places = buildPlaces([
        ...rows,
        // p3: three visits too, but older than p1's last.
        _row(_at(2020, 1, 1, 8), placeId: 'p3'),
        _row(_at(2020, 1, 1, 9), placeId: 'p3'),
        _row(_at(2020, 1, 2, 8), placeId: 'p3'),
        _row(_at(2020, 1, 2, 9), placeId: 'p3'),
        _row(_at(2020, 1, 3, 8), placeId: 'p3'),
        _row(_at(2020, 1, 3, 9), placeId: 'p3'),
      ]);
      expect(
        places.map((p) => p.key).toList(),
        ['pid:p1', 'pid:p3', 'pid:p2'],
      );
    });
  });

  group('sortPlaces', () {
    final rows = [
      // few: 1 visit, most recent, longest total.
      _row(_at(2026, 6, 1, 8), placeId: 'few'),
      _row(_at(2026, 6, 3, 8), placeId: 'few'),
      // many: 2 visits, older, shorter total.
      _row(_at(2024, 1, 1, 8), placeId: 'many'),
      _row(_at(2024, 1, 1, 9), placeId: 'many'),
      _row(_at(2024, 2, 1, 8), placeId: 'many'),
      _row(_at(2024, 2, 1, 9), placeId: 'many'),
    ];

    test('visits → most visits first', () {
      final out = sortPlaces(buildPlaces(rows), PlaceSort.visits);
      expect(out.map((p) => p.key).toList(), ['pid:many', 'pid:few']);
    });

    test('recent → most recently visited first', () {
      final out = sortPlaces(buildPlaces(rows), PlaceSort.recent);
      expect(out.map((p) => p.key).toList(), ['pid:few', 'pid:many']);
    });

    test('longest → most time spent first', () {
      final out = sortPlaces(buildPlaces(rows), PlaceSort.longest);
      expect(out.map((p) => p.key).toList(), ['pid:few', 'pid:many']);
    });

    test('does not mutate the input list', () {
      final built = buildPlaces(rows);
      final before = built.map((p) => p.key).toList();
      sortPlaces(built, PlaceSort.recent);
      expect(built.map((p) => p.key).toList(), before);
    });

    test('empty list survives every sort', () {
      for (final sort in PlaceSort.values) {
        expect(sortPlaces(const [], sort), isEmpty);
      }
    });
  });

  group('formatters', () {
    test('formatPlaceDuration', () {
      expect(formatPlaceDuration(Duration.zero), '< 1 m');
      expect(formatPlaceDuration(const Duration(seconds: 30)), '< 1 m');
      expect(formatPlaceDuration(const Duration(minutes: 45)), '45 m');
      expect(formatPlaceDuration(const Duration(hours: 2)), '2 h');
      expect(
        formatPlaceDuration(const Duration(hours: 12, minutes: 30)),
        '12 h 30 m',
      );
      expect(formatPlaceDuration(const Duration(days: 2)), '2 d');
      expect(
        formatPlaceDuration(const Duration(days: 2, hours: 3, minutes: 40)),
        '2 d 3 h',
      );
    });

    test('formatPlaceSubtitle spans first → last with a total', () {
      final p = buildPlaces([
        _row(_at(2024, 1, 3, 9), placeId: 'p1'),
        _row(_at(2024, 1, 3, 10), placeId: 'p1'),
        _row(_at(2026, 5, 8, 9), placeId: 'p1'),
        _row(_at(2026, 5, 8, 10), placeId: 'p1'),
      ]).single;
      final subtitle = formatPlaceSubtitle(p);
      expect(subtitle, startsWith('2 visits · '));
      expect(subtitle, contains(' – '));
      expect(subtitle, endsWith(' · total 2 h'));
    });

    test('formatPlaceSubtitle collapses a single-day place to one date '
        'and drops an unknown total', () {
      final p = buildPlaces([_row(_at(2024, 1, 3, 9), placeId: 'p1')]).single;
      final subtitle = formatPlaceSubtitle(p);
      expect(subtitle, startsWith('1 visit · '));
      expect(subtitle, isNot(contains('–')));
      expect(subtitle, isNot(contains('total')));
    });

    test('formatVisitRange keeps the clock only for a same-day end', () {
      final sameDay = Visit(
        startMs: DateTime(2024, 1, 3, 14, 5).millisecondsSinceEpoch,
        endMs: DateTime(2024, 1, 3, 15, 20).millisecondsSinceEpoch,
      );
      expect(formatVisitRange(sameDay), '3 Jan 2024 14:05 – 15:20');

      final overnight = Visit(
        startMs: DateTime(2024, 1, 3, 23, 40).millisecondsSinceEpoch,
        endMs: DateTime(2024, 1, 4, 7, 15).millisecondsSinceEpoch,
      );
      expect(
        formatVisitRange(overnight),
        '3 Jan 2024 23:40 – 4 Jan 2024 07:15',
      );
    });

    test('formatVisitRange / formatVisitDuration on an unpaired start', () {
      final open = Visit(
        startMs: DateTime(2024, 1, 3, 14, 5).millisecondsSinceEpoch,
      );
      expect(formatVisitRange(open), '3 Jan 2024 14:05');
      expect(formatVisitDuration(open), 'duration unknown');
    });

    test('formatVisitDuration of a known visit', () {
      final v = Visit(
        startMs: DateTime(2024, 1, 3, 14, 5).millisecondsSinceEpoch,
        endMs: DateTime(2024, 1, 3, 16, 20).millisecondsSinceEpoch,
      );
      expect(formatVisitDuration(v), '2 h 15 m');
    });
  });
}
