import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/import_thinning.dart';
import 'package:trail/services/import/timeline_models.dart';

/// `yearBreakdown` — the per-year audit the import preview shows so
/// "I don't see 2024" can be answered from the file itself: did the
/// export contain that year at all, did thinning keep it, or did the
/// dedupe skip it as already-logged?
///
/// Pure maths only (CLAUDE.md gotcha 18): no isolate, no DB, no widgets.

/// A candidate at a given UTC instant, [metres] north of Bath.
ImportCandidate at(
  DateTime utc, {
  ImportKind kind = ImportKind.path,
  double lat = 51.3811,
  double lon = -2.3590,
}) =>
    ImportCandidate(
      tsUtcMs: utc.millisecondsSinceEpoch,
      lat: lat,
      lon: lon,
      kind: kind,
      note: 'gmaps:${kind.name}',
      accuracyM: kind == ImportKind.raw ? 12 : null,
    );

/// A candidate at a wall-clock instant in the host's LOCAL zone — the
/// only way to pin local-year bucketing without knowing the host zone.
ImportCandidate atLocal(DateTime local, {ImportKind kind = ImportKind.path}) =>
    at(local.toUtc(), kind: kind);

ImportYearRow rowFor(List<ImportYearRow> rows, int year) =>
    rows.firstWhere((r) => r.year == year);

void main() {
  group('yearBreakdown — shape', () {
    test('empty input produces no rows', () {
      expect(
        yearBreakdown(
          candidates: const [],
          keptBeforeDedupe: const [],
          kept: const [],
        ),
        isEmpty,
      );
    });

    test('one year in, one row out, newest first over four years', () {
      final candidates = <ImportCandidate>[
        for (final year in [2023, 2024, 2025, 2026])
          for (var i = 0; i < 3; i++) at(DateTime.utc(year, 6, 1 + i, 12)),
      ];
      final rows = yearBreakdown(
        candidates: candidates,
        keptBeforeDedupe: candidates,
        kept: candidates,
      );
      expect(rows.map((r) => r.year).toList(), <int>[2026, 2025, 2024, 2023]);
      expect(rows.map((r) => r.candidatesInFile).toSet(), <int>{3});
      expect(rows.map((r) => r.keptAfterThinning).toSet(), <int>{3});
      expect(rows.map((r) => r.skippedAsDuplicate).toSet(), <int>{0});
    });

    test('first/last are the file\'s first and last point of that year', () {
      final first = at(DateTime.utc(2024, 1, 2, 8));
      final middle = at(DateTime.utc(2024, 7, 4, 9));
      final last = at(DateTime.utc(2024, 12, 30, 22));
      final rows = yearBreakdown(
        candidates: [first, middle, last],
        keptBeforeDedupe: [middle],
        kept: [middle],
      );
      expect(rows.single.firstTsUtcMs, first.tsUtcMs);
      expect(rows.single.lastTsUtcMs, last.tsUtcMs);
    });

    test('an unsorted file still reports the right first/last', () {
      final rows = yearBreakdown(
        candidates: [
          at(DateTime.utc(2024, 12, 30, 22)),
          at(DateTime.utc(2024, 1, 2, 8)),
          at(DateTime.utc(2024, 7, 4, 9)),
        ],
        keptBeforeDedupe: const [],
        kept: const [],
      );
      expect(
        rows.single.firstTsUtcMs,
        DateTime.utc(2024, 1, 2, 8).millisecondsSinceEpoch,
      );
      expect(
        rows.single.lastTsUtcMs,
        DateTime.utc(2024, 12, 30, 22).millisecondsSinceEpoch,
      );
    });
  });

  group('yearBreakdown — 2023-2026 with known outcomes', () {
    // 2023: 4 in the file, 2 survive thinning, 1 of those is a duplicate.
    // 2024: 3 in the file, all 3 kept.
    // 2025: 2 in the file, both survive thinning, both duplicates.
    // 2026: 1 in the file, thinned away entirely (the bug shape).
    final y2023 = [for (var i = 0; i < 4; i++) at(DateTime.utc(2023, 3, 1 + i))];
    final y2024 = [for (var i = 0; i < 3; i++) at(DateTime.utc(2024, 5, 1 + i))];
    final y2025 = [for (var i = 0; i < 2; i++) at(DateTime.utc(2025, 8, 1 + i))];
    final y2026 = [at(DateTime.utc(2026, 2, 9))];
    final candidates = [...y2023, ...y2024, ...y2025, ...y2026];
    final thinned = [...y2023.take(2), ...y2024, ...y2025];
    final kept = [y2023[1], ...y2024];

    final rows = yearBreakdown(
      candidates: candidates,
      keptBeforeDedupe: thinned,
      kept: kept,
    );

    test('every year of the file gets a row, newest first', () {
      expect(rows.map((r) => r.year).toList(), <int>[2026, 2025, 2024, 2023]);
    });

    test('in-file / kept / duplicate counts are exact', () {
      expect(
        rows.map((r) => r.candidatesInFile).toList(),
        <int>[1, 2, 3, 4],
      );
      expect(
        rows.map((r) => r.keptAfterThinning).toList(),
        <int>[0, 0, 3, 1],
      );
      expect(
        rows.map((r) => r.skippedAsDuplicate).toList(),
        <int>[0, 2, 0, 1],
      );
    });

    test('the totals match the whole-file projection', () {
      var inFile = 0;
      var keptRows = 0;
      var duplicates = 0;
      for (final row in rows) {
        inFile += row.candidatesInFile;
        keptRows += row.keptAfterThinning;
        duplicates += row.skippedAsDuplicate;
      }
      expect(inFile, candidates.length);
      expect(keptRows, kept.length);
      expect(duplicates, thinned.length - kept.length);
    });

    test('only the year that lost everything is flagged', () {
      expect(rowFor(rows, 2026).thinnedToNothing, isTrue);
      expect(rowFor(rows, 2025).thinnedToNothing, isFalse);
      expect(rowFor(rows, 2024).thinnedToNothing, isFalse);
      expect(rowFor(rows, 2023).thinnedToNothing, isFalse);
    });
  });

  group('yearBreakdown — kinds', () {
    test('each year gets its own per-kind split, summing to in-file', () {
      final candidates = <ImportCandidate>[
        at(DateTime.utc(2024, 4, 1, 8)),
        at(DateTime.utc(2024, 4, 1, 9)),
        at(DateTime.utc(2024, 4, 1, 10), kind: ImportKind.visitStart),
        at(DateTime.utc(2024, 4, 1, 11), kind: ImportKind.visitEnd),
        at(DateTime.utc(2024, 4, 1, 12), kind: ImportKind.raw),
        at(DateTime.utc(2025, 4, 1, 8), kind: ImportKind.activityStart),
        at(DateTime.utc(2025, 4, 1, 9), kind: ImportKind.activityEnd),
        at(DateTime.utc(2025, 4, 1, 10), kind: ImportKind.raw),
      ];
      final rows = yearBreakdown(
        candidates: candidates,
        keptBeforeDedupe: candidates,
        kept: candidates,
      );

      final r2024 = rowFor(rows, 2024);
      expect(r2024.pathPoints, 2);
      // Visit endpoints count one each: start + end = 2.
      expect(r2024.visits, 2);
      expect(r2024.activities, 0);
      expect(r2024.rawPositions, 1);

      final r2025 = rowFor(rows, 2025);
      expect(r2025.pathPoints, 0);
      expect(r2025.visits, 0);
      expect(r2025.activities, 2);
      expect(r2025.rawPositions, 1);

      for (final row in rows) {
        expect(
          row.pathPoints + row.visits + row.activities + row.rawPositions,
          row.candidatesInFile,
          reason: 'kinds must add up for ${row.year}',
        );
      }
    });
  });

  group('yearBreakdown — local year boundary', () {
    test('midnight either side of New Year splits by LOCAL year', () {
      // Built from local wall-clock time: on any zone east of UTC the
      // 00:30 instant is still 31 December in UTC, so bucketing by the
      // UTC year would put it in 2023.
      final lastOf2023 = atLocal(DateTime(2023, 12, 31, 23, 30));
      final firstOf2024 = atLocal(DateTime(2024, 1, 1, 0, 30));
      final rows = yearBreakdown(
        candidates: [lastOf2023, firstOf2024],
        keptBeforeDedupe: [firstOf2024],
        kept: [firstOf2024],
      );

      expect(rows.map((r) => r.year).toList(), <int>[2024, 2023]);
      expect(rowFor(rows, 2023).candidatesInFile, 1);
      expect(rowFor(rows, 2023).keptAfterThinning, 0);
      expect(rowFor(rows, 2024).candidatesInFile, 1);
      expect(rowFor(rows, 2024).keptAfterThinning, 1);
    });

    test('importYearOf agrees with the local calendar', () {
      final instant = DateTime.utc(2023, 12, 31, 23, 30);
      expect(
        importYearOf(instant.millisecondsSinceEpoch),
        instant.toLocal().year,
      );
    });
  });
}
