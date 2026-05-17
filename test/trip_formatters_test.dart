import 'package:flutter_test/flutter_test.dart';

import 'package:trail/screens/trips_screen.dart';
import 'package:trail/services/stats/stats_service.dart';

Trip _trip({
  required DateTime start,
  required DateTime end,
  double maxMeters = 12345,
  int pings = 12,
}) =>
    Trip(
      startUtc: start.toUtc(),
      endUtc: end.toUtc(),
      maxDistanceMeters: maxMeters,
      pingCount: pings,
      centroidLat: 0,
      centroidLon: 0,
    );

void main() {
  group('formatTripDateRange', () {
    test('same-day trip renders as a single yMMMd', () {
      final out = formatTripDateRange(_trip(
        start: DateTime(2026, 5, 17, 9),
        end: DateTime(2026, 5, 17, 19),
      ));
      expect(out, 'May 17, 2026');
    });

    test('same-month trip collapses to day-range + month + year', () {
      final out = formatTripDateRange(_trip(
        start: DateTime(2026, 5, 12, 9),
        end: DateTime(2026, 5, 15, 19),
      ));
      expect(out, '12–15 May 2026');
    });

    test('cross-month trip uses full dates on both ends', () {
      final out = formatTripDateRange(_trip(
        start: DateTime(2026, 4, 28),
        end: DateTime(2026, 5, 4),
      ));
      // DateFormat.yMMMd → "Apr 28, 2026 – May 4, 2026"
      expect(out.contains('Apr'), isTrue);
      expect(out.contains('May'), isTrue);
      expect(out.contains('–'), isTrue);
    });
  });

  group('formatTripSubtitle', () {
    test('< 1 h duration renders as minutes', () {
      final t = _trip(
        start: DateTime(2026, 5, 17, 9),
        end: DateTime(2026, 5, 17, 9, 47),
        maxMeters: 12000,
        pings: 4,
      );
      // 47 min, 12 km
      expect(formatTripSubtitle(t),
          '47 min · up to 12.0 km from home · 4 pings');
    });

    test('1–9.9 h duration shows one decimal', () {
      final t = _trip(
        start: DateTime(2026, 5, 17, 9),
        end: DateTime(2026, 5, 17, 16, 30),
        maxMeters: 50000,
        pings: 12,
      );
      // 7.5 h, 50 km
      expect(formatTripSubtitle(t),
          '7.5 h · up to 50.0 km from home · 12 pings');
    });

    test('10+ h duration drops the decimal', () {
      final t = _trip(
        start: DateTime(2026, 5, 17, 9),
        end: DateTime(2026, 5, 17, 21),
        maxMeters: 99500,
        pings: 20,
      );
      // 12 h, 99.5 km
      expect(formatTripSubtitle(t),
          '12 h · up to 99.5 km from home · 20 pings');
    });

    test('> 24 h duration renders as days with one decimal', () {
      final t = _trip(
        start: DateTime(2026, 5, 17),
        end: DateTime(2026, 5, 20),
        maxMeters: 150000,
        pings: 30,
      );
      // 72 h = 3.0 d, 150 km (≥100 → drop decimal)
      expect(formatTripSubtitle(t),
          '3.0 d · up to 150 km from home · 30 pings');
    });

    test('singular "1 ping" when count == 1', () {
      final t = _trip(
        start: DateTime(2026, 5, 17, 9),
        end: DateTime(2026, 5, 17, 9, 5),
        maxMeters: 11000,
        pings: 1,
      );
      expect(formatTripSubtitle(t).endsWith('1 ping'), isTrue);
    });
  });
}
