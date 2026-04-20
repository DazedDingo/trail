import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/screens/export_dialog.dart';

/// Helpers to build pings for the filter tests without writing the full
/// constructor each time.
Ping _pingAt(DateTime tsUtc) => Ping(
      timestampUtc: tsUtc,
      source: PingSource.scheduled,
    );

void main() {
  group('filterPingsByRange', () {
    test('null range returns rows unchanged', () {
      final rows = [
        _pingAt(DateTime.utc(2026, 1, 1)),
        _pingAt(DateTime.utc(2026, 6, 1)),
      ];
      expect(filterPingsByRange(rows, null), equals(rows));
    });

    test('empty input returns empty regardless of range', () {
      final range = DateTimeRange(
        start: DateTime(2026, 4, 20),
        end: DateTime(2026, 4, 20),
      );
      expect(filterPingsByRange(<Ping>[], range), isEmpty);
    });

    test('single-day range includes every ping from that local day', () {
      // User picks "2026-04-20 → 2026-04-20" (date-only, local midnight).
      // Filter should include pings from local 00:00 through local 23:59:59.
      final range = DateTimeRange(
        start: DateTime(2026, 4, 20),
        end: DateTime(2026, 4, 20),
      );
      final localStart = DateTime(2026, 4, 20).toUtc();
      final localNoon = DateTime(2026, 4, 20, 12, 0).toUtc();
      final localEndOfDay = DateTime(2026, 4, 20, 23, 59, 59).toUtc();
      final rows = [
        _pingAt(localStart.subtract(const Duration(seconds: 1))), // out
        _pingAt(localStart), // in (inclusive start)
        _pingAt(localNoon), // in
        _pingAt(localEndOfDay), // in
        _pingAt(DateTime(2026, 4, 21).toUtc()), // out (exclusive end)
      ];
      final result = filterPingsByRange(rows, range);
      expect(result, hasLength(3));
      expect(
        result.map((p) => p.timestampUtc).toList(),
        [localStart, localNoon, localEndOfDay],
      );
    });

    test('start is inclusive, end-of-day is the exclusive upper bound', () {
      final range = DateTimeRange(
        start: DateTime(2026, 1, 10),
        end: DateTime(2026, 1, 12),
      );
      final startUtc = DateTime(2026, 1, 10).toUtc();
      final justAfterEnd = DateTime(2026, 1, 13).toUtc();
      final rows = [
        _pingAt(startUtc), // boundary: should be in
        _pingAt(justAfterEnd), // boundary: should be out
      ];
      final result = filterPingsByRange(rows, range);
      expect(result, hasLength(1));
      expect(result.single.timestampUtc, startUtc);
    });

    test('multi-day range spans the middle days too', () {
      final range = DateTimeRange(
        start: DateTime(2026, 4, 18),
        end: DateTime(2026, 4, 20),
      );
      final rows = [
        _pingAt(DateTime(2026, 4, 17, 12).toUtc()), // out
        _pingAt(DateTime(2026, 4, 18, 3).toUtc()), // in
        _pingAt(DateTime(2026, 4, 19, 9).toUtc()), // in
        _pingAt(DateTime(2026, 4, 20, 23).toUtc()), // in
        _pingAt(DateTime(2026, 4, 21, 0, 0, 1).toUtc()), // out
      ];
      expect(filterPingsByRange(rows, range), hasLength(3));
    });

    test('preserves input order of the matching rows', () {
      final range = DateTimeRange(
        start: DateTime(2026, 4, 20),
        end: DateTime(2026, 4, 20),
      );
      final a = _pingAt(DateTime(2026, 4, 20, 1).toUtc());
      final b = _pingAt(DateTime(2026, 4, 20, 5).toUtc());
      final c = _pingAt(DateTime(2026, 4, 20, 20).toUtc());
      expect(filterPingsByRange([c, a, b], range), equals([c, a, b]));
    });
  });
}
