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
  });
}
