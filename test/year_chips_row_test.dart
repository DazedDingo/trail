import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trail/widgets/year_chips_row.dart';

/// Widget coverage for the shared year-chip row (0.16.2) — the map's
/// date filter panel and the History screen both mount this one widget,
/// so its contract is pinned here rather than twice at the call sites.
/// No map is involved (gotcha 18): it is chips and callbacks.

Future<void> _pump(
  WidgetTester tester, {
  required List<int> years,
  int? selectedYear,
  ValueChanged<int>? onYear,
  ValueChanged<List<int>>? onOlder,
  VoidCallback? onAll,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: YearChipsRow(
          years: years,
          selectedYear: selectedYear,
          onYear: onYear ?? (_) {},
          onOlder: onOlder,
          onAll: onAll,
        ),
      ),
    ),
  );
}

bool _chipSelected(WidgetTester tester, String label) => tester
    .widget<ChoiceChip>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(ChoiceChip),
      ),
    )
    .selected;

void main() {
  group('YearChipsRow — rendering', () {
    testWidgets('renders one chip per year, newest first', (tester) async {
      await _pump(tester, years: const [2026, 2025, 2024]);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('2025'), findsOneWidget);
      expect(find.text('2024'), findsOneWidget);
      final xs = [
        for (final y in ['2026', '2025', '2024'])
          tester.getTopLeft(find.text(y)).dx,
      ];
      expect(xs[0], lessThan(xs[1]));
      expect(xs[1], lessThan(xs[2]));
    });

    testWidgets('an empty year list renders no chips', (tester) async {
      await _pump(tester, years: const []);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Older…'), findsNothing);
    });

    testWidgets('the selected year renders selected, the others do not',
        (tester) async {
      await _pump(tester, years: const [2026, 2025], selectedYear: 2025);
      expect(_chipSelected(tester, '2025'), isTrue);
      expect(_chipSelected(tester, '2026'), isFalse);
    });

    testWidgets('a selectedYear with no chip selects nothing',
        (tester) async {
      await _pump(tester, years: const [2026, 2025], selectedYear: 1999);
      expect(_chipSelected(tester, '2026'), isFalse);
      expect(_chipSelected(tester, '2025'), isFalse);
    });
  });

  group('YearChipsRow — the optional "All" chip', () {
    testWidgets('absent when onAll is null (the map panel keeps its own '
        '"All time" preset)', (tester) async {
      await _pump(tester, years: const [2026, 2025]);
      expect(find.text('All'), findsNothing);
    });

    testWidgets('present and selected when onAll is set and no year is',
        (tester) async {
      await _pump(tester, years: const [2026, 2025], onAll: () {});
      expect(find.text('All'), findsOneWidget);
      expect(_chipSelected(tester, 'All'), isTrue);
      // It leads the row.
      expect(
        tester.getTopLeft(find.text('All')).dx,
        lessThan(tester.getTopLeft(find.text('2026')).dx),
      );
    });

    testWidgets('deselected once a year is picked', (tester) async {
      await _pump(
        tester,
        years: const [2026, 2025],
        selectedYear: 2026,
        onAll: () {},
      );
      expect(_chipSelected(tester, 'All'), isFalse);
      expect(_chipSelected(tester, '2026'), isTrue);
    });

    testWidgets('tapping it fires onAll', (tester) async {
      var calls = 0;
      await _pump(
        tester,
        years: const [2026, 2025],
        selectedYear: 2025,
        onAll: () => calls++,
      );
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  group('YearChipsRow — callbacks', () {
    testWidgets('tapping a year chip reports that year once', (tester) async {
      final tapped = <int>[];
      await _pump(
        tester,
        years: const [2026, 2025, 2024],
        onYear: tapped.add,
      );
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();
      expect(tapped, [2024]);
    });

    testWidgets('tapping the already-selected year still reports it',
        (tester) async {
      final tapped = <int>[];
      await _pump(
        tester,
        years: const [2026],
        selectedYear: 2026,
        onYear: tapped.add,
      );
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(tapped, [2026]);
    });
  });

  group('YearChipsRow — overflow', () {
    testWidgets('exactly 12 years all get their own chip', (tester) async {
      final years = [for (var y = 2026; y >= 2015; y--) y]; // 12
      await _pump(tester, years: years);
      expect(find.byType(ChoiceChip), findsNWidgets(12));
      expect(find.text('Older…'), findsNothing);
      expect(find.text('2015'), findsOneWidget);
    });

    testWidgets('beyond 12 years the oldest collapse into "Older…"',
        (tester) async {
      final years = [for (var y = 2026; y >= 2010; y--) y]; // 17
      await _pump(tester, years: years);
      // 11 year chips + one "Older…" = 12 slots.
      expect(find.byType(ChoiceChip), findsNWidgets(11));
      expect(find.text('2016'), findsOneWidget); // the 11th, still a chip
      expect(find.text('2015'), findsNothing); // the 12th, folded away
      expect(find.text('Older…'), findsOneWidget);
    });

    testWidgets('"Older…" hands back every hidden year, newest first',
        (tester) async {
      final years = [for (var y = 2026; y >= 2010; y--) y]; // 17
      List<int>? hidden;
      await _pump(tester, years: years, onOlder: (h) => hidden = h);
      await tester.tap(find.text('Older…'));
      await tester.pumpAndSettle();
      expect(hidden, [for (var y = 2015; y >= 2010; y--) y]);
    });

    testWidgets('the All chip does not eat a year slot', (tester) async {
      final years = [for (var y = 2026; y >= 2015; y--) y]; // 12
      await _pump(tester, years: years, onAll: () {});
      // 12 years + All, still no overflow chip.
      expect(find.byType(ChoiceChip), findsNWidgets(13));
      expect(find.text('Older…'), findsNothing);
    });
  });

  group('shouldShowYearChips', () {
    test('hidden on a fresh install — one year and it is the current one',
        () {
      expect(shouldShowYearChips(const [2026], 2026), isFalse);
    });

    test('hidden while the provider has not resolved', () {
      expect(shouldShowYearChips(const [], 2026), isFalse);
    });

    test('shown for two or more years', () {
      expect(shouldShowYearChips(const [2026, 2025], 2026), isTrue);
    });

    test('shown for a single non-current year (the just-imported case)', () {
      expect(shouldShowYearChips(const [2015], 2026), isTrue);
    });
  });
}
