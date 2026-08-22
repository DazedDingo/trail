import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/database.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';

/// Schema-migration coverage for [TrailDatabase]. Runs the PRODUCTION
/// `_onCreate` / `_onUpgrade` DDL (via the `@visibleForTesting` hooks)
/// against an in-memory `sqflite_common_ffi` handle, so unlike the DAO
/// tests nothing here is hand-mirrored.
///
/// Same libsqlite3 loader workaround as `ping_dao_test.dart` — must be a
/// top-level function (CLAUDE.md gotcha 8).
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

Future<Database> _openEmpty() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  return databaseFactory.openDatabase(inMemoryDatabasePath);
}

const _pingsV1Columns = '''
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
      note TEXT''';

/// What a 0.11.x-and-earlier install has on disk: schema v1.
Future<void> _createV1(Database db) async {
  await db.execute('CREATE TABLE pings ($_pingsV1Columns);');
  await db.execute('CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);');
  await db.execute('''
    CREATE TABLE emergency_contacts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      phone_e164 TEXT NOT NULL
    );
  ''');
}

/// What a 0.13.x install has on disk: schema v3 (v1 + `comment` +
/// `ping_photos` + `area_photos`).
Future<void> _createV3(Database db) async {
  await db.execute('CREATE TABLE pings ($_pingsV1Columns,\n      comment TEXT);');
  await db.execute('CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);');
  await db.execute('''
    CREATE TABLE emergency_contacts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      phone_e164 TEXT NOT NULL
    );
  ''');
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
}

Future<List<String>> _names(Database db, String type) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%'",
    [type],
  );
  return rows.map((r) => r['name'] as String).toList();
}

Future<String?> _indexSql(Database db, String name) async {
  final rows = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
    [name],
  );
  return rows.isEmpty ? null : rows.first['sql'] as String?;
}

Future<List<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toList();
}

/// `EXPLAIN QUERY PLAN` rows joined into one string for `contains`.
Future<String> _plan(Database db, String sql, [List<Object?>? args]) async {
  final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
  return rows.map((r) => r['detail']).join('\n');
}

/// The exact statement `PingDao.fixesByDateRange(start, end)` issues.
const _fixesRangeSql = 'SELECT * FROM pings WHERE ${PingDao.fixPredicate} '
    'AND ts_utc BETWEEN ? AND ? ORDER BY ts_utc ASC';

/// `PingDao.fixesByDateRange()` — no bounds.
const _fixesAllSql =
    'SELECT * FROM pings WHERE ${PingDao.fixPredicate} ORDER BY ts_utc ASC';

/// `PingDao.latestSuccessful()`.
const _latestSuccessfulSql = 'SELECT * FROM pings WHERE ${PingDao.fixPredicate} '
    "AND source != 'no_fix' ORDER BY ts_utc DESC LIMIT 1";

Ping _p(DateTime t, {double? lat, double? lon, PingSource? source}) => Ping(
      timestampUtc: t,
      lat: lat,
      lon: lon,
      source: source ?? (lat == null ? PingSource.noFix : PingSource.scheduled),
    );

void main() {
  late Database db;

  setUp(() async {
    db = await _openEmpty();
  });

  tearDown(() async {
    await db.close();
  });

  test('schema version is 4', () {
    expect(TrailDatabase.schemaVersionForTest, 4);
  });

  group('fresh install (onCreate)', () {
    test('creates every table and the v4 partial index', () async {
      await TrailDatabase.createSchemaForTest(db);
      expect(
        await _names(db, 'table'),
        containsAll(['pings', 'emergency_contacts', 'ping_photos', 'area_photos']),
      );
      expect(
        await _names(db, 'index'),
        containsAll([
          'idx_pings_ts_utc',
          'idx_pings_ts_fix',
          'idx_ping_photos_ping_id',
          'idx_area_photos_cell',
        ]),
      );
      final sql = await _indexSql(db, 'idx_pings_ts_fix');
      expect(sql, contains('ON pings(ts_utc, lat, lon)'));
      expect(sql, contains('WHERE lat IS NOT NULL AND lon IS NOT NULL'));
    });

    test('the index WHERE text equals PingDao.fixPredicate (implication is '
        'syntactic)', () async {
      await TrailDatabase.createSchemaForTest(db);
      final sql = await _indexSql(db, 'idx_pings_ts_fix');
      expect(sql, contains('WHERE ${PingDao.fixPredicate}'));
    });
  });

  group('v3 → v4', () {
    setUp(() async {
      await _createV3(db);
      final dao = PingDao(db);
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 8), lat: 51.5, lon: -0.1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12))); // no_fix
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 16), lat: 51.6, lon: -0.2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 20))); // no_fix
      await dao.insert(_p(DateTime.utc(2026, 1, 2, 8), lat: 51.7, lon: -0.3));
    });

    test('adds idx_pings_ts_fix and keeps every row', () async {
      expect(await _names(db, 'index'), isNot(contains('idx_pings_ts_fix')));
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      expect(await _names(db, 'index'), contains('idx_pings_ts_fix'));
      expect(
        await _indexSql(db, 'idx_pings_ts_fix'),
        contains('WHERE lat IS NOT NULL AND lon IS NOT NULL'),
      );
      // Index-only migration: nothing about the data moves.
      expect(await PingDao(db).count(), 5);
      expect(await _columns(db, 'pings'), contains('comment'));
      expect(await _names(db, 'table'), containsAll(['ping_photos', 'area_photos']));
    });

    test('runs ANALYZE so the planner has stats for the new index', () async {
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      final stats = await db.rawQuery(
        "SELECT idx, stat FROM sqlite_stat1 WHERE tbl = 'pings'",
      );
      final byIdx = {for (final r in stats) r['idx'] as String: r['stat']};
      expect(byIdx.keys, contains('idx_pings_ts_fix'));
      // 3 fix rows out of 5 — the partial index only holds the fixes.
      expect(byIdx['idx_pings_ts_fix'], startsWith('3 '));
      expect(byIdx['idx_pings_ts_utc'], startsWith('5 '));
    });

    test('query plans for the fixes-only reads use idx_pings_ts_fix',
        () async {
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      final lo = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final hi = DateTime.utc(2026, 1, 3).millisecondsSinceEpoch;
      expect(await _plan(db, _fixesRangeSql, [lo, hi]), contains('idx_pings_ts_fix'));
      expect(await _plan(db, _fixesAllSql), contains('idx_pings_ts_fix'));
      expect(await _plan(db, _latestSuccessfulSql), contains('idx_pings_ts_fix'));
      // The unfiltered recent() read must NOT have been stolen by the
      // partial index — it needs the no_fix rows.
      expect(
        await _plan(db, 'SELECT * FROM pings ORDER BY ts_utc DESC LIMIT 200'),
        contains('idx_pings_ts_utc'),
      );
    });

    test('fixesByDateRange + latestSuccessful return the right rows after '
        'the upgrade', () async {
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      final dao = PingDao(db);
      final fixes = await dao.fixesByDateRange();
      expect(fixes.map((p) => p.lat), [51.5, 51.6, 51.7]);
      expect((await dao.latestSuccessful())!.lat, 51.7);
    });

    test('is idempotent — re-running the step is a no-op (IF NOT EXISTS)',
        () async {
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      await TrailDatabase.upgradeSchemaForTest(db, from: 3);
      final dupes = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE name = 'idx_pings_ts_fix'",
      );
      expect(dupes.first['c'], 1);
    });
  });

  group('v1 → v4 (full chain)', () {
    test('lands on the same shape as a fresh install', () async {
      await _createV1(db);
      await db.insert('pings', {
        'ts_utc': DateTime.utc(2025, 6, 1).millisecondsSinceEpoch,
        'lat': 1.0,
        'lon': 2.0,
        'source': 'scheduled',
      });
      await TrailDatabase.upgradeSchemaForTest(db, from: 1);

      final fresh = await _openEmpty();
      try {
        await TrailDatabase.createSchemaForTest(fresh);
        expect((await _names(db, 'table'))..sort(),
            (await _names(fresh, 'table'))..sort());
        expect((await _names(db, 'index'))..sort(),
            (await _names(fresh, 'index'))..sort());
        expect(await _columns(db, 'pings'), await _columns(fresh, 'pings'));
      } finally {
        await fresh.close();
      }
      // Legacy row survived with a NULL comment and is a fix.
      final row = (await PingDao(db).fixesByDateRange()).single;
      expect(row.lat, 1.0);
      expect(row.comment, isNull);
    });
  });
}
