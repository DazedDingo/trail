import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/import_thinning.dart';
import 'package:trail/services/import/timeline_models.dart';

/// 2023-11-14T22:13:20Z — an arbitrary but fixed base timestamp.
const int kBaseTs = 1700000000000;

int mins(num m) => (m * 60000).round();
int secs(num s) => (s * 1000).round();

/// Degrees of latitude per metre, using the same earth radius as
/// [haversineMeters], so `latPlus(lat, 24)` is exactly 24 m away.
const double _degPerMetreLat = 180 / (math.pi * 6371000.0);

double latPlus(double lat, double metres) => lat + metres * _degPerMetreLat;

const double kBathLat = 51.3811;
const double kBathLon = -2.3590;

ImportCandidate cand({
  required int ts,
  double lat = kBathLat,
  double lon = kBathLon,
  ImportKind kind = ImportKind.path,
  double? accuracyM,
  String? note,
}) =>
    ImportCandidate(
      tsUtcMs: ts,
      lat: lat,
      lon: lon,
      kind: kind,
      note: note ?? 'gmaps:${kind.name}',
      accuracyM: accuracyM,
    );

/// Path candidate at `kBaseTs + offsetMs`, [metres] north of Bath.
ImportCandidate path(int offsetMs, {double metres = 0}) =>
    cand(ts: kBaseTs + offsetMs, lat: latPlus(kBathLat, metres));

ImportCandidate raw(int offsetMs, {double metres = 0, double accuracy = 12}) =>
    cand(
      ts: kBaseTs + offsetMs,
      lat: latPlus(kBathLat, metres),
      kind: ImportKind.raw,
      accuracyM: accuracy,
    );

ImportCandidate visit(int offsetMs, {double metres = 0, bool end = false}) =>
    cand(
      ts: kBaseTs + offsetMs,
      lat: latPlus(kBathLat, metres),
      kind: end ? ImportKind.visitEnd : ImportKind.visitStart,
    );

ImportCandidate activity(int offsetMs,
        {double metres = 0, bool end = false}) =>
    cand(
      ts: kBaseTs + offsetMs,
      lat: latPlus(kBathLat, metres),
      kind: end ? ImportKind.activityEnd : ImportKind.activityStart,
    );

List<int> offsets(List<ImportCandidate> list) =>
    [for (final c in list) c.tsUtcMs - kBaseTs];

ExistingFix fix(int offsetMs, {double metres = 0, double? lon}) => ExistingFix(
      tsUtcMs: kBaseTs + offsetMs,
      lat: latPlus(kBathLat, metres),
      lon: lon ?? kBathLon,
    );

void main() {
  group('haversineMeters', () {
    test('Bath to London is about 156 km', () {
      final d = haversineMeters(kBathLat, kBathLon, 51.5074, -0.1278);
      expect(d, closeTo(156000, 156000 * 0.02));
    });

    test('is zero for identical points', () {
      expect(haversineMeters(kBathLat, kBathLon, kBathLat, kBathLon), 0);
    });

    test('is symmetric', () {
      final a = haversineMeters(kBathLat, kBathLon, 51.5074, -0.1278);
      final b = haversineMeters(51.5074, -0.1278, kBathLat, kBathLon);
      expect(a, closeTo(b, 1e-6));
    });

    test('the metre helper round-trips through the haversine', () {
      expect(
        haversineMeters(kBathLat, kBathLon, latPlus(kBathLat, 300), kBathLon),
        closeTo(300, 0.001),
      );
    });
  });

  group('thinCandidates — trivial inputs', () {
    test('returns empty for empty input, every preset', () {
      for (final preset in ImportPreset.values) {
        expect(thinCandidates(const [], preset), isEmpty, reason: '$preset');
      }
    });

    test('keeps a single candidate, every preset', () {
      for (final preset in ImportPreset.values) {
        expect(thinCandidates([path(0)], preset), hasLength(1),
            reason: '$preset');
      }
      // …including a lone visit and a lone activity endpoint.
      expect(thinCandidates([visit(0)], ImportPreset.normal), hasLength(1));
      expect(thinCandidates([activity(0)], ImportPreset.normal), hasLength(1));
    });

    test('accepts equal timestamps', () {
      final out = thinCandidates(
        [path(0), visit(0)],
        ImportPreset.full,
      );
      expect(out, hasLength(2));
    });

    test('output stays sorted', () {
      final input = [
        visit(0),
        path(secs(10)),
        raw(secs(20)),
        path(mins(3)),
        visit(mins(30), end: true),
        raw(mins(45), metres: 900),
      ];
      for (final preset in ImportPreset.values) {
        final out = thinCandidates(input, preset);
        for (var i = 1; i < out.length; i++) {
          expect(out[i].tsUtcMs, greaterThanOrEqualTo(out[i - 1].tsUtcMs),
              reason: '$preset');
        }
      }
    });

    test('throws ArgumentError on unsorted input', () {
      expect(
        () => thinCandidates([path(mins(1)), path(0)], ImportPreset.normal),
        throwsArgumentError,
      );
    });
  });

  group('thinCandidates — Normal (15 min / 250 m)', () {
    test('keeps points at 15-minute gaps', () {
      final out = thinCandidates(
        [path(0), path(mins(15)), path(mins(30))],
        ImportPreset.normal,
      );
      expect(offsets(out), [0, mins(15), mins(30)]);
    });

    test('drops 5-minute jitter at the same place', () {
      final input = [
        for (var i = 0; i <= 6; i++) path(mins(5 * i), metres: i.isEven ? 2 : -2)
      ];
      final out = thinCandidates(input, ImportPreset.normal);
      expect(offsets(out), [0, mins(15), mins(30)]);
    });

    test('keeps a 300 m move inside 15 minutes', () {
      final out = thinCandidates(
        [path(0), path(mins(5), metres: 300)],
        ImportPreset.normal,
      );
      expect(offsets(out), [0, mins(5)]);
    });

    test('drops a 100 m move inside 15 minutes', () {
      final out = thinCandidates(
        [path(0), path(mins(5), metres: 100)],
        ImportPreset.normal,
      );
      expect(offsets(out), [0]);
    });
  });

  group('thinCandidates — Coarse (60 min / 1 km)', () {
    test('needs 60 minutes or 1 km', () {
      final input = [
        path(0),
        path(mins(30), metres: 500), // too soon, too close
        path(mins(45), metres: 1500), // 1.5 km from the last kept
        path(mins(105), metres: 1510), // 60 min after the last kept
      ];
      final out = thinCandidates(input, ImportPreset.coarse);
      expect(offsets(out), [0, mins(45), mins(105)]);
    });

    test('is stricter than Normal on the same data', () {
      final input = [
        for (var i = 0; i <= 8; i++) path(mins(15 * i), metres: 10.0 * i)
      ];
      final normal = thinCandidates(input, ImportPreset.normal);
      final coarse = thinCandidates(input, ImportPreset.coarse);
      expect(normal, hasLength(9));
      expect(offsets(coarse), [0, mins(60), mins(120)]);
    });
  });

  group('thinCandidates — Full', () {
    test('keeps everything except the 60-second group dedupe', () {
      final input = [
        path(0),
        path(secs(90)),
        path(secs(180)),
        path(secs(190)), // same group as 180 s
        path(secs(200)), // same group as 180 s
        path(secs(400)),
      ];
      final out = thinCandidates(input, ImportPreset.full);
      expect(offsets(out), [0, secs(90), secs(180), secs(400)]);
    });

    test('keeps 5-minute jitter that Normal would thin away', () {
      final input = [
        for (var i = 0; i <= 6; i++) path(mins(5 * i), metres: i.isEven ? 2 : -2)
      ];
      expect(thinCandidates(input, ImportPreset.full), hasLength(7));
      expect(thinCandidates(input, ImportPreset.normal), hasLength(3));
    });
  });

  group('thinCandidates — 60-second group dedupe', () {
    test('prefers the raw candidate (non-null accuracy) over path', () {
      final out = thinCandidates(
        [path(0), raw(secs(10)), path(secs(20))],
        ImportPreset.full,
      );
      expect(out, hasLength(1));
      expect(out.single.kind, ImportKind.raw);
      expect(offsets(out), [secs(10)]);
    });

    test('keeps the earliest on ties', () {
      final out = thinCandidates(
        [path(0), path(secs(10)), path(secs(20))],
        ImportPreset.full,
      );
      expect(offsets(out), [0]);
    });

    test('keeps the earliest raw when several carry accuracy', () {
      final out = thinCandidates(
        [
          path(0),
          raw(secs(10), accuracy: 40),
          raw(secs(20), accuracy: 3), // better accuracy, but later
        ],
        ImportPreset.full,
      );
      expect(offsets(out), [secs(10)]);
      expect(out.single.accuracyM, 40);
    });

    test('groups on the first timestamp: 60 s in, 60.001 s out', () {
      expect(
        thinCandidates([path(0), path(secs(60))], ImportPreset.full),
        hasLength(1),
      );
      expect(
        offsets(thinCandidates([path(0), path(60001)], ImportPreset.full)),
        [0, 60001],
      );
    });

    test('re-anchors on the first candidate after a group closes', () {
      // 0 and 60 s are one group; 120 s anchors the next one even though
      // it is only 60 s after the previous member.
      final out = thinCandidates(
        [path(0), path(secs(60)), path(secs(120))],
        ImportPreset.full,
      );
      expect(offsets(out), [0, secs(120)]);
    });

    test('applies to every preset', () {
      final input = [path(0), raw(secs(10)), path(secs(20))];
      for (final preset in ImportPreset.values) {
        final out = thinCandidates(input, preset);
        expect(out, hasLength(1), reason: '$preset');
        expect(out.single.kind, ImportKind.raw, reason: '$preset');
      }
    });
  });

  group('thinCandidates — visit endpoints', () {
    test('survive every preset', () {
      final input = <ImportCandidate>[
        visit(0),
        for (var i = 1; i <= 9; i++) path(mins(i), metres: i.toDouble()),
        visit(mins(10), end: true),
      ];
      for (final preset in ImportPreset.values) {
        final out = thinCandidates(input, preset);
        expect(
          out.where((c) => c.kind == ImportKind.visitStart).map((c) => c.tsUtcMs),
          [kBaseTs],
          reason: '$preset',
        );
        expect(
          out.where((c) => c.kind == ImportKind.visitEnd).map((c) => c.tsUtcMs),
          [kBaseTs + mins(10)],
          reason: '$preset',
        );
      }
    });

    test('are emitted in addition to their group winner', () {
      final out = thinCandidates(
        [visit(0), path(secs(10)), raw(secs(20)), visit(secs(30), end: true)],
        ImportPreset.full,
      );
      expect(offsets(out), [0, secs(20), secs(30)]);
      expect(out.map((c) => c.kind), [
        ImportKind.visitStart,
        ImportKind.raw,
        ImportKind.visitEnd,
      ]);
    });

    test('survive a group made only of visits', () {
      final out = thinCandidates(
        [visit(0), visit(secs(20), end: true), visit(secs(40))],
        ImportPreset.coarse,
      );
      expect(offsets(out), [0, secs(20), secs(40)]);
    });

    test('become the new anchor for gap/distance thinning', () {
      // The visit is 2 km away; the path point 60 s later is 10 m from the
      // visit, so it only survives if the anchor stayed at path(0).
      final out = thinCandidates(
        [path(0), visit(secs(60), metres: 2000), path(secs(120), metres: 2010)],
        ImportPreset.normal,
      );
      expect(offsets(out), [0, secs(60)]);
    });
  });

  group('thinCandidates — activity endpoints', () {
    test('dropped when a kept point is within 5 minutes', () {
      final out = thinCandidates(
        [path(0), activity(mins(2))],
        ImportPreset.full,
      );
      expect(offsets(out), [0]);
    });

    test('kept when the nearest kept point is beyond 5 minutes', () {
      final out = thinCandidates(
        [path(0), activity(mins(10), end: true)],
        ImportPreset.full,
      );
      expect(offsets(out), [0, mins(10)]);
      expect(out.last.kind, ImportKind.activityEnd);
    });

    test('the ±5 minute window is inclusive', () {
      expect(
        offsets(thinCandidates([path(0), activity(mins(5))],
            ImportPreset.full)),
        [0],
      );
      expect(
        offsets(thinCandidates([path(0), activity(mins(5) + 1)],
            ImportPreset.full)),
        [0, mins(5) + 1],
      );
    });

    test('looks both ways in time', () {
      final out = thinCandidates(
        [activity(0), path(mins(3))],
        ImportPreset.full,
      );
      expect(offsets(out), [mins(3)]);
    });

    test('competes in the 60-second group like any other candidate', () {
      // Pass 1 runs first: the endpoint is exactly 60 s after the path
      // point, so they resolve as one group and the earlier point wins.
      final out = thinCandidates(
        [path(0), activity(secs(60), end: true)],
        ImportPreset.full,
      );
      expect(offsets(out), [0]);
    });

    test('a lone activity endpoint is kept', () {
      final out = thinCandidates([activity(0)], ImportPreset.full);
      expect(out, hasLength(1));
    });

    test('two activity endpoints within 5 minutes drop each other', () {
      final out = thinCandidates(
        [activity(0, end: true), activity(mins(3))],
        ImportPreset.full,
      );
      expect(out, isEmpty);
    });

    test('survives when the neighbouring point was thinned away', () {
      final input = [
        path(0),
        path(mins(15), metres: 5),
        path(mins(20), metres: 7), // thinned by Normal; 2 min before the activity
        activity(mins(22), metres: 400, end: true),
      ];
      // Full keeps the 20-minute point, which kills the activity endpoint.
      expect(
        offsets(thinCandidates(input, ImportPreset.full)),
        [0, mins(15), mins(20)],
      );
      // Normal drops it (5 min / 2 m after the last kept row), so the
      // activity endpoint has no neighbour within 5 minutes and survives.
      final normal = thinCandidates(input, ImportPreset.normal);
      expect(offsets(normal), [0, mins(15), mins(22)]);
      expect(normal.last.kind, ImportKind.activityEnd);
    });
  });

  group('dedupeAgainstExisting', () {
    test('keeps everything when there are no existing fixes', () {
      final kept = [path(0), path(mins(20))];
      final r = dedupeAgainstExisting(kept, const []);
      expect(r.kept, kept);
      expect(r.duplicates, 0);
    });

    test('keeps everything when there are no candidates', () {
      final r = dedupeAgainstExisting(const [], [fix(0)]);
      expect(r.kept, isEmpty);
      expect(r.duplicates, 0);
    });

    test('59 s away and 24 m away is a duplicate', () {
      final r = dedupeAgainstExisting(
        [path(0)],
        [fix(secs(59), metres: 24)],
      );
      expect(r.kept, isEmpty);
      expect(r.duplicates, 1);
    });

    test('61 s away is not a duplicate', () {
      for (final offset in [secs(61), -secs(61)]) {
        final r = dedupeAgainstExisting([path(0)], [fix(offset)]);
        expect(r.kept, hasLength(1), reason: 'offset $offset');
        expect(r.duplicates, 0, reason: 'offset $offset');
      }
    });

    test('26 m away is not a duplicate', () {
      final r = dedupeAgainstExisting([path(0)], [fix(0, metres: 26)]);
      expect(r.kept, hasLength(1));
      expect(r.duplicates, 0);
    });

    test('the time window is inclusive', () {
      final r = dedupeAgainstExisting([path(0)], [fix(secs(60))]);
      expect(r.duplicates, 1);
      final r2 = dedupeAgainstExisting([path(0)], [fix(secs(60) + 1)]);
      expect(r2.duplicates, 0);
    });

    test('the radius is exclusive', () {
      final exact =
          haversineMeters(kBathLat, kBathLon, latPlus(kBathLat, 25), kBathLon);
      expect(
        dedupeAgainstExisting([path(0)], [fix(0, metres: 25)],
                radiusM: exact)
            .duplicates,
        0,
      );
      expect(
        dedupeAgainstExisting([path(0)], [fix(0, metres: 25)],
                radiusM: exact * 1.000001)
            .duplicates,
        1,
      );
    });

    test('a zero radius never dedupes', () {
      final r = dedupeAgainstExisting([path(0)], [fix(0)], radiusM: 0);
      expect(r.duplicates, 0);
    });

    test('any fix in the window is enough', () {
      final r = dedupeAgainstExisting(
        [path(0)],
        [fix(-secs(30), metres: 5000), fix(secs(30), metres: 5)],
      );
      expect(r.duplicates, 1);
    });

    test('honours custom window and radius', () {
      final r = dedupeAgainstExisting(
        [path(0)],
        [fix(mins(4), metres: 80)],
        windowMs: mins(5),
        radiusM: 100,
      );
      expect(r.duplicates, 1);
    });

    test('counts duplicates and preserves the order of the kept rows', () {
      final candidates = [
        path(0),
        path(mins(20), metres: 500),
        path(mins(40), metres: 1000),
        path(mins(60), metres: 1500),
      ];
      final existing = [
        fix(secs(10), metres: 3), // kills the first
        fix(mins(40) + secs(5), metres: 1002), // kills the third
      ];
      final r = dedupeAgainstExisting(candidates, existing);
      expect(offsets(r.kept), [mins(20), mins(60)]);
      expect(r.duplicates, 2);
    });

    test('throws ArgumentError on unsorted candidates', () {
      expect(
        () => dedupeAgainstExisting([path(mins(1)), path(0)], const []),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError on unsorted existing fixes', () {
      expect(
        () => dedupeAgainstExisting([path(0)], [fix(mins(1)), fix(0)]),
        throwsArgumentError,
      );
    });

    test('binary search matches brute force on 2000 x 2000 random points',
        () {
      final rnd = math.Random(20260822);
      const spanMs = 3600000;
      ImportCandidate randomCandidate() => cand(
            ts: kBaseTs + rnd.nextInt(spanMs),
            lat: 51.3800 + rnd.nextDouble() * 0.002,
            lon: -2.3600 + rnd.nextDouble() * 0.003,
          );
      ExistingFix randomFix() => ExistingFix(
            tsUtcMs: kBaseTs + rnd.nextInt(spanMs),
            lat: 51.3800 + rnd.nextDouble() * 0.002,
            lon: -2.3600 + rnd.nextDouble() * 0.003,
          );

      final candidates = List.generate(2000, (_) => randomCandidate())
        ..sort((a, b) => a.tsUtcMs.compareTo(b.tsUtcMs));
      final existing = List.generate(2000, (_) => randomFix())
        ..sort((a, b) => a.tsUtcMs.compareTo(b.tsUtcMs));

      const windowMs = 60000;
      const radiusM = 25.0;
      final bruteKept = <ImportCandidate>[];
      var bruteDuplicates = 0;
      for (final c in candidates) {
        final dup = existing.any((e) =>
            (e.tsUtcMs - c.tsUtcMs).abs() <= windowMs &&
            haversineMeters(c.lat, c.lon, e.lat, e.lon) < radiusM);
        if (dup) {
          bruteDuplicates++;
        } else {
          bruteKept.add(c);
        }
      }

      final r = dedupeAgainstExisting(candidates, existing);
      expect(r.duplicates, bruteDuplicates);
      expect(r.kept, bruteKept);
      // The fixture has to actually exercise both branches.
      expect(bruteDuplicates, greaterThan(0));
      expect(bruteKept, isNotEmpty);
    });
  });

  group('projectImport', () {
    test('reports candidates, kept, duplicates and the kept range', () {
      final candidates = [
        path(0),
        path(mins(5), metres: 5), // thinned by Normal
        path(mins(20), metres: 500),
        path(mins(40), metres: 1000),
      ];
      final existing = [fix(secs(20), metres: 3)]; // kills the first kept row
      final p = projectImport(candidates, ImportPreset.normal, existing);
      expect(p.candidates, 4);
      expect(p.kept, 2);
      expect(p.duplicates, 1);
      expect(p.tsMinUtcMs, kBaseTs + mins(20));
      expect(p.tsMaxUtcMs, kBaseTs + mins(40));
      expect(p.exceedsWarnThreshold, isFalse);
    });

    test('range is null when nothing survives', () {
      final p = projectImport([path(0)], ImportPreset.normal, [fix(0)]);
      expect(p.candidates, 1);
      expect(p.kept, 0);
      expect(p.duplicates, 1);
      expect(p.tsMinUtcMs, isNull);
      expect(p.tsMaxUtcMs, isNull);
    });

    test('empty input projects to zeroes', () {
      final p = projectImport(const [], ImportPreset.full, const []);
      expect(p.candidates, 0);
      expect(p.kept, 0);
      expect(p.duplicates, 0);
      expect(p.tsMinUtcMs, isNull);
      expect(p.exceedsWarnThreshold, isFalse);
    });

    test('warns above 50 000 kept rows but not at exactly 50 000', () {
      const at = ImportProjection(candidates: 60000, kept: 50000, duplicates: 0);
      const over =
          ImportProjection(candidates: 60000, kept: 50001, duplicates: 0);
      expect(at.exceedsWarnThreshold, isFalse);
      expect(over.exceedsWarnThreshold, isTrue);
    });

    test('a Full-preset import of 50 001 points trips the warning', () {
      // 90 s apart so nothing groups; Full keeps every one of them.
      final candidates = [
        for (var i = 0; i < 50001; i++) path(i * secs(90)),
      ];
      final p = projectImport(candidates, ImportPreset.full, const []);
      expect(p.kept, 50001);
      expect(p.exceedsWarnThreshold, isTrue);
      // Normal thins the same file well under the threshold.
      final normal = projectImport(candidates, ImportPreset.normal, const []);
      expect(normal.exceedsWarnThreshold, isFalse);
    });
  });

  group('yearBreakdown', () {
    // kBaseTs is 2023-11-14; +60 days lands in mid-January 2024, far
    // enough from either New Year to be the same calendar year in every
    // host time zone.
    int days(int d) => mins(d * 24 * 60);

    test('splits the same pipeline the worker runs, year by year', () {
      final candidates = [
        path(0),
        path(mins(20), metres: 500),
        path(days(60)),
        path(days(60) + mins(20), metres: 500),
      ];
      final existing = [fix(days(60) + secs(20), metres: 3)];

      final thinned = thinCandidates(candidates, ImportPreset.normal);
      final deduped = dedupeAgainstExisting(thinned, existing);
      final rows = yearBreakdown(
        candidates: candidates,
        keptBeforeDedupe: thinned,
        kept: deduped.kept,
      );

      expect(rows.map((r) => r.year).toList(), <int>[2024, 2023]);
      expect(rows.first.candidatesInFile, 2);
      expect(rows.first.keptAfterThinning, 1);
      expect(rows.first.skippedAsDuplicate, 1);
      expect(rows.last.candidatesInFile, 2);
      expect(rows.last.keptAfterThinning, 2);
      expect(rows.last.skippedAsDuplicate, 0);
    });

    test('the per-year totals add up to the projection', () {
      final candidates = [
        path(0),
        raw(secs(30)), // groups with the first point
        visit(mins(30)),
        visit(mins(90), end: true),
        path(days(200), metres: 900),
        activity(days(200) + mins(30), end: true),
      ];
      final existing = [fix(mins(30) + secs(10), metres: 5)];

      final thinned = thinCandidates(candidates, ImportPreset.normal);
      final deduped = dedupeAgainstExisting(thinned, existing);
      final rows = yearBreakdown(
        candidates: candidates,
        keptBeforeDedupe: thinned,
        kept: deduped.kept,
      );
      final projection =
          projectImport(candidates, ImportPreset.normal, existing);

      var inFile = 0;
      var kept = 0;
      var duplicates = 0;
      for (final row in rows) {
        inFile += row.candidatesInFile;
        kept += row.keptAfterThinning;
        duplicates += row.skippedAsDuplicate;
        expect(
          row.pathPoints + row.visits + row.activities + row.rawPositions,
          row.candidatesInFile,
          reason: 'kinds must add up for ${row.year}',
        );
      }
      expect(inFile, projection.candidates);
      expect(kept, projection.kept);
      expect(duplicates, projection.duplicates);
    });
  });

  group('performance', () {
    test('200 000 candidates thin and dedupe in under 1.5 s', () {
      final rnd = math.Random(7);
      var ts = kBaseTs;
      var lat = kBathLat;
      var lon = kBathLon;
      final candidates = <ImportCandidate>[];
      for (var i = 0; i < 200000; i++) {
        ts += 4000 + rnd.nextInt(4000); // a fix every 4–8 s
        lat += (rnd.nextDouble() - 0.5) * 0.0004;
        lon += (rnd.nextDouble() - 0.5) * 0.0006;
        final kind = switch (i % 500) {
          0 => ImportKind.visitStart,
          1 => ImportKind.visitEnd,
          2 => ImportKind.activityStart,
          3 => ImportKind.activityEnd,
          _ => i.isEven ? ImportKind.raw : ImportKind.path,
        };
        candidates.add(cand(
          ts: ts,
          lat: lat,
          lon: lon,
          kind: kind,
          accuracyM: kind == ImportKind.raw ? 8 + rnd.nextInt(30) * 1.0 : null,
        ));
      }
      // Half the existing fixes shadow a real candidate (Trail was already
      // logging then) so the duplicate branch is exercised; half are noise.
      final spanMs = ts - kBaseTs;
      final existing = <ExistingFix>[
        for (var i = 0; i < 10000; i++)
          () {
            final c = candidates[rnd.nextInt(candidates.length)];
            return ExistingFix(
              tsUtcMs: c.tsUtcMs + rnd.nextInt(40000) - 20000,
              lat: latPlus(c.lat, rnd.nextDouble() * 8),
              lon: c.lon,
            );
          }(),
        for (var i = 0; i < 10000; i++)
          ExistingFix(
            tsUtcMs: kBaseTs + rnd.nextInt(spanMs),
            lat: kBathLat + (rnd.nextDouble() - 0.5) * 0.05,
            lon: kBathLon + (rnd.nextDouble() - 0.5) * 0.05,
          ),
      ]..sort((a, b) => a.tsUtcMs.compareTo(b.tsUtcMs));

      final sw = Stopwatch()..start();
      final thinned = thinCandidates(candidates, ImportPreset.normal);
      final result = dedupeAgainstExisting(thinned, existing);
      // Also dedupe the unthinned list — the Full preset feeds every
      // candidate through the binary search.
      final fullResult = dedupeAgainstExisting(candidates, existing);
      sw.stop();

      expect(thinned, isNotEmpty);
      expect(result.kept.length, lessThanOrEqualTo(thinned.length));
      expect(fullResult.kept.length + fullResult.duplicates,
          candidates.length);
      expect(fullResult.duplicates, greaterThan(0));
      // ignore: avoid_print
      print('thin+dedupe of ${candidates.length} candidates took '
          '${sw.elapsedMilliseconds} ms -> ${thinned.length} thinned, '
          '${result.kept.length} kept, ${result.duplicates} duplicates '
          '(full-list dedupe: ${fullResult.duplicates} duplicates)');
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });
}
