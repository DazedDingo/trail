import 'dart:async';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping.dart';
import '../models/ping_photo.dart';
import 'online_photo_service.dart';

/// Progress snapshot emitted while a backfill is running.
class PhotoBackfillProgress {
  final int processed;
  final int total;
  final int photosAdded;
  final bool finished;
  final String? error;

  const PhotoBackfillProgress({
    required this.processed,
    required this.total,
    required this.photosAdded,
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

/// Walks every fixed ping with no `source='wikimedia'` photos and runs
/// the online photo fetcher on it. Designed for an explicit user-tap
/// trigger from Settings — never runs automatically (the dispatcher's
/// per-ping path covers new pings; this fills the back-catalogue).
///
/// Throttled: 1 ping/sec minimum gap between Wikimedia hits so we don't
/// look like a scraper. Cancellable: callers pass a `cancel` Completer
/// they can complete to stop the walk mid-way.
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

    final all = await pingDao.all();
    final wikimediaIds = await _idsWithWikimediaPhotos(db);
    final eligible = selectEligibleForBackfill(all, wikimediaIds);
    final total = eligible.length;
    var processed = 0;
    var added = 0;

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
        try {
          final fetched = await onlineService.fetchNearby(
            lat: ping.lat!,
            lon: ping.lon!,
          );
          if (fetched.isNotEmpty) {
            final rows = <PingPhoto>[];
            for (var i = 0; i < fetched.length; i++) {
              final f = fetched[i];
              rows.add(PingPhoto(
                pingId: ping.id!,
                uri: f.uri,
                source: PingPhotoSource.wikimedia,
                attribution: f.attribution,
                license: f.license,
                thumbUri: f.thumbUri,
                fetchedAt: DateTime.now().toUtc(),
                ordinal: i,
              ));
            }
            await photoDao.insertAll(rows);
            added += rows.length;
          }
        } catch (_) {
          // Per-ping failure shouldn't abort the whole walk — log
          // would be nice but the UI surfaces no-progress anyway via
          // the next emitted event.
        }
        processed++;
        yield PhotoBackfillProgress(
          processed: processed,
          total: total,
          photosAdded: added,
        );
        if (processed < total) {
          await Future.delayed(throttle);
        }
      }
      yield PhotoBackfillProgress(
        processed: processed,
        total: total,
        photosAdded: added,
        finished: true,
      );
    } catch (e) {
      yield PhotoBackfillProgress(
        processed: processed,
        total: total,
        photosAdded: added,
        finished: true,
        error: e.toString(),
      );
    }
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
