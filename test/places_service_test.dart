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

/// A start + end row for one visit — the pair `timeline_mappers.dart`
/// writes.
List<VisitRow> _pair(
  int startMs,
  int endMs, {
  double lat = 51.5,
  double lon = -0.1,
  String type = 'UNKNOWN',
  String placeId = '-',
}) =>
    [
      _row(startMs, lat: lat, lon: lon, type: type, placeId: placeId),
      _row(endMs, lat: lat, lon: lon, type: type, placeId: placeId),
    ];

/// [metres] north of 51.5 — 1e-4° of latitude is ~11.1 m, so the
/// clustering tests can say "30 m away" instead of a magic decimal.
double _north(double metres) => 51.5 + metres / 111320.0;

/// A ready-made row for the [mergeByLabel] tests, which start from
/// summaries rather than from visit rows.
PlaceSummary _place(
  String key, {
  double lat = 51.5,
  double lon = -0.1,
  int visits = 1,
  int firstMs = 0,
  int lastMs = 0,
  Duration total = Duration.zero,
  Duration longest = Duration.zero,
  List<String> types = const [],
  List<String>? members,
}) =>
    PlaceSummary(
      key: key,
      memberKeys: members ?? [key],
      semanticTypes: types,
      lat: lat,
      lon: lon,
      visitCount: visits,
      firstMs: firstMs,
      lastMs: lastMs,
      totalDuration: total,
      longestVisit: longest,
    );

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
        _row(_at(2024, 1, 3, 10), lat: 51.6, placeId: 'p2'),
        _row(_at(2024, 1, 3, 11), placeId: 'p1'),
        _row(_at(2024, 1, 3, 12), lat: 51.6, placeId: 'p2'),
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
        // p2: one long visit, more recent — 11 km away, so the
        // spatial merge leaves it alone.
        _row(_at(2026, 1, 1, 8), lat: 51.6, placeId: 'p2', type: 'WORK'),
        _row(_at(2026, 1, 2, 8), lat: 51.6, placeId: 'p2', type: 'WORK'),
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
        _row(_at(2020, 1, 1, 8), lat: 51.7, placeId: 'p3'),
        _row(_at(2020, 1, 1, 9), lat: 51.7, placeId: 'p3'),
        _row(_at(2020, 1, 2, 8), lat: 51.7, placeId: 'p3'),
        _row(_at(2020, 1, 2, 9), lat: 51.7, placeId: 'p3'),
        _row(_at(2020, 1, 3, 8), lat: 51.7, placeId: 'p3'),
        _row(_at(2020, 1, 3, 9), lat: 51.7, placeId: 'p3'),
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
      // many: 2 visits, older, shorter total — 11 km from `few`.
      _row(_at(2024, 1, 1, 8), lat: 51.6, placeId: 'many'),
      _row(_at(2024, 1, 1, 9), lat: 51.6, placeId: 'many'),
      _row(_at(2024, 2, 1, 8), lat: 51.6, placeId: 'many'),
      _row(_at(2024, 2, 1, 9), lat: 51.6, placeId: 'many'),
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

  group('buildPlaces — spatial clustering (0.17.5)', () {
    test('two placeId-less visits 30 m apart are one place', () {
      final rows = [
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(30)),
      ];
      final p = buildPlaces(rows).single;
      expect(p.visitCount, 2);
      expect(p.memberCount, 2);
      // The seed — the earlier place — keeps the row's identity.
      expect(p.key, 'at:51.5000,-0.1000');
      expect(p.memberKeys, ['at:51.5000,-0.1000', 'at:51.5003,-0.1000']);
      expect(p.lat, 51.5);
    });

    test('two placeId-less visits 500 m apart stay two places', () {
      final places = buildPlaces([
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(500)),
      ]);
      expect(places, hasLength(2));
      for (final p in places) {
        expect(p.memberCount, 1);
        expect(p.visitCount, 1);
      }
    });

    test('a placeId place and a coordinate place 50 m apart merge', () {
      final rows = [
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10), placeId: 'ChIJabc'),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(50)),
      ];
      final p = buildPlaces(rows).single;
      expect(p.key, 'pid:ChIJabc');
      expect(p.memberKeys, ['pid:ChIJabc', 'at:51.5004,-0.1000']);
      expect(p.visitCount, 2);
    });

    test('two different placeIds at the same spot merge — Google '
        're-issues an id for one place', () {
      final p = buildPlaces([
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10), placeId: 'old'),
        ..._pair(_at(2026, 1, 3, 9), _at(2026, 1, 3, 10), placeId: 'new'),
      ]).single;
      expect(p.key, 'pid:old');
      expect(p.memberCount, 2);
    });

    test('HOME wins over an untyped member', () {
      final p = buildPlaces([
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(
          _at(2024, 1, 4, 9),
          _at(2024, 1, 4, 10),
          lat: _north(30),
          type: 'HOME',
        ),
      ]).single;
      expect(p.semanticType, 'Home');
      expect(p.semanticTypes, ['Home']);
    });

    test('the most frequent type leads; the rest stay as chips', () {
      final p = buildPlaces([
        ..._pair(
          _at(2024, 1, 3, 9),
          _at(2024, 1, 3, 10),
          type: 'HOME',
          placeId: 'a',
        ),
        ..._pair(
          _at(2024, 1, 4, 9),
          _at(2024, 1, 4, 10),
          lat: _north(30),
          type: 'WORK',
          placeId: 'b',
        ),
        ..._pair(
          _at(2024, 1, 5, 9),
          _at(2024, 1, 5, 10),
          lat: _north(60),
          type: 'WORK',
          placeId: 'c',
        ),
      ]).single;
      expect(p.semanticTypes, ['Work', 'Home']);
      expect(p.semanticType, 'Work');
    });

    test('counts, first/last, total and longest recompute over the union',
        () {
      final p = buildPlaces([
        // 1 h at the seed, then 3 h and 30 min at two jittered keys.
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(_at(2024, 5, 1, 8), _at(2024, 5, 1, 11), lat: _north(30)),
        ..._pair(_at(2025, 2, 2, 8), _at(2025, 2, 2, 8, 30), lat: _north(60)),
      ]).single;
      expect(p.memberCount, 3);
      expect(p.visitCount, 3);
      expect(p.firstMs, _at(2024, 1, 3, 9));
      expect(p.lastMs, _at(2025, 2, 2, 8));
      expect(p.totalDuration, const Duration(hours: 4, minutes: 30));
      expect(p.longestVisit, const Duration(hours: 3));
      expect(formatPlaceSubtitle(p), startsWith('3 visits · '));
    });

    test('the seed is the earliest first visit, whatever order the rows '
        'arrive in', () {
      final early = _pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10),
          lat: _north(30), placeId: 'early');
      final later = _pair(_at(2024, 6, 3, 9), _at(2024, 6, 3, 10),
          placeId: 'later');
      expect(buildPlaces([...early, ...later]).single.key, 'pid:early');
      expect(buildPlaces([...later, ...early]).single.key, 'pid:early');
    });

    test('clusterM: 0 reproduces the pre-0.17.5 one-row-per-key behaviour',
        () {
      final rows = [
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(30)),
        // Same coordinates, different id: distance 0 must NOT merge.
        ..._pair(_at(2024, 1, 5, 9), _at(2024, 1, 5, 10), placeId: 'p1'),
      ];
      final places = buildPlaces(rows, clusterM: 0);
      expect(places.map((p) => p.key).toSet(), {
        'at:51.5000,-0.1000',
        'at:51.5003,-0.1000',
        'pid:p1',
      });
      for (final p in places) {
        expect(p.memberCount, 1);
        expect(p.visitCount, 1);
      }
      expect(
        visitsForPlace(rows, 'at:51.5003,-0.1000', clusterM: 0),
        hasLength(1),
      );
    });

    test('visitsForPlace returns the merged set from any member key', () {
      final rows = [
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10)),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(30)),
      ];
      for (final key in ['at:51.5000,-0.1000', 'at:51.5003,-0.1000']) {
        final visits = visitsForPlace(rows, key);
        expect(visits, hasLength(2));
        expect(visits.first.startMs, _at(2024, 1, 3, 9));
        expect(visits.last.startMs, _at(2024, 1, 4, 9));
      }
    });

    test('visitsForPlaceKeys unions separate places, oldest first', () {
      final rows = [
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), placeId: 'b',
            lat: _north(500)),
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10), placeId: 'a'),
      ];
      final visits = visitsForPlaceKeys(rows, ['pid:a', 'pid:b']);
      expect(visits.map((v) => v.startMs).toList(), [
        _at(2024, 1, 3, 9),
        _at(2024, 1, 4, 9),
      ]);
      expect(visitsForPlaceKeys(rows, const []), isEmpty);
      expect(visitsForPlaceKeys(rows, ['pid:nope']), isEmpty);
    });

    test('visitsKey addresses every member of a merged row', () {
      final rows = [
        ..._pair(_at(2024, 1, 3, 9), _at(2024, 1, 3, 10), placeId: 'a'),
        ..._pair(_at(2024, 1, 4, 9), _at(2024, 1, 4, 10), lat: _north(30),
            placeId: 'b'),
      ];
      final place = buildPlaces(rows).single;
      expect(place.visitsKey.split(kPlaceKeySep), ['pid:a', 'pid:b']);
      expect(
        visitsForPlaceKeys(rows, place.visitsKey.split(kPlaceKeySep)),
        hasLength(2),
      );
    });
  });

  group('mergeByLabel (0.17.5)', () {
    test('the same label within 1 km collapses into one row', () {
      final merged = mergeByLabel(
        [
          _place('a', visits: 3, firstMs: 100, lastMs: 500),
          _place('b', lat: _north(400), visits: 2, firstMs: 50, lastMs: 900),
        ],
        {'a': 'Redcliffe, Bristol', 'b': 'Redcliffe, Bristol'},
      );
      final row = merged.single;
      expect(row.key, 'a');
      expect(row.visitCount, 5);
      expect(row.firstMs, 50);
      expect(row.lastMs, 900);
      expect(row.memberCount, 2);
      expect(row.memberKeys, ['a', 'b']);
      // The seed's coordinates stay the row's geocoding identity.
      expect(row.lat, 51.5);
    });

    test('durations sum and the longest stay is the biggest member', () {
      final row = mergeByLabel(
        [
          _place('a',
              total: const Duration(hours: 2),
              longest: const Duration(hours: 2)),
          _place('b',
              lat: _north(200),
              total: const Duration(hours: 5),
              longest: const Duration(hours: 4)),
        ],
        {'a': 'Redcliffe', 'b': 'Redcliffe'},
      ).single;
      expect(row.totalDuration, const Duration(hours: 7));
      expect(row.longestVisit, const Duration(hours: 4));
    });

    test('the same label 5 km apart stays two rows', () {
      final merged = mergeByLabel(
        [
          _place('a'),
          _place('b', lat: _north(5000)),
        ],
        {'a': 'High Street', 'b': 'High Street'},
      );
      expect(merged.map((p) => p.key).toList(), ['a', 'b']);
      expect(merged.first.memberCount, 1);
    });

    test('a place whose label has not resolved is never merged', () {
      final places = [
        _place('a'),
        _place('b', lat: _north(50)),
        _place('c', lat: _north(80)),
      ];
      final merged = mergeByLabel(places, {
        'a': null, // resolved to nothing
        'b': '   ', // blank
        // 'c' missing entirely — not looked up yet
      });
      expect(merged.map((p) => p.key).toList(), ['a', 'b', 'c']);
      expect(merged.every((p) => p.memberCount == 1), isTrue);
      // Unmerged rows come back as the very same objects.
      expect(identical(merged.first, places.first), isTrue);
    });

    test('case and surrounding whitespace do not matter', () {
      final merged = mergeByLabel(
        [
          _place('a'),
          _place('b', lat: _north(100)),
          _place('c', lat: _north(200)),
        ],
        {
          'a': 'Redcliffe, Bristol',
          'b': '  redcliffe, bristol ',
          'c': 'REDCLIFFE, BRISTOL',
        },
      );
      expect(merged, hasLength(1));
      expect(merged.single.memberCount, 3);
      expect(merged.single.memberKeys, ['a', 'b', 'c']);
    });

    test('chips are the union of the members, seed order first', () {
      final row = mergeByLabel(
        [
          _place('a', types: const ['Home']),
          _place('b', lat: _north(100), types: const ['Work']),
          _place('c', lat: _north(150), types: const ['Home']),
        ],
        {'a': 'Redcliffe', 'b': 'Redcliffe', 'c': 'Redcliffe'},
      ).single;
      expect(row.semanticTypes, ['Home', 'Work']);
      expect(row.semanticType, 'Home');
    });

    test('members merged by buildPlaces are carried into the label row', () {
      final row = mergeByLabel(
        [
          _place('a', members: const ['a', 'a2']),
          _place('b', lat: _north(100), members: const ['b']),
        ],
        {'a': 'Redcliffe', 'b': 'Redcliffe'},
      ).single;
      expect(row.memberKeys, ['a', 'a2', 'b']);
      expect(row.memberCount, 3);
      expect(row.visitsKey.split(kPlaceKeySep), ['a', 'a2', 'b']);
    });

    test('input order is preserved and the input is left alone', () {
      final places = [
        _place('a'),
        _place('far', lat: _north(5000)),
        _place('b', lat: _north(100)),
      ];
      final merged = mergeByLabel(places, {
        'a': 'Redcliffe',
        'far': 'Clifton',
        'b': 'Redcliffe',
      });
      expect(merged.map((p) => p.key).toList(), ['a', 'far']);
      expect(places, hasLength(3));
      expect(places.first.memberCount, 1);
    });

    test('empty in → empty out; no labels at all changes nothing', () {
      expect(mergeByLabel(const [], const {}), isEmpty);
      final places = [_place('a'), _place('b', lat: _north(50))];
      expect(mergeByLabel(places, const {}), hasLength(2));
    });

    test('maxKm: 0 turns the label merge off', () {
      final merged = mergeByLabel(
        [_place('a'), _place('b', lat: _north(10))],
        {'a': 'Redcliffe', 'b': 'Redcliffe'},
        maxKm: 0,
      );
      expect(merged, hasLength(2));
    });

    test('sort modes still rank the merged list', () {
      final merged = mergeByLabel(
        [
          _place('a', visits: 2, lastMs: 10, total: const Duration(hours: 1)),
          _place('b',
              lat: _north(200),
              visits: 2,
              lastMs: 20,
              total: const Duration(hours: 1)),
          _place('solo',
              lat: _north(5000),
              visits: 3,
              lastMs: 30,
              total: const Duration(hours: 5)),
        ],
        {'a': 'Redcliffe', 'b': 'Redcliffe', 'solo': 'Clifton'},
      );
      // The merged row's 4 visits outrank the 3-visit single row.
      expect(
        sortPlaces(merged, PlaceSort.visits).map((p) => p.key).toList(),
        ['a', 'solo'],
      );
      expect(
        sortPlaces(merged, PlaceSort.recent).map((p) => p.key).toList(),
        ['solo', 'a'],
      );
      expect(
        sortPlaces(merged, PlaceSort.longest).map((p) => p.key).toList(),
        ['solo', 'a'],
      );
    });
  });

  group('merged-row strings', () {
    test('formatSpotsHint only speaks for a merged row', () {
      expect(formatSpotsHint(_place('a')), isNull);
      expect(
        formatSpotsHint(_place('a', members: const ['a', 'b', 'c'])),
        '×3 spots',
      );
    });

    test('formatMergedPlaces only speaks for a merged row', () {
      expect(formatMergedPlaces(_place('a')), isNull);
      expect(
        formatMergedPlaces(_place('a', members: const ['a', 'b', 'c'])),
        '3 places within 1 km',
      );
    });

    test('formatMergedPlaces states the radius it was given', () {
      final merged = _place('a', members: const ['a', 'b']);
      // The default is the constant the screen merges with, not a
      // hard-coded string.
      expect(
        formatMergedPlaces(merged),
        '2 places within ${kPlaceLabelMergeKm.toInt()} km',
      );
      expect(
        formatMergedPlaces(merged, maxKm: 2.5),
        '2 places within 2.5 km',
      );
      expect(
        formatMergedPlaces(merged, maxKm: 3),
        '2 places within 3 km',
      );
      expect(
        formatMergedPlaces(merged, maxKm: 0.5),
        '2 places within 500 m',
      );
      expect(
        formatMergedPlaces(merged, maxKm: 0.12),
        '2 places within 120 m',
      );
    });
  });
}
