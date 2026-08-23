import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:trail/providers/pings_provider.dart';
import 'package:trail/providers/places_provider.dart';
import 'package:trail/screens/places_screen.dart';
import 'package:trail/services/geocoding_service.dart';
import 'package:trail/services/stats/places_service.dart';

/// UX-level coverage for the Places screen's second de-duplication pass
/// (0.17.5): rows the reverse geocoder gives the same name collapse into
/// one, and the row says how many spots it stands for. The maths itself
/// is pinned in `places_service_test.dart`; this only proves the screen
/// feeds `mergeByLabel` the labels as they land and renders the hint.
///
/// Providers are faked in-memory — the DB read behind `placesProvider`
/// can't resolve inside `testWidgets`' fake-async zone, and there is no
/// platform geocoder in a widget test.

/// [metres] north of 51.5 — 1e-4° of latitude is ~11.1 m.
double _north(double metres) => 51.5 + metres / 111320.0;

PlaceSummary _place(
  String key, {
  required double lat,
  int visits = 2,
  List<String> types = const [],
}) =>
    PlaceSummary(
      key: key,
      memberKeys: [key],
      semanticTypes: types,
      lat: lat,
      lon: -0.1,
      visitCount: visits,
      firstMs: DateTime.utc(2024, 1, 3, 9).millisecondsSinceEpoch,
      lastMs: DateTime.utc(2024, 5, 3, 9).millisecondsSinceEpoch,
      totalDuration: const Duration(hours: 2),
      longestVisit: const Duration(hours: 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<PlaceSummary> places,
  String? Function(double lat, double lon)? name,
  Duration delay = Duration.zero,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        placesProvider.overrideWith((_) => places),
        geocodingServiceProvider.overrideWithValue(
          GeocodingService(
            lookup: (lat, lon) async {
              if (delay > Duration.zero) await Future<void>.delayed(delay);
              final label = name?.call(lat, lon);
              return label == null
                  ? const <Placemark>[]
                  : [Placemark(locality: label, administrativeArea: 'Bristol')];
            },
          ),
        ),
      ],
      child: const MaterialApp(home: PlacesScreen()),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets('same-named places within 1 km collapse into one row once '
      'the labels resolve', (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5),
        _place('b', lat: _north(300)),
        _place('c', lat: _north(600)),
      ],
      name: (_, __) => 'Redcliffe',
    );

    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('Redcliffe, Bristol'), findsOneWidget);
    expect(find.text('×3 spots'), findsOneWidget);
    // 3 rows × 2 visits, summed on the surviving row.
    expect(
      find.textContaining('6 visits'),
      findsOneWidget,
      reason: 'the merged row sums its members',
    );
  });

  testWidgets('rows stay separate while the labels are still loading',
      (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5),
        _place('b', lat: _north(300)),
        _place('c', lat: _north(600)),
      ],
      name: (_, __) => 'Redcliffe',
      delay: const Duration(milliseconds: 50),
      settle: false,
    );
    await tester.pump();

    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('×3 spots'), findsNothing);

    // …and collapse of their own accord once the labels land.
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('×3 spots'), findsOneWidget);
  });

  testWidgets('no label from the geocoder → no merge, coordinates as titles',
      (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5),
        _place('b', lat: _north(300)),
      ],
    );

    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.text('×2 spots'), findsNothing);
    expect(find.text('51.5000, -0.1000'), findsOneWidget);
  });

  testWidgets('the same name 5 km apart stays two rows', (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5),
        _place('b', lat: _north(5000)),
      ],
      name: (_, __) => 'High Street',
    );

    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.text('×2 spots'), findsNothing);
    expect(find.text('High Street, Bristol'), findsNWidgets(2));
  });

  testWidgets('a merged row keeps its members type chips', (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5, types: const ['Home']),
        _place('b', lat: _north(300), types: const ['Work']),
      ],
      name: (_, __) => 'Redcliffe',
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('×2 spots'), findsOneWidget);
  });

  testWidgets('sort modes still work on the merged list', (tester) async {
    await _pump(
      tester,
      places: [
        _place('a', lat: 51.5),
        _place('b', lat: _north(300)),
        _place('far', lat: _north(20000), visits: 5),
      ],
      name: (lat, __) => lat > 51.6 ? 'Clifton' : 'Redcliffe',
    );

    expect(find.byType(ListTile), findsNWidgets(2));
    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.text('×2 spots'), findsOneWidget);
  });

  testWidgets('no places → the import empty state', (tester) async {
    await _pump(tester, places: const []);

    expect(find.text('No places yet'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
