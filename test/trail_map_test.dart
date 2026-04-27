import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/widgets/trail_map.dart';

/// Widget-test coverage for [TrailMap].
///
/// We cover the **placeholder** branches (zero fixes, no region installed)
/// because those render pure Flutter widgets we can assert on. We do
/// *not* mount [TrailMap] with a real region in tests — that path
/// instantiates `MapLibreMap`, which talks to the native platform view
/// layer that doesn't exist in `flutter_test`. The map render itself is
/// covered by `maplibre`'s own integration tests upstream.

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

Future<void> _pumpWith(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: child),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('TrailMap placeholder branches', () {
    testWidgets('renders a helpful message when there are zero fixes',
        (tester) async {
      await _pumpWith(tester, const TrailMap(pings: []));
      expect(find.textContaining('No fixes yet'), findsOneWidget);
    });

    testWidgets('ignores rows without lat/lon when counting fixes',
        (tester) async {
      // Two no_fix rows + zero real fixes should hit the "no fixes"
      // placeholder, not try to mount the map.
      await _pumpWith(
        tester,
        TrailMap(pings: [
          _noFix(DateTime.utc(2026, 4, 18, 10)),
          _noFix(DateTime.utc(2026, 4, 18, 18)),
        ]),
      );
      expect(find.textContaining('No fixes yet'), findsOneWidget);
    });

    testWidgets('shows the install-region prompt when fixes exist but no '
        'region is active', (tester) async {
      // App is offline-only — no online tile fallback. Without a region
      // installed the widget must point the user at the regions screen
      // rather than mounting a blank or broken map.
      await _pumpWith(
        tester,
        TrailMap(pings: [_fix(ts: DateTime.utc(2026, 4, 18))]),
      );
      expect(find.textContaining('Install an offline map region'),
          findsOneWidget);
      expect(find.textContaining('Settings'), findsOneWidget);
    });
  });

  group('TilesRegion (used by TrailMap)', () {
    test('has a name, path, and byte size', () {
      const region = TilesRegion(
        name: 'gb',
        path: '/data/files/tiles/gb.pmtiles',
        bytes: 511 * 1024 * 1024,
      );
      expect(region.name, 'gb');
      expect(region.path, '/data/files/tiles/gb.pmtiles');
      expect(region.bytes, 511 * 1024 * 1024);
    });
  });
}
