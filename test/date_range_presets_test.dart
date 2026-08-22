import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/providers/pings_provider.dart' show mapRangeUtcBounds;
import 'package:trail/screens/export_dialog.dart' show exportRangeUtcBounds;
import 'package:trail/services/stats/date_range_presets.dart';

void main() {
  // Fixed clock: Sunday 2026-05-17 14:23 local. Every preset resolves
  // against this so the expected ranges are deterministic.
  final now = DateTime(2026, 5, 17, 14, 23);

  group('dateRangePresets', () {
    test('exposes 5 presets in fixed Today → Yesterday → 7d → 30d → All order',
        () {
      final out = dateRangePresets(now);
      expect(out.map((p) => p.id).toList(), [
        DateRangePresetId.today,
        DateRangePresetId.yesterday,
        DateRangePresetId.last7,
        DateRangePresetId.last30,
        DateRangePresetId.all,
      ]);
      expect(out.map((p) => p.label).toList(), [
        'Today',
        'Yesterday',
        'Last 7 days',
        'Last 30 days',
        'All time',
      ]);
    });

    test('Today range is local midnight start, same-day end', () {
      final today = dateRangePresets(now).first;
      expect(today.range, isNotNull);
      expect(today.range!.start, DateTime(2026, 5, 17));
      expect(today.range!.end, DateTime(2026, 5, 17));
    });

    test('Yesterday is single-day, one day back from today', () {
      final yesterday = dateRangePresets(now)[1];
      expect(yesterday.range!.start, DateTime(2026, 5, 16));
      expect(yesterday.range!.end, DateTime(2026, 5, 16));
    });

    test('Last 7 days = today minus 6 → today (inclusive count = 7)', () {
      final last7 = dateRangePresets(now)[2];
      expect(last7.range!.start, DateTime(2026, 5, 11));
      expect(last7.range!.end, DateTime(2026, 5, 17));
      // Sanity: 7 calendar days inclusive
      final days =
          last7.range!.end.difference(last7.range!.start).inDays + 1;
      expect(days, 7);
    });

    test('Last 30 days = today minus 29 → today (inclusive count = 30)', () {
      final last30 = dateRangePresets(now)[3];
      expect(last30.range!.start, DateTime(2026, 4, 18));
      expect(last30.range!.end, DateTime(2026, 5, 17));
      final days =
          last30.range!.end.difference(last30.range!.start).inDays + 1;
      expect(days, 30);
    });

    test('All time is the sentinel range=null', () {
      final all = dateRangePresets(now).last;
      expect(all.id, DateRangePresetId.all);
      expect(all.range, isNull);
    });

    test('handles a `now` near midnight without overflowing into tomorrow',
        () {
      final lateNow = DateTime(2026, 5, 17, 23, 59);
      final out = dateRangePresets(lateNow);
      expect(out.first.range!.end, DateTime(2026, 5, 17));
    });
  });

  group('presetIdMatching', () {
    test('null current matches "All time"', () {
      expect(presetIdMatching(null, now), DateRangePresetId.all);
    });

    test('today-as-DateTimeRange matches Today preset', () {
      final today = dateRangePresets(now).first.range!;
      expect(presetIdMatching(today, now), DateRangePresetId.today);
    });

    test('Last 7 matches even when current has a time-of-day component', () {
      // Same calendar days, different time-of-day — should still match.
      final last7Anchored = dateRangePresets(now)[2].range!;
      final withTime = DateTimeRange(
        start: DateTime(last7Anchored.start.year, last7Anchored.start.month,
            last7Anchored.start.day, 8, 30),
        end: DateTime(last7Anchored.end.year, last7Anchored.end.month,
            last7Anchored.end.day, 22, 0),
      );
      expect(presetIdMatching(withTime, now), DateRangePresetId.last7);
    });

    test('off-by-one range matches no preset', () {
      final odd = DateTimeRange(
        start: DateTime(2026, 4, 1),
        end: DateTime(2026, 4, 15),
      );
      expect(presetIdMatching(odd, now), isNull);
    });
  });

  int msUtc(int y, [int m = 1, int d = 1, int h = 0, int min = 0]) =>
      DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

  /// Local-time epoch ms — the year a fix belongs to is the LOCAL one,
  /// so the boundary cases have to be expressed in local time.
  int msLocal(int y, int m, int d, int h, [int min = 0]) =>
      DateTime(y, m, d, h, min).millisecondsSinceEpoch;

  group('yearsCovering', () {
    test('null bounds (empty pings table) → empty list', () {
      expect(
        yearsCovering(minUtcMs: null, maxUtcMs: null, now: now),
        isEmpty,
      );
      expect(
        yearsCovering(minUtcMs: msUtc(2024), maxUtcMs: null, now: now),
        isEmpty,
      );
      expect(
        yearsCovering(minUtcMs: null, maxUtcMs: msUtc(2024), now: now),
        isEmpty,
      );
    });

    test('a single year yields exactly that year', () {
      expect(
        yearsCovering(
          minUtcMs: msLocal(2026, 1, 5, 9),
          maxUtcMs: msLocal(2026, 5, 17, 9),
          now: now,
        ),
        [2026],
      );
    });

    test('one instant (min == max) yields one year', () {
      final t = msLocal(2021, 7, 4, 12);
      expect(yearsCovering(minUtcMs: t, maxUtcMs: t, now: now), [2021]);
    });

    test('2023-01-05 .. 2026-08-22 → [2026, 2025, 2024, 2023] descending',
        () {
      expect(
        yearsCovering(
          minUtcMs: msLocal(2023, 1, 5, 8),
          maxUtcMs: msLocal(2026, 8, 22, 8),
          now: DateTime(2026, 8, 22, 14),
        ),
        [2026, 2025, 2024, 2023],
      );
    });

    test('every year in the span is listed, gaps included', () {
      // No fixes at all in 2020 — the chip still shows, because the
      // panel cannot know that without a per-year count, and an empty
      // year is a legitimate (if boring) answer.
      final out = yearsCovering(
        minUtcMs: msLocal(2018, 3, 1, 0),
        maxUtcMs: msLocal(2022, 3, 1, 0),
        now: DateTime(2026, 1, 1),
      );
      expect(out, [2022, 2021, 2020, 2019, 2018]);
    });

    test('boundaries are LOCAL: 1 Jan 00:05 local starts a new year', () {
      expect(
        yearsCovering(
          minUtcMs: msLocal(2025, 12, 31, 23, 55),
          maxUtcMs: msLocal(2026, 1, 1, 0, 5),
          now: now,
        ),
        [2026, 2025],
      );
    });

    test('31 Dec 23:55 local on both ends stays inside the old year', () {
      final t = msLocal(2025, 12, 31, 23, 55);
      expect(yearsCovering(minUtcMs: t, maxUtcMs: t, now: now), [2025]);
    });

    test('a clock-skewed future stamp is clamped at the current year', () {
      // One 2099 row must not spray 74 chips across the panel.
      final out = yearsCovering(
        minUtcMs: msLocal(2024, 1, 1, 0),
        maxUtcMs: msLocal(2099, 1, 1, 0),
        now: DateTime(2026, 5, 17),
      );
      expect(out, [2026, 2025, 2024]);
    });

    test('a wholly-future dataset still yields its own year (clamp never '
        'cuts below the oldest)', () {
      final out = yearsCovering(
        minUtcMs: msLocal(2030, 1, 1, 0),
        maxUtcMs: msLocal(2030, 6, 1, 0),
        now: DateTime(2026, 5, 17),
      );
      expect(out, [2030]);
    });

    test('reversed bounds are tolerated', () {
      expect(
        yearsCovering(
          minUtcMs: msLocal(2026, 1, 1, 0),
          maxUtcMs: msLocal(2024, 1, 1, 0),
          now: now,
        ),
        [2026, 2025, 2024],
      );
    });
  });

  group('rangeForYear', () {
    test('spans 1 Jan → 31 Dec, both at local midnight', () {
      final r = rangeForYear(2024);
      expect(r.start, DateTime(2024, 1, 1));
      expect(r.end, DateTime(2024, 12, 31));
    });

    test('leap years end on the 31st too', () {
      expect(rangeForYear(2024).end, DateTime(2024, 12, 31));
      expect(rangeForYear(2025).end, DateTime(2025, 12, 31));
    });

    test('the MAP clip covers the whole year to the last millisecond and '
        'not a tick more', () {
      final b = mapRangeUtcBounds(rangeForYear(2024));
      expect(b.startUtc, DateTime(2024, 1, 1).toUtc());
      expect(b.endUtc, DateTime(2024, 12, 31, 23, 59, 59, 999).toUtc());
      // The first instant of the next year must fall outside.
      expect(
        b.endUtc.isBefore(DateTime(2025, 1, 1).toUtc()),
        isTrue,
        reason: 'a "2024" chip must not leak 1 Jan 2025 onto the map',
      );
    });

    test('the EXPORT clip lands on the same instant, exclusive', () {
      final b = exportRangeUtcBounds(rangeForYear(2024));
      expect(b.startUtc, DateTime(2024, 1, 1).toUtc());
      expect(b.endUtcExclusive, DateTime(2025, 1, 1).toUtc());
    });

    test('consecutive years tile without overlapping', () {
      final a = mapRangeUtcBounds(rangeForYear(2024));
      final b = mapRangeUtcBounds(rangeForYear(2025));
      expect(a.endUtc.isBefore(b.startUtc), isTrue);
      expect(
        b.startUtc.difference(a.endUtc),
        const Duration(milliseconds: 1),
      );
    });
  });

  group('yearOfRange', () {
    test('an exact calendar year returns that year', () {
      expect(yearOfRange(rangeForYear(2024)), 2024);
      expect(yearOfRange(rangeForYear(1999)), 1999);
    });

    test('tolerates a time-of-day on either end', () {
      expect(
        yearOfRange(DateTimeRange(
          start: DateTime(2024, 1, 1, 6, 30),
          end: DateTime(2024, 12, 31, 22, 15),
        )),
        2024,
      );
    });

    test('null range ("All time") → null', () {
      expect(yearOfRange(null), isNull);
    });

    test('Last 30 days → null', () {
      expect(yearOfRange(dateRangePresets(now)[3].range), isNull);
    });

    test('Today → null', () {
      expect(yearOfRange(dateRangePresets(now).first.range), isNull);
    });

    test('a range that misses either end of the year → null', () {
      expect(
        yearOfRange(DateTimeRange(
          start: DateTime(2024, 1, 2),
          end: DateTime(2024, 12, 31),
        )),
        isNull,
      );
      expect(
        yearOfRange(DateTimeRange(
          start: DateTime(2024, 1, 1),
          end: DateTime(2024, 12, 30),
        )),
        isNull,
      );
    });

    test('a two-year span → null', () {
      expect(
        yearOfRange(DateTimeRange(
          start: DateTime(2024, 1, 1),
          end: DateTime(2025, 12, 31),
        )),
        isNull,
      );
    });

    test('round-trips every year chip the panel can render', () {
      for (final y in yearsCovering(
        minUtcMs: DateTime(2018, 4, 1).millisecondsSinceEpoch,
        maxUtcMs: DateTime(2026, 4, 1).millisecondsSinceEpoch,
        now: DateTime(2026, 5, 17),
      )) {
        expect(yearOfRange(rangeForYear(y)), y);
      }
    });
  });
}
