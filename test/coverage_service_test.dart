import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/coverage/coverage_planner.dart';
import 'package:trail/services/coverage/coverage_prefs.dart';
import 'package:trail/services/coverage/coverage_service.dart';
import 'package:trail/services/coverage/tile_server_client.dart';
import 'package:trail/services/local_tile_server.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tile_downloader.dart';
import 'package:trail/services/tiles/tile_schema.dart';

/// Stands in for the user's extract server. Records every call so the
/// tests can assert on what was sized versus what was downloaded.
class _FakeServer implements CoverageTileServer {
  _FakeServer({this.bytesPerBox = 2 * 1024 * 1024});

  final int bytesPerBox;
  final int tilesPerBox = 75;
  final String planetDate = '20260822';

  /// Set by a test to make the next dry-run / download fail.
  TileServerException? dryRunError;
  Object? downloadError;

  final List<CoverageBox> dryRuns = [];
  final List<CoverageBox> downloads = [];
  int closes = 0;

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
    final err = dryRunError;
    if (err != null) throw err;
    return (tiles: tilesPerBox, bytes: bytesPerBox, planetDate: planetDate);
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
    downloads.add(box);
    final err = downloadError;
    if (err != null) throw err;
    if (cancelToken?.isCancelled ?? false) throw const TileDownloadCancelled();
    onProgress?.call(bytesPerBox, bytesPerBox);
    final name = coverageFileName(box,
        minzoom: minzoom, maxzoom: maxzoom, date: planetDate ?? '00000000');
    return TilesRegion(
      name: name.replaceAll('.pmtiles', ''),
      path: '/tmp/tiles/$name',
      bytes: bytesPerBox,
    );
  }

  @override
  void close() => closes++;
}

ServedArchiveSummary _summary(
  String path, {
  int minZoom = 0,
  int maxZoom = 14,
  List<double>? bounds,
}) =>
    ServedArchiveSummary(
      path: path,
      minZoom: minZoom,
      maxZoom: maxZoom,
      bounds: bounds,
      format: 'pbf',
      schema: TileSchema.unknown,
      sizeBytes: 1024,
    );

void main() {
  const bath = [
    GeoPoint(51.375, -2.360),
    GeoPoint(51.380, -2.365),
  ];
  const lisbon = [GeoPoint(38.715, -9.140)];

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  CoverageService serviceWith({
    List<TilesRegion> installed = const [],
    Map<String, ServedArchiveSummary> probes = const {},
    Set<String> probeFailures = const {},
    CoverageTileServer? server,
    int autoByteCap = CoverageService.defaultAutoByteCap,
  }) {
    return CoverageService(
      listInstalled: () async => installed,
      probe: (path) async {
        if (probeFailures.contains(path)) throw StateError('corrupt: $path');
        return probes[path] ?? _summary(path);
      },
      serverFactory: () async => server,
      autoByteCap: autoByteCap,
    );
  }

  group('refreshExtents', () {
    test('probes every installed archive and writes prefs', () async {
      final service = serviceWith(
        installed: const [
          TilesRegion(name: 'gb', path: '/t/gb.pmtiles', bytes: 1),
          TilesRegion(name: 'world', path: '/t/world.pmtiles', bytes: 1),
        ],
        probes: {
          '/t/gb.pmtiles': _summary('/t/gb.pmtiles',
              minZoom: 0, maxZoom: 13, bounds: [-8.7, 49.8, 1.9, 60.9]),
          '/t/world.pmtiles': _summary('/t/world.pmtiles',
              minZoom: 0, maxZoom: 6, bounds: [-180, -85, 180, 85]),
        },
      );
      final extents = await service.refreshExtents();
      expect(extents.length, 2);
      final stored = await CoveragePrefs.readExtents();
      expect(stored.map((e) => e.path),
          ['/t/gb.pmtiles', '/t/world.pmtiles']);
      expect(stored.first.maxZoom, 13);
      expect(stored.first.bounds!.north, 60.9);
    });

    test('a corrupt archive is skipped, the rest are still written',
        () async {
      final service = serviceWith(
        installed: const [
          TilesRegion(name: 'bad', path: '/t/bad.pmtiles', bytes: 1),
          TilesRegion(name: 'gb', path: '/t/gb.pmtiles', bytes: 1),
        ],
        probeFailures: {'/t/bad.pmtiles'},
      );
      final extents = await service.refreshExtents();
      expect(extents.map((e) => e.path), ['/t/gb.pmtiles']);
    });

    test('no archives writes an empty list', () async {
      await serviceWith().refreshExtents();
      expect(await CoveragePrefs.readExtents(), isEmpty);
    });
  });

  group('planForPoints', () {
    test('dry-runs every planned box and sums the bytes', () async {
      final server = _FakeServer();
      final service = serviceWith(server: server);
      final plan = await service.planForPoints([...bath, ...lisbon]);
      expect(plan.boxes.length, 2);
      expect(server.dryRuns.length, 2);
      expect(plan.totalBytes, 4 * 1024 * 1024);
      expect(plan.totalTiles, 150);
      expect(plan.planetDate, '20260822');
    });

    test('places already covered in detail are not planned', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(
          path: '/t/gb.pmtiles',
          minZoom: 0,
          maxZoom: 13,
          bounds: CoverageBox(west: -8.7, south: 49.8, east: 1.9, north: 60.9),
        ),
      ]);
      final server = _FakeServer();
      final plan =
          await serviceWith(server: server).planForPoints([...bath, ...lisbon]);
      expect(plan.boxes.length, 1);
      expect(plan.boxes.single.box.contains(38.715, -9.140), isTrue);
    });

    test('a z6 overview does not count as covered', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(
          path: '/t/world.pmtiles',
          minZoom: 0,
          maxZoom: 6,
          bounds: CoverageBox(west: -180, south: -85, east: 180, north: 85),
        ),
      ]);
      final plan = await serviceWith(server: _FakeServer())
          .planForPoints([...bath, ...lisbon]);
      expect(plan.boxes.length, 2);
    });

    test('no points plans nothing and never calls the server', () async {
      final server = _FakeServer();
      final plan = await serviceWith(server: server).planForPoints(const []);
      expect(plan.isEmpty, isTrue);
      expect(server.dryRuns, isEmpty);
    });

    test('a 413 on one box drops it and counts it as skipped', () async {
      final server = _FakeServer()
        ..dryRunError = const TileServerException(413, 'too big');
      final plan = await serviceWith(server: server).planForPoints(bath);
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped, 1);
    });

    test('a 401 aborts the whole plan', () async {
      final server = _FakeServer()
        ..dryRunError = const TileServerException(401, 'bad token');
      await expectLater(
        serviceWith(server: server).planForPoints(bath),
        throwsA(isA<TileServerException>()
            .having((e) => e.status, 'status', 401)),
      );
    });

    test('an unconfigured server throws rather than silently no-oping',
        () async {
      await expectLater(
        serviceWith().planForPoints(bath),
        throwsA(isA<TileServerException>()),
      );
    });
  });

  group('fetchPlan', () {
    test('downloads every box, records the fetch, fires onInstalled',
        () async {
      final server = _FakeServer();
      final service = serviceWith(server: server);
      final plan = await service.planForPoints([...bath, ...lisbon]);
      var installedCalls = 0;
      final progress = <String>[];
      final result = await service.fetchPlan(
        plan,
        server: server,
        onInstalled: () => installedCalls++,
        onProgress: (i, count, received, total) =>
            progress.add('$i/$count:$received/$total'),
      );
      expect(result.downloaded, 2);
      expect(result.bytes, 4 * 1024 * 1024);
      expect(result.cancelled, isFalse);
      expect(result.error, isNull);
      expect(installedCalls, 1);
      expect(progress.length, 2);
      expect(await CoveragePrefs.readLastFetch(), isNotNull);
    });

    test('an empty plan is a no-op', () async {
      final server = _FakeServer();
      final result = await serviceWith(server: server)
          .fetchPlan(CoveragePlan.empty, server: server);
      expect(result.downloaded, 0);
      expect(server.downloads, isEmpty);
      expect(await CoveragePrefs.readLastFetch(), isNull);
    });

    test('a pre-cancelled token stops before the first download', () async {
      final server = _FakeServer();
      final service = serviceWith(server: server);
      final plan = await service.planForPoints(bath);
      final result = await service.fetchPlan(
        plan,
        server: server,
        cancelToken: TileDownloadCancelToken()..isCancelled = true,
      );
      expect(result.cancelled, isTrue);
      expect(result.downloaded, 0);
      expect(server.downloads, isEmpty);
    });

    test('a failing download is reported but does not throw', () async {
      final server = _FakeServer()..downloadError = StateError('disk full');
      final service = serviceWith(server: server);
      final plan = await service.planForPoints(bath);
      final result = await service.fetchPlan(plan, server: server);
      expect(result.downloaded, 0);
      expect(result.error, contains('disk full'));
      expect(result.shouldRequeue, isTrue);
    });

    test('no configured server reports notConfigured', () async {
      final service = serviceWith();
      const plan = CoveragePlan(boxes: [
        CoverageBoxPlan(
          box: CoverageBox(west: -2.5, south: 51, east: -2, north: 51.5),
          tiles: 1,
          bytes: 10,
          planetDate: '20260822',
        )
      ]);
      final result = await service.fetchPlan(plan);
      expect(result.notConfigured, isTrue);
      expect(result.shouldRequeue, isTrue);
    });
  });

  group('CoveragePlan.cappedTo', () {
    test('keeps the prefix that fits', () {
      const box = CoverageBox(west: 0, south: 0, east: 1, north: 1);
      const plan = CoveragePlan(boxes: [
        CoverageBoxPlan(box: box, tiles: 1, bytes: 10, planetDate: 'd'),
        CoverageBoxPlan(box: box, tiles: 1, bytes: 10, planetDate: 'd'),
        CoverageBoxPlan(box: box, tiles: 1, bytes: 10, planetDate: 'd'),
      ]);
      expect(plan.cappedTo(25).boxes.length, 2);
      expect(plan.cappedTo(5).boxes, isEmpty);
      expect(plan.cappedTo(1000).boxes.length, 3);
    });
  });

  group('fetchForPoints', () {
    test('plan → dry-run → download, reporting the plan to onPlan',
        () async {
      final server = _FakeServer();
      CoveragePlan? seen;
      final result = await serviceWith(server: server).fetchForPoints(
        [...bath, ...lisbon],
        confirmLarge: false,
        onPlan: (p) => seen = p,
        server: server,
      );
      expect(seen!.boxes.length, 2);
      expect(server.downloads.length, 2);
      expect(result.downloaded, 2);
    });

    test('over the auto cap without confirmation downloads nothing',
        () async {
      final server = _FakeServer(bytesPerBox: 15 * 1024 * 1024);
      final result = await serviceWith(server: server).fetchForPoints(
        [...bath, ...lisbon],
        confirmLarge: false,
        server: server,
      );
      expect(result.exceededCap, isTrue);
      expect(result.downloaded, 0);
      expect(result.shouldRequeue, isTrue);
      expect(server.downloads, isEmpty);
    });

    test('the same plan goes ahead once the caller has confirmed', () async {
      final server = _FakeServer(bytesPerBox: 15 * 1024 * 1024);
      final result = await serviceWith(server: server).fetchForPoints(
        [...bath, ...lisbon],
        confirmLarge: true,
        server: server,
      );
      expect(result.exceededCap, isFalse);
      expect(result.downloaded, 2);
    });

    test('no points is a no-op', () async {
      final server = _FakeServer();
      final result = await serviceWith(server: server)
          .fetchForPoints(const [], confirmLarge: true, server: server);
      expect(result.downloaded, 0);
      expect(server.dryRuns, isEmpty);
    });
  });

  group('processPendingOnAppOpen', () {
    test('drains the queue on Wi-Fi and clears it on success', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      await CoveragePrefs.addPending(38.72, -9.14);
      final server = _FakeServer();
      final service = serviceWith(server: server);
      await service.processPendingOnAppOpen(networkState: 'wifi');
      expect(server.downloads.length, 2);
      expect(await CoveragePrefs.readPending(), isEmpty);
      expect(await CoveragePrefs.readNotice(), contains('Downloaded 2 areas'));
    });

    test('Wi-Fi only blocks a mobile connection and keeps the queue',
        () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      await serviceWith(server: server)
          .processPendingOnAppOpen(networkState: 'mobile');
      expect(server.dryRuns, isEmpty);
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('clearing Wi-Fi only lets a mobile connection run', () async {
      await CoveragePrefs.writeSettings(
        const CoverageSettings(wifiOnly: false),
      );
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      await serviceWith(server: server)
          .processPendingOnAppOpen(networkState: 'mobile');
      expect(server.downloads.length, 1);
    });

    test('the feature being off blocks everything', () async {
      await CoveragePrefs.writeSettings(const CoverageSettings(enabled: false));
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      await serviceWith(server: server)
          .processPendingOnAppOpen(networkState: 'wifi');
      expect(server.dryRuns, isEmpty);
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('a plan over the 20 MB cap leaves the points pending with a notice',
        () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      await CoveragePrefs.addPending(38.72, -9.14);
      final server = _FakeServer(bytesPerBox: 15 * 1024 * 1024);
      await serviceWith(server: server)
          .processPendingOnAppOpen(networkState: 'wifi');
      expect(server.downloads, isEmpty);
      expect((await CoveragePrefs.readPending()).length, 2);
      final notice = await CoveragePrefs.readNotice();
      expect(notice, contains('2 new places'));
      expect(notice, contains('30 MB'));
    });

    test('no server configured leaves the queue untouched', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      await serviceWith().processPendingOnAppOpen(networkState: 'wifi');
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('an empty queue still refreshes the extents', () async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      final service = serviceWith(
        installed: const [
          TilesRegion(name: 'gb', path: '/t/gb.pmtiles', bytes: 1),
        ],
        probes: {
          '/t/gb.pmtiles': _summary('/t/gb.pmtiles',
              maxZoom: 13, bounds: [-8.7, 49.8, 1.9, 60.9]),
        },
        server: _FakeServer(),
      );
      await service.processPendingOnAppOpen(networkState: 'wifi');
      expect((await CoveragePrefs.readExtents()).length, 1);
    });

    test('a second call inside the throttle window does nothing', () async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      final service = serviceWith(server: server);
      final start = DateTime.utc(2026, 8, 22, 10);
      await service.processPendingOnAppOpen(networkState: 'wifi', now: start);
      expect(server.downloads.length, 1);
      await CoveragePrefs.addPending(38.72, -9.14);
      await service.processPendingOnAppOpen(
        networkState: 'wifi',
        now: start.add(const Duration(minutes: 5)),
      );
      expect(server.downloads.length, 1);
      await service.processPendingOnAppOpen(
        networkState: 'wifi',
        now: start.add(const Duration(minutes: 11)),
      );
      expect(server.downloads.length, 2);
    });

    test('never throws, even when everything underneath fails', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer()..downloadError = StateError('boom');
      final service = serviceWith(server: server);
      await service.processPendingOnAppOpen(networkState: 'wifi');
      // The failed points go back on the queue rather than vanishing.
      expect((await CoveragePrefs.readPending()).length, 1);
    });
  });

  group('noteFixInWorker', () {
    test('queues a place no archive covers in detail', () async {
      await CoverageService.noteFixInWorker(38.72, -9.14);
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('does not queue a place a z13 archive already covers', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(
          path: '/t/gb.pmtiles',
          minZoom: 0,
          maxZoom: 13,
          bounds: CoverageBox(west: -8.7, south: 49.8, east: 1.9, north: 60.9),
        ),
      ]);
      await CoverageService.noteFixInWorker(51.38, -2.36);
      expect(await CoveragePrefs.readPending(), isEmpty);
    });

    test('a z6 overview does not stop the queue', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(
          path: '/t/world.pmtiles',
          minZoom: 0,
          maxZoom: 6,
          bounds: CoverageBox(west: -180, south: -85, east: 180, north: 85),
        ),
      ]);
      await CoverageService.noteFixInWorker(51.38, -2.36);
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('the feature being off queues nothing', () async {
      await CoveragePrefs.writeSettings(const CoverageSettings(enabled: false));
      await CoverageService.noteFixInWorker(38.72, -9.14);
      expect(await CoveragePrefs.readPending(), isEmpty);
    });

    test('repeated fixes in the same place queue once', () async {
      await CoverageService.noteFixInWorker(38.72, -9.14);
      await CoverageService.noteFixInWorker(38.721, -9.141);
      await CoverageService.noteFixInWorker(38.7205, -9.1405);
      expect((await CoveragePrefs.readPending()).length, 1);
    });
  });

  group('noticeFor', () {
    test('over the cap names the count and the megabytes', () {
      expect(
        CoverageService.noticeFor(
          const CoverageRunResult(
              planned: 3, bytes: 42 * 1024 * 1024, exceededCap: true),
          3,
        ),
        '3 new places need ≈ 42 MB — too big to fetch automatically, '
        'tap to download.',
      );
    });

    test('singular wording for one place', () {
      final notice = CoverageService.noticeFor(
        const CoverageRunResult(bytes: 1024 * 1024, exceededCap: true),
        1,
      );
      expect(notice, contains('1 new place need'));
    });

    test('a success reports what landed', () {
      expect(
        CoverageService.noticeFor(
          const CoverageRunResult(downloaded: 2, bytes: 3 * 1024 * 1024),
          2,
        ),
        'Downloaded 2 areas (3.0 MB).',
      );
    });

    test('cancelled, failed, unconfigured and idle', () {
      expect(
        CoverageService.noticeFor(const CoverageRunResult(cancelled: true), 1),
        'Last map-detail download was cancelled.',
      );
      expect(
        CoverageService.noticeFor(const CoverageRunResult(error: 'nope'), 1),
        'Last map-detail download failed.',
      );
      expect(
        CoverageService.noticeFor(
            const CoverageRunResult(notConfigured: true, error: 'x'), 1),
        isNull,
      );
      expect(CoverageService.noticeFor(const CoverageRunResult(), 0), isNull);
    });
  });

  group('CoverageResumeObserver', () {
    test('a resume drives processPendingOnAppOpen with the network label',
        () async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      final service = serviceWith(server: server);
      final observer = CoverageResumeObserver(
        networkLabel: () async => 'wifi',
        service: service,
      );
      await observer.run();
      expect(server.downloads.length, 1);
    });

    test('a null network label blocks the run', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      final server = _FakeServer();
      final observer = CoverageResumeObserver(
        networkLabel: () async => null,
        service: serviceWith(server: server),
      );
      await observer.run();
      expect(server.dryRuns, isEmpty);
    });

    test('a throwing network probe does not escape', () async {
      final observer = CoverageResumeObserver(
        networkLabel: () async => throw StateError('no plugin'),
        service: serviceWith(server: _FakeServer()),
      );
      await observer.run();
    });
  });
}
