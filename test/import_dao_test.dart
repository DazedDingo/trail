import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:trail/db/import_dao.dart';

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

/// Mirror of `TrailDatabase._importsCreateSql` (schema v5) — kept
/// in lock-step, same convention as `ping_dao_test.dart` (gotcha 20).
Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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

ImportRecord _rec({
  DateTime? importedAtUtc,
  String? fileName = 'Timeline.json',
  required String fileHash,
  String preset = 'normal',
  int rowCount = 100,
  DateTime? tsMinUtc,
  DateTime? tsMaxUtc,
}) =>
    ImportRecord(
      importedAtUtc: importedAtUtc ?? DateTime.utc(2026, 8, 22),
      fileName: fileName,
      fileHash: fileHash,
      preset: preset,
      rowCount: rowCount,
      tsMinUtc: tsMinUtc,
      tsMaxUtc: tsMaxUtc,
    );

void main() {
  late Database db;
  late ImportDao dao;

  setUp(() async {
    db = await _openMemDb();
    dao = ImportDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ImportDao.insert', () {
    test('returns the generated rowid', () async {
      final id = await dao.insert(_rec(fileHash: 'hash-a'));
      expect(id, isNonZero);
    });

    test('strips caller-provided id (autoincrement owns it)', () async {
      final withId = ImportRecord(
        id: 999,
        importedAtUtc: DateTime.utc(2026, 8, 22),
        fileHash: 'hash-b',
        preset: 'normal',
        rowCount: 5,
      );
      final id = await dao.insert(withId);
      expect(id, 1);
    });

    test('a conflicting file_hash surfaces as a DatabaseException '
        '(refuses a byte-identical re-import)', () async {
      await dao.insert(_rec(fileHash: 'dupe-hash'));
      expect(
        () => dao.insert(_rec(fileHash: 'dupe-hash')),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('ImportDao.byHash', () {
    test('returns null when no import has this hash', () async {
      expect(await dao.byHash('nope'), isNull);
    });

    test('returns the matching record', () async {
      await dao.insert(_rec(
        fileHash: 'abc123',
        fileName: 'my-timeline.json',
        rowCount: 42,
        preset: 'coarse',
        tsMinUtc: DateTime.utc(2026, 1, 1),
        tsMaxUtc: DateTime.utc(2026, 6, 1),
      ));
      final got = await dao.byHash('abc123');
      expect(got, isNotNull);
      expect(got!.fileName, 'my-timeline.json');
      expect(got.rowCount, 42);
      expect(got.preset, 'coarse');
      expect(got.tsMinUtc, DateTime.utc(2026, 1, 1));
      expect(got.tsMaxUtc, DateTime.utc(2026, 6, 1));
    });

    test('nullable file_name / ts bounds round-trip as null', () async {
      await dao.insert(_rec(fileHash: 'no-extras', fileName: null));
      final got = await dao.byHash('no-extras');
      expect(got!.fileName, isNull);
      expect(got.tsMinUtc, isNull);
      expect(got.tsMaxUtc, isNull);
    });
  });

  group('ImportDao.latest', () {
    test('returns null on an empty table', () async {
      expect(await dao.latest(), isNull);
    });

    test('returns the most-recently-imported record', () async {
      await dao.insert(_rec(
        fileHash: 'first',
        importedAtUtc: DateTime.utc(2026, 1, 1),
      ));
      await dao.insert(_rec(
        fileHash: 'second',
        importedAtUtc: DateTime.utc(2026, 6, 1),
      ));
      final latest = await dao.latest();
      expect(latest!.fileHash, 'second');
    });
  });

  group('ImportDao.all', () {
    test('returns every record, newest first', () async {
      await dao.insert(_rec(
        fileHash: 'jan',
        importedAtUtc: DateTime.utc(2026, 1, 1),
      ));
      await dao.insert(_rec(
        fileHash: 'aug',
        importedAtUtc: DateTime.utc(2026, 8, 1),
      ));
      await dao.insert(_rec(
        fileHash: 'apr',
        importedAtUtc: DateTime.utc(2026, 4, 1),
      ));
      final all = await dao.all();
      expect(all.map((r) => r.fileHash), ['aug', 'apr', 'jan']);
    });

    test('empty table returns an empty list, not null', () async {
      expect(await dao.all(), isEmpty);
    });
  });

  group('ImportDao.delete', () {
    test('removes the row and returns 1', () async {
      final id = await dao.insert(_rec(fileHash: 'gone-soon'));
      expect(await dao.delete(id), 1);
      expect(await dao.byHash('gone-soon'), isNull);
    });

    test('returns 0 for a missing id and does not throw', () async {
      expect(await dao.delete(424242), 0);
    });

    test('does not touch other import records', () async {
      final keep = await dao.insert(_rec(fileHash: 'keep'));
      final doomed = await dao.insert(_rec(fileHash: 'doomed'));
      await dao.delete(doomed);
      expect(await dao.byHash('keep'), isNotNull);
      expect((await dao.all()).map((r) => r.id), [keep]);
    });
  });
}
