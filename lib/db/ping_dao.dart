import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/ping.dart';

/// Thin repository for the `pings` table.
///
/// Stateless — pass in a [Database] per call. Both the UI isolate and the
/// WorkManager background isolate instantiate their own DB handle, so a
/// cached static handle would cross isolate boundaries incorrectly.
class PingDao {
  final Database db;
  PingDao(this.db);

  Future<int> insert(Ping p) async {
    final map = p.toMap()..remove('id');
    return db.insert('pings', map);
  }

  /// Single-row read by primary key. Returns `null` if the row was deleted
  /// (e.g. archived between the notification firing and the user replying).
  Future<Ping?> byId(int id) async {
    final rows = await db.query(
      'pings',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Ping.fromMap(rows.first);
  }

  /// Sets `comment` on a ping. Used by the "How is it?" reply-attach
  /// flow (schema v2). Returns the row count actually updated (0 when
  /// the target row was archived/deleted between fire and reply).
  Future<int> attachComment(int pingId, String comment) async {
    return db.update(
      'pings',
      {'comment': comment},
      where: 'id = ?',
      whereArgs: [pingId],
    );
  }

  /// Most-recent ping regardless of source. `null` on a brand-new install.
  Future<Ping?> latest() async {
    final rows = await db.query(
      'pings',
      orderBy: 'ts_utc DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Ping.fromMap(rows.first);
  }

  /// Most-recent successful fix — used by the "last successful ping" card
  /// on the home screen. Rejects `no_fix` and null-coord rows.
  Future<Ping?> latestSuccessful() async {
    final rows = await db.query(
      'pings',
      where: "source != 'no_fix' AND lat IS NOT NULL AND lon IS NOT NULL",
      orderBy: 'ts_utc DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Ping.fromMap(rows.first);
  }

  Future<List<Ping>> recent({int limit = 200}) async {
    final rows = await db.query(
      'pings',
      orderBy: 'ts_utc DESC',
      limit: limit,
    );
    return rows.map(Ping.fromMap).toList();
  }

  Future<List<Ping>> all() async {
    final rows = await db.query('pings', orderBy: 'ts_utc ASC');
    return rows.map(Ping.fromMap).toList();
  }

  /// Pings whose `ts_utc` falls in `[startUtc, endUtc]` (inclusive on
  /// both ends). Same chronological (oldest-first) order as [all],
  /// just clipped at the SQL layer so the map's date-range filter
  /// doesn't have to round-trip the full `pings` table when the user
  /// only cares about last weekend.
  Future<List<Ping>> byDateRange(DateTime startUtc, DateTime endUtc) async {
    final rows = await db.query(
      'pings',
      where: 'ts_utc BETWEEN ? AND ?',
      whereArgs: [
        startUtc.millisecondsSinceEpoch,
        endUtc.millisecondsSinceEpoch,
      ],
      orderBy: 'ts_utc ASC',
    );
    return rows.map(Ping.fromMap).toList();
  }

  Future<int> count() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM pings');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Number of rows with `ts_utc < cutoff` (strict). Used by the
  /// archive flow to show "about to archive N pings" before the user
  /// confirms.
  Future<int> countOlderThan(DateTime cutoffUtc) async {
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pings WHERE ts_utc < ?',
      [cutoffUtc.millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// Every row with `ts_utc < cutoff`, ASCENDING — same order as
  /// [all] so exports match historical shape.
  Future<List<Ping>> olderThan(DateTime cutoffUtc) async {
    final rows = await db.query(
      'pings',
      where: 'ts_utc < ?',
      whereArgs: [cutoffUtc.millisecondsSinceEpoch],
      orderBy: 'ts_utc ASC',
    );
    return rows.map(Ping.fromMap).toList();
  }

  /// Deletes every row with `ts_utc < cutoff`. Returns the deleted row
  /// count so the archive flow can show "archived 421 pings" without
  /// racing a concurrent writer (transactional delete).
  Future<int> deleteOlderThan(DateTime cutoffUtc) async {
    return db.delete(
      'pings',
      where: 'ts_utc < ?',
      whereArgs: [cutoffUtc.millisecondsSinceEpoch],
    );
  }

  /// Deletes a single ping by id, atomically with its `ping_photos`
  /// dependents. SQLCipher ships with foreign-key enforcement OFF by
  /// default, so we delete photos explicitly first inside the same
  /// transaction — a half-finished delete would leave orphaned photo
  /// rows referencing a nonexistent ping_id. Returns true when the
  /// ping row was actually removed (false on missing id).
  Future<bool> deleteById(int id) async {
    var removed = 0;
    await db.transaction((txn) async {
      await txn.delete(
        'ping_photos', where: 'ping_id = ?', whereArgs: [id],
      );
      removed = await txn.delete(
        'pings', where: 'id = ?', whereArgs: [id],
      );
    });
    return removed > 0;
  }
}
