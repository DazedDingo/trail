import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';

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
      comment TEXT
    );
  ''');
  await db.execute('CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);');
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
  });

  group('PingDao.all', () {
    test('returns rows in ASCENDING order (opposite of recent())', () async {
      // This asymmetry matters for exports — GPX readers expect
      // chronological order, not reverse. A regression that swapped this
      // would invert every exported track.
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 12), lat: 1, lon: 1));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 10), lat: 2, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 1, 11), lat: 3, lon: 3));
      final rows = await dao.all();
      expect(rows.map((r) => r.timestampUtc).toList(), [
        DateTime.utc(2026, 1, 1, 10),
        DateTime.utc(2026, 1, 1, 11),
        DateTime.utc(2026, 1, 1, 12),
      ]);
    });

    test('returns EVERY row — no implicit limit on all()', () async {
      for (var i = 0; i < 300; i++) {
        await dao.insert(_p(
          DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          lat: 1,
          lon: 2,
        ));
      }
      expect((await dao.all()).length, 300);
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
      final rows = await dao.all();
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
}
