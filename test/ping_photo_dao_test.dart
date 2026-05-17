import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:trail/db/ping_photo_dao.dart';
import 'package:trail/models/ping_photo.dart';

void _ffiInit() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      const candidates = [
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/aarch64-linux-gnu/libsqlite3.so.0',
      ];
      for (final p in candidates) {
        if (File(p).existsSync()) return DynamicLibrary.open(p);
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
}

Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  // ping_photos has a FK on pings.id but the DAO never touches pings; we
  // create a tiny stub so the FK declaration parses.
  await db.execute(
    'CREATE TABLE pings (id INTEGER PRIMARY KEY AUTOINCREMENT, ts_utc INTEGER);',
  );
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
  return db;
}

PingPhoto _photo({
  int pingId = 1,
  String uri = 'https://commons.wikimedia.org/x.jpg',
  PingPhotoSource source = PingPhotoSource.wikimedia,
  String attribution = 'Jane Doe',
  String license = 'CC BY-SA 4.0',
  String? thumbUri,
  int ordinal = 0,
}) =>
    PingPhoto(
      pingId: pingId,
      uri: uri,
      source: source,
      attribution: attribution,
      license: license,
      thumbUri: thumbUri,
      fetchedAt: DateTime.utc(2026, 5, 17),
      ordinal: ordinal,
    );

void main() {
  group('PingPhotoDao', () {
    late Database db;
    late PingPhotoDao dao;

    setUp(() async {
      db = await _openMemDb();
      dao = PingPhotoDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('insert + byPingId round-trips fields and orders by ordinal', () async {
      await dao.insert(_photo(pingId: 1, ordinal: 1, uri: 'b'));
      await dao.insert(_photo(pingId: 1, ordinal: 0, uri: 'a'));
      await dao.insert(_photo(pingId: 2, ordinal: 0, uri: 'c'));

      final ping1 = await dao.byPingId(1);
      expect(ping1.map((p) => p.uri).toList(), ['a', 'b']);
      expect(ping1.first.source, PingPhotoSource.wikimedia);
      expect(ping1.first.attribution, 'Jane Doe');
      expect(ping1.first.license, 'CC BY-SA 4.0');

      final ping2 = await dao.byPingId(2);
      expect(ping2.single.uri, 'c');

      final pingNone = await dao.byPingId(99);
      expect(pingNone, isEmpty);
    });

    test('insertAll commits atomically (batch path)', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'x'),
        _photo(pingId: 1, ordinal: 1, uri: 'y'),
        _photo(pingId: 1, ordinal: 2, uri: 'z'),
      ]);
      final out = await dao.byPingId(1);
      expect(out.length, 3);
      expect(out.map((p) => p.uri).toList(), ['x', 'y', 'z']);
    });

    test('byPingIds returns a map grouped by ping_id', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'a'),
        _photo(pingId: 2, ordinal: 0, uri: 'b'),
        _photo(pingId: 2, ordinal: 1, uri: 'c'),
      ]);
      final out = await dao.byPingIds([1, 2, 3]);
      expect(out.keys.toSet(), {1, 2});
      expect(out[1]!.single.uri, 'a');
      expect(out[2]!.map((p) => p.uri).toList(), ['b', 'c']);
      // ping 3 has no photos → key absent (not an empty list).
      expect(out.containsKey(3), isFalse);
    });

    test('byPingIds short-circuits on empty input', () async {
      final out = await dao.byPingIds(const <int>[]);
      expect(out, isEmpty);
    });

    test('onlineCountForPing only counts wikimedia source', () async {
      await dao.insertAll([
        _photo(pingId: 5, ordinal: 0, source: PingPhotoSource.wikimedia),
        _photo(pingId: 5, ordinal: 1, source: PingPhotoSource.userCamera),
        _photo(pingId: 5, ordinal: 2, source: PingPhotoSource.userGallery),
        _photo(pingId: 5, ordinal: 3, source: PingPhotoSource.wikimedia),
      ]);
      expect(await dao.onlineCountForPing(5), 2);
      expect(await dao.onlineCountForPing(6), 0);
    });

    test('deleteById removes only the targeted row', () async {
      final id1 = await dao.insert(_photo(pingId: 1, ordinal: 0, uri: 'a'));
      await dao.insert(_photo(pingId: 1, ordinal: 1, uri: 'b'));
      expect(await dao.deleteById(id1), 1);
      final out = await dao.byPingId(1);
      expect(out.single.uri, 'b');
    });

    test('deleteForPing removes every row for the ping', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'a'),
        _photo(pingId: 1, ordinal: 1, uri: 'b'),
        _photo(pingId: 2, ordinal: 0, uri: 'c'),
      ]);
      final removed = await dao.deleteForPing(1);
      expect(removed, 2);
      expect(await dao.byPingId(1), isEmpty);
      expect((await dao.byPingId(2)).single.uri, 'c');
    });
  });

  group('PingPhotoSource enum mapping', () {
    test('round-trips through dbValue / fromDb', () {
      for (final s in PingPhotoSource.values) {
        expect(PingPhotoSource.fromDb(s.dbValue), s);
      }
    });

    test('unknown source string defaults to wikimedia (forward-compat)', () {
      expect(PingPhotoSource.fromDb('made_up_future_source'),
          PingPhotoSource.wikimedia);
    });

    test('isUserSupplied flags camera + gallery but not wikimedia', () {
      expect(PingPhotoSource.wikimedia.isUserSupplied, isFalse);
      expect(PingPhotoSource.userCamera.isUserSupplied, isTrue);
      expect(PingPhotoSource.userGallery.isUserSupplied, isTrue);
    });
  });
}
