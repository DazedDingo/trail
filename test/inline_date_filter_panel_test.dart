import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trail/widgets/inline_date_filter_panel.dart';

/// UX-level coverage for the inline date filter panel (#1). The panel
/// is the visible replacement for the previous `showDateRangePicker`
/// modal — these tests assert "is the user shown the controls they
/// need, and do they flow when tapped" without touching the system
/// date picker (which the "Custom range…" chip opens).

Future<void> _pump(
  WidgetTester tester, {
  required bool open,
  DateTimeRange? currentRange,
  required ValueChanged<DateTimeRange?> onApply,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InlineDateFilterPanel(
          open: open,
          currentRange: currentRange,
          now: DateTime(2026, 5, 17),
          earliestPing: DateTime.utc(2024, 1, 1),
          latestPing: DateTime.utc(2026, 5, 17),
          onApply: onApply,
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 260));
}

void main() {
  group('InlineDateFilterPanel — open state', () {
    testWidgets('renders all 5 preset chips + Custom range', (tester) async {
      await _pump(tester, open: true, currentRange: null, onApply: (_) {});
      // Five canonical presets always visible:
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Last 7 days'), findsOneWidget);
      expect(find.text('Last 30 days'), findsOneWidget);
      expect(find.text('All time'), findsOneWidget);
      // Plus the system-picker escape hatch:
      expect(find.text('Custom range…'), findsOneWidget);
    });

    testWidgets(
        'shows "No filter (showing every ping)" header when currentRange '
        'is null', (tester) async {
      await _pump(tester, open: true, currentRange: null, onApply: (_) {});
      expect(find.textContaining('No filter'), findsOneWidget);
    });

    testWidgets(
        'shows the active range in the header line when currentRange is set',
        (tester) async {
      await _pump(
        tester,
        open: true,
        currentRange: DateTimeRange(
          start: DateTime(2026, 5, 11),
          end: DateTime(2026, 5, 17),
        ),
        onApply: (_) {},
      );
      // DateFormat.yMMMd → "May 11, 2026 – May 17, 2026"
      expect(find.textContaining('May 11, 2026'), findsOneWidget);
      expect(find.textContaining('May 17, 2026'), findsOneWidget);
    });

    testWidgets('exposes the Clear chip ONLY when a range is active',
        (tester) async {
      // First — no range, no Clear.
      await _pump(tester, open: true, currentRange: null, onApply: (_) {});
      expect(find.text('Clear'), findsNothing);
      // Then — range active, Clear visible.
      await _pump(
        tester,
        open: true,
        currentRange: DateTimeRange(
          start: DateTime(2026, 5, 17),
          end: DateTime(2026, 5, 17),
        ),
        onApply: (_) {},
      );
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('tapping a preset chip calls onApply with its range',
        (tester) async {
      DateTimeRange? captured;
      var calls = 0;
      await _pump(
        tester,
        open: true,
        currentRange: null,
        onApply: (range) {
          captured = range;
          calls++;
        },
      );
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      // Today preset at the fixed now=2026-05-17 yields a single-day
      // range collapsed to that calendar day.
      expect(captured!.start, DateTime(2026, 5, 17));
      expect(captured!.end, DateTime(2026, 5, 17));
    });

    testWidgets('tapping "All time" applies null (no-filter sentinel)',
        (tester) async {
      DateTimeRange? captured = DateTimeRange(
        start: DateTime(2026, 5, 10),
        end: DateTime(2026, 5, 17),
      );
      var calls = 0;
      await _pump(
        tester,
        open: true,
        currentRange: captured,
        onApply: (range) {
          captured = range;
          calls++;
        },
      );
      await tester.tap(find.text('All time'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(captured, isNull);
    });

    testWidgets('tapping Clear applies null', (tester) async {
      DateTimeRange? captured = DateTimeRange(
        start: DateTime(2026, 5, 10),
        end: DateTime(2026, 5, 17),
      );
      await _pump(
        tester,
        open: true,
        currentRange: captured,
        onApply: (range) {
          captured = range;
        },
      );
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(captured, isNull);
    });

    testWidgets('tapping the close icon fires onClose', (tester) async {
      var closed = 0;
      await _pump(
        tester,
        open: true,
        currentRange: null,
        onApply: (_) {},
        onClose: () => closed++,
      );
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(closed, 1);
    });
  });

  group('InlineDateFilterPanel — closed state', () {
    testWidgets('collapses to zero height and shows no chips',
        (tester) async {
      await _pump(tester, open: false, currentRange: null, onApply: (_) {});
      expect(find.text('Today'), findsNothing);
      expect(find.text('Last 7 days'), findsNothing);
      expect(find.text('Custom range…'), findsNothing);
    });
  });
}
