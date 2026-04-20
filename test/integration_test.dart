import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/screens/export_dialog.dart';
import 'package:trail/services/archive/archive_service.dart';
import 'package:trail/services/export/csv_exporter.dart';
import 'package:trail/services/export/gpx_exporter.dart';
import 'package:trail/services/home_location_service.dart';
import 'package:trail/services/scheduler/worker_run_log.dart';

/// Phase-6 integration test pass.
///
/// Everything in this file exercises **multiple** shipped features
/// stitched together, rather than a single service in isolation. The
/// per-service unit tests already cover the edges of each module; this
/// file makes sure the wiring between them holds up.

/// Must match the top-level function in `ping_dao_test.dart` /
/// `archive_service_test.dart` — see CLAUDE.md gotcha #8.
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
      note TEXT
    );
  ''');
  await db.execute('CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);');
  return db;
}

Ping _p(DateTime t, {double? lat, double? lon, PingSource? source}) => Ping(
      timestampUtc: t,
      lat: lat,
      lon: lon,
      source: source ?? PingSource.scheduled,
    );

void main() {
  late Database db;
  late PingDao dao;
  late Directory tmp;

  setUp(() async {
    db = await _openMemDb();
    dao = PingDao(db);
    tmp = await Directory.systemTemp.createTemp('trail_integ_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  // 1. Archive → DAO → GPX/CSV exporter integration.
  //    After an archive run, the exported files must contain exactly the
  //    archived rows (and only those); the DB must contain only the
  //    survivors. This catches any off-by-one between `olderThan`,
  //    exporter input, and `deleteOlderThan`.
  // -------------------------------------------------------------------------
  group('archive → export → DB-survivors ordering', () {
    test('archived GPX contains exactly the pre-cutoff rows', () async {
      await dao.insert(_p(DateTime.utc(2025, 12, 1), lat: 1.0, lon: 1.0));
      await dao.insert(_p(DateTime.utc(2026, 1, 15), lat: 2.0, lon: 2.0));
      await dao.insert(_p(DateTime.utc(2026, 2, 10), lat: 3.0, lon: 3.0));
      await dao.insert(_p(DateTime.utc(2026, 3, 20), lat: 4.0, lon: 4.0));

      final cutoff = DateTime.utc(2026, 2, 1);
      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: cutoff,
        writeDir: tmp,
        format: ArchiveFormat.gpxAndCsv,
      );

      expect(res.deletedCount, 2);
      final gpxPath = res.exportedFiles.firstWhere((f) => f.endsWith('.gpx'));
      final gpxBody = File(gpxPath).readAsStringSync();
      // The two pre-cutoff pings' coords should appear.
      expect(gpxBody, contains('lat="1.0" lon="1.0"'));
      expect(gpxBody, contains('lat="2.0" lon="2.0"'));
      // The two survivors must NOT leak into the archive file.
      expect(gpxBody, isNot(contains('lat="3.0"')));
      expect(gpxBody, isNot(contains('lat="4.0"')));

      // DB now has only the post-cutoff rows.
      final remaining = await dao.all();
      expect(remaining.map((p) => p.lat).toList(), [3.0, 4.0]);
    });

    test('archived CSV body is consistent with the archive row set',
        () async {
      await dao.insert(_p(DateTime.utc(2026, 1, 5), lat: 10.0, lon: 10.0));
      await dao.insert(_p(DateTime.utc(2026, 1, 10), lat: 20.0, lon: 20.0));
      await dao.insert(_p(DateTime.utc(2026, 4, 5), lat: 30.0, lon: 30.0));

      final res = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
        format: ArchiveFormat.csvOnly,
      );
      final csvBody = File(res.exportedFiles.single).readAsStringSync();
      final lines = const LineSplitter().convert(csvBody);
      // Header + 2 data rows.
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('timestamp_utc,'));
      expect(lines[1], contains('10.0,10.0'));
      expect(lines[2], contains('20.0,20.0'));
    });

    test('subsequent date-range export of survivors is disjoint from archive',
        () async {
      // This is the realistic user journey: archive old pings, then
      // export a recent range. The two outputs must never overlap.
      await dao.insert(_p(DateTime.utc(2026, 1, 1), lat: 1.0, lon: 1.0));
      await dao.insert(_p(DateTime.utc(2026, 1, 15), lat: 2.0, lon: 2.0));
      await dao.insert(_p(DateTime.utc(2026, 3, 10), lat: 3.0, lon: 3.0));
      await dao.insert(_p(DateTime.utc(2026, 4, 20), lat: 4.0, lon: 4.0));

      final archive = await archiveWithHandle(
        dao: dao,
        cutoffUtc: DateTime.utc(2026, 2, 1),
        writeDir: tmp,
        format: ArchiveFormat.gpxOnly,
      );
      final archivedGpx =
          File(archive.exportedFiles.single).readAsStringSync();

      final survivors = await dao.all();
      final range = DateTimeRange(
        start: DateTime.utc(2026, 3, 1),
        end: DateTime.utc(2026, 4, 20),
      );
      final ranged = filterPingsByRange(survivors, range);
      final rangedGpx = GpxExporter().build(ranged, now: DateTime.utc(2026, 5));

      // Archived set never appears in the subsequent ranged export.
      expect(rangedGpx, isNot(contains('lat="1.0"')));
      expect(rangedGpx, isNot(contains('lat="2.0"')));
      // Archive never contains what stayed behind.
      expect(archivedGpx, isNot(contains('lat="3.0"')));
      expect(archivedGpx, isNot(contains('lat="4.0"')));
    });
  });

  // -------------------------------------------------------------------------
  // 2. Date-range filter + exporter integration.
  //    `filterPingsByRange` is the gate the export dialog uses before
  //    handing rows to the exporter. This verifies the filter's
  //    boundary behaviour survives the full round-trip through the
  //    exporter output.
  // -------------------------------------------------------------------------
  group('date-range filter → exporter output', () {
    test('GPX body only contains pings inside the picked range', () async {
      final rows = <Ping>[
        _p(DateTime(2026, 4, 18, 10).toUtc(), lat: 1.0, lon: 1.0),
        _p(DateTime(2026, 4, 19, 10).toUtc(), lat: 2.0, lon: 2.0),
        _p(DateTime(2026, 4, 20, 10).toUtc(), lat: 3.0, lon: 3.0),
        _p(DateTime(2026, 4, 21, 10).toUtc(), lat: 4.0, lon: 4.0),
      ];
      final range = DateTimeRange(
        start: DateTime(2026, 4, 19),
        end: DateTime(2026, 4, 20),
      );
      final filtered = filterPingsByRange(rows, range);
      final gpx = GpxExporter().build(filtered, now: DateTime.utc(2026, 5));
      expect(gpx, isNot(contains('lat="1.0"')));
      expect(gpx, contains('lat="2.0" lon="2.0"'));
      expect(gpx, contains('lat="3.0" lon="3.0"'));
      expect(gpx, isNot(contains('lat="4.0"')));
    });

    test(
      'CSV body row-count equals filter output length (no drops/dupes)',
      () async {
        // Dense pings every 30 min across 3 days.
        final rows = <Ping>[
          for (var i = 0; i < 144; i++)
            _p(
              DateTime.utc(2026, 4, 18).add(Duration(minutes: 30 * i)),
              lat: 51.5 + i * 0.0001,
              lon: -0.1,
            ),
        ];
        final range = DateTimeRange(
          start: DateTime(2026, 4, 19),
          end: DateTime(2026, 4, 19),
        );
        final filtered = filterPingsByRange(rows, range);
        final csv = CsvExporter().build(filtered);
        final lines = const LineSplitter().convert(csv);
        // header + 1-per-filtered-row.
        expect(lines.length - 1, filtered.length);
      },
    );

    test('null range (All history) matches "export everything" path',
        () async {
      final rows = <Ping>[
        _p(DateTime.utc(2020, 1, 1), lat: 1, lon: 1),
        _p(DateTime.utc(2026, 4, 20), lat: 2, lon: 2),
      ];
      final allPath = filterPingsByRange(rows, null);
      final allCsv = CsvExporter().build(allPath);
      final directCsv = CsvExporter().build(rows);
      expect(allCsv, directCsv);
    });
  });

  // -------------------------------------------------------------------------
  // 3. Home location + ping trail distance.
  //    The home-screen "X km from home" subtitle uses
  //    HomeLocation.distanceMetersTo on the latest successful ping.
  //    This tests the full chain: persist home, read it back, compute
  //    distances across a simulated walk.
  // -------------------------------------------------------------------------
  group('home location + ping-trail distance', () {
    test('distance grows monotonically on a straight-line outbound walk',
        () async {
      // Home at Trafalgar Square. Ping trail heading NE along a line.
      await HomeLocationService.set(
        lat: 51.5080,
        lon: -0.1281,
        label: 'Trafalgar',
      );
      final home = (await HomeLocationService.get())!;
      final trail = <({double lat, double lon})>[
        (lat: 51.5090, lon: -0.1270),
        (lat: 51.5100, lon: -0.1260),
        (lat: 51.5110, lon: -0.1250),
        (lat: 51.5120, lon: -0.1240),
        (lat: 51.5130, lon: -0.1230),
      ];
      final distances = trail
          .map((p) => home.distanceMetersTo(p.lat, p.lon))
          .toList();
      for (var i = 1; i < distances.length; i++) {
        expect(distances[i], greaterThan(distances[i - 1]),
            reason: 'step $i must be farther from home than step ${i - 1}');
      }
    });

    test('0 distance to a ping exactly at home', () async {
      await HomeLocationService.set(
        lat: 40.7128,
        lon: -74.0060,
        label: 'NYC',
      );
      final home = (await HomeLocationService.get())!;
      expect(home.distanceMetersTo(40.7128, -74.0060), closeTo(0, 0.01));
    });

    test('clear then set replaces everything cleanly', () async {
      await HomeLocationService.set(lat: 1, lon: 2, label: 'First');
      await HomeLocationService.clear();
      await HomeLocationService.set(lat: 3, lon: 4);
      final h = (await HomeLocationService.get())!;
      expect(h.lat, 3);
      expect(h.lon, 4);
      expect(h.label, isNull,
          reason: 'post-clear set without label must not inherit the old one');
    });
  });

  // -------------------------------------------------------------------------
  // 4. Worker-run log cross-isolate simulation.
  //    In production the WorkManager isolate writes and the UI isolate
  //    reads, but both use the same SharedPreferences key. This
  //    simulates the diagnostics-screen read path against a
  //    mixed-outcome write pattern.
  // -------------------------------------------------------------------------
  group('worker run log — mixed-outcome rolling history', () {
    test('25 mixed writes → 20 newest visible, oldest 5 dropped', () async {
      const outcomes = ['ok', 'no_fix', 'low_battery_skip', 'error',
          'awaiting_passphrase'];
      for (var i = 0; i < 25; i++) {
        await WorkerRunLog.record(
          task: 'trail_scheduled_ping',
          outcome: outcomes[i % outcomes.length],
          note: 'run $i',
        );
      }
      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(20));
      expect(runs.first.note, 'run 24',
          reason: 'newest first');
      expect(runs.last.note, 'run 5',
          reason: 'oldest surviving = index 5 (runs 0-4 evicted)');
      // All 5 outcome kinds should still be represented in the
      // visible window (25 mod 5 keeps distribution even).
      expect(
        runs.map((r) => r.outcome).toSet(),
        outcomes.toSet(),
      );
    });

    test('timestamps are monotonically non-decreasing within the stored set',
        () async {
      for (var i = 0; i < 10; i++) {
        await WorkerRunLog.record(
          task: 't',
          outcome: 'ok',
          note: 'run $i',
        );
      }
      final runs = await WorkerRunLog.recent();
      // recent() is newest-first, so timestamps should descend (or be
      // equal within the same millisecond if two writes land fast).
      for (var i = 1; i < runs.length; i++) {
        expect(
          runs[i].timestamp.isAfter(runs[i - 1].timestamp),
          isFalse,
          reason: 'newest-first ordering should not reverse',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // 5. DB integrity-check on a DAO-populated database.
  //    This is the closest we can get to testing
  //    `TrailDatabase.integrityCheck` without SQLCipher — we run the
  //    same PRAGMA on a plain ffi DB with the production schema and
  //    some inserted rows, and confirm the pragma returns the
  //    expected healthy-DB signal.
  // -------------------------------------------------------------------------
  group('PRAGMA integrity_check on DAO-populated DB', () {
    test('healthy DB returns a single "ok" row', () async {
      for (var i = 0; i < 10; i++) {
        await dao.insert(_p(
          DateTime.utc(2026, 1, 1).add(Duration(hours: 4 * i)),
          lat: 51.5 + i * 0.001,
          lon: -0.1 + i * 0.001,
        ));
      }
      final result = await db.rawQuery('PRAGMA integrity_check');
      expect(result, hasLength(1));
      expect(result.single.values.first, 'ok');
    });
  });
}

/// Minimal replacement for `dart:convert`'s LineSplitter without
/// pulling the full convert import into the test's public scope.
class LineSplitter {
  const LineSplitter();
  List<String> convert(String body) =>
      body.split('\n').where((l) => l.isNotEmpty).toList();
}
