import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/db/import_dao.dart';
import 'package:trail/providers/import_provider.dart';
import 'package:trail/screens/import_timeline_screen.dart';

/// The "Timeline imports" sheet (Settings → History). It grew a
/// per-import "Map detail…" action: the Settings fetch button only
/// covers the last 365 days, so an import of 2015–2019 was otherwise
/// permanently out of reach of map detail — and if no server was set up
/// at import time, the one-shot offer never appeared at all.

ImportRecord _record({int id = 1, int rows = 120, String? file}) =>
    ImportRecord(
      id: id,
      importedAtUtc: DateTime.utc(2026, 8, 22, 9, 30),
      fileName: file ?? 'Timeline.json',
      fileHash: 'hash$id',
      preset: 'normal',
      rowCount: rows,
      tsMinUtc: DateTime.utc(2015, 1, 1),
      tsMaxUtc: DateTime.utc(2019, 12, 31),
    );

Future<void> _openSheet(
  WidgetTester tester, {
  required List<ImportRecord> records,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        importHistoryProvider.overrideWith((ref) async => records),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTimelineImportsSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every import row offers Map detail alongside Undo',
      (tester) async {
    await _openSheet(tester, records: [_record(id: 1), _record(id: 2)]);
    expect(find.byTooltip('Map detail…'), findsNWidgets(2));
    expect(find.byTooltip('Undo import'), findsNWidgets(2));
  });

  testWidgets('the row still shows its count, preset and file', (tester) async {
    await _openSheet(tester, records: [_record(rows: 120)]);
    expect(find.textContaining('120 pings · normal'), findsOneWidget);
    expect(find.textContaining('Timeline.json'), findsOneWidget);
  });

  testWidgets('the empty state has no per-import actions', (tester) async {
    await _openSheet(tester, records: const []);
    expect(find.text('No Timeline imports yet'), findsOneWidget);
    expect(find.byTooltip('Map detail…'), findsNothing);
    expect(find.byTooltip('Photos…'), findsNothing);
  });

  // Photos for an import are opt-in, per import: imported coordinates
  // may only reach Wikimedia when the user has read what gets sent and
  // tapped Fetch (CLAUDE.md gotcha 21).
  group('Photos…', () {
    testWidgets('every row offers it alongside Map detail and Undo',
        (tester) async {
      await _openSheet(tester, records: [_record(id: 1), _record(id: 2)]);
      expect(find.byTooltip('Photos…'), findsNWidgets(2));
      expect(find.byTooltip('Map detail…'), findsNWidgets(2));
      expect(find.byTooltip('Undo import'), findsNWidgets(2));
    });

    testWidgets('asks first, naming what is sent and to whom',
        (tester) async {
      await _openSheet(tester, records: [_record(rows: 120)]);
      await tester.tap(find.byTooltip('Photos…'));
      await tester.pumpAndSettle();

      expect(find.text('Fetch photos for this import?'), findsOneWidget);
      expect(
        find.textContaining(
          'Sends the coordinates of up to 120 imported places to Wikimedia '
          'Commons',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Imports never do this on their own.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Fetch'), findsOneWidget);
    });

    testWidgets('a one-ping import is asked about in the singular',
        (tester) async {
      await _openSheet(tester, records: [_record(rows: 1)]);
      await tester.tap(find.byTooltip('Photos…'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('up to 1 imported place to Wikimedia'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel sends nothing and leaves the sheet standing',
        (tester) async {
      await _openSheet(tester, records: [_record()]);
      await tester.tap(find.byTooltip('Photos…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Fetch photos for this import?'), findsNothing);
      // The progress dialog is the first thing a real fetch pushes.
      expect(find.text('Fetching photos'), findsNothing);
      expect(find.byTooltip('Photos…'), findsOneWidget);
    });
  });
}
