import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
