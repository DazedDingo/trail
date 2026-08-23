import 'dart:async';

import 'package:flutter/widgets.dart';

import '../battery_network_service.dart';
import '../local_tile_server.dart';
import '../mbtiles_service.dart';
import '../tile_downloader.dart';
import 'coverage_planner.dart';
import 'coverage_prefs.dart';
import 'tile_server_client.dart';

/// Per-archive progress for a coverage run: which box of how many, and
/// the bytes of the current download.
typedef CoverageProgress = void Function(
  int boxIndex,
  int boxCount,
  int received,
  int? total,
);

/// One planned extract: the bbox plus the server's exact dry-run
/// sizing. `pmtiles extract --dry-run` sizes are byte-exact
/// (`docs/TIMELINE_IMPORT.md` §3), so the confirm dialog can show real
/// numbers rather than an estimate.
class CoverageBoxPlan {
  const CoverageBoxPlan({
    required this.box,
    required this.tiles,
    required this.bytes,
    required this.planetDate,
  });

  final CoverageBox box;
  final int tiles;
  final int bytes;
  final String planetDate;
}

/// The whole "here's what we'd download" answer.
class CoveragePlan {
  const CoveragePlan({
    required this.boxes,
    this.skipped = 0,
    this.minzoom = TileServerClient.defaultMinZoom,
    this.maxzoom = TileServerClient.defaultMaxZoom,
  });

  static const empty = CoveragePlan(boxes: []);

  final List<CoverageBoxPlan> boxes;

  /// Boxes whose dry-run failed (server hiccup, 413). They are dropped
  /// from the plan rather than failing the whole run, and counted here
  /// so the UI can say "2 areas couldn't be sized".
  final int skipped;

  final int minzoom;
  final int maxzoom;

  bool get isEmpty => boxes.isEmpty;
  int get totalTiles => boxes.fold(0, (a, b) => a + b.tiles);
  int get totalBytes => boxes.fold(0, (a, b) => a + b.bytes);
  String? get planetDate => boxes.isEmpty ? null : boxes.first.planetDate;

  /// The prefix of [boxes] that fits inside [byteCap]. Boxes come out of
  /// [planCoverage] smallest-first, so a capped run buys the largest
  /// number of places.
  CoveragePlan cappedTo(int byteCap) {
    final kept = <CoverageBoxPlan>[];
    var running = 0;
    for (final b in boxes) {
      if (running + b.bytes > byteCap) break;
      kept.add(b);
      running += b.bytes;
    }
    return CoveragePlan(
      boxes: kept,
      skipped: skipped,
      minzoom: minzoom,
      maxzoom: maxzoom,
    );
  }
}

/// Outcome of a coverage run.
class CoverageRunResult {
  const CoverageRunResult({
    this.planned = 0,
    this.downloaded = 0,
    this.bytes = 0,
    this.refreshed = 0,
    this.cancelled = false,
    this.exceededCap = false,
    this.notConfigured = false,
    this.error,
  });

  /// Boxes in the plan.
  final int planned;

  /// Boxes actually written to `<docs>/tiles/`.
  final int downloaded;

  /// Bytes written.
  final int bytes;

  /// Stale coverage packs rebuilt on a newer planet build during the
  /// same run (the weekly pass in [CoverageService.processPendingOnAppOpen]).
  /// Independent of [downloaded], which only counts NEW places.
  final int refreshed;

  final bool cancelled;

  /// The plan was bigger than the auto budget and the caller hadn't
  /// pre-confirmed — nothing was downloaded, the points stay pending.
  final bool exceededCap;

  /// No server URL / token configured yet.
  final bool notConfigured;

  final String? error;

  bool get didWork => downloaded > 0 || refreshed > 0;

  /// Same result with [refreshed] filled in — the refresh pass runs
  /// after the pending fetch, so the two halves are stitched together
  /// before the notice is written.
  CoverageRunResult withRefreshed(int count) => CoverageRunResult(
        planned: planned,
        downloaded: downloaded,
        bytes: bytes,
        refreshed: count,
        cancelled: cancelled,
        exceededCap: exceededCap,
        notConfigured: notConfigured,
        error: error,
      );

  /// True when the caller should put its points back on the pending
  /// queue rather than considering them handled.
  bool get shouldRequeue =>
      exceededCap || notConfigured || cancelled || error != null;
}

/// Fetches high-zoom map detail for places the user has actually been
/// (Phase C of `docs/TIMELINE_IMPORT.md` §3).
///
/// Three entry points, deliberately different in what they may do:
///
///   1. [noteFixInWorker] — the WorkManager isolate. Prefs only: no
///      network, no DB, no plugins beyond SharedPreferences (CLAUDE.md
///      gotchas 1 + 11). It just records "I was somewhere with no
///      detailed tiles" for the UI isolate to act on later.
///   2. [processPendingOnAppOpen] — app start / resume. Gated by
///      [shouldAutoFetchNow] and a 20 MB budget; anything bigger stays
///      pending and surfaces as a Settings notice. Once a week the same
///      pass also rebuilds up to [maxStaleRefreshPerRun] coverage packs
///      whose planet build has gone stale.
///   3. [planForPoints] + [fetchPlan] — the explicit paths (the
///      Settings "fetch now" button, and later the Timeline import's
///      finish screen). The user sees box count and megabytes before
///      anything is downloaded.
///
/// Nothing here throws at its callers: the automatic paths swallow and
/// [debugPrint], the explicit paths return the failure in
/// [CoverageRunResult.error].
class CoverageService {
  CoverageService({
    Future<List<TilesRegion>> Function()? listInstalled,
    Future<ServedArchiveSummary> Function(String path)? probe,
    Future<CoverageTileServer?> Function()? serverFactory,
    Future<void> Function(TilesRegion region)? deleteArchive,
    this.autoByteCap = defaultAutoByteCap,
  })  : _listInstalled = listInstalled ?? TilesService.listInstalled,
        _probe = probe ?? LocalTileServer.probe,
        _serverFactory = serverFactory ?? _serverFromPrefs,
        _deleteArchive = deleteArchive ?? TilesService.delete;

  /// Singleton used by `main.dart` and the Settings screen. Assignable
  /// so tests can swap in a service built on fakes.
  static CoverageService instance = CoverageService();

  /// How much an unattended run may download without the user seeing a
  /// number first. ~10 towns at the measured ~2 MB each.
  static const defaultAutoByteCap = 20 * 1024 * 1024;

  /// Minimum gap between unattended runs, so a user flicking between
  /// apps doesn't re-plan every few seconds.
  static const autoRunThrottle = Duration(minutes: 10);

  /// Minimum gap between stale-coverage-pack refresh passes. A pack is
  /// six months out of date at worst; re-checking weekly is plenty and
  /// keeps the resume path off the network almost every time.
  static const staleRefreshInterval = Duration(days: 7);

  /// How many stale packs one pass may rebuild. Two at ~2 MB apiece is
  /// a rounding error against the 20 MB budget, and a library that has
  /// gone stale wholesale is worked through a fortnight at a time
  /// rather than in one surprise download.
  static const maxStaleRefreshPerRun = 2;

  final Future<List<TilesRegion>> Function() _listInstalled;
  final Future<ServedArchiveSummary> Function(String path) _probe;
  final Future<CoverageTileServer?> Function() _serverFactory;
  final Future<void> Function(TilesRegion region) _deleteArchive;
  final int autoByteCap;

  DateTime? _lastAutoRun;
  bool _running = false;

  /// Whether a run is in flight — the Settings tile disables its button
  /// on this rather than starting a second, overlapping download.
  bool get isRunning => _running;

  // --- extents ---------------------------------------------------------

  /// Probes every installed archive and writes what they cover to
  /// prefs, so the worker isolate can answer "already detailed?"
  /// without opening a file. Call after any install/delete.
  ///
  /// A probe that throws (corrupt file, unsupported extension) is
  /// skipped — one bad archive must not blank the whole extent list,
  /// which would make the worker queue every fix.
  Future<List<ArchiveExtent>> refreshExtents() async {
    final extents = <ArchiveExtent>[];
    try {
      for (final region in await _listInstalled()) {
        try {
          final summary = await _probe(region.path);
          extents.add(ArchiveExtent(
            path: summary.path,
            minZoom: summary.minZoom,
            maxZoom: summary.maxZoom,
            bounds: CoverageBox.fromBounds(summary.bounds),
          ));
        } catch (e) {
          debugPrint('[coverage] probe failed for ${region.path}: $e');
        }
      }
      await CoveragePrefs.writeExtents(extents);
    } catch (e) {
      debugPrint('[coverage] refreshExtents failed: $e');
    }
    return extents;
  }

  // --- planning ---------------------------------------------------------

  /// Clusters [points] into padded boxes, drops what the installed
  /// archives already cover in detail, and dry-runs each survivor
  /// against the server for exact sizing.
  ///
  /// Exposed for the Timeline import's finish screen ("download map
  /// detail for N places (≈ X MB)") as well as the Settings button.
  Future<CoveragePlan> planForPoints(
    List<GeoPoint> points, {
    double clusterKm = 15,
    double padKm = 3,
    int minzoom = TileServerClient.defaultMinZoom,
    int maxzoom = TileServerClient.defaultMaxZoom,
    CoverageTileServer? server,
  }) async {
    if (points.isEmpty) return CoveragePlan.empty;
    final extents = await CoveragePrefs.readExtents();
    final covered = <CoverageBox>[
      for (final e in extents)
        if (e.maxZoom >= defaultMinDetailZoom && e.bounds != null) e.bounds!
    ];
    final boxes = planCoverage(
      points,
      clusterKm: clusterKm,
      padKm: padKm,
      covered: covered,
    );
    if (boxes.isEmpty) return CoveragePlan.empty;

    final owned = server == null;
    final client = server ?? await _serverFactory();
    if (client == null) {
      throw const TileServerException(
        0,
        'No map-detail server configured',
      );
    }
    try {
      final planned = <CoverageBoxPlan>[];
      var skipped = 0;
      for (final box in boxes) {
        try {
          final r =
              await client.dryRun(box, minzoom: minzoom, maxzoom: maxzoom);
          planned.add(CoverageBoxPlan(
            box: box,
            tiles: r.tiles,
            bytes: r.bytes,
            planetDate: r.planetDate,
          ));
        } on TileServerException catch (e) {
          if (e.isAuth || e.isUnreachable) rethrow;
          // 400/413/429/503 on ONE box: drop it, keep the rest.
          debugPrint('[coverage] dry-run failed for ${box.slug}: $e');
          skipped++;
        }
      }
      return CoveragePlan(
        boxes: planned,
        skipped: skipped,
        minzoom: minzoom,
        maxzoom: maxzoom,
      );
    } finally {
      if (owned) client.close();
    }
  }

  // --- fetching ---------------------------------------------------------

  /// Downloads every box in [plan], sequentially, into `<docs>/tiles/`.
  ///
  /// `TileDownloader` writes directly to the directory
  /// `TilesService.listInstalled` reads, with an atomic rename, and the
  /// `coverage-…` file name makes `inferRoleFromFileName` tag the
  /// result as a coverage pack — so there is no separate install step
  /// and no role to persist. [onInstalled] fires once at the end when
  /// at least one archive landed; the Settings screen passes
  /// `invalidateTileProviders`, which is what restarts the loopback on
  /// a new port with the new archive set (CLAUDE.md gotcha 31).
  Future<CoverageRunResult> fetchPlan(
    CoveragePlan plan, {
    CoverageProgress? onProgress,
    TileDownloadCancelToken? cancelToken,
    void Function()? onInstalled,
    CoverageTileServer? server,
  }) async {
    if (plan.isEmpty) return const CoverageRunResult();
    final owned = server == null;
    final client = server ?? await _serverFactory();
    if (client == null) {
      return CoverageRunResult(
        planned: plan.boxes.length,
        notConfigured: true,
        error: 'No map-detail server configured',
      );
    }
    _running = true;
    var downloaded = 0;
    var bytes = 0;
    String? error;
    var cancelled = false;
    try {
      for (var i = 0; i < plan.boxes.length; i++) {
        if (cancelToken?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        final entry = plan.boxes[i];
        try {
          final region = await client.downloadExtract(
            entry.box,
            minzoom: plan.minzoom,
            maxzoom: plan.maxzoom,
            planetDate: entry.planetDate,
            cancelToken: cancelToken,
            onProgress: (received, total) => onProgress?.call(
              i,
              plan.boxes.length,
              received,
              total ?? entry.bytes,
            ),
          );
          // Verify the archive actually landed — an empty file would
          // otherwise be served as a permanently blank coverage pack.
          if (region.bytes <= 0) {
            error = 'Server returned an empty archive for ${entry.box.slug}';
            continue;
          }
          downloaded++;
          bytes += region.bytes;
        } on TileDownloadCancelled {
          cancelled = true;
          break;
        } catch (e) {
          debugPrint('[coverage] download failed for ${entry.box.slug}: $e');
          error = '$e';
        }
      }
    } finally {
      _running = false;
      if (owned) client.close();
    }
    if (downloaded > 0) {
      await CoveragePrefs.setLastFetch(DateTime.now().toUtc());
      // Extents must reflect the new packs before the next worker tick,
      // or the same place gets queued again on the next fix.
      await refreshExtents();
      onInstalled?.call();
    }
    return CoverageRunResult(
      planned: plan.boxes.length,
      downloaded: downloaded,
      bytes: bytes,
      cancelled: cancelled,
      error: error,
    );
  }

  /// Plan + fetch in one call.
  ///
  /// [confirmLarge] is the caller asserting "the user has seen the
  /// numbers": when false (the unattended path) a plan bigger than
  /// [autoByteCap] is refused outright — [CoverageRunResult.exceededCap]
  /// — so the points stay pending until the user runs it by hand.
  /// [onPlan] is a notification (the UI's own confirm flow uses
  /// [planForPoints] + [fetchPlan] so it can veto between the two).
  Future<CoverageRunResult> fetchForPoints(
    List<GeoPoint> points, {
    required bool confirmLarge,
    void Function(CoveragePlan plan)? onPlan,
    CoverageProgress? onProgress,
    TileDownloadCancelToken? cancelToken,
    void Function()? onInstalled,
    CoverageTileServer? server,
  }) async {
    if (points.isEmpty) return const CoverageRunResult();
    final owned = server == null;
    final client = server ?? await _serverFactory();
    if (client == null) {
      return const CoverageRunResult(
        notConfigured: true,
        error: 'No map-detail server configured',
      );
    }
    try {
      final CoveragePlan plan;
      try {
        plan = await planForPoints(points, server: client);
      } on TileServerException catch (e) {
        return CoverageRunResult(error: e.toString());
      }
      onPlan?.call(plan);
      if (plan.isEmpty) return CoverageRunResult(planned: 0, error: null);
      if (!confirmLarge && plan.totalBytes > autoByteCap) {
        return CoverageRunResult(
          planned: plan.boxes.length,
          bytes: plan.totalBytes,
          exceededCap: true,
        );
      }
      // Must be awaited: the `finally` below owns the client, and
      // returning the future unawaited closed it mid-download.
      return await fetchPlan(
        plan,
        onProgress: onProgress,
        cancelToken: cancelToken,
        onInstalled: onInstalled,
        server: client,
      );
    } finally {
      if (owned) client.close();
    }
  }

  // --- automatic paths ---------------------------------------------------

  /// App start / resume hook. Never throws.
  ///
  /// Order matters: the network gate comes first (it's free), then the
  /// pending queue (a prefs read), and only then the extents refresh
  /// and the server round-trips.
  Future<void> processPendingOnAppOpen({
    required String? networkState,
    void Function()? onInstalled,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now().toUtc();
    try {
      if (_running) return;
      final last = _lastAutoRun;
      if (last != null && at.difference(last) < autoRunThrottle) return;
      final settings = await CoveragePrefs.readSettings();
      if (!shouldAutoFetchNow(
        enabled: settings.enabled,
        wifiOnly: settings.wifiOnly,
        networkState: networkState,
      )) {
        return;
      }
      // No server yet: leave the queue exactly as it is, and don't
      // burn the throttle either — the very next resume after the user
      // configures one should run.
      final client = await _serverFactory();
      if (client == null) return;
      // Throttle everything below: the extents refresh probes every
      // installed archive, which is a file open apiece.
      _lastAutoRun = at;
      try {
        final pending = await CoveragePrefs.readPending();
        // An archive installed by hand since the last launch changes
        // what counts as "already covered", so this is worth doing even
        // with an empty queue — and the refresh pass below needs it.
        final extents = await refreshExtents();
        var result = const CoverageRunResult();
        var takenCount = 0;
        if (pending.isNotEmpty) {
          final taken = await CoveragePrefs.takePending();
          takenCount = taken.length;
          result = await fetchForPoints(
            [for (final p in taken) p.toGeoPoint()],
            confirmLarge: false,
            onInstalled: onInstalled,
            server: client,
          );
          if (result.shouldRequeue) {
            await CoveragePrefs.addPendingAll(taken);
          }
        }
        final refreshed = await _refreshStalePacks(
          client: client,
          at: at,
          spentBytes: result.bytes,
          extents: extents,
          onInstalled: onInstalled,
        );
        // Nothing happened at all: leave whatever notice the last run
        // wrote rather than blanking the Settings tile on every resume.
        if (pending.isNotEmpty || refreshed > 0) {
          await CoveragePrefs.writeNotice(
            noticeFor(result.withRefreshed(refreshed), takenCount),
          );
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[coverage] processPendingOnAppOpen failed: $e');
    }
  }

  /// Weekly maintenance: rebuilds the oldest stale coverage packs on
  /// the server's current planet build.
  ///
  /// A pack is a snapshot of a planet extract, so an ageing one shows
  /// ageing streets. Rather than expiring packs (which would blank the
  /// map for a place the user has actually been) we re-fetch the SAME
  /// bbox and zooms — taken from the probed extents, so the new file
  /// covers exactly what the old one did — and delete the old file only
  /// once the new one has landed.
  ///
  /// Deliberately timid: [staleRefreshInterval] between passes,
  /// [maxStaleRefreshPerRun] packs per pass, and only the leftover of
  /// the same [autoByteCap] the pending fetch already spent from. Never
  /// throws; a pack that fails is left alone until next week.
  Future<int> _refreshStalePacks({
    required CoverageTileServer client,
    required DateTime at,
    required int spentBytes,
    required List<ArchiveExtent> extents,
    void Function()? onInstalled,
  }) async {
    final last = await CoveragePrefs.readLastRefresh();
    if (last != null && at.difference(last) < staleRefreshInterval) return 0;
    final stale = selectStalePacks(
      await _listInstalled(),
      now: at,
      maxCount: maxStaleRefreshPerRun,
    );
    // Nothing stale: don't burn the weekly marker, so the pass still
    // runs on the day a pack does age out.
    if (stale.isEmpty) return 0;
    // From here we are about to spend network, so the marker is set
    // whatever the outcome — a server that 500s must not be retried on
    // every resume for a week.
    await CoveragePrefs.setLastRefresh(at);
    final byPath = {for (final e in extents) e.path: e};
    var budget = autoByteCap - spentBytes;
    var refreshed = 0;
    _running = true;
    try {
      for (final pack in stale) {
        final extent = byPath[pack.path];
        final box = extent?.bounds;
        // No probed bounds means we cannot ask for the same area again,
        // and a guessed bbox would move the pack's footprint.
        if (extent == null || box == null) continue;
        try {
          final sized = await client.dryRun(
            box,
            minzoom: extent.minZoom,
            maxzoom: extent.maxZoom,
          );
          // The server is still on the planet build this pack came
          // from: the download would be a byte-for-byte copy under the
          // same name.
          final packDate = archiveDateFromName(pack.name);
          if (int.tryParse(sized.planetDate) == packDate) continue;
          if (sized.bytes > budget) break;
          final fresh = await client.downloadExtract(
            box,
            minzoom: extent.minZoom,
            maxzoom: extent.maxZoom,
            planetDate: sized.planetDate,
          );
          if (fresh.bytes <= 0) continue;
          budget -= fresh.bytes;
          // Only now is the old pack redundant. The path guard covers
          // the pathological case of a new file landing on the old
          // one's name.
          if (fresh.path != pack.path) await _deleteArchive(pack);
          refreshed++;
        } catch (e) {
          debugPrint('[coverage] refresh failed for ${pack.name}: $e');
        }
      }
    } finally {
      _running = false;
    }
    if (refreshed > 0) {
      await refreshExtents();
      onInstalled?.call();
    }
    return refreshed;
  }

  /// One-line status for the Settings tile. Pure so the wording is
  /// unit-testable.
  static String? noticeFor(CoverageRunResult result, int pendingCount) {
    final parts = <String>[];
    final pending = _pendingNotice(result, pendingCount);
    if (pending != null) parts.add(pending);
    if (result.refreshed > 0) {
      parts.add('Refreshed ${result.refreshed} map-detail pack'
          '${result.refreshed == 1 ? '' : 's'}.');
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// The half of [noticeFor] that talks about newly discovered places.
  static String? _pendingNotice(CoverageRunResult result, int pendingCount) {
    if (result.exceededCap) {
      final mb = (result.bytes / (1024 * 1024)).toStringAsFixed(0);
      return '$pendingCount new place${pendingCount == 1 ? '' : 's'} need '
          '≈ $mb MB — too big to fetch automatically, tap to download.';
    }
    if (result.notConfigured) return null;
    if (result.cancelled) return 'Last map-detail download was cancelled.';
    if (result.error != null) return 'Last map-detail download failed.';
    if (result.downloaded > 0) {
      final mb = (result.bytes / (1024 * 1024)).toStringAsFixed(1);
      return 'Downloaded ${result.downloaded} area'
          '${result.downloaded == 1 ? '' : 's'} ($mb MB).';
    }
    return null;
  }

  /// WorkManager-isolate hook, called after a successful real fix is
  /// inserted. Prefs only — no network, no DB, no UI providers.
  ///
  /// Records the place when no installed archive already renders it at
  /// street detail. The comparison uses the extent list the UI isolate
  /// last wrote; an empty list (fresh install, cleared prefs) means
  /// "nothing is covered", so the first few fixes queue and the first
  /// app open sorts them out.
  static Future<void> noteFixInWorker(double lat, double lon) async {
    try {
      final settings = await CoveragePrefs.readSettings();
      if (!settings.enabled) return;
      final extents = await CoveragePrefs.readExtents();
      if (isCoveredInDetail(lat, lon, extents)) return;
      await CoveragePrefs.addPending(lat, lon);
    } catch (e) {
      // Coverage is decorative relative to the ping row, which is
      // already committed. Same rule as the auto-photo fetch.
      debugPrint('[coverage] noteFixInWorker failed: $e');
    }
  }

  /// Builds a client from the stored URL + token, or `null` when the
  /// user hasn't configured a server.
  static Future<CoverageTileServer?> _serverFromPrefs() async {
    final url = await CoveragePrefs.readServerUrl();
    if (url == null) return null;
    return TileServerClient(baseUrl: url, token: await CoveragePrefs.readToken());
  }
}

/// Runs [CoverageService.processPendingOnAppOpen] when the app comes
/// back to the foreground.
///
/// Registered from `main.dart`'s post-frame block alongside
/// `MemoryPressureObserver` rather than wrapping the widget tree in an
/// `AppLifecycleListener` — same effect, one file touched, and the
/// service's own 10-minute throttle means the cold-start call and an
/// immediate resume don't both plan.
class CoverageResumeObserver with WidgetsBindingObserver {
  CoverageResumeObserver({
    Future<String?> Function()? networkLabel,
    CoverageService? service,
  })  : _networkLabel = networkLabel ?? _defaultNetworkLabel,
        _service = service;

  final Future<String?> Function() _networkLabel;
  final CoverageService? _service;

  CoverageService get _target => _service ?? CoverageService.instance;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(run());
  }

  /// Reads the current network label and hands it to the service.
  /// Exposed so `main.dart` can drive the cold-start call through the
  /// same path as a resume.
  Future<void> run() async {
    try {
      await _target.processPendingOnAppOpen(
        networkState: await _networkLabel(),
      );
    } catch (e) {
      debugPrint('[coverage] resume hook failed: $e');
    }
  }

  /// The same passive read the scheduler uses per ping — no listeners,
  /// no scan-triggering calls. `null` on any plugin failure, which
  /// [shouldAutoFetchNow] reads as "don't".
  static Future<String?> _defaultNetworkLabel() async {
    try {
      return (await BatteryNetworkService().snapshot()).networkState;
    } catch (e) {
      debugPrint('[coverage] network probe failed: $e');
      return null;
    }
  }
}
