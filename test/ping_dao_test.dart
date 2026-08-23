import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/stats/places_service.dart';

/// Isolate-side sqlite3 loader. Must be a TOP-LEVEL function so it can be
/// sent across the `Isolate.spawn` boundary inside `sqflite_common_ffi`'s
/// FFI factory (a closure would fail to serialize). Registers the linker
/// override inside the background isolate, since `open.overrideFor`
/// registrations in the main isolate do NOT propagate.
///
/// Pinned to `.so.0` because `sqflite_common_ffi 2.3.7+1` (forced by
/// `flutter_map_mbtiles`' transitive pins) calls `DynamicLibrary.open(
/// 'libsqlite3.so')` — the unversioned symlink only exists in
/// `libsqlite3-dev`, which isn't installed on CI workers or fresh dev
/// images. The `.so.0` versioned file IS on every Debian/Ubuntu system.
void _ffiInit() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      for (final candidate in const [
        'libsqlite3.so.0',
        '/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
      ]) {
        try {
          return DynamicLibrary.open(candidate);
        } on ArgumentError {
          // Try next candidate.
        }
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
}

/// In-memory sqflite-ffi harness. Schema mirrors production exactly (see
/// [TrailDatabase._onCreate]) — keep them in lock-step when bumping the
/// schema version.
Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE pings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts_utc INTEGER NOT NULL,
      lat REAL,
      lon REAL,
      accuracy REAL,
      altitude REAL,
      heading REAL,
      speed REAL,
      battery_pct INTEGER,
      network_state TEXT,
      cell_id TEXT,
      wifi_ssid TEXT,
      source TEXT NOT NULL,
      note TEXT,
      comment TEXT,
      import_id INTEGER
    );
  ''');
  await db.execute('CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);');
  // idx_pings_ts_fix (schema v4) — partial covering index the fixes-only
  // map read + latestSuccessful walk. Mirror of
  // TrailDatabase._pingsTsFixIndexSql; keep byte-identical (gotcha 20).
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_pings_ts_fix ON pings(ts_utc, lat, lon) '
    'WHERE lat IS NOT NULL AND lon IS NOT NULL;',
  );
  // idx_pings_import (schema v5) — partial index for import-batch lookups
  // (`deleteByImportId` / `countByImportId`). Mirror of
  // TrailDatabase._pingsImportIndexSql.
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_pings_import ON pings(import_id) '
    'WHERE import_id IS NOT NULL;',
  );
  // ping_photos (schema v2) — kept in lock-step with TrailDatabase._onCreate
  // so the DAO tests can exercise photo CRUD without a real SQLCipher open.
  await db.execute('''
    CREATE TABLE ping_photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ping_id INTEGER NOT NULL,
      uri TEXT NOT NULL,
      source TEXT NOT NULL,
      attribution TEXT,
      license TEXT,
      thumb_uri TEXT,
      fetched_at INTEGER NOT NULL,
      ordinal INTEGER NOT NULL,
      FOREIGN KEY (ping_id) REFERENCES pings(id) ON DELETE CASCADE
    );
  ''');
  await db.execute(
      'CREATE INDEX idx_ping_photos_ping_id ON ping_photos(ping_id);');
  // area_photos (schema v3) — cell-keyed photo cache. Mirror of
  // TrailDatabase._areaPhotosCreateSql.
  await db.execute('''
    CREATE TABLE area_photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cell_lat REAL NOT NULL,
      cell_lon REAL NOT NULL,
      uri TEXT NOT NULL,
      thumb_uri TEXT,
      attribution TEXT,
      license TEXT,
      discovered_at INTEGER NOT NULL
    );
  ''');
  await db.execute(
      'CREATE INDEX idx_area_photos_cell ON area_photos(cell_lat, cell_lon);');
  // imports (schema v5) — mirror of TrailDatabase._importsCreateSql.
  await db.execute('''
    CREATE TABLE imports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      imported_at_utc INTEGER NOT NULL,
      file_name TEXT,
      file_hash TEXT NOT NULL UNIQUE,
      preset TEXT NOT NULL,
      row_count INTEGER NOT NULL,
      ts_min_utc INTEGER,
      ts_max_utc INTEGER
    );
  ''');
  return db;
}

Ping _p(
  DateTime t, {
  double? lat,
  double? lon,
  PingSource source = PingSource.scheduled,
  String? note,
}) =>
    Ping(
      timestampUtc: t,
      lat: lat,
      lon: lon,
      source: source,
      note: note,
    );

void main() {
  late Database db;
  late PingDao dao;

  setUp(() async {
    db = await _openMemDb();
    dao = PingDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('PingDao.insert', () {
    test('returns the generated rowid', () async {
      final id =
          await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 1.0, lon: 2.0));
      expect(id, isNonZero);
    });

    test('strips caller-provided id (autoincrement owns it)', () async {
      final ping = Ping(
        id: 999,
        timestampUtc: DateTime.utc(2026, 1, 1),
        lat: 1.0,
        lon: 2.0,
        source: PingSource.scheduled,
      );
      final id = await dao.insert(ping);
      // A fresh table starts at 1; if we didn't strip, this would be 999.
      expect(id, 1);
    });

    test('persists a no_fix row with null coords (gap visibility)', () async {
      final id = await dao.insert(_p(
        DateTime.utc(2026, 1, 1),
        source: PingSource.noFix,
        note: 'permission_denied',
      ));
      expect(id, isNonZero);
      final rows = await db.query('pings');
      expect(rows.first['lat'], isNull);
      expect(rows.first['source'], 'no_fix');
    });

    test('a plain (non-import) ping round-trips with a NULL import_id '
        '(schema v5)', () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 1, lon: 2));
      final got = await dao.byId(id);
      expect(got!.importId, isNull);
    });

    test('Ping.importId round-trips through toMap/fromMap when set directly',
        () async {
      final id = await dao.insert(Ping(
        timestampUtc: DateTime.utc(2026, 1, 1),
        lat: 1,
        lon: 2,
        source: PingSource.imported,
        importId: 42,
      ));
      final got = await dao.byId(id);
      expect(got!.source, PingSource.imported);
      expect(got.importId, 42);
    });
  });

  group('PingDao.latest', () {
    test('returns null on an empty table', () async {
      expect(await dao.latest(), isNull);
    });

    test('returns the row with the greatest ts_utc', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12), lat: 3, lon: 4));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11), lat: 5, lon: 6));
      final latest = await dao.latest();
      expect(latest!.timestampUtc, DateTime.utc(2026, 1, 1, 12));
      expect(latest.lat, 3);
    });

    test('no_fix rows are eligible — latest() does NOT filter by source',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 2));
      await dao.insert(_p(
        DateTime.utc(2026, 1, 1, 12),
        source: PingSource.noFix,
        note: 'permission_denied',
      ));
      final latest = await dao.latest();
      expect(latest!.source, PingSource.noFix);
      expect(latest.lat, isNull);
    });
  });

  group('PingDao.latestSuccessful', () {
    test('returns null when every row is a no_fix', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10),
          source: PingSource.noFix, note: 'a'));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12),
          source: PingSource.noFix, note: 'b'));
      expect(await dao.latestSuccessful(), isNull);
    });

    test(
        'skips a more-recent no_fix and returns the previous successful fix',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12),
          source: PingSource.noFix, note: 'boom'));
      final latest = await dao.latestSuccessful();
      expect(latest!.timestampUtc, DateTime.utc(2026, 1, 1, 10));
      expect(latest.lat, 1);
    });

    test('rejects rows with null lat/lon even if source is scheduled', () async {
      // Defensive — a scheduled row without coords shouldn't exist in theory,
      // but if a bug ever inserts one, the "last successful fix" card must
      // NOT treat it as successful.
      await dao.insert(Ping(
        timestampUtc: DateTime.utc(2026, 1, 1, 12),
        source: PingSource.scheduled,
        // lat/lon deliberately null
      ));
      expect(await dao.latestSuccessful(), isNull);
    });

    test('boot-source rows with coords ARE considered successful', () async {
      // A boot-triggered fix is as valid as any scheduled one.
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10),
          lat: 51.5, lon: -0.1, source: PingSource.boot));
      final latest = await dao.latestSuccessful();
      expect(latest, isNotNull);
      expect(latest!.source, PingSource.boot);
    });

    test('panic-source rows with coords ARE considered successful', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10),
          lat: 1, lon: 2, source: PingSource.panic));
      final latest = await dao.latestSuccessful();
      expect(latest, isNotNull);
      expect(latest!.source, PingSource.panic);
    });

    test('skips a NEWER imported row and returns the previous live fix '
        '(schema v5 — an export must never become "the last ping")',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10),
          lat: 51.5, lon: -0.1, source: PingSource.scheduled));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12),
          lat: 51.9, lon: -0.9, source: PingSource.imported));
      final latest = await dao.latestSuccessful();
      expect(latest, isNotNull);
      expect(latest!.source, PingSource.scheduled);
      expect(latest.lat, 51.5);
    });

    test('returns null when every fix is imported', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10),
          lat: 1, lon: 2, source: PingSource.imported));
      expect(await dao.latestSuccessful(), isNull);
    });
  });

  group('PingDao.recent', () {
    test('returns rows in descending timestamp order', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12), lat: 2, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11), lat: 3, lon: 3));
      final rows = await dao.recent();
      expect(rows.map((r) => r.timestampUtc).toList(), [
        DateTime.utc(2026, 1, 1, 12),
        DateTime.utc(2026, 1, 1, 11),
        DateTime.utc(2026, 1, 1, 10),
      ]);
    });

    test('default limit is 200 (battery: never deserialize more by default)',
        () async {
      // Insert 250 rows then ask for recent() with no args.
      final batch = db.batch();
      for (var i = 0; i < 250; i++) {
        batch.insert('pings', {
          'ts_utc': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch + i,
          'lat': 1.0,
          'lon': 2.0,
          'source': 'scheduled',
        });
      }
      await batch.commit(noResult: true);
      final rows = await dao.recent();
      expect(rows.length, 200);
    });

    test('custom limit is honoured', () async {
      for (var i = 0; i < 10; i++) {
        await dao.insert(_p(
          DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          lat: 1,
          lon: 2,
        ));
      }
      expect((await dao.recent(limit: 3)).length, 3);
    });

    test('empty table returns an empty list, not null', () async {
      expect(await dao.recent(), isEmpty);
    });

    test('excludes imported rows by default (schema v5 — Home "Recent" '
        'must show live activity)', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12),
          lat: 2, lon: 2, source: PingSource.imported));
      final rows = await dao.recent();
      expect(rows.map((r) => r.source), [PingSource.scheduled]);
    });

    test('includeImported: true returns imports too, still newest-first',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12),
          lat: 2, lon: 2, source: PingSource.imported));
      final rows = await dao.recent(includeImported: true);
      expect(rows.map((r) => r.timestampUtc), [
        DateTime.utc(2026, 1, 1, 12),
        DateTime.utc(2026, 1, 1, 10),
      ]);
    });
  });

  group('PingDao.allPings', () {
    test('returns rows in ASCENDING order (opposite of recent())', () async {
      // This asymmetry matters for exports — GPX readers expect
      // chronological order, not reverse. A regression that swapped this
      // would invert every exported track.
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 2, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11), lat: 3, lon: 3));
      final rows = await dao.allPings();
      expect(rows.map((r) => r.timestampUtc).toList(), [
        DateTime.utc(2026, 1, 1, 10),
        DateTime.utc(2026, 1, 1, 11),
        DateTime.utc(2026, 1, 1, 12),
      ]);
    });

    test('returns EVERY row — no implicit limit on allPings()', () async {
      for (var i = 0; i < 300; i++) {
        await dao.insert(_p(
          DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          lat: 1,
          lon: 2,
        ));
      }
      expect((await dao.allPings()).length, 300);
    });

    test('excludes imported rows by default (schema v5 — stats/trips stay '
        'live Trail data)', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11),
          lat: 2, lon: 2, source: PingSource.imported));
      final rows = await dao.allPings();
      expect(rows.map((r) => r.source), [PingSource.scheduled]);
    });

    test('includeImported: true returns every row', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11),
          lat: 2, lon: 2, source: PingSource.imported));
      final rows = await dao.allPings(includeImported: true);
      expect(rows, hasLength(2));
    });
  });

  group('PingDao.count', () {
    test('returns 0 on an empty table', () async {
      expect(await dao.count(), 0);
    });

    test('counts every row regardless of source', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 2),
          source: PingSource.noFix, note: 'x'));
      await dao.insert(_p(DateTime.utc(2026, 1, 3),
          source: PingSource.boot, note: 'device_boot'));
      expect(await dao.count(), 3);
    });
  });

  group('PingDao.countOlderThan', () {
    test('returns 0 on an empty table', () async {
      expect(
        await dao.countOlderThan(DateTime.utc(2026, 1, 1)),
        0,
      );
    });

    test('cutoff is strict (<): rows AT the cutoff are NOT counted', () async {
      final cutoff = DateTime.utc(2026, 1, 15);
      await dao.insert(_p(cutoff, lat: 1, lon: 2));
      await dao.insert(_p(cutoff.subtract(const Duration(seconds: 1)),
          lat: 1, lon: 2));
      // The exact-cutoff row must NOT count — otherwise archive-then-delete
      // would nuke rows the preview said it would leave behind.
      expect(await dao.countOlderThan(cutoff), 1);
    });

    test('counts noFix rows too — archive prunes gaps as well', () async {
      final cutoff = DateTime.utc(2026, 1, 15);
      await dao.insert(_p(DateTime.utc(2026, 1, 10), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 11),
          source: PingSource.noFix, note: 'denied'));
      await dao.insert(_p(DateTime.utc(2026, 1, 20), lat: 1, lon: 2));
      expect(await dao.countOlderThan(cutoff), 2);
    });
  });

  group('PingDao.olderThan', () {
    test('returns rows in ASCENDING order (exports need chronological)',
        () async {
      final cutoff = DateTime.utc(2026, 2, 1);
      await dao.insert(_p(DateTime.utc(2026, 1, 20), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 10), lat: 2, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 15), lat: 3, lon: 3));
      await dao.insert(_p(DateTime.utc(2026, 2, 5), lat: 4, lon: 4));
      final rows = await dao.olderThan(cutoff);
      expect(rows.map((r) => r.timestampUtc).toList(), [
        DateTime.utc(2026, 1, 10),
        DateTime.utc(2026, 1, 15),
        DateTime.utc(2026, 1, 20),
      ]);
    });

    test('empty table → empty list', () async {
      expect(await dao.olderThan(DateTime.utc(2026, 1, 1)), isEmpty);
    });
  });

  group('PingDao.deleteOlderThan', () {
    test('returns the number of rows deleted', () async {
      final cutoff = DateTime.utc(2026, 2, 1);
      await dao.insert(_p(DateTime.utc(2026, 1, 10), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 20), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 2, 5), lat: 1, lon: 2));
      final deleted = await dao.deleteOlderThan(cutoff);
      expect(deleted, 2);
    });

    test('leaves newer rows untouched', () async {
      final cutoff = DateTime.utc(2026, 2, 1);
      await dao.insert(_p(DateTime.utc(2026, 1, 10), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 2, 5), lat: 9, lon: 9));
      await dao.deleteOlderThan(cutoff);
      final rows = await dao.allPings();
      expect(rows, hasLength(1));
      expect(rows.single.lat, 9);
      expect(rows.single.timestampUtc, DateTime.utc(2026, 2, 5));
    });

    test('rows exactly at cutoff survive (strict <)', () async {
      final cutoff = DateTime.utc(2026, 2, 1);
      await dao.insert(_p(cutoff, lat: 1, lon: 2));
      final deleted = await dao.deleteOlderThan(cutoff);
      expect(deleted, 0);
      expect(await dao.count(), 1);
    });

    test('empty table deletes 0 and does not throw', () async {
      expect(await dao.deleteOlderThan(DateTime.utc(2026, 1, 1)), 0);
    });
  });

  group('PingDao.byId + attachComment (schema v2)', () {
    test('byId returns the row matching the primary key', () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 5, 17, 9),
          lat: 1, lon: 2));
      final got = await dao.byId(id);
      expect(got, isNotNull);
      expect(got!.id, id);
      expect(got.lat, 1);
      expect(got.comment, isNull);
    });

    test('byId returns null for a missing id (archived between fire+reply)',
        () async {
      final got = await dao.byId(99999);
      expect(got, isNull);
    });

    test('attachComment sets the comment column and is roundtrip-readable',
        () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 5, 17, 10),
          lat: 1, lon: 2));
      final updated = await dao.attachComment(id, 'rainy but pretty');
      expect(updated, 1, reason: 'one row matched');
      final got = await dao.byId(id);
      expect(got!.comment, 'rainy but pretty');
    });

    test('attachComment returns 0 when the target row is gone', () async {
      final updated = await dao.attachComment(424242, 'late reply');
      expect(updated, 0);
    });

    test('attachComment is idempotent — same comment twice does not throw',
        () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 5, 17, 11),
          lat: 1, lon: 2));
      await dao.attachComment(id, 'first');
      await dao.attachComment(id, 'second-overwrite');
      final got = await dao.byId(id);
      expect(got!.comment, 'second-overwrite');
    });
  });

  group('PingDao.deleteById (schema v2 cascade)', () {
    test('returns true and removes the row', () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 5, 20, 9),
          lat: 1, lon: 2));
      expect(await dao.deleteById(id), isTrue);
      expect(await dao.byId(id), isNull);
    });

    test('returns false when the row was already gone', () async {
      expect(await dao.deleteById(424242), isFalse);
    });

    test('cascades to ping_photos rows for the same ping (FK off — '
        'we delete photos explicitly in the same txn)', () async {
      final id = await dao.insert(_p(DateTime.utc(2026, 5, 20, 10),
          lat: 1, lon: 2));
      // Seed a couple of photo rows on this ping.
      await db.insert('ping_photos', {
        'ping_id': id,
        'uri': 'file:///a.jpg',
        'source': 'user_camera',
        'attribution': '',
        'license': '',
        'fetched_at': DateTime.utc(2026, 5, 20).millisecondsSinceEpoch,
        'ordinal': 0,
      });
      await db.insert('ping_photos', {
        'ping_id': id,
        'uri': 'https://w.org/b.jpg',
        'source': 'wikimedia',
        'attribution': 'X',
        'license': 'CC BY-SA 4.0',
        'fetched_at': DateTime.utc(2026, 5, 20).millisecondsSinceEpoch,
        'ordinal': 1,
      });

      final beforeRows = await db.query('ping_photos',
          where: 'ping_id = ?', whereArgs: [id]);
      expect(beforeRows, hasLength(2));

      expect(await dao.deleteById(id), isTrue);

      final afterRows = await db.query('ping_photos',
          where: 'ping_id = ?', whereArgs: [id]);
      expect(afterRows, isEmpty,
          reason: 'ping_photos rows must be removed in the same '
              'transaction — otherwise orphans accumulate');
    });

    test('does not touch other pings\' photos', () async {
      final keep = await dao.insert(_p(DateTime.utc(2026, 5, 20, 9),
          lat: 1, lon: 2));
      final doomed = await dao.insert(_p(DateTime.utc(2026, 5, 20, 10),
          lat: 3, lon: 4));
      await db.insert('ping_photos', {
        'ping_id': keep,
        'uri': 'file:///keep.jpg',
        'source': 'user_camera',
        'fetched_at': 0,
        'ordinal': 0,
      });
      await db.insert('ping_photos', {
        'ping_id': doomed,
        'uri': 'file:///doomed.jpg',
        'source': 'user_camera',
        'fetched_at': 0,
        'ordinal': 0,
      });
      await dao.deleteById(doomed);
      final keepRows = await db.query('ping_photos',
          where: 'ping_id = ?', whereArgs: [keep]);
      expect(keepRows, hasLength(1));
    });
  });

  group('PingDao.fixesByDateRange (schema v4 map read)', () {
    late int idA, idNoFix, idB, idHalf, idC;

    setUp(() async {
      idA = await dao.insert(_p(DateTime.utc(2026, 3, 1, 8), lat: 1, lon: 1));
      idNoFix = await dao.insert(_p(DateTime.utc(2026, 3, 1, 12),
          source: PingSource.noFix, note: 'timeout'));
      idB = await dao.insert(_p(DateTime.utc(2026, 3, 2, 8), lat: 2, lon: 2));
      // lat present, lon missing — not a drawable fix either.
      idHalf = await dao.insert(_p(DateTime.utc(2026, 3, 2, 12), lat: 3));
      idC = await dao.insert(_p(DateTime.utc(2026, 3, 3, 8), lat: 4, lon: 4));
    });

    test('no bounds → every row with BOTH coords, oldest-first', () async {
      final rows = await dao.fixesByDateRange();
      expect(rows.map((p) => p.id), [idA, idB, idC]);
      expect(rows.map((p) => p.id), isNot(contains(idNoFix)));
      expect(rows.map((p) => p.id), isNot(contains(idHalf)));
    });

    test('rows are full Ping objects (detail sheet reads every column)',
        () async {
      final row = (await dao.fixesByDateRange()).first;
      expect(row.id, idA);
      expect(row.source, PingSource.scheduled);
      expect(row.timestampUtc, DateTime.utc(2026, 3, 1, 8));
      // Columns the map itself never draws but the sheet renders.
      expect(row.note, isNull);
      expect(row.comment, isNull);
      expect(row.batteryPct, isNull);
    });

    test('bounds are inclusive on both ends', () async {
      final rows = await dao.fixesByDateRange(
        startUtc: DateTime.utc(2026, 3, 1, 8),
        endUtc: DateTime.utc(2026, 3, 3, 8),
      );
      expect(rows.map((p) => p.id), [idA, idB, idC]);
    });

    test('1 ms outside either bound is excluded', () async {
      final rows = await dao.fixesByDateRange(
        startUtc: DateTime.utc(2026, 3, 1, 8, 0, 0, 1),
        endUtc: DateTime.utc(2026, 3, 3, 7, 59, 59, 999),
      );
      expect(rows.map((p) => p.id), [idB]);
    });

    test('a window containing only no_fix / half rows returns empty',
        () async {
      final rows = await dao.fixesByDateRange(
        startUtc: DateTime.utc(2026, 3, 1, 12),
        endUtc: DateTime.utc(2026, 3, 1, 12),
      );
      expect(rows, isEmpty);
    });

    test('one-sided bounds work', () async {
      final from = await dao.fixesByDateRange(
        startUtc: DateTime.utc(2026, 3, 2),
      );
      expect(from.map((p) => p.id), [idB, idC]);
      final until = await dao.fixesByDateRange(
        endUtc: DateTime.utc(2026, 3, 2, 23, 59),
      );
      expect(until.map((p) => p.id), [idA, idB]);
    });

    test('ordering is ascending even when inserted out of order', () async {
      await dao.insert(_p(DateTime.utc(2026, 2, 1), lat: 9, lon: 9));
      final rows = await dao.fixesByDateRange();
      final ts = rows.map((p) => p.timestampUtc).toList();
      expect(ts, ts.toList()..sort());
      expect(ts.first, DateTime.utc(2026, 2, 1));
    });

    test('empty table → empty list', () async {
      await db.delete('pings');
      expect(await dao.fixesByDateRange(), isEmpty);
    });
  });

  group('PingDao query plans (idx_pings_ts_fix, schema v4)', () {
    Future<String> plan(String sql, [List<Object?>? args]) async {
      final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
      return rows.map((r) => r['detail']).join('\n');
    }

    test('fixesByDateRange walks the partial index, not idx_pings_ts_utc',
        () async {
      final p = await plan(
        'SELECT * FROM pings WHERE ${PingDao.fixPredicate} '
        'AND ts_utc BETWEEN ? AND ? ORDER BY ts_utc ASC',
        [0, 1],
      );
      expect(p, contains('idx_pings_ts_fix'));
      expect(p, isNot(contains('idx_pings_ts_utc')));
    });

    test('latestSuccessful walks the partial index backwards', () async {
      final p = await plan(
        'SELECT * FROM pings WHERE ${PingDao.fixPredicate} '
        "AND source != 'no_fix' ORDER BY ts_utc DESC LIMIT 1",
      );
      expect(p, contains('idx_pings_ts_fix'));
      expect(p, isNot(contains('TEMP B-TREE')));
    });

    test('latestSuccessful ignores a long no_fix streak on top of the last '
        'fix', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 7, lon: 7));
      for (var i = 1; i <= 300; i++) {
        await dao.insert(_p(
          DateTime.utc(2026, 1, 1).add(Duration(hours: i)),
          source: PingSource.noFix,
          note: 'indoors',
        ));
      }
      expect((await dao.latestSuccessful())!.lat, 7);
    });

    test('latestSuccessful with the schema-v5 import exclusion still walks '
        'idx_pings_ts_fix', () async {
      final p = await plan(
        'SELECT * FROM pings WHERE ${PingDao.fixPredicate} '
        "AND source != 'no_fix' AND ${PingDao.notImportedPredicate} "
        'ORDER BY ts_utc DESC LIMIT 1',
      );
      expect(p, contains('idx_pings_ts_fix'));
    });
  });

  group('PingDao.existingFixesInRange (schema v5, import dedupe)', () {
    test('returns (ts, lat, lon) tuples in range, oldest-first', () async {
      await dao.insert(_p(DateTime.utc(2026, 3, 1, 8), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 3, 1, 12))); // no_fix, excluded
      await dao.insert(_p(DateTime.utc(2026, 3, 2, 8), lat: 2, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 3, 5, 8), lat: 3, lon: 3));

      final lo = DateTime.utc(2026, 3, 1).millisecondsSinceEpoch;
      final hi = DateTime.utc(2026, 3, 3).millisecondsSinceEpoch;
      final rows = await dao.existingFixesInRange(lo, hi);
      expect(rows.map((r) => r.lat), [1, 2]);
      expect(rows.map((r) => r.lon), [1, 2]);
      expect(rows[0].tsUtcMs, DateTime.utc(2026, 3, 1, 8).millisecondsSinceEpoch);
    });

    test('bounds are inclusive on both ends', () async {
      final t = DateTime.utc(2026, 3, 1, 8);
      await dao.insert(_p(t, lat: 5, lon: 5));
      final ms = t.millisecondsSinceEpoch;
      expect((await dao.existingFixesInRange(ms, ms)), hasLength(1));
    });

    test('includes previously-imported rows — a re-import must dedupe '
        'against them too', () async {
      await dao.insert(_p(DateTime.utc(2026, 3, 1, 8),
          lat: 1, lon: 1, source: PingSource.imported));
      final lo = DateTime.utc(2026, 3, 1).millisecondsSinceEpoch;
      final hi = DateTime.utc(2026, 3, 2).millisecondsSinceEpoch;
      expect(await dao.existingFixesInRange(lo, hi), hasLength(1));
    });

    test('empty table / no rows in range → empty list', () async {
      final lo = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final hi = DateTime.utc(2026, 1, 2).millisecondsSinceEpoch;
      expect(await dao.existingFixesInRange(lo, hi), isEmpty);
    });
  });

  group('PingDao.insertImportedBatch (schema v5)', () {
    List<Ping> buildRows(int n, {DateTime? start}) => [
          for (var i = 0; i < n; i++)
            Ping(
              timestampUtc:
                  (start ?? DateTime.utc(2026, 1, 1)).add(Duration(minutes: i)),
              lat: 51.0 + i * 0.001,
              lon: -0.1,
              // Deliberately the "wrong" source/importId — insertImportedBatch
              // must stamp its own values regardless of what the caller sets.
              source: PingSource.scheduled,
            ),
        ];

    test('stamps source=import and import_id, returns the inserted count',
        () async {
      final count =
          await dao.insertImportedBatch(buildRows(3), importId: 7);
      expect(count, 3);
      final rows = await dao.allPings(includeImported: true);
      expect(rows, hasLength(3));
      expect(rows.every((p) => p.source == PingSource.imported), isTrue);
      expect(rows.every((p) => p.importId == 7), isTrue);
    });

    test('empty list is a no-op and returns 0', () async {
      expect(await dao.insertImportedBatch(const [], importId: 1), 0);
      expect(await dao.count(), 0);
    });

    test('1200 rows insert as 3 chunks of the 500-row batch size and all '
        'land', () async {
      // 500 + 500 + 200 — ceil(1200 / 500) == 3 chunks, exercising the
      // final partial chunk as well as two full ones.
      expect((1200 / PingDao.importBatchChunkSize).ceil(), 3);
      final rows = buildRows(1200);
      final count = await dao.insertImportedBatch(rows, importId: 3);
      expect(count, 1200);
      expect(await dao.countByImportId(3), 1200);
    });

    test('is atomic per call — a second batch gets its own import_id',
        () async {
      await dao.insertImportedBatch(buildRows(2), importId: 1);
      await dao.insertImportedBatch(
        buildRows(2, start: DateTime.utc(2026, 2, 1)),
        importId: 2,
      );
      expect(await dao.countByImportId(1), 2);
      expect(await dao.countByImportId(2), 2);
    });
  });

  group('PingDao.deleteByImportId / countByImportId (schema v5)', () {
    test('deleteByImportId removes only that import\'s rows', () async {
      await dao.insertImportedBatch(
        [Ping(timestampUtc: DateTime.utc(2026, 1, 1), lat: 1, lon: 1, source: PingSource.scheduled)],
        importId: 1,
      );
      await dao.insertImportedBatch(
        [Ping(timestampUtc: DateTime.utc(2026, 1, 2), lat: 2, lon: 2, source: PingSource.scheduled)],
        importId: 2,
      );
      await dao.insert(_p(DateTime.utc(2026, 1, 3), lat: 3, lon: 3)); // live ping

      final deleted = await dao.deleteByImportId(1);
      expect(deleted, 1);
      expect(await dao.countByImportId(1), 0);
      expect(await dao.countByImportId(2), 1);
      expect(await dao.count(), 2, reason: 'import 2 + the live ping survive');
    });

    test('countByImportId returns 0 for an unknown/empty import', () async {
      expect(await dao.countByImportId(999), 0);
    });

    test('deleteByImportId on an unknown import deletes 0 and does not '
        'throw', () async {
      expect(await dao.deleteByImportId(999), 0);
    });

    test('query plans for import-id lookups use idx_pings_import, not a '
        'full scan', () async {
      final p = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT * FROM pings WHERE import_id = ?',
        [1],
      );
      final detail = p.map((r) => r['detail']).join('\n');
      expect(detail, contains('idx_pings_import'));
    });
  });

  group('PingDao.tsRange (year chips)', () {
    test('empty table → (null, null)', () async {
      final r = await dao.tsRange();
      expect(r.minUtcMs, isNull);
      expect(r.maxUtcMs, isNull);
    });

    test('returns the oldest and newest fix timestamps', () async {
      await dao.insert(_p(DateTime.utc(2024, 3, 4, 5), lat: 51, lon: -0.1));
      await dao.insert(_p(DateTime.utc(2026, 8, 22, 9), lat: 52, lon: -0.2));
      await dao.insert(_p(DateTime.utc(2025, 1, 1), lat: 53, lon: -0.3));
      final r = await dao.tsRange();
      expect(r.minUtcMs, DateTime.utc(2024, 3, 4, 5).millisecondsSinceEpoch);
      expect(r.maxUtcMs, DateTime.utc(2026, 8, 22, 9).millisecondsSinceEpoch);
    });

    test('ignores coordinate-less rows at both ends', () async {
      // no_fix rows bracket the only real fix — neither may set a bound.
      await dao.insert(_p(DateTime.utc(2019, 1, 1), source: PingSource.noFix));
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 51, lon: -0.1));
      await dao.insert(_p(DateTime.utc(2030, 1, 1), source: PingSource.noFix));
      final r = await dao.tsRange();
      expect(r.minUtcMs, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
      expect(r.maxUtcMs, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    });

    test('a table of only no-fix rows still reads as empty', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1), source: PingSource.noFix));
      final r = await dao.tsRange();
      expect(r.minUtcMs, isNull);
      expect(r.maxUtcMs, isNull);
    });

    test('includes imported rows — the chips exist for them', () async {
      await dao.insertImportedBatch(
        [
          Ping(
            timestampUtc: DateTime.utc(2015, 6, 1),
            lat: 51,
            lon: -0.1,
            source: PingSource.scheduled,
          ),
        ],
        importId: 1,
      );
      final r = await dao.tsRange();
      expect(r.minUtcMs, DateTime.utc(2015, 6, 1).millisecondsSinceEpoch);
    });
  });

  group('PingDao.fixesByImportId (per-import map detail)', () {
    Future<void> seedImport(int id, int rows, DateTime start) =>
        dao.insertImportedBatch(
          [
            for (var i = 0; i < rows; i++)
              Ping(
                timestampUtc: start.add(Duration(minutes: i)),
                lat: 51.0 + i * 0.01,
                lon: -0.1,
                source: PingSource.scheduled,
              ),
          ],
          importId: id,
        );

    test('returns only that import\'s fixes, oldest-first', () async {
      await seedImport(1, 3, DateTime.utc(2015, 6, 1));
      await seedImport(2, 2, DateTime.utc(2019, 6, 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 60, lon: 10));

      final rows = await dao.fixesByImportId(1);
      expect(rows, hasLength(3));
      expect(
        rows.first.tsUtcMs,
        DateTime.utc(2015, 6, 1).millisecondsSinceEpoch,
      );
      expect(
        rows.last.tsUtcMs,
        DateTime.utc(2015, 6, 1, 0, 2).millisecondsSinceEpoch,
      );
      expect(rows.map((r) => r.lat), everyElement(lessThan(52)));
      final ts = rows.map((r) => r.tsUtcMs).toList();
      final sorted = [...ts]..sort();
      expect(ts, sorted);
    });

    test('unknown import id → empty', () async {
      await seedImport(1, 2, DateTime.utc(2015, 6, 1));
      expect(await dao.fixesByImportId(999), isEmpty);
    });

    test('drops coordinate-less rows belonging to the import', () async {
      await seedImport(1, 2, DateTime.utc(2015, 6, 1));
      // A no-coord row stamped with the same import_id (a Timeline
      // element that mapped to a time but no place).
      await db.insert('pings', {
        'ts_utc': DateTime.utc(2015, 6, 2).millisecondsSinceEpoch,
        'source': 'import',
        'import_id': 1,
      });
      expect(await dao.countByImportId(1), 3);
      expect(await dao.fixesByImportId(1), hasLength(2));
    });

    test('stride-samples down to at most `limit`, keeping both ends of '
        'the batch', () async {
      await seedImport(1, 10, DateTime.utc(2015, 6, 1));
      final rows = await dao.fixesByImportId(1, limit: 3);
      // ceil(10 / 3) == 4 → indices 0, 4, 8.
      expect(rows, hasLength(3));
      expect(
        rows.first.tsUtcMs,
        DateTime.utc(2015, 6, 1).millisecondsSinceEpoch,
      );
      expect(
        rows.last.tsUtcMs,
        DateTime.utc(2015, 6, 1, 0, 8).millisecondsSinceEpoch,
        reason: 'an even stride must reach the far end of the import, not '
            'stop after the first N rows',
      );
    });

    test('a batch at or under the limit is returned whole', () async {
      await seedImport(1, 4, DateTime.utc(2015, 6, 1));
      expect(await dao.fixesByImportId(1, limit: 4), hasLength(4));
    });

    test('limit <= 0 disables the cap', () async {
      await seedImport(1, 5, DateTime.utc(2015, 6, 1));
      expect(await dao.fixesByImportId(1, limit: 0), hasLength(5));
    });
  });
  group('PingDao.importedVisits (Places screen)', () {
    Future<void> seedVisitPair(
      int importId,
      DateTime start,
      DateTime end, {
      String type = 'UNKNOWN',
      String placeId = '-',
      double lat = 51.5,
      double lon = -0.1,
    }) =>
        dao.insertImportedBatch(
          [
            for (final t in [start, end])
              Ping(
                timestampUtc: t,
                lat: lat,
                lon: lon,
                source: PingSource.imported,
                note: 'gmaps:visit:$type:$placeId',
              ),
          ],
          importId: importId,
        );

    test('returns only imported visit rows, oldest-first', () async {
      // A live ping that happens to carry a visit-shaped note (paranoia:
      // the source check, not the note, is what excludes it).
      await dao.insert(_p(
        DateTime.utc(2026, 1, 1),
        lat: 60,
        lon: 10,
        note: 'gmaps:visit:HOME:fake',
      ));
      // Imported path/activity/raw rows — same import, wrong note.
      await dao.insertImportedBatch(
        [
          _p(DateTime.utc(2015, 6, 1), lat: 51.0, lon: -0.2,
              note: 'gmaps:path'),
          _p(DateTime.utc(2015, 6, 1, 1),
              lat: 51.0, lon: -0.2, note: 'gmaps:activity:WALKING:1200m'),
          _p(DateTime.utc(2015, 6, 1, 2),
              lat: 51.0, lon: -0.2, note: 'gmaps:raw:GPS'),
        ],
        importId: 1,
      );
      // Two visits, seeded newest-first to prove the ORDER BY.
      await seedVisitPair(
        1,
        DateTime.utc(2019, 6, 2, 9),
        DateTime.utc(2019, 6, 2, 10),
        type: 'WORK',
        placeId: 'p2',
      );
      await seedVisitPair(
        1,
        DateTime.utc(2015, 6, 3, 9),
        DateTime.utc(2015, 6, 3, 11),
        type: 'HOME',
        placeId: 'p1',
      );

      final rows = await dao.importedVisits();
      expect(rows, hasLength(4));
      expect(
        rows.map((r) => r.note).toList(),
        [
          'gmaps:visit:HOME:p1',
          'gmaps:visit:HOME:p1',
          'gmaps:visit:WORK:p2',
          'gmaps:visit:WORK:p2',
        ],
      );
      final ts = rows.map((r) => r.tsUtcMs).toList();
      expect(ts, [...ts]..sort());
      expect(rows.first.lat, 51.5);
      expect(rows.first.lon, -0.1);
    });

    test('a coordinate-less visit row is dropped', () async {
      await seedVisitPair(
        1,
        DateTime.utc(2015, 6, 3, 9),
        DateTime.utc(2015, 6, 3, 11),
        placeId: 'p1',
      );
      await db.insert('pings', {
        'ts_utc': DateTime.utc(2015, 6, 4).millisecondsSinceEpoch,
        'source': 'import',
        'import_id': 1,
        'note': 'gmaps:visit:HOME:p1',
      });
      expect(await dao.countByImportId(1), 3);
      expect(await dao.importedVisits(), hasLength(2));
    });

    test('no imports → empty', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 60, lon: 10));
      expect(await dao.importedVisits(), isEmpty);
    });

    test('feeds buildPlaces end to end', () async {
      await seedVisitPair(
        1,
        DateTime.utc(2015, 6, 3, 9),
        DateTime.utc(2015, 6, 3, 11),
        type: 'HOME',
        placeId: 'p1',
      );
      await seedVisitPair(
        1,
        DateTime.utc(2016, 6, 3, 9),
        DateTime.utc(2016, 6, 3, 10),
        type: 'HOME',
        placeId: 'p1',
      );
      final places = buildPlaces(await dao.importedVisits());
      expect(places, hasLength(1));
      expect(places.single.key, 'pid:p1');
      expect(places.single.semanticType, 'Home');
      expect(places.single.visitCount, 2);
      expect(places.single.totalDuration, const Duration(hours: 3));
    });
  });

  group('PingDao.pageByRange (History paging, 0.16.2)', () {
    // Plain epoch-ms bounds: the local-year → UTC conversion is the
    // provider's job (`historyYearUtcBoundsMs`), so the DAO test picks
    // UTC instants and stays timezone-independent.
    final start2024 = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch;
    final start2025 = DateTime.utc(2025, 1, 1).millisecondsSinceEpoch;

    Future<void> seed(List<DateTime> stamps) async {
      for (final t in stamps) {
        await dao.insert(_p(t, lat: 51, lon: -0.1));
      }
    }

    test('start bound inclusive, end bound exclusive', () async {
      await seed([
        DateTime.utc(2023, 12, 31, 23, 59, 59, 999), // just before
        DateTime.utc(2024, 1, 1), // exactly the start
        DateTime.utc(2024, 12, 31, 23, 59, 59, 999), // last ms of the year
        DateTime.utc(2025, 1, 1), // exactly the end
      ]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
      );
      expect(rows.map((p) => p.timestampUtc).toList(), [
        DateTime.utc(2024, 12, 31, 23, 59, 59, 999),
        DateTime.utc(2024, 1, 1),
      ]);
    });

    test('newest first', () async {
      await seed([
        DateTime.utc(2024, 3, 1),
        DateTime.utc(2024, 9, 1),
        DateTime.utc(2024, 6, 1),
      ]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
      );
      expect(rows.map((p) => p.timestampUtc.month).toList(), [9, 6, 3]);
    });

    test('limit caps the page at the newest rows', () async {
      await seed([
        for (var d = 1; d <= 5; d++) DateTime.utc(2024, 1, d),
      ]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 2,
      );
      expect(rows.map((p) => p.timestampUtc.day).toList(), [5, 4]);
    });

    test('keyset: beforeTsUtcMs walks the whole year with no duplicates '
        'and no gaps', () async {
      await seed([
        for (var d = 1; d <= 5; d++) DateTime.utc(2024, 1, d),
      ]);
      final seen = <DateTime>[];
      int? before;
      while (true) {
        final page = await dao.pageByRange(
          startUtcMs: start2024,
          endUtcMs: start2025,
          limit: 2,
          beforeTsUtcMs: before,
        );
        if (page.isEmpty) break;
        seen.addAll(page.map((p) => p.timestampUtc));
        before = page.last.timestampUtc.millisecondsSinceEpoch;
      }
      expect(seen.map((t) => t.day).toList(), [5, 4, 3, 2, 1]);
      expect(seen.toSet(), hasLength(5)); // no row served twice
    });

    test('beforeTsUtcMs is strict — the seek row is not repeated',
        () async {
      await seed([
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 1, 2),
      ]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
        beforeTsUtcMs: DateTime.utc(2024, 1, 2).millisecondsSinceEpoch,
      );
      expect(rows.map((p) => p.timestampUtc).toList(),
          [DateTime.utc(2024, 1, 1)]);
    });

    test('paging past the oldest row returns an empty page', () async {
      await seed([DateTime.utc(2024, 1, 1)]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
        beforeTsUtcMs: DateTime.utc(2024, 1, 1).millisecondsSinceEpoch,
      );
      expect(rows, isEmpty);
    });

    test('a year with no pings is empty', () async {
      await seed([DateTime.utc(2026, 5, 1)]);
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
      );
      expect(rows, isEmpty);
    });

    test('coordinate-less rows are kept — History shows the gaps',
        () async {
      await dao.insert(
          _p(DateTime.utc(2024, 2, 2), source: PingSource.noFix));
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
      );
      expect(rows, hasLength(1));
      expect(rows.single.source, PingSource.noFix);
    });

    test('imports are INCLUDED by default (gotcha 34: History is their '
        'one list)', () async {
      await seed([DateTime.utc(2024, 4, 1)]);
      await dao.insertImportedBatch(
        [
          Ping(
            timestampUtc: DateTime.utc(2024, 5, 1),
            lat: 51,
            lon: -0.1,
            source: PingSource.scheduled,
          ),
        ],
        importId: 1,
      );
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
      );
      expect(rows.map((p) => p.source).toList(),
          [PingSource.imported, PingSource.scheduled]);
    });

    test('includeImported: false drops them', () async {
      await seed([DateTime.utc(2024, 4, 1)]);
      await dao.insertImportedBatch(
        [
          Ping(
            timestampUtc: DateTime.utc(2024, 5, 1),
            lat: 51,
            lon: -0.1,
            source: PingSource.scheduled,
          ),
        ],
        importId: 1,
      );
      final rows = await dao.pageByRange(
        startUtcMs: start2024,
        endUtcMs: start2025,
        limit: 100,
        includeImported: false,
      );
      expect(rows, hasLength(1));
      expect(rows.single.source, PingSource.scheduled);
    });
  });
}
