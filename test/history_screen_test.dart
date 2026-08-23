import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:trail/models/ping.dart';
import 'package:trail/providers/pings_provider.dart';
import 'package:trail/screens/history_screen.dart';
import 'package:trail/services/geocoding_service.dart';

/// UX-level coverage for the paginated History screen (0.16.2): the year
/// chip row on top, month headings, the per-year list and its "Load
/// more" footer. Providers are faked in-memory — the SQL they wrap is
/// pinned in `ping_dao_test.dart` (`pageByRange`), and a real ffi DB
/// can't resolve its futures inside `testWidgets`' fake-async zone.

Ping _fix(DateTime local, {PingSource source = PingSource.scheduled}) => Ping(
      timestampUtc: local.toUtc(),
      lat: 51.5,
      lon: -0.1,
      source: source,
    );

/// Serves canned pages per year so "Load more" can be exercised without
/// seeding 200 rows.
class _FakeYearNotifier extends HistoryYearNotifier {
  _FakeYearNotifier(this.pagesByYear);

  final Map<int, List<List<Ping>>> pagesByYear;
  int _index = 0;

  @override
  Future<HistoryYearPage> build(int arg) async {
    _index = 0;
    final pages = pagesByYear[arg] ?? const <List<Ping>>[];
    if (pages.isEmpty) {
      return const HistoryYearPage(pings: [], hasMore: false);
    }
    return HistoryYearPage(pings: pages.first, hasMore: pages.length > 1);
  }

  @override
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore) return;
    final pages = pagesByYear[arg]!;
    _index++;
    state = AsyncData(
      HistoryYearPage(
        pings: [...current.pings, ...pages[_index]],
        hasMore: _index < pages.length - 1,
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  List<Ping> recent = const [],
  List<int> years = const [],
  Map<int, List<List<Ping>>> yearPages = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No platform geocoder in a widget test; "no label" is the
        // normal offline case anyway.
        geocodingServiceProvider.overrideWithValue(
          GeocodingService(lookup: (_, __) async => const <Placemark>[]),
        ),
        historyPingsProvider.overrideWith((_) async => recent),
        pingYearsProvider.overrideWith((_) async => years),
        historyYearProvider.overrideWith(() => _FakeYearNotifier(yearPages)),
      ],
      child: const MaterialApp(home: HistoryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('HistoryScreen — All', () {
    testWidgets('empty database → "No pings yet." and no chips',
        (tester) async {
      await _pump(tester);
      expect(find.text('No pings yet.'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('groups rows under month headings, newest first',
        (tester) async {
      await _pump(
        tester,
        recent: [
          _fix(DateTime(2026, 1, 5, 12)),
          _fix(DateTime(2024, 9, 2, 12)),
          _fix(DateTime(2024, 8, 11, 12)),
        ],
        years: const [2026, 2025, 2024],
      );

      expect(find.text('January 2026'), findsOneWidget);
      expect(find.text('September 2024'), findsOneWidget);
      expect(find.text('August 2024'), findsOneWidget);
      expect(find.text('51.50000, -0.10000'), findsNWidgets(3));
      expect(
        tester.getTopLeft(find.text('January 2026')).dy,
        lessThan(tester.getTopLeft(find.text('August 2024')).dy),
      );
    });

    testWidgets('renders the year chips with "All" selected', (tester) async {
      await _pump(
        tester,
        recent: [_fix(DateTime(2024, 8, 11, 12))],
        years: const [2026, 2025, 2024],
      );
      expect(find.text('All'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('2024'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.ancestor(
              of: find.text('All'),
              matching: find.byType(ChoiceChip),
            ))
            .selected,
        isTrue,
      );
    });

    testWidgets('no chip row on a fresh install (one year, the current one)',
        (tester) async {
      await _pump(
        tester,
        recent: [_fix(DateTime(DateTime.now().year, 1, 5, 12))],
        years: [DateTime.now().year],
      );
      expect(find.text('All'), findsNothing);
    });

    testWidgets('imported rows carry an "import" tag', (tester) async {
      await _pump(
        tester,
        recent: [
          _fix(DateTime(2024, 8, 11, 12), source: PingSource.imported),
          _fix(DateTime(2024, 8, 10, 12)),
        ],
        years: const [2026, 2025, 2024],
      );
      expect(find.text('import'), findsOneWidget);
    });
  });

  group('HistoryScreen — year paging', () {
    final pages2024 = {
      2024: [
        [
          _fix(DateTime(2024, 2, 3, 12)),
          _fix(DateTime(2024, 2, 1, 12)),
        ],
        [
          _fix(DateTime(2024, 1, 9, 12)),
        ],
      ],
    };

    testWidgets('picking a year swaps in that year\'s list', (tester) async {
      await _pump(
        tester,
        recent: [_fix(DateTime(2026, 1, 5, 12))],
        years: const [2026, 2025, 2024],
        yearPages: pages2024,
      );
      expect(find.text('January 2026'), findsOneWidget);

      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();

      expect(find.text('February 2024'), findsOneWidget);
      expect(find.text('January 2026'), findsNothing);
    });

    testWidgets('a year with no pings says so', (tester) async {
      await _pump(
        tester,
        recent: [_fix(DateTime(2026, 1, 5, 12))],
        years: const [2026, 2025, 2024],
        yearPages: pages2024,
      );
      await tester.tap(find.text('2025'));
      await tester.pumpAndSettle();
      expect(find.text('No pings in 2025.'), findsOneWidget);
    });

    testWidgets('"All" returns to the recent list', (tester) async {
      await _pump(
        tester,
        recent: [_fix(DateTime(2026, 1, 5, 12))],
        years: const [2026, 2025, 2024],
        yearPages: pages2024,
      );
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();
      expect(find.text('January 2026'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('January 2026'), findsOneWidget);
    });

    testWidgets('"Load more" appends the next page and then retires itself',
        (tester) async {
      await _pump(
        tester,
        recent: const [],
        years: const [2026, 2025, 2024],
        yearPages: pages2024,
      );
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();

      expect(find.text('Load more'), findsOneWidget);
      expect(find.text('January 2024'), findsNothing);

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      // Page 2's row arrived under its own month heading, and there is
      // nothing left to load.
      expect(find.text('January 2024'), findsOneWidget);
      expect(find.text('February 2024'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('no "Load more" when the first page is the whole year',
        (tester) async {
      await _pump(
        tester,
        years: const [2026, 2025, 2024],
        yearPages: {
          2024: [
            [_fix(DateTime(2024, 2, 3, 12))],
          ],
        },
      );
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();
      expect(find.text('February 2024'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });
  });
}
