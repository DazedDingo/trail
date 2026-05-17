import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/archive/archive_service.dart';

/// See [ping_dao_test] for the rationale. Must match exactly — the ffi
/// isolate resolves the override from THIS top-level function.
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
          // try next
        }
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
}

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
  return db;
}

Ping _p(DateTime t, {double? lat, double? lon}) => Ping(
      timestampUtc: t,
      lat: lat,
      lon: lon,
      source: PingSource.scheduled,
    );

void main() {
  late Database db;
  late PingDao dao;
  late Directory tmp;

  setUp(() async {
    db = await _openMemDb();
    dao = PingDao(db);
    tmp = await Directory.systemTemp.createTemp('trail_archive_test_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('archiveWithHandle — export ordering (safety: export BEFORE delete)',
      () {
    test('writes the export files and then deletes the matching rows',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 1, lon: 2));
      await dao.insert(_p(DateTime.utc(2026, 1, 20), lat: 3, lon: 4));
      await dao.insert(_p(DateTime.utc(2026, 3, 1), lat: 5, lon: 6));

      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
      );
      expect(res.deletedCount, 2);
      expect(res.exportedFiles, hasLength(2));
      for (final path in res.exportedFiles) {
        expect(File(path).existsSync(), isTrue,
            reason: 'archive export must exist on disk');
      }
      expect(await dao.count(), 1,
          reason: 'only the post-cutoff row should remain');
    });

    test('throws StateError when nothing to archive — DB untouched', () async {
      await dao.insert(_p(DateTime.utc(2026, 3, 1), lat: 5, lon: 6));
      expect(
        () => archiveWithHandle(
          dao: dao,
          cutoffUtc: DateTime.utc(2026, 2, 1),
          writeDir: tmp,
        ),
        throwsStateError,
      );
      expect(await dao.count(), 1);
      expect(tmp.listSync(), isEmpty,
          reason: 'no files should have been written when nothing to archive');
    });

    test('gpxAndCsv format produces one .gpx AND one .csv', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 1, lon: 2));
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
        format: ArchiveFormat.gpxAndCsv,
      );
      final exts = res.exportedFiles.map(p.extension).toSet();
      expect(exts, {'.gpx', '.csv'});
    });

    test('gpxOnly produces exactly one .gpx file', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 1, lon: 2));
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
        format: ArchiveFormat.gpxOnly,
      );
      expect(res.exportedFiles, hasLength(1));
      expect(p.extension(res.exportedFiles.single), '.gpx');
    });

    test('csvOnly produces exactly one .csv file', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 1, lon: 2));
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
        format: ArchiveFormat.csvOnly,
      );
      expect(res.exportedFiles, hasLength(1));
      expect(p.extension(res.exportedFiles.single), '.csv');
    });

    test('exported filename encodes cutoff YYYYMMDD', () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 1, lon: 2));
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 3, 15),
        writeDir: tmp,
        format: ArchiveFormat.gpxOnly,
      );
      expect(p.basename(res.exportedFiles.single),
          'trail_archive_before_20260315.gpx');
    });

    test('rows exactly at the cutoff survive (strict <)', () async {
      final cutoff = DateTime.utc(2026, 2, 1);
      await dao.insert(_p(cutoff.subtract(const Duration(seconds: 1)),
          lat: 1, lon: 2));
      await dao.insert(_p(cutoff, lat: 9, lon: 9));
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: cutoff,
        writeDir: tmp,
      );
      expect(res.deletedCount, 1);
      final remaining = await dao.all();
      expect(remaining, hasLength(1));
      expect(remaining.single.lat, 9);
    });
  });
}
