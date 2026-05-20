import 'dart:async';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../db/area_photo_dao.dart';
import '../db/database.dart';
import '../db/ping_dao.dart';
import '../db/ping_photo_dao.dart';
import '../models/area_photo.dart';
import '../models/ping.dart';
import '../models/ping_photo.dart';
import 'cell_photo_picker.dart';
import 'online_photo_service.dart';
import 'photo_shuffle_prefs.dart';

/// Progress snapshot emitted while a backfill is running.
class PhotoBackfillProgress {
  final int processed;
  final int total;
  final int photosAdded;
  final int cellCacheHits;
  final bool finished;
  final String? error;

  const PhotoBackfillProgress({
    required this.processed,
    required this.total,
    required this.photosAdded,
    this.cellCacheHits = 0,
    this.finished = false,
    this.error,
  });

  double get fraction => total == 0 ? 1.0 : processed / total;
}

/// Decides which pings still need an online-photo lookup. Pure so the
/// test suite can lock the contract without spinning up SQLite or HTTP.
/// A ping is eligible when it has real coords AND no `wikimedia` photos
/// yet. User-supplied photos don't block an eligible status — a manual
/// shot doesn't replace what the auto-fetcher would have found.
List<Ping> selectEligibleForBackfill(
  List<Ping> pings,
  Set<int> pingIdsWithWikimedia,
) {
  final out = <Ping>[];
  for (final p in pings) {
    if (p.id == null) continue;
    if (p.lat == null || p.lon == null) continue;
    if (p.source == PingSource.noFix) continue;
    if (pingIdsWithWikimedia.contains(p.id!)) continue;
    out.add(p);
  }
  return out;
}

/// Walks every fixed ping with no `source='wikimedia'` photos and
/// attaches photos. As of 0.13.3 the walk is cell-aware: pings sharing
/// a cell reuse the same Wikimedia query, so a 2-year history with
/// dozens of repeat visits to the same coffee shop pays one HTTP hit
/// instead of dozens. Throttle only applies between *fresh* Wikimedia
/// hits, not between cache-hit pings — so a re-backfill of an already
/// well-traveled history finishes in seconds rather than minutes.
class PhotoBackfillService {
  final OnlinePhotoService onlineService;
  final Duration throttle;

  PhotoBackfillService({
    OnlinePhotoService? onlineService,
    this.throttle = const Duration(milliseconds: 1100),
  }) : onlineService = onlineService ?? OnlinePhotoService();

  /// Streams progress events. Final event carries `finished: true` (or
  /// an `error` string). Cancellation: complete [cancel] from the
  /// caller — the next inter-ping pause checks it and exits cleanly.
  Stream<PhotoBackfillProgress> run({Completer<void>? cancel}) async* {
    final db = await TrailDatabase.shared();
    final pingDao = PingDao(db);
    final photoDao = PingPhotoDao(db);
    final areaDao = AreaPhotoDao(db);
    final salt = await PhotoShufflePrefs.getSalt();

    final all = await pingDao.all();
    final wikimediaIds = await _idsWithWikimediaPhotos(db);
    final eligible = selectEligibleForBackfill(all, wikimediaIds);
    final total = eligible.length;
    var processed = 0;
    var added = 0;
    var cacheHits = 0;

    yield PhotoBackfillProgress(
      processed: 0,
      total: total,
      photosAdded: 0,
    );

    if (total == 0) {
      yield PhotoBackfillProgress(
        processed: 0,
        total: 0,
        photosAdded: 0,
        finished: true,
      );
      return;
    }

    try {
      for (final ping in eligible) {
        if (cancel != null && cancel.isCompleted) break;
        final cellLat = quantizeCellLat(ping.lat!);
        final cellLon = quantizeCellLon(ping.lon!);
        var cacheHit = false;
        try {
          var pool = await areaDao.byCell(cellLat, cellLon);
          if (pool.isEmpty) {
            final fetched = await onlineService.fetchNearby(
              lat: ping.lat!,
              lon: ping.lon!,
              limit: 20,
            );
            if (fetched.isNotEmpty) {
              final now = DateTime.now().toUtc();
              final toCache = [
                for (final f in fetched)
                  AreaPhoto(
                    cellLat: cellLat,
                    cellLon: cellLon,
                    uri: f.uri,
                    thumbUri: f.thumbUri,
                    attribution: f.attribution,
                    license: f.license,
                    discoveredAt: now,
                  ),
              ];
              await areaDao.insertForCell(
                cellLat: cellLat,
                cellLon: cellLon,
                photos: toCache,
              );
              pool = await areaDao.byCell(cellLat, cellLon);
            }
          } else {
            cacheHit = true;
            cacheHits++;
          }
          if (pool.isNotEmpty) {
            final picks = pickRotatedPhotos(
              allCellPhotos: pool,
              pingId: ping.id!,
              k: 5,
              salt: salt,
            );
            if (picks.isNotEmpty) {
              final now = DateTime.now().toUtc();
              final rows = <PingPhoto>[];
              for (var i = 0; i < picks.length; i++) {
                final p = picks[i];
                rows.add(PingPhoto(
                  pingId: ping.id!,
                  uri: p.uri,
                  source: PingPhotoSource.wikimedia,
                  attribution: p.attribution,
                  license: p.license,
                  thumbUri: p.thumbUri,
                  fetchedAt: now,
                  ordinal: i,
                ));
              }
              await photoDao.insertAll(rows);
              added += rows.length;
            }
          }
        } catch (_) {
          // Per-ping failure shouldn't abort the whole walk.
        }
        processed++;
        yield PhotoBackfillProgress(
          processed: processed,
          total: total,
          photosAdded: added,
          cellCacheHits: cacheHits,
        );
        // Throttle only when we actually hit Wikimedia; cache hits are
        // free, so re-backfills cruise.
        if (processed < total && !cacheHit) {
          await Future.delayed(throttle);
        }
      }
      yield PhotoBackfillProgress(
        processed: processed,
        total: total,
        photosAdded: added,
        cellCacheHits: cacheHits,
        finished: true,
      );
    } catch (e) {
      yield PhotoBackfillProgress(
        processed: processed,
        total: total,
        photosAdded: added,
        cellCacheHits: cacheHits,
        finished: true,
        error: e.toString(),
      );
    }
  }

  /// Re-shuffle path: drops every wikimedia row from `ping_photos`,
  /// bumps the shuffle salt, then re-runs the regular walk — which is
  /// now all cache hits for cells the user has visited before, so it
  /// completes in seconds. User photos are untouched.
  Stream<PhotoBackfillProgress> reshuffle({Completer<void>? cancel}) async* {
    final db = await TrailDatabase.shared();
    await db.delete('ping_photos', where: "source = 'wikimedia'");
    await PhotoShufflePrefs.bumpSalt();
    yield* run(cancel: cancel);
  }

  Future<Set<int>> _idsWithWikimediaPhotos(Database db) async {
    final rows = await db.rawQuery(
      "SELECT DISTINCT ping_id FROM ping_photos WHERE source = 'wikimedia'",
    );
    return rows
        .map((r) => (r['ping_id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();
  }
}
