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
      await dao.insert(_photo(pingId: 1, ordinal: 1, uri: 'b.jpg'));
      await dao.insert(_photo(pingId: 1, ordinal: 0, uri: 'a.jpg'));
      await dao.insert(_photo(pingId: 2, ordinal: 0, uri: 'c.jpg'));

      final ping1 = await dao.byPingId(1);
      expect(ping1.map((p) => p.uri).toList(), ['a.jpg', 'b.jpg']);
      expect(ping1.first.source, PingPhotoSource.wikimedia);
      expect(ping1.first.attribution, 'Jane Doe');
      expect(ping1.first.license, 'CC BY-SA 4.0');

      final ping2 = await dao.byPingId(2);
      expect(ping2.single.uri, 'c.jpg');

      final pingNone = await dao.byPingId(99);
      expect(pingNone, isEmpty);
    });

    test('insertAll commits atomically (batch path)', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'x.jpg'),
        _photo(pingId: 1, ordinal: 1, uri: 'y.jpg'),
        _photo(pingId: 1, ordinal: 2, uri: 'z.jpg'),
      ]);
      final out = await dao.byPingId(1);
      expect(out.length, 3);
      expect(out.map((p) => p.uri).toList(), ['x.jpg', 'y.jpg', 'z.jpg']);
    });

    test('byPingIds returns a map grouped by ping_id', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'a.jpg'),
        _photo(pingId: 2, ordinal: 0, uri: 'b.jpg'),
        _photo(pingId: 2, ordinal: 1, uri: 'c.jpg'),
      ]);
      final out = await dao.byPingIds([1, 2, 3]);
      expect(out.keys.toSet(), {1, 2});
      expect(out[1]!.single.uri, 'a.jpg');
      expect(out[2]!.map((p) => p.uri).toList(), ['b.jpg', 'c.jpg']);
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
      final id1 = await dao.insert(_photo(pingId: 1, ordinal: 0, uri: 'a.jpg'));
      await dao.insert(_photo(pingId: 1, ordinal: 1, uri: 'b.jpg'));
      expect(await dao.deleteById(id1), 1);
      final out = await dao.byPingId(1);
      expect(out.single.uri, 'b.jpg');
    });

    test('deleteForPing removes every row for the ping', () async {
      await dao.insertAll([
        _photo(pingId: 1, ordinal: 0, uri: 'a.jpg'),
        _photo(pingId: 1, ordinal: 1, uri: 'b.jpg'),
        _photo(pingId: 2, ordinal: 0, uri: 'c.jpg'),
      ]);
      final removed = await dao.deleteForPing(1);
      expect(removed, 2);
      expect(await dao.byPingId(1), isEmpty);
      expect((await dao.byPingId(2)).single.uri, 'c.jpg');
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
  _addTombstoneTests();
}

void _addTombstoneTests() {
  group('PingPhotoDao — non-image tombstone filter (0.13.2)', () {
    late Database db;
    late PingPhotoDao dao;

    setUp(() async {
      db = await _openMemDb();
      dao = PingPhotoDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('byPingId drops wikimedia rows with non-image URIs', () async {
      await dao.insert(_photo(pingId: 1, ordinal: 0,
          uri: 'https://upload.wikimedia.org/.../good.jpg'));
      await dao.insert(_photo(pingId: 1, ordinal: 1,
          uri: 'https://upload.wikimedia.org/.../audio.ogg'));
      await dao.insert(_photo(pingId: 1, ordinal: 2,
          uri: 'https://upload.wikimedia.org/.../paper.pdf'));
      await dao.insert(_photo(pingId: 1, ordinal: 3,
          uri: 'https://upload.wikimedia.org/.../movie.mp4'));
      await dao.insert(_photo(pingId: 1, ordinal: 4,
          uri: 'https://upload.wikimedia.org/.../another.PNG'));
      final out = await dao.byPingId(1);
      expect(out.map((p) => p.uri.split('/').last).toList(),
          ['good.jpg', 'another.PNG']);
    });

    test('byPingId keeps a wikimedia row when only thumbUri is image-like',
        () async {
      await dao.insert(_photo(pingId: 1, ordinal: 0,
          uri: 'https://upload.wikimedia.org/.../diagram.svg',
          thumbUri:
              'https://upload.wikimedia.org/.../thumb/diagram.svg/512px-diagram.png'));
      final out = await dao.byPingId(1);
      expect(out, hasLength(1));
    });

    test('user-supplied rows are never filtered, even if URI looks weird',
        () async {
      await dao.insert(_photo(pingId: 1, ordinal: 0,
          uri: 'file:///data/user/0/.../IMG_0123',
          source: PingPhotoSource.userCamera));
      final out = await dao.byPingId(1);
      expect(out, hasLength(1));
    });

    test('byPingIds applies the same tombstone filter', () async {
      await dao.insert(_photo(pingId: 1, ordinal: 0,
          uri: 'https://w.org/x.jpg'));
      await dao.insert(_photo(pingId: 1, ordinal: 1,
          uri: 'https://w.org/x.ogg'));
      await dao.insert(_photo(pingId: 2, ordinal: 0,
          uri: 'https://w.org/y.pdf'));
      final out = await dao.byPingIds([1, 2]);
      expect(out.keys.toSet(), {1}, reason: 'ping 2 had only a PDF');
      expect(out[1]!.map((p) => p.uri).toList(), ['https://w.org/x.jpg']);
    });

    test('URI with a query string still matches the extension', () async {
      await dao.insert(_photo(pingId: 1, ordinal: 0,
          uri: 'https://w.org/x.jpg?cache=1234'));
      final out = await dao.byPingId(1);
      expect(out, hasLength(1));
    });
  });
}
