import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/ping_photo.dart';
import '../services/online_photo_service.dart' show isLikelyImage;

/// CRUD for the `ping_photos` table (schema v2).
class PingPhotoDao {
  final Database db;
  PingPhotoDao(this.db);

  /// Returns every photo for a single ping, in display order. Empty
  /// list for pings with no photos yet (auto-fetch pending, or user
  /// declined to attach anything).
  ///
  /// Read-time tombstone filter (added 0.13.2): rows whose URI isn't a
  /// decodable image type are skipped. 0.13.0 + earlier inserted a lot
  /// of non-image File: namespace entries (OGG / PDF / MP4) that
  /// rendered as broken-image placeholders in the gallery and
  /// slideshow. The parser-side fix prevents new bad rows; this filter
  /// hides existing ones until a future migration deletes them.
  Future<List<PingPhoto>> byPingId(int pingId) async {
    final rows = await db.query(
      'ping_photos',
      where: 'ping_id = ?',
      whereArgs: [pingId],
      orderBy: 'ordinal ASC, id ASC',
    );
    return rows.map(PingPhoto.fromMap).where(_renderable).toList();
  }

  /// Batch-load all photos for a set of pings. Returned as
  /// `Map<pingId, List<PingPhoto>>` so the picture-mode playback can
  /// hydrate the whole trail in a single SQLite query instead of N+1.
  /// Empty/missing keys mean the ping has no photos. Same read-time
  /// tombstone filter as [byPingId].
  Future<Map<int, List<PingPhoto>>> byPingIds(Iterable<int> pingIds) async {
    final ids = pingIds.toList();
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'ping_photos',
      where: 'ping_id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'ping_id ASC, ordinal ASC, id ASC',
    );
    final out = <int, List<PingPhoto>>{};
    for (final r in rows) {
      final p = PingPhoto.fromMap(r);
      if (!_renderable(p)) continue;
      (out[p.pingId] ??= <PingPhoto>[]).add(p);
    }
    return out;
  }

  /// True when the photo's primary URI looks like an image Flutter can
  /// decode. User-supplied rows always pass (the camera/gallery picker
  /// only returns image files), so the filter only screens the online
  /// `wikimedia` path that GeoSearch over-returns for non-image media.
  static bool _renderable(PingPhoto p) {
    if (p.source != PingPhotoSource.wikimedia) return true;
    return isLikelyImage(p.uri) ||
        (p.thumbUri != null && isLikelyImage(p.thumbUri!));
  }

  /// Insert a photo. Returns the new row id. The caller is responsible
  /// for assigning `ordinal` — typically `existingCount` for an append.
  Future<int> insert(PingPhoto photo) async {
    final map = photo.toMap()..remove('id');
    return db.insert('ping_photos', map);
  }

  /// Batch-insert photos for one ping in a single transaction. Convenience
  /// for the online auto-fetch path which writes 0–5 rows per ping.
  Future<void> insertAll(List<PingPhoto> photos) async {
    if (photos.isEmpty) return;
    final batch = db.batch();
    for (final p in photos) {
      final map = p.toMap()..remove('id');
      batch.insert('ping_photos', map);
    }
    await batch.commit(noResult: true);
  }

  /// Count of online-source photos for a ping. Used by the auto-fetcher
  /// to skip pings that already have online photos (idempotency on retry).
  Future<int> onlineCountForPing(int pingId) async {
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ping_photos '
      "WHERE ping_id = ? AND source = 'wikimedia'",
      [pingId],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// Remove a single photo by id. Used by the gallery sheet's
  /// long-press → remove flow.
  Future<int> deleteById(int id) async {
    return db.delete('ping_photos', where: 'id = ?', whereArgs: [id]);
  }

  /// Remove every photo for a ping. Called when the parent ping is
  /// archived — SQLite's `ON DELETE CASCADE` would handle this if foreign
  /// keys were enabled, but SQLCipher's default is off, so we do it
  /// explicitly.
  Future<int> deleteForPing(int pingId) async {
    return db.delete('ping_photos', where: 'ping_id = ?', whereArgs: [pingId]);
  }
}
