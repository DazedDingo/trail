import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trail/models/ping_photo.dart';
import 'package:trail/providers/photos_provider.dart';
import 'package:trail/screens/photo_backfill_sheet.dart';
import 'package:trail/services/photo_backfill_service.dart';

/// The bug this file exists for (device report, 2026-08-23): "pictures
/// don't seem to display on pins anymore on backfill". `pingPhotosProvider`
/// is a non-autoDispose family, so a pin whose sheet had been opened once
/// kept its cached (empty) list for the life of the process — the walk
/// wrote rows the UI never re-read. The sheet now refreshes the photo
/// reads when the walk lands.

/// Stand-in for the walk: no DB, no HTTP, just the progress events.
class _FakeBackfill extends PhotoBackfillService {
  _FakeBackfill({this.events = const [], this.hangAtEnd = false});

  final List<PhotoBackfillProgress> events;

  /// Leaves the stream open after the last event — the "user swipes the
  /// sheet away mid-walk" case.
  final bool hangAtEnd;

  final Completer<void> _hang = Completer<void>();
  int runs = 0;
  int reshuffles = 0;

  Stream<PhotoBackfillProgress> _emit() async* {
    for (final e in events) {
      yield e;
    }
    if (hangAtEnd) await _hang.future;
  }

  @override
  Stream<PhotoBackfillProgress> run({
    Completer<void>? cancel,
    int? onlyImportId,
  }) {
    runs++;
    return _emit();
  }

  @override
  Stream<PhotoBackfillProgress> reshuffle({Completer<void>? cancel}) {
    reshuffles++;
    return _emit();
  }
}

/// Counts how often the pin-gallery read is (re)computed and captures the
/// latest photo-library revision, both from inside the sheet's own
/// `ProviderScope`. One read at first pump; a refresh makes it two.
class _Probe {
  int photoReads = 0;
  Object? revision;
}

Future<ValueNotifier<bool>> _pumpSheet(
  WidgetTester tester, {
  required PhotoBackfillService service,
  required _Probe probe,
}) async {
  final visible = ValueNotifier<bool>(true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pingPhotosProvider.overrideWith((ref, pingId) async {
          probe.photoReads++;
          return const <PingPhoto>[];
        }),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    probe.revision = ref.watch(photoLibraryRevisionProvider);
                    ref.watch(pingPhotosProvider(7));
                    return const SizedBox(width: 1, height: 1);
                  },
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (_, show, __) => show
                      ? PhotoBackfillSheet(service: service)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return visible;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

PhotoBackfillProgress _p({
  int processed = 0,
  int total = 0,
  int photosAdded = 0,
  int importedTotal = 0,
  bool finished = false,
}) =>
    PhotoBackfillProgress(
      processed: processed,
      total: total,
      photosAdded: photosAdded,
      importedTotal: importedTotal,
      finished: finished,
    );

void main() {
  group('refreshing the photo reads', () {
    testWidgets('a finished walk that added photos refreshes them',
        (tester) async {
      final probe = _Probe();
      await _pumpSheet(
        tester,
        probe: probe,
        service: _FakeBackfill(events: [
          _p(total: 2),
          _p(processed: 1, total: 2, photosAdded: 3),
          _p(processed: 2, total: 2, photosAdded: 5, finished: true),
        ]),
      );
      final before = probe.revision;
      expect(probe.photoReads, 1, reason: 'the first read is the baseline');

      await _tap(tester, 'Start backfill');
      await tester.pumpAndSettle();

      expect(probe.photoReads, 2,
          reason: 'the pin gallery re-reads instead of serving its cache');
      expect(probe.revision, isNot(before));
      expect(probe.revision, isNotNull);
    });

    testWidgets('a walk that added nothing leaves the caches alone',
        (tester) async {
      final probe = _Probe();
      await _pumpSheet(
        tester,
        probe: probe,
        service: _FakeBackfill(events: [_p(), _p(finished: true)]),
      );
      final before = probe.revision;

      await _tap(tester, 'Start backfill');
      // Not `pumpAndSettle`: a zero-total walk paints an indeterminate
      // progress bar, which never settles.
      await tester.pump();
      await tester.pump();

      expect(find.text('All pings already have photos.'), findsOneWidget);
      expect(probe.photoReads, 1, reason: 'nothing was written to re-read');
      expect(probe.revision, same(before));
    });

    testWidgets('re-shuffle refreshes even when it adds nothing — it '
        'deleted every wikimedia row first', (tester) async {
      final probe = _Probe();
      final service = _FakeBackfill(events: [_p(finished: true)]);
      await _pumpSheet(tester, probe: probe, service: service);
      final before = probe.revision;

      await _tap(tester, 'Re-shuffle (different photos)');
      await tester.pump();
      await tester.pump();

      expect(service.reshuffles, 1);
      expect(probe.photoReads, 2);
      expect(probe.revision, isNot(before));
    });

    testWidgets('photos that landed before the sheet was swiped away still '
        'refresh', (tester) async {
      final probe = _Probe();
      final visible = await _pumpSheet(
        tester,
        probe: probe,
        service: _FakeBackfill(
          events: [_p(processed: 1, total: 9, photosAdded: 4)],
          hangAtEnd: true,
        ),
      );
      final before = probe.revision;

      await _tap(tester, 'Start backfill');
      await tester.pump();
      expect(probe.photoReads, 1, reason: 'nothing refreshed mid-walk yet');

      visible.value = false;
      await tester.pumpAndSettle();

      expect(probe.photoReads, 2);
      expect(probe.revision, isNot(before));
    });

    testWidgets('a sheet that was opened and closed without starting '
        'refreshes nothing', (tester) async {
      final probe = _Probe();
      final visible = await _pumpSheet(
        tester,
        probe: probe,
        service: _FakeBackfill(events: [_p(finished: true)]),
      );
      final before = probe.revision;

      visible.value = false;
      await tester.pumpAndSettle();

      expect(probe.photoReads, 1);
      expect(probe.revision, same(before));
    });
  });

  group('copy', () {
    testWidgets('the privacy subtitle says imported pins are included',
        (tester) async {
      await _pumpSheet(
        tester,
        probe: _Probe(),
        service: _FakeBackfill(events: [_p(finished: true)]),
      );

      expect(
        find.textContaining(
          'Imported Timeline pins are included in this manual run',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('imports still never fetch on their own'),
        findsOneWidget,
      );
    });

    testWidgets('the progress block shows the imported split',
        (tester) async {
      await _pumpSheet(
        tester,
        probe: _Probe(),
        service: _FakeBackfill(events: [_p(total: 12, importedTotal: 5)]),
      );

      await _tap(tester, 'Start backfill');
      await tester.pump();

      expect(
        find.text('12 pings without photos — 5 of them imported'),
        findsOneWidget,
      );
    });

    testWidgets('no imported clause when the walk has no imported pins',
        (tester) async {
      await _pumpSheet(
        tester,
        probe: _Probe(),
        service: _FakeBackfill(events: [_p(total: 4)]),
      );

      await _tap(tester, 'Start backfill');
      await tester.pump();

      expect(find.text('4 pings without photos'), findsOneWidget);
      expect(find.textContaining('of them imported'), findsNothing);
    });

    testWidgets('a single imported pin reads in the singular',
        (tester) async {
      await _pumpSheet(
        tester,
        probe: _Probe(),
        service: _FakeBackfill(events: [_p(total: 1, importedTotal: 1)]),
      );

      await _tap(tester, 'Start backfill');
      await tester.pump();

      expect(
        find.text('1 ping without photos — 1 of them imported'),
        findsOneWidget,
      );
    });
  });
}
