import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/widgets/trail_map.dart';

Ping _fix({required DateTime ts, double lat = 42.37, double lon = -71.10}) =>
    Ping(
      timestampUtc: ts,
      lat: lat,
      lon: lon,
      source: PingSource.scheduled,
    );

Ping _noFix(DateTime ts) => Ping(
      timestampUtc: ts,
      source: PingSource.noFix,
    );

Future<void> _pumpWith(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('TrailMap', () {
    testWidgets('renders a helpful message with no fixes', (tester) async {
      await _pumpWith(tester, const TrailMap(pings: []));
      expect(find.textContaining('No fixes yet'), findsOneWidget);
    });

    testWidgets('renders a helpful message with exactly one fix',
        (tester) async {
      await _pumpWith(
        tester,
        TrailMap(pings: [_fix(ts: DateTime.utc(2026, 4, 18))]),
      );
      expect(find.textContaining('Only one fix'), findsOneWidget);
    });

    testWidgets('ignores rows without lat/lon when counting fixes',
        (tester) async {
      // Two no_fix rows + one real fix should fall through to the
      // single-fix message, not the multi-fix CustomPaint.
      await _pumpWith(
        tester,
        TrailMap(pings: [
          _noFix(DateTime.utc(2026, 4, 18, 10)),
          _fix(ts: DateTime.utc(2026, 4, 18, 14)),
          _noFix(DateTime.utc(2026, 4, 18, 18)),
        ]),
      );
      expect(find.textContaining('Only one fix'), findsOneWidget);
    });

    testWidgets('draws a CustomPaint when at least two fixes exist',
        (tester) async {
      final pings = List.generate(
        5,
        (i) => _fix(
          ts: DateTime.utc(2026, 4, 18, i * 4),
          lat: 42.37 + i * 0.01,
          lon: -71.10 + i * 0.01,
        ),
      );
      await _pumpWith(tester, TrailMap(pings: pings));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.textContaining('No fixes'), findsNothing);
      expect(find.textContaining('Only one fix'), findsNothing);
    });

    testWidgets('handles degenerate bbox (all pings at one spot)',
        (tester) async {
      // All three fixes at the same coordinate — the painter must not
      // divide-by-zero on a zero-span lat/lon range.
      final pings = List.generate(
        3,
        (i) => _fix(
          ts: DateTime.utc(2026, 4, 18, i * 4),
          lat: 42.37,
          lon: -71.10,
        ),
      );
      await _pumpWith(tester, TrailMap(pings: pings));
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
