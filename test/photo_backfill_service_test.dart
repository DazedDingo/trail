import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:trail/db/database.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/db/ping_photo_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/models/ping_photo.dart';
import 'package:trail/services/online_photo_service.dart';
import 'package:trail/services/photo_backfill_service.dart';

Ping _p({
  required int id,
  double? lat = 51.5,
  double? lon = -0.1,
  PingSource source = PingSource.scheduled,
}) =>
    Ping(
      id: id,
      timestampUtc: DateTime.utc(2026, 5, 17),
      lat: lat,
      lon: lon,
      source: source,
    );

/// Top-level libsqlite3 loader workaround (CLAUDE.md gotcha 8) — same
/// copy as `ping_dao_test.dart`; must be top-level to survive the
/// `Isolate.spawn` inside `sqflite_common_ffi`.
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

/// Production DDL on an ffi handle (gotcha 28's preferred pattern).
Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await TrailDatabase.createSchemaForTest(db);
  return db;
}

/// Stands in for Wikimedia: records every coordinate it was asked
/// about — which is the whole point of the import tests, since a
/// leaked imported coordinate is the bug (gotcha 21) — and always
/// returns one photo so the walk has something to attach.
class _RecordingPhotoService extends OnlinePhotoService {
  final List<({double lat, double lon})> asked = [];

  @override
  Future<List<FetchedOnlinePhoto>> fetchNearby({
    required double lat,
    required double lon,
    int radiusMeters = 500,
    int limit = 5,
  }) async {
    asked.add((lat: lat, lon: lon));
    return [
      FetchedOnlinePhoto(
        uri: 'https://example.invalid/$lat,$lon.jpg',
        attribution: 'Someone',
        license: 'CC BY-SA 4.0',
        distanceMeters: 12,
      ),
    ];
  }
}

/// A persistable ping (no id — SQLite assigns it).
Ping _row(double lat, double lon, {int minute = 0}) => Ping(
      timestampUtc: DateTime.utc(2026, 5, 17, 9, minute),
      lat: lat,
      lon: lon,
      source: PingSource.scheduled,
    );

void main() {
  group('selectEligibleForBackfill', () {
    test('returns pings with coords + no wikimedia row', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1), _p(id: 2)],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [1, 2]);
    });

    test('skips pings that already have wikimedia photos', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1), _p(id: 2), _p(id: 3)],
        const {2},
      );
      expect(out.map((p) => p.id).toList(), [1, 3]);
    });

    test('skips no_fix rows even when no wikimedia row exists', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1, source: PingSource.noFix)],
        const <int>{},
      );
      expect(out, isEmpty);
    });

    test('skips imported rows even with real coords and no wikimedia row '
        '(CLAUDE.md gotcha 21 — imported coordinates must never reach '
        'Wikimedia)', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1, source: PingSource.imported)],
        const <int>{},
      );
      expect(out, isEmpty);
    });

    test('imported rows are excluded even among otherwise-eligible pings',
        () {
      final out = selectEligibleForBackfill(
        [
          _p(id: 1),
          _p(id: 2, source: PingSource.imported),
          _p(id: 3),
        ],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [1, 3]);
    });

    test('skips rows with null lat or lon', () {
      final out = selectEligibleForBackfill(
        [
          _p(id: 1, lat: null),
          _p(id: 2, lon: null),
          _p(id: 3),
        ],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [3]);
    });

    test('skips rows with null id (defensive against pre-persist state)',
        () {
      final out = selectEligibleForBackfill(
        [
          Ping(
            timestampUtc: DateTime.utc(2026, 5, 17),
            lat: 1,
            lon: 2,
            source: PingSource.scheduled,
          ),
        ],
        const <int>{},
      );
      expect(out, isEmpty);
    });

    test('preserves input order', () {
      final out = selectEligibleForBackfill(
        [_p(id: 5), _p(id: 1), _p(id: 9)],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [5, 1, 9]);
    });

    test('returns empty on empty input', () {
      expect(
          selectEligibleForBackfill(const [], const <int>{}), isEmpty);
    });

    test('user-supplied photos do NOT block backfill eligibility', () {
      // The "wikimediaPhotoPingIds" set deliberately tracks wikimedia
      // rows only — a manual user photo doesn't replace what the auto-
      // fetcher would have found. Test by passing an empty wikimedia
      // set (the user-supplied row exists in production but isn't in
      // this set), expecting the ping is still eligible.
      final out = selectEligibleForBackfill(
        [_p(id: 1)],
        const <int>{},
      );
      expect(out, hasLength(1));
    });
  });

  group('selectEligibleForBackfill includeImported', () {
    test('the opt-in lets imported rows through', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1, source: PingSource.imported)],
        const <int>{},
        includeImported: true,
      );
      expect(out.map((p) => p.id).toList(), [1]);
    });

    test('the opt-in still skips no_fix, null coords and null ids', () {
      final out = selectEligibleForBackfill(
        [
          _p(id: 1, source: PingSource.noFix),
          _p(id: 2, lat: null, source: PingSource.imported),
          _p(id: 3, source: PingSource.imported),
        ],
        const <int>{},
        includeImported: true,
      );
      expect(out.map((p) => p.id).toList(), [3]);
    });

    test('the opt-in still skips rows that already have wikimedia photos',
        () {
      final out = selectEligibleForBackfill(
        [
          _p(id: 1, source: PingSource.imported),
          _p(id: 2, source: PingSource.imported),
        ],
        const {1},
        includeImported: true,
      );
      expect(out.map((p) => p.id).toList(), [2]);
    });

    test('defaults to false — an unnamed caller never gets imports', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1, source: PingSource.imported)],
        const <int>{},
      );
      expect(out, isEmpty);
    });
  });

  // 0.17.5, commander 2026-08-23 ("make sure they work on imported ones
  // too"): the manual backfill sheet now covers imported pins as well —
  // it is a user tap whose subtitle says the coordinates go out. The
  // automatic paths still never fetch for an import (gotcha 21), and
  // `onlyImportId` still scopes the walk to one batch. Real (ffi) DB +
  // a recording stand-in for Wikimedia.
  group('PhotoBackfillService.run', () {
    late Database db;
    late PingDao dao;
    late _RecordingPhotoService online;
    late PhotoBackfillService service;
    late int ownPingId;
    late List<int> importOneIds;
    late int importTwoId;

    Future<List<int>> pingIdsWithPhotos() async {
      final rows = await db.rawQuery(
        'SELECT DISTINCT ping_id FROM ping_photos ORDER BY ping_id',
      );
      return rows.map((r) => (r['ping_id'] as num).toInt()).toList();
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      db = await _openMemDb();
      TrailDatabase.useSharedForTest(db);
      dao = PingDao(db);
      online = _RecordingPhotoService();
      service = PhotoBackfillService(
        onlineService: online,
        throttle: Duration.zero,
      );

      ownPingId = await dao.insert(_row(51.5, -0.1));
      // Import 1: two distinct cells plus a repeat of the first cell.
      await dao.insertImportedBatch(
        [
          _row(52.1, -1.1, minute: 1),
          _row(52.2, -1.2, minute: 2),
          _row(52.1001, -1.1001, minute: 3),
        ],
        importId: 1,
      );
      await dao.insertImportedBatch([_row(53.3, -2.3, minute: 4)],
          importId: 2);
      final rows = await db.query('pings',
          columns: ['id', 'import_id'], orderBy: 'id ASC');
      importOneIds = [
        for (final r in rows)
          if ((r['import_id'] as num?)?.toInt() == 1) (r['id'] as num).toInt(),
      ];
      importTwoId = [
        for (final r in rows)
          if ((r['import_id'] as num?)?.toInt() == 2) (r['id'] as num).toInt(),
      ].single;
    });

    tearDown(() async {
      TrailDatabase.resetSharedForTest();
      await db.close();
    });

    test('the default walk covers imported rows too (0.17.5 — the '
        'commander asked for photos on imported pins)', () async {
      final events = await service.run().toList();

      expect(events.last.finished, isTrue);
      expect(events.last.error, isNull);
      expect(events.last.total, 5,
          reason: 'the own ping + three from import 1 + one from import 2');
      // 52.1001 shares a cell with 52.1, so four lookups for five pings.
      expect(online.asked.map((a) => a.lat).toList(),
          [51.5, 52.1, 52.2, 53.3]);
      expect(events.last.cellCacheHits, 1);
      expect(
        await pingIdsWithPhotos(),
        [ownPingId, ...importOneIds, importTwoId]..sort(),
      );
    });

    test('the default walk reports how many of the total are imported',
        () async {
      final events = await service.run().toList();

      expect(events.first.total, 5);
      expect(events.first.importedTotal, 4);
      expect(events.last.importedTotal, 4,
          reason: 'the split rides every event so the sheet can show it');
    });

    test('importedTotal is 0 when nothing imported is left to do',
        () async {
      // Give every imported row a wikimedia photo up front.
      for (final id in [...importOneIds, importTwoId]) {
        await db.insert('ping_photos', {
          'ping_id': id,
          'uri': 'https://example.invalid/existing.jpg',
          'source': 'wikimedia',
          'fetched_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
          'ordinal': 0,
        });
      }

      final events = await service.run().toList();

      expect(events.last.total, 1);
      expect(events.last.importedTotal, 0);
      expect(online.asked, [(lat: 51.5, lon: -0.1)]);
    });

    test('an imported ping that already has a wikimedia row is skipped by '
        'the default walk', () async {
      await db.insert('ping_photos', {
        'ping_id': importOneIds.first,
        'uri': 'https://example.invalid/existing.jpg',
        'source': 'wikimedia',
        'fetched_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
        'ordinal': 0,
      });

      final events = await service.run().toList();

      expect(events.last.total, 4);
      expect(events.last.importedTotal, 3);
      expect(online.asked.map((a) => a.lat).toList(),
          [51.5, 52.2, 52.1001, 53.3]);
    });

    test('a user-attached photo does not stop the default walk from '
        'fetching for an imported pin', () async {
      await db.insert('ping_photos', {
        'ping_id': importTwoId,
        'uri': 'file:///tmp/mine.jpg',
        'source': 'user_camera',
        'fetched_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
        'ordinal': 0,
      });

      final events = await service.run().toList();

      expect(events.last.total, 5);
      expect(online.asked.map((a) => a.lat).toList(), contains(53.3));
    });

    test('no fixes at all → finishes at zero without fetching', () async {
      await db.delete('pings');

      final events = await service.run().toList();

      expect(events.last.total, 0);
      expect(events.last.importedTotal, 0);
      expect(events.last.finished, isTrue);
      expect(online.asked, isEmpty);
    });

    test('onlyImportId touches that import and nothing else', () async {
      final events = await service.run(onlyImportId: 1).toList();

      expect(events.last.finished, isTrue);
      expect(events.last.total, 3);
      expect(events.last.processed, 3);
      // Two lookups, not three: the third ping shares a cell with the
      // first (see the cell-cache test below).
      expect(online.asked.map((a) => a.lat).toList(), [52.1, 52.2]);
      expect(await pingIdsWithPhotos(), importOneIds);
      expect(await pingIdsWithPhotos(), isNot(contains(ownPingId)));
      expect(await pingIdsWithPhotos(), isNot(contains(importTwoId)));
    });

    test('the cell cache still applies — a repeated cell is one lookup',
        () async {
      // 52.1 and 52.1001 quantize to the same ~110 m cell, so the third
      // ping is served from `area_photos`.
      final events = await service.run(onlyImportId: 1).toList();

      expect(online.asked, hasLength(2));
      expect(events.last.cellCacheHits, 1);
      expect(await pingIdsWithPhotos(), hasLength(3));
    });

    test('pings that already have a wikimedia row are skipped', () async {
      await db.insert('ping_photos', {
        'ping_id': importOneIds.first,
        'uri': 'https://example.invalid/existing.jpg',
        'source': 'wikimedia',
        'fetched_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
        'ordinal': 0,
      });

      final events = await service.run(onlyImportId: 1).toList();

      expect(events.last.total, 2);
      expect(online.asked.map((a) => a.lat).toList(), [52.2, 52.1001]);
    });

    test('an import with no rows left finishes at zero, fetching nothing',
        () async {
      final events = await service.run(onlyImportId: 999).toList();

      expect(events.last.total, 0);
      expect(events.last.finished, isTrue);
      expect(online.asked, isEmpty);
      expect(await pingIdsWithPhotos(), isEmpty);
    });
  });

  // The reported bug was "pictures don't display on pins" — so pin
  // photos have to be readable back through the exact calls the pin
  // sheet (`byPingId`) and the slideshow (`byPingIds`) make, for
  // imported rows as much as for own ones.
  group('imported pins, read back the way the UI reads them', () {
    late Database db;
    late PingDao dao;
    late PingPhotoDao photoDao;
    late List<int> importedIds;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      db = await _openMemDb();
      TrailDatabase.useSharedForTest(db);
      dao = PingDao(db);
      photoDao = PingPhotoDao(db);
      await dao.insertImportedBatch(
        [_row(52.1, -1.1, minute: 1), _row(52.2, -1.2, minute: 2)],
        importId: 7,
      );
      final rows = await db.query('pings',
          columns: ['id', 'source', 'import_id'], orderBy: 'id ASC');
      expect(rows.map((r) => r['source']).toSet(), {'import'});
      expect(rows.map((r) => (r['import_id'] as num).toInt()).toSet(), {7});
      importedIds = [for (final r in rows) (r['id'] as num).toInt()];
    });

    tearDown(() async {
      TrailDatabase.resetSharedForTest();
      await db.close();
    });

    test('insertAll rows on imported pings come back from byPingIds '
        '(the slideshow batch read)', () async {
      await photoDao.insertAll([
        for (final id in importedIds)
          PingPhoto(
            pingId: id,
            uri: 'https://example.invalid/$id.jpg',
            source: PingPhotoSource.wikimedia,
            attribution: 'Someone',
            license: 'CC BY-SA 4.0',
            fetchedAt: DateTime.utc(2026, 5, 17),
            ordinal: 0,
          ),
      ]);

      final byPing = await photoDao.byPingIds(importedIds);

      expect(byPing.keys.toSet(), importedIds.toSet());
      for (final id in importedIds) {
        expect(byPing[id], hasLength(1));
      }
    });

    test('a default backfill fills both the gallery read and the '
        'slideshow read for imported pins', () async {
      final online = _RecordingPhotoService();
      final service =
          PhotoBackfillService(onlineService: online, throttle: Duration.zero);

      final events = await service.run().toList();

      expect(events.last.total, 2);
      expect(events.last.importedTotal, 2);
      for (final id in importedIds) {
        // Gallery path.
        expect(await photoDao.byPingId(id), isNotEmpty);
      }
      // Slideshow path.
      final byPing = await photoDao.byPingIds(importedIds);
      expect(byPing.keys.toSet(), importedIds.toSet());
    });
  });

  group('PhotoBackfillProgress.fraction', () {
    test('total=0 → 1.0 (no work, treat as complete)', () {
      const p = PhotoBackfillProgress(
          processed: 0, total: 0, photosAdded: 0);
      expect(p.fraction, 1.0);
    });

    test('processed/total ratio', () {
      const p = PhotoBackfillProgress(
          processed: 3, total: 12, photosAdded: 5);
      expect(p.fraction, 0.25);
    });
  });
}
