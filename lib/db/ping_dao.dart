import 'dart:math' as math;

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

  /// "This row is a real fix." Byte-identical to the WHERE clause of the
  /// partial index `idx_pings_ts_fix` (schema v4, `TrailDatabase`) —
  /// SQLite only considers a partial index when the query's WHERE
  /// *syntactically* implies the index's, so keep this text and the
  /// index DDL in lock-step. Every fixes-only read composes it.
  static const fixPredicate = 'lat IS NOT NULL AND lon IS NOT NULL';

  /// "This row is not a Timeline import." Timeline import rows (schema
  /// v5, source = 'import') are map-only data (docs/TIMELINE_IMPORT.md,
  /// "Exclusions that must ship with it" + commander's decision "imports
  /// are map-only"): the heartbeat/"last ping" card, the Recent list and
  /// the photo backfill must never surface or act on one. Not tied to a
  /// specific index the way [fixPredicate] is — `idx_pings_import` only
  /// helps a lookup keyed *by* `import_id`, not a `!= 'import'` scan.
  static const notImportedPredicate = "source != 'import'";

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
  /// on the home screen. Rejects `no_fix`, null-coord rows, AND imported
  /// rows (schema v5) — an export must never become "the last ping"
  /// (docs/TIMELINE_IMPORT.md exclusions).
  ///
  /// Leads with [fixPredicate] so the planner walks `idx_pings_ts_fix`
  /// backwards and stops at its first entry — O(1) regardless of how
  /// many no_fix rows a stationary/indoor streak has piled on top of the
  /// last real fix (pre-v4 this scanned `idx_pings_ts_utc` through every
  /// one of them). The `source` checks are evaluated on that one row.
  Future<Ping?> latestSuccessful() async {
    final rows = await db.query(
      'pings',
      where: "$fixPredicate AND source != 'no_fix' AND $notImportedPredicate",
      orderBy: 'ts_utc DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Ping.fromMap(rows.first);
  }

  /// Most-recent pings, newest-first. Excludes Timeline imports by
  /// default (schema v5) — the Home screen's "Recent" list and the
  /// motion-aware skip heuristic (`_maybeMotionAwareSkip`) must both
  /// reason about live device fixes only, not a historical export.
  /// Pass `includeImported: true` for a full-history read (e.g. the
  /// History screen, which is the one place imports belong).
  Future<List<Ping>> recent({
    int limit = 200,
    bool includeImported = false,
  }) async {
    final rows = await db.query(
      'pings',
      where: includeImported ? null : notImportedPredicate,
      orderBy: 'ts_utc DESC',
      limit: limit,
    );
    return rows.map(Ping.fromMap).toList();
  }

  /// Every row, oldest-first. Excludes Timeline imports by default —
  /// stats/trips/heatmap are live-Trail-data-only per the commander's
  /// decision ("imported rows are map-only ... stats stay real Trail
  /// data", docs/TIMELINE_IMPORT.md). Pass `includeImported: true` for
  /// paths that legitimately want the full table (e.g. a "no range
  /// picked" export).
  Future<List<Ping>> allPings({bool includeImported = false}) async {
    final rows = await db.query(
      'pings',
      where: includeImported ? null : notImportedPredicate,
      orderBy: 'ts_utc ASC',
    );
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

  /// ONE page of History, newest-first, clipped to the half-open
  /// window `[startUtcMs, endUtcMs)` (epoch ms UTC — the local-year →
  /// UTC conversion lives in `pings_provider.dart`,
  /// `historyYearUtcBoundsMs`, so this layer stays free of Flutter
  /// types). Start inclusive, end exclusive on purpose: a calendar year
  /// is `[1 Jan, next 1 Jan)`, so consecutive years tile the timeline
  /// with neither a gap nor a shared row (unlike [byDateRange]'s
  /// `BETWEEN`, which is inclusive at both ends because export/archive
  /// windows are user-picked days).
  ///
  /// Keyset pagination, not OFFSET: pass the LAST row's `ts_utc` of the
  /// previous page as [beforeTsUtcMs] and the next page starts strictly
  /// below it. `LIMIT n OFFSET k` re-walks and discards `k` index
  /// entries per page, which turns "Load more" on a decade-deep import
  /// into an O(k) scan; a keyset seek is one index descent regardless
  /// of depth, and it can't skip or duplicate rows when a write lands
  /// between two pages.
  ///
  /// Includes Timeline imports by DEFAULT (the inverse of [recent]) —
  /// History is the one list where an import belongs (gotcha 34).
  ///
  /// Ties: rows sharing the exact boundary millisecond with the page's
  /// last row are not carried into the next page (the seek is strictly
  /// `<`). `ts_utc` is a wall-clock-millisecond fix time, so this needs
  /// two pings in the same millisecond at a 200-row page boundary to
  /// bite; the tie-break inside a page is `id DESC` so the order is
  /// still total and stable.
  Future<List<Ping>> pageByRange({
    required int startUtcMs,
    required int endUtcMs,
    required int limit,
    int? beforeTsUtcMs,
    bool includeImported = true,
  }) async {
    final where = StringBuffer('ts_utc >= ? AND ts_utc < ?');
    final args = <Object?>[startUtcMs, endUtcMs];
    if (beforeTsUtcMs != null) {
      where.write(' AND ts_utc < ?');
      args.add(beforeTsUtcMs);
    }
    if (!includeImported) where.write(' AND $notImportedPredicate');
    final rows = await db.query(
      'pings',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'ts_utc DESC, id DESC',
      limit: limit,
    );
    return rows.map(Ping.fromMap).toList();
  }

  /// Fixes only — rows with a usable `lat`/`lon` — oldest-first,
  /// optionally clipped to `[startUtc, endUtc]` (both ends inclusive;
  /// either bound may be omitted, neither = every fix ever). This is the
  /// map's read (0.14.1, PERF_PLAN §2 M4): the map never draws a
  /// coordinate-less `no_fix`/boot row, so they are dropped here instead
  /// of in `buildPinSnapshot`, and [fixPredicate] lets the planner range-
  /// scan the partial index `idx_pings_ts_fix` — only fix rows are
  /// touched, and the index carries the (ts_utc, lat, lon) triple the
  /// map needs.
  ///
  /// Deliberately still `SELECT *` rather than a 5-column projection: the
  /// pin detail sheet reads accuracy / altitude / speed / battery /
  /// network / cell / wifi / note / comment straight off the `id → Ping`
  /// map the panel builds from this list, so a narrower row would force
  /// a second per-tap read. Row decode is off the hot path (~30–50 ms per
  /// 10k rows, PERF_PLAN §1.1); the pin-upload cost it sat next to is gone.
  ///
  /// Bounds are UTC instants. The local-day → UTC expansion the UI needs
  /// lives in `pings_provider.dart` (`mapRangeUtcBounds`), keeping this
  /// layer free of Flutter types.
  Future<List<Ping>> fixesByDateRange({
    DateTime? startUtc,
    DateTime? endUtc,
  }) async {
    final where = StringBuffer(fixPredicate);
    final args = <Object?>[];
    if (startUtc != null && endUtc != null) {
      where.write(' AND ts_utc BETWEEN ? AND ?');
      args
        ..add(startUtc.millisecondsSinceEpoch)
        ..add(endUtc.millisecondsSinceEpoch);
    } else if (startUtc != null) {
      where.write(' AND ts_utc >= ?');
      args.add(startUtc.millisecondsSinceEpoch);
    } else if (endUtc != null) {
      where.write(' AND ts_utc <= ?');
      args.add(endUtc.millisecondsSinceEpoch);
    }
    final rows = await db.query(
      'pings',
      where: where.toString(),
      whereArgs: args,
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
  /// [allPings] so exports match historical shape.
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

  /// `(ts_utc, lat, lon)` for every existing fix in
  /// `[tsMinUtcMs, tsMaxUtcMs]` (inclusive, epoch ms), oldest-first. The
  /// import pipeline's dedupe pass (docs/TIMELINE_IMPORT.md: "skip a
  /// candidate within ±60 s and < 25 m of an existing row") loads this
  /// once per file and binary-searches it rather than round-tripping
  /// SQLite per candidate. Index-only: [fixPredicate] + the `ts_utc`
  /// range are exactly `idx_pings_ts_fix`'s covering columns, so this
  /// never touches the base table. Deliberately NOT filtered by
  /// [notImportedPredicate] — a re-import must dedupe against a
  /// *previous* import's rows too, not just live pings.
  Future<List<({int tsUtcMs, double lat, double lon})>> existingFixesInRange(
    int tsMinUtcMs,
    int tsMaxUtcMs,
  ) async {
    final rows = await db.query(
      'pings',
      columns: const ['ts_utc', 'lat', 'lon'],
      where: '$fixPredicate AND ts_utc BETWEEN ? AND ?',
      whereArgs: [tsMinUtcMs, tsMaxUtcMs],
      orderBy: 'ts_utc ASC',
    );
    return rows
        .map((r) => (
              tsUtcMs: r['ts_utc'] as int,
              lat: (r['lat'] as num).toDouble(),
              lon: (r['lon'] as num).toDouble(),
            ))
        .toList();
  }

  /// Rows per `Batch.commit` — a single-transaction, single-batch insert
  /// of a 100k-row import would hold one giant SQLCipher journal open
  /// for the whole write; chunking keeps each commit's journal bounded
  /// while the surrounding transaction still makes the whole import
  /// atomic (a crash mid-way rolls every chunk back, never a partial
  /// import sitting in the table).
  static const importBatchChunkSize = 500;

  /// Inserts [rows] as one Timeline import batch, stamping every row's
  /// `source` to [PingSource.imported] and `import_id` to [importId]
  /// regardless of whatever source/importId the caller's [Ping] objects
  /// already carry (the import pipeline builds plain [Ping]s from parsed
  /// candidates; this is where they become "imported"). Runs inside a
  /// single transaction, `Batch`-committed in chunks of
  /// [importBatchChunkSize]. Returns the number of rows inserted.
  Future<int> insertImportedBatch(
    List<Ping> rows, {
    required int importId,
  }) async {
    if (rows.isEmpty) return 0;
    await db.transaction((txn) async {
      for (var start = 0; start < rows.length; start += importBatchChunkSize) {
        final end = math.min(start + importBatchChunkSize, rows.length);
        final batch = txn.batch();
        for (final p in rows.sublist(start, end)) {
          final map = p.toMap()..remove('id');
          map['source'] = PingSource.imported.dbValue;
          map['import_id'] = importId;
          batch.insert('pings', map);
        }
        await batch.commit(noResult: true);
      }
    });
    return rows.length;
  }

  /// Deletes every row belonging to one import batch. Used by "Undo last
  /// import". Returns the deleted row count.
  Future<int> deleteByImportId(int id) async {
    return db.delete('pings', where: 'import_id = ?', whereArgs: [id]);
  }

  /// Row count for one import batch — the preview/undo confirmation's
  /// "this will remove N pings" figure.
  Future<int> countByImportId(int id) async {
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pings WHERE import_id = ?',
      [id],
    );
    return (r.first['c'] as int?) ?? 0;
  }
  /// Oldest and newest fix timestamps (epoch ms UTC), or `(null, null)`
  /// on a table with no usable coordinate. Index-only: `MIN`/`MAX` over
  /// [fixPredicate] is answered from the two ends of the partial index
  /// `idx_pings_ts_fix`, never a scan.
  ///
  /// Timeline imports are deliberately INCLUDED (no
  /// [notImportedPredicate]) — this feeds the map's year chips, and the
  /// years an import added are exactly the ones the user needs a chip
  /// for (docs/TIMELINE_IMPORT.md: imports are map-only, and the map is
  /// what this serves).
  Future<({int? minUtcMs, int? maxUtcMs})> tsRange() async {
    final r = await db.rawQuery(
      'SELECT MIN(ts_utc) AS lo, MAX(ts_utc) AS hi FROM pings '
      'WHERE $fixPredicate',
    );
    final row = r.first;
    return (minUtcMs: row['lo'] as int?, maxUtcMs: row['hi'] as int?);
  }

  /// Full [Ping] rows for one import batch's fixes, oldest-first.
  ///
  /// [fixesByImportId] hands the coverage planner stripped triples; the
  /// per-import "Photos…" action needs real [Ping] objects (ids and
  /// source) to feed `selectEligibleForBackfill`. Fixes only — a
  /// no-coordinate row has nothing to look up. No cap: the caller is
  /// about to make one network round-trip per uncached cell, so it wants
  /// the honest count, not a sample.
  Future<List<Ping>> pingsByImportId(int importId) async {
    final rows = await db.query(
      'pings',
      where: 'import_id = ? AND $fixPredicate',
      whereArgs: [importId],
      orderBy: 'ts_utc ASC',
    );
    return rows.map(Ping.fromMap).toList();
  }

  /// Every imported Timeline **visit** row, oldest-first — the
  /// `visitStart` / `visitEnd` pairs `timeline_mappers.dart` writes for a
  /// `semanticSegments[].visit` element (both rows share the
  /// `gmaps:visit:<TYPE>:<placeId>` note and the place's coordinates, see
  /// gotcha 35). Feeds the Places screen via `buildPlaces`.
  ///
  /// The one read that is imports-ONLY: a visit note can only exist on an
  /// imported row, and live pings have no notion of "a place you stayed
  /// at". This does not loosen the exclusion contract (gotcha 34) — it
  /// runs the other way, showing imports and nothing else.
  ///
  /// Bounded by the export, not by history: an Android Timeline export
  /// carries a few thousand visits, so this returns the whole set rather
  /// than paging.
  Future<List<({int tsUtcMs, double lat, double lon, String note})>>
      importedVisits() async {
    final rows = await db.query(
      'pings',
      columns: const ['ts_utc', 'lat', 'lon', 'note'],
      where: "source = 'import' AND note LIKE 'gmaps:visit:%' "
          'AND $fixPredicate',
      orderBy: 'ts_utc ASC',
    );
    return [
      for (final r in rows)
        (
          tsUtcMs: r['ts_utc'] as int,
          lat: (r['lat'] as num).toDouble(),
          lon: (r['lon'] as num).toDouble(),
          note: r['note'] as String,
        ),
    ];
  }

  /// `(ts_utc, lat, lon)` for one import batch's fixes, oldest-first,
  /// stride-sampled down to at most [limit] rows.
  ///
  /// Feeds the per-import "Map detail…" action (a Timeline import older
  /// than a year is out of reach of the Settings button, which only
  /// looks at the last 365 days). The planner only needs enough points
  /// to find the clusters, so an even stride over the whole batch beats
  /// the first N rows — those would all sit in the oldest week.
  /// `limit <= 0` disables the cap.
  Future<List<({int tsUtcMs, double lat, double lon})>> fixesByImportId(
    int importId, {
    int limit = 5000,
  }) async {
    final rows = await db.query(
      'pings',
      columns: const ['ts_utc', 'lat', 'lon'],
      where: 'import_id = ? AND $fixPredicate',
      whereArgs: [importId],
      orderBy: 'ts_utc ASC',
    );
    final stride =
        (limit <= 0 || rows.length <= limit) ? 1 : (rows.length / limit).ceil();
    final out = <({int tsUtcMs, double lat, double lon})>[];
    for (var i = 0; i < rows.length; i += stride) {
      final r = rows[i];
      out.add((
        tsUtcMs: r['ts_utc'] as int,
        lat: (r['lat'] as num).toDouble(),
        lon: (r['lon'] as num).toDouble(),
      ));
    }
    return out;
  }
}
