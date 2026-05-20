import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/area_photo.dart';

/// CRUD for the per-cell `area_photos` cache (schema v3).
class AreaPhotoDao {
  final Database db;
  AreaPhotoDao(this.db);

  /// All cached photos for the cell at quantized [cellLat]/[cellLon].
  /// Returns an empty list when the cell hasn't been fetched yet.
  Future<List<AreaPhoto>> byCell(double cellLat, double cellLon) async {
    final rows = await db.query(
      'area_photos',
      where: 'cell_lat = ? AND cell_lon = ?',
      whereArgs: [cellLat, cellLon],
      orderBy: 'id ASC',
    );
    return rows.map(AreaPhoto.fromMap).toList();
  }

  /// True when the cell already has cached photos. Used by the
  /// dispatcher + backfill to short-circuit before hitting Wikimedia.
  Future<bool> hasCellCache(double cellLat, double cellLon) async {
    final r = await db.rawQuery(
      'SELECT 1 FROM area_photos WHERE cell_lat = ? AND cell_lon = ? LIMIT 1',
      [cellLat, cellLon],
    );
    return r.isNotEmpty;
  }

  /// Inserts a batch of photos for one cell. Idempotency guard built
  /// into the helper so concurrent first-visit dispatchers don't
  /// duplicate: re-checks `hasCellCache` inside the transaction and
  /// no-ops if another writer beat us to it.
  Future<int> insertForCell({
    required double cellLat,
    required double cellLon,
    required List<AreaPhoto> photos,
  }) async {
    if (photos.isEmpty) return 0;
    return db.transaction<int>((txn) async {
      final r = await txn.rawQuery(
        'SELECT 1 FROM area_photos WHERE cell_lat = ? AND cell_lon = ? LIMIT 1',
        [cellLat, cellLon],
      );
      if (r.isNotEmpty) return 0; // another writer won the race
      final batch = txn.batch();
      for (final p in photos) {
        final map = p.toMap()..remove('id');
        batch.insert('area_photos', map);
      }
      await batch.commit(noResult: true);
      return photos.length;
    });
  }

  /// Diagnostic — total cached cells. Used by Settings to surface
  /// "Photo cache: N cells across M photos".
  Future<int> cellCount() async {
    final r = await db.rawQuery(
      'SELECT COUNT(DISTINCT cell_lat || ":" || cell_lon) AS c FROM area_photos',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> totalPhotoCount() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM area_photos');
    return (r.first['c'] as int?) ?? 0;
  }
}
