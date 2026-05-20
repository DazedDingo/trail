import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:trail/db/area_photo_dao.dart';
import 'package:trail/models/area_photo.dart';

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

AreaPhoto _ap({
  double cellLat = 51.512,
  double cellLon = -0.127,
  required String uri,
}) =>
    AreaPhoto(
      cellLat: cellLat,
      cellLon: cellLon,
      uri: uri,
      thumbUri: '$uri.thumb',
      attribution: 'Alice',
      license: 'CC0',
      discoveredAt: DateTime.utc(2026, 4, 28),
    );

void main() {
  late Database db;
  late AreaPhotoDao dao;

  setUp(() async {
    db = await _openMemDb();
    dao = AreaPhotoDao(db);
  });

  tearDown(() => db.close());

  test('byCell returns empty when nothing cached', () async {
    expect(await dao.byCell(51.512, -0.127), isEmpty);
    expect(await dao.hasCellCache(51.512, -0.127), isFalse);
  });

  test('insertForCell persists every photo, byCell reads them back', () async {
    final wrote = await dao.insertForCell(
      cellLat: 51.512,
      cellLon: -0.127,
      photos: [
        _ap(uri: 'a.jpg'),
        _ap(uri: 'b.jpg'),
        _ap(uri: 'c.jpg'),
      ],
    );
    expect(wrote, 3);
    final back = await dao.byCell(51.512, -0.127);
    expect(back.map((p) => p.uri), ['a.jpg', 'b.jpg', 'c.jpg']);
    expect(back.first.attribution, 'Alice');
    expect(back.first.license, 'CC0');
    expect(back.first.thumbUri, 'a.jpg.thumb');
    expect(await dao.hasCellCache(51.512, -0.127), isTrue);
  });

  test('insertForCell is idempotent — second call no-ops on the same cell',
      () async {
    await dao.insertForCell(
      cellLat: 51.512,
      cellLon: -0.127,
      photos: [_ap(uri: 'a.jpg')],
    );
    final secondTry = await dao.insertForCell(
      cellLat: 51.512,
      cellLon: -0.127,
      photos: [_ap(uri: 'b.jpg'), _ap(uri: 'c.jpg')],
    );
    expect(secondTry, 0);
    final back = await dao.byCell(51.512, -0.127);
    expect(back.map((p) => p.uri), ['a.jpg']);
  });

  test('different cells are isolated', () async {
    await dao.insertForCell(
      cellLat: 51.512,
      cellLon: -0.127,
      photos: [_ap(uri: 'lon.jpg')],
    );
    await dao.insertForCell(
      cellLat: 40.713,
      cellLon: -74.006,
      photos: [_ap(cellLat: 40.713, cellLon: -74.006, uri: 'ny.jpg')],
    );
    expect((await dao.byCell(51.512, -0.127)).single.uri, 'lon.jpg');
    expect((await dao.byCell(40.713, -74.006)).single.uri, 'ny.jpg');
  });

  test('empty insert list is a no-op (no transaction overhead)', () async {
    final wrote = await dao.insertForCell(
      cellLat: 1,
      cellLon: 2,
      photos: const [],
    );
    expect(wrote, 0);
    expect(await dao.hasCellCache(1, 2), isFalse);
  });

  test('cellCount + totalPhotoCount diagnostics', () async {
    await dao.insertForCell(
      cellLat: 51.512,
      cellLon: -0.127,
      photos: [_ap(uri: 'a.jpg'), _ap(uri: 'b.jpg')],
    );
    await dao.insertForCell(
      cellLat: 40.713,
      cellLon: -74.006,
      photos: [_ap(cellLat: 40.713, cellLon: -74.006, uri: 'c.jpg')],
    );
    expect(await dao.cellCount(), 2);
    expect(await dao.totalPhotoCount(), 3);
  });
}
