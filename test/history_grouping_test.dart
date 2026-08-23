import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:trail/models/ping.dart';
import 'package:trail/providers/pings_provider.dart';
import 'package:trail/screens/history_screen.dart';

/// Pure coverage for the History screen's month grouping + flattening
/// (0.16.2). No DB, no widget tree — the functions are top-level for
/// exactly that reason (same pattern as `filterPingsByRange`, gotcha 13).

/// A ping at a LOCAL wall-clock instant. Built local-then-`toUtc()` so
/// the assertions hold in any timezone the test host happens to run in
/// (grouping is by local month, deliberately).
Ping _at(int y, int m, int d, [int hour = 12]) => Ping(
      timestampUtc: DateTime(y, m, d, hour).toUtc(),
      lat: 51.5,
      lon: -0.1,
      source: PingSource.scheduled,
    );

void main() {
  group('groupByMonth', () {
    test('empty input → no sections', () {
      expect(groupByMonth(const []), isEmpty);
    });

    test('one month → one section holding every row in input order', () {
      final pings = [
        _at(2024, 8, 20),
        _at(2024, 8, 15),
        _at(2024, 8, 1),
      ];
      final sections = groupByMonth(pings);
      expect(sections, hasLength(1));
      expect(sections.single.monthStart, DateTime(2024, 8));
      expect(sections.single.pings, pings);
    });

    test('splits across months, newest section first', () {
      final sections = groupByMonth([
        _at(2024, 9, 2),
        _at(2024, 9, 1),
        _at(2024, 8, 31),
        _at(2024, 7, 4),
      ]);
      expect(
        sections.map((s) => s.monthStart).toList(),
        [DateTime(2024, 9), DateTime(2024, 8), DateTime(2024, 7)],
      );
      expect(sections.map((s) => s.pings.length).toList(), [2, 1, 1]);
    });

    test('splits across a year boundary — Jan and Dec are not one month',
        () {
      final sections = groupByMonth([
        _at(2025, 1, 3),
        _at(2024, 12, 31),
        _at(2023, 12, 31),
      ]);
      expect(
        sections.map((s) => s.monthStart).toList(),
        [DateTime(2025, 1), DateTime(2024, 12), DateTime(2023, 12)],
      );
    });

    test('rows of the same month arriving out of order share ONE section',
        () {
      // Defensive: a duplicate "August 2024" header is the visible bug.
      final sections = groupByMonth([
        _at(2024, 8, 20),
        _at(2024, 9, 1),
        _at(2024, 8, 2),
      ]);
      expect(sections, hasLength(2));
      expect(sections.first.monthStart, DateTime(2024, 8));
      expect(sections.first.pings, hasLength(2));
      expect(sections.last.monthStart, DateTime(2024, 9));
    });

    test('section labels format as "August 2024"', () {
      final sections = groupByMonth([_at(2024, 8, 11)]);
      expect(
        DateFormat.yMMMM().format(sections.single.monthStart),
        'August 2024',
      );
    });

    test('the month key is LOCAL, not UTC', () {
      // 1 Sep 00:30 local belongs to September wherever the host sits.
      final sections = groupByMonth([_at(2024, 9, 1, 0)]);
      expect(sections.single.monthStart, DateTime(2024, 9));
    });
  });

  group('flattenSections', () {
    test('empty → empty', () {
      expect(flattenSections(const []), isEmpty);
    });

    test('interleaves one header per section with its rows', () {
      final items = flattenSections(groupByMonth([
        _at(2024, 9, 2),
        _at(2024, 9, 1),
        _at(2024, 8, 31),
      ]));
      expect(items, hasLength(5)); // 2 headers + 3 rows
      expect(items[0], isA<HistoryMonthHeaderItem>());
      expect(items[1], isA<HistoryPingItem>());
      expect(items[2], isA<HistoryPingItem>());
      expect(items[3], isA<HistoryMonthHeaderItem>());
      expect(items[4], isA<HistoryPingItem>());
      expect((items[0] as HistoryMonthHeaderItem).count, 2);
      expect((items[3] as HistoryMonthHeaderItem).count, 1);
    });

    test('rows keep the newest-first order of the input', () {
      final newest = _at(2024, 9, 2);
      final oldest = _at(2024, 9, 1);
      final items = flattenSections(groupByMonth([newest, oldest]));
      expect((items[1] as HistoryPingItem).ping.timestampUtc,
          newest.timestampUtc);
      expect((items[2] as HistoryPingItem).ping.timestampUtc,
          oldest.timestampUtc);
    });
  });

  group('historyItemExtent', () {
    test('headers are shorter than rows, footers taller than headers', () {
      const scaler = TextScaler.noScaling;
      final header = historyItemExtent(
        HistoryMonthHeaderItem(monthStart: DateTime(2024, 8), count: 1),
        scaler,
      );
      final row = historyItemExtent(HistoryPingItem(_at(2024, 8, 1)), scaler);
      final footer =
          historyItemExtent(const HistoryFooterItem(), scaler);
      expect(header, kHistoryHeaderExtent);
      expect(row, kHistoryRowExtent);
      expect(footer, kHistoryFooterExtent);
      expect(header, lessThan(row));
    });

    test('grows with the user text scale so big fonts do not overflow', () {
      final row = historyItemExtent(
        HistoryPingItem(_at(2024, 8, 1)),
        const TextScaler.linear(2.0),
      );
      expect(row, kHistoryRowExtent * 2);
    });

    test('never shrinks below the base extent on a down-scaled device', () {
      final row = historyItemExtent(
        HistoryPingItem(_at(2024, 8, 1)),
        const TextScaler.linear(0.5),
      );
      expect(row, kHistoryRowExtent);
    });
  });

  group('historyYearUtcBoundsMs', () {
    test('start is local 1 Jan midnight, end is the NEXT 1 Jan (exclusive)',
        () {
      final b = historyYearUtcBoundsMs(2024);
      expect(b.startMs, DateTime(2024, 1, 1).millisecondsSinceEpoch);
      expect(b.endMs, DateTime(2025, 1, 1).millisecondsSinceEpoch);
      expect(b.startMs, lessThan(b.endMs));
    });

    test('the last local millisecond of the year is inside the window', () {
      final b = historyYearUtcBoundsMs(2024);
      final lastMs =
          DateTime(2024, 12, 31, 23, 59, 59, 999).millisecondsSinceEpoch;
      expect(lastMs, greaterThanOrEqualTo(b.startMs));
      expect(lastMs, lessThan(b.endMs));
    });

    test('consecutive years tile with no gap and no shared millisecond', () {
      expect(
        historyYearUtcBoundsMs(2024).endMs,
        historyYearUtcBoundsMs(2025).startMs,
      );
    });
  });
}
