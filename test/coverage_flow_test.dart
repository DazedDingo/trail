import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/coverage/coverage_flow.dart';
import 'package:trail/services/coverage/coverage_planner.dart';
import 'package:trail/services/coverage/coverage_prefs.dart';
import 'package:trail/services/coverage/coverage_service.dart';
import 'package:trail/services/coverage/tile_server_client.dart';
import 'package:trail/services/local_tile_server.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tile_downloader.dart';
import 'package:trail/services/tiles/tile_schema.dart';

/// Widget-level coverage for the shared "download map detail?" flow —
/// the piece the Timeline import screen, the per-import action and the
/// Settings button all funnel through. The interesting cases are the
/// ones that used to end in silence: no server configured, and the user
/// declining.

class _FakeServer implements CoverageTileServer {
  _FakeServer();

  /// 2 MB per box — the measured size of a town-sized z7–14 extract
  /// (docs/TIMELINE_IMPORT.md §3), so the dialog string under test is
  /// the one a real run would show.
  final int bytesPerBox = 2 * 1024 * 1024;
  final String planetDate = '20260822';

  /// When set, `downloadExtract` blocks on it — lets a test tap Cancel
  /// while a download is "in flight".
  Completer<void>? gate;

  final List<CoverageBox> dryRuns = [];
  final List<CoverageBox> downloads = [];

  @override
  Future<({bool ok, String planet, String planetDate})> health() async =>
      (ok: true, planet: 'protomaps', planetDate: planetDate);

  @override
  Future<({int tiles, int bytes, String planetDate})> dryRun(
    CoverageBox box, {
    int minzoom = 7,
    int maxzoom = 14,
  }) async {
    dryRuns.add(box);
    return (tiles: 75, bytes: bytesPerBox, planetDate: planetDate);
  }

  @override
  Future<TilesRegion> downloadExtract(
    CoverageBox box, {
    int minzoom = 7,
    int maxzoom = 14,
    String? planetDate,
    DownloadProgress? onProgress,
    TileDownloadCancelToken? cancelToken,
  }) async {
    final g = gate;
    if (g != null) await g.future;
    if (cancelToken?.isCancelled ?? false) throw const TileDownloadCancelled();
    downloads.add(box);
    onProgress?.call(bytesPerBox, bytesPerBox);
    return TilesRegion(
      name: 'coverage-${box.slug}',
      path: '/tmp/tiles/coverage-${box.slug}.pmtiles',
      bytes: bytesPerBox,
    );
  }

  @override
  void close() {}
}

ServedArchiveSummary _summary(List<double> bounds) => ServedArchiveSummary(
      path: '/tmp/tiles/region.pmtiles',
      minZoom: 0,
      maxZoom: 14,
      bounds: bounds,
      format: 'pbf',
      schema: TileSchema.unknown,
      sizeBytes: 1024,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bath = [GeoPoint(51.375, -2.360)];

  late _FakeServer server;

  CoverageService buildService({
    bool haveServer = true,
    List<double>? installedBounds,
  }) =>
      CoverageService(
        listInstalled: () async => installedBounds == null
            ? const []
            : [
                const TilesRegion(
                  name: 'region',
                  path: '/tmp/tiles/region.pmtiles',
                  bytes: 1024,
                ),
              ],
        probe: (path) async => _summary(installedBounds!),
        serverFactory: () async => haveServer ? server : null,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = _FakeServer();
  });

  /// Mounts a bare screen and starts the flow against its context.
  /// Returns a getter for the (eventually) completed result.
  Future<CoverageFlowResult? Function()> start(
    WidgetTester tester, {
    required List<GeoPoint> points,
    required CoverageService service,
    String serverMissingNote = 'no server note',
    String declinedNote = 'declined note',
    String alreadyCoveredNote = 'covered note',
    void Function()? onInstalled,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          }),
        ),
      ),
    );
    CoverageFlowResult? result;
    unawaited(runCoverageFlow(
      ctx,
      points: points,
      service: service,
      serverMissingNote: serverMissingNote,
      declinedNote: declinedNote,
      alreadyCoveredNote: alreadyCoveredNote,
      onInstalled: onInstalled ?? () {},
    ).then((r) => result = r));
    await tester.pump();
    await tester.pump();
    return () => result;
  }

  Future<void> settle(WidgetTester tester,
      CoverageFlowResult? Function() read) async {
    for (var i = 0; i < 40 && read() == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('coverageServerNotSetNote', () {
    test('names the count, the setting and the way back', () {
      expect(
        coverageServerNotSetNote(12),
        'Map detail server not set — 12 places from this import could get '
        'detail. Set it up in Settings → Map detail server, then use '
        'Timeline imports → Map detail.',
      );
    });

    test('singular for one place', () {
      expect(coverageServerNotSetNote(1), contains('1 place from'));
    });
  });

  group('runCoverageFlow', () {
    testWidgets('no points → noPoints, nothing shown', (tester) async {
      final read = await start(
        tester,
        points: const [],
        service: buildService(),
      );
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.noPoints);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('no server URL in prefs → noServer with the caller\'s note, '
        'and NO dialog (this is the silent-return bug)', (tester) async {
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
        serverMissingNote: 'set one up',
      );
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.noServer);
      expect(read()!.message, 'set one up');
      expect(read()!.attemptedDownload, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(server.dryRuns, isEmpty);
    });

    testWidgets('an empty server URL counts as not set', (tester) async {
      await CoveragePrefs.writeServerUrl('');
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
      );
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.noServer);
    });

    testWidgets('everything already covered → alreadyCovered, no dialog',
        (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      final read = await start(
        tester,
        points: bath,
        // An installed z14 archive whose bounds swallow the point.
        service: buildService(installedBounds: const [-3.0, 51.0, -2.0, 52.0]),
        alreadyCoveredNote: 'all covered already',
      );
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.alreadyCovered);
      expect(read()!.message, 'all covered already');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('planning failure surfaces as a message, not a throw',
        (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      final read = await start(
        tester,
        points: bath,
        service: buildService(haveServer: false),
      );
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.failed);
      expect(read()!.message, startsWith('Map detail unavailable:'));
    });

    testWidgets('shows areas · MB · planet and honours "Not now"',
        (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      var installed = 0;
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
        declinedNote: 'maybe later',
        onInstalled: () => installed++,
      );
      await tester.pumpAndSettle();
      expect(find.text('Download map detail?'), findsOneWidget);
      expect(find.text('1 area · 2.0 MB · planet 20260822'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.declined);
      expect(read()!.message, 'maybe later');
      expect(read()!.attemptedDownload, isFalse);
      expect(server.downloads, isEmpty);
      expect(installed, 0);
    });

    testWidgets('an empty declinedNote comes back empty — the Settings '
        'button uses that to stay quiet on a dismissed dialog',
        (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
        declinedNote: '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.declined);
      expect(read()!.message, isEmpty);
    });

    testWidgets('confirming downloads, reports the size and fires '
        'onInstalled once', (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      var installed = 0;
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
        onInstalled: () => installed++,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.installed);
      expect(read()!.downloaded, 1);
      expect(read()!.message, 'Installed 1 map-detail pack (2.0 MB).');
      expect(read()!.attemptedDownload, isTrue);
      expect(installed, 1);
      // The progress dialog closed itself.
      await tester.pumpAndSettle();
      expect(find.text('Downloading map detail'), findsNothing);
    });

    testWidgets('cancelling mid-download stops it and says so',
        (tester) async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      final gate = Completer<void>();
      server.gate = gate;
      final read = await start(
        tester,
        points: bath,
        service: buildService(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Downloading map detail'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      gate.complete();
      await settle(tester, read);
      expect(read()!.status, CoverageFlowStatus.cancelled);
      expect(read()!.message, 'Cancelled after 0 areas.');
      expect(server.downloads, isEmpty);
    });
  });
}
