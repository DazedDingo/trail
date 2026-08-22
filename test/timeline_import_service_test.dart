import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/database.dart';
import 'package:trail/db/import_dao.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/import/timeline_import_service.dart';
import 'package:trail/services/import/timeline_models.dart';

/// End-to-end tests for the Timeline import pipeline: a real
/// `Isolate.spawn`ed worker parsing `test/fixtures/timeline/*.json`, a
/// real (ffi, in-memory) database on the other side of the message
/// protocol.
///
/// The expected numbers come from the mapper + thinning tests: the
/// Android fixture yields 11 candidates (6 path, 1 visit ×2, 1 activity
/// ×2, 1 raw), which the Normal preset thins to 8 rows.

/// Same top-level libsqlite3 loader workaround as `ping_dao_test.dart`
/// (CLAUDE.md gotcha 8) — must be top-level so it survives the
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

/// Production DDL on an ffi handle (gotcha 28's preferred pattern) —
/// schema v5 brings `pings.import_id` + the `imports` table.
Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await TrailDatabase.createSchemaForTest(db);
  return db;
}

String _fixture(String name) =>
    '${Directory.current.path}/test/fixtures/timeline/$name';

void main() {
  late Database db;
  late PingDao pings;
  late ImportDao imports;
  late TimelineImportService service;

  setUp(() async {
    db = await _openMemDb();
    TrailDatabase.useSharedForTest(db);
    pings = PingDao(db);
    imports = ImportDao(db);
    service = TimelineImportService(pingDao: pings, importDao: imports);
  });

  tearDown(() async {
    service.dispose();
    TrailDatabase.resetSharedForTest();
    await db.close();
  });

  group('preview', () {
    test('reports the Android fixture\'s counts and projection', () async {
      final progress = <ImportProgress>[];
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
        onProgress: progress.add,
      );

      expect(preview.fileName, 'android_small.json');
      expect(preview.preset, ImportPreset.normal);
      expect(preview.counts.pathPoints, 6);
      expect(preview.counts.visits, 1);
      expect(preview.counts.activities, 1);
      expect(preview.counts.rawPositions, 1);
      expect(preview.counts.rawRejectedAccuracy, 1);
      expect(preview.counts.ignoredElements, 2);
      expect(preview.counts.malformedElements, 0);

      expect(preview.projection.candidates, 11);
      expect(preview.projection.kept, 8);
      expect(preview.projection.duplicates, 0);
      expect(preview.projection.exceedsWarnThreshold, isFalse);
      expect(
        DateTime.fromMillisecondsSinceEpoch(
          preview.projection.tsMinUtcMs!,
          isUtc: true,
        ),
        DateTime.utc(2026, 3, 1, 9),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(
          preview.projection.tsMaxUtcMs!,
          isUtc: true,
        ),
        DateTime.utc(2026, 3, 1, 13, 20),
      );

      expect(
        preview.frequentPlaces.map((p) => p.label).toList(),
        <String>['HOME', 'WORK'],
      );
      // At least the terminal progress tick lands, and it never claims
      // more bytes than the file has.
      expect(progress, isNotEmpty);
      expect(progress.last.phase, ImportPhase.parsing);
      expect(progress.last.current, lessThanOrEqualTo(progress.last.total!));
    });

    test('the Coarse preset keeps fewer rows than Normal', () async {
      final coarse = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.coarse,
      );
      // 60 min / 1 km: only the first path point, both visit endpoints,
      // the activity end and the first afternoon path point survive.
      expect(coarse.projection.kept, 5);
      expect(coarse.projection.candidates, 11);
    });

    test('the Full preset keeps every candidate', () async {
      final full = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.full,
      );
      // Only the 60-second group dedupe applies; nothing in the fixture
      // is within 60 s of anything else.
      expect(full.projection.kept, 11);
    });

    test('skips candidates Trail already logged (±60 s, < 25 m)', () async {
      // Same instant + coordinates as the fixture's first path point.
      await pings.insert(Ping(
        timestampUtc: DateTime.utc(2026, 3, 1, 9, 0, 30),
        lat: 51.5074,
        lon: -0.1278,
        source: PingSource.scheduled,
      ));

      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      expect(preview.projection.duplicates, 1);
      expect(preview.projection.kept, 7);
    });

    test('an unreadable path is an error, not a crash', () async {
      expect(
        () => service.preview(
          '${Directory.current.path}/test/fixtures/timeline/nope.json',
          ImportPreset.normal,
        ),
        throwsA(isA<ImportException>()),
      );
    });

    test('a file that is not JSON fails with an error', () async {
      final dir = await Directory.systemTemp.createTemp('trail_import_test');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/garbage.json';
      await File(path).writeAsString('{ "semanticSegments": [ {oops} ] }');
      // The mappers are permissive, so a broken element is *counted*,
      // never fatal: the file previews with zero candidates.
      final preview = await service.preview(path, ImportPreset.normal);
      expect(preview.projection.kept, 0);
      expect(preview.counts.malformedElements, greaterThan(0));
    });
  });

  group('commit', () {
    test('inserts imported rows and finalises the record', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final progress = <ImportProgress>[];
      final result = await service.commit(preview, onProgress: progress.add);

      expect(result.ok, isTrue);
      expect(result.rows, 8);
      expect(result.importId, isNotNull);
      expect(result.tsMinUtc, DateTime.utc(2026, 3, 1, 9));
      expect(result.tsMaxUtc, DateTime.utc(2026, 3, 1, 13, 20));
      expect(result.sampledPoints.length, 8);
      expect(progress.last.phase, ImportPhase.inserting);
      expect(progress.last.current, 8);

      final rows = await db.query('pings', orderBy: 'ts_utc ASC');
      expect(rows.length, 8);
      expect(rows.map((r) => r['source']).toSet(), <String>{'import'});
      expect(
        rows.map((r) => r['import_id']).toSet(),
        <int>{result.importId!},
      );
      expect(
        rows.map((r) => r['note'] as String).toSet(),
        containsAll(<String>[
          'gmaps:path',
          'gmaps:visit:HOME:ChIJ_fixture-123',
          'gmaps:activity:WALKING:2346m',
        ]),
      );

      final record = (await imports.all()).single;
      expect(record.rowCount, 8);
      expect(record.fileName, 'android_small.json');
      expect(record.preset, 'normal');
      expect(record.tsMinUtc, DateTime.utc(2026, 3, 1, 9));
      expect(record.tsMaxUtc, DateTime.utc(2026, 3, 1, 13, 20));
      expect(record.fileHash, preview.fileHash);
    });

    test('imported rows stay out of the live-ping reads', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      await service.commit(preview);

      expect(await pings.latestSuccessful(), isNull);
      expect(await pings.recent(), isEmpty);
      expect(await pings.allPings(), isEmpty);
      expect((await pings.recent(includeImported: true)).length, 8);
      expect((await pings.fixesByDateRange()).length, 8);
    });

    test('re-previewing the same file refuses it', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final result = await service.commit(preview);

      try {
        await service.preview(
          _fixture('android_small.json'),
          ImportPreset.normal,
        );
        fail('expected AlreadyImportedException');
      } on AlreadyImportedException catch (e) {
        expect(e.record.id, result.importId);
        expect(e.record.rowCount, 8);
      }
    });

    test('a different file still imports next to the first', () async {
      final first = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      await service.commit(first);
      final second = await service.preview(
        _fixture('ios_small.json'),
        ImportPreset.normal,
      );
      final result = await service.commit(second);

      expect(result.ok, isTrue);
      expect(result.rows, greaterThan(0));
      expect((await imports.all()).length, 2);
      expect(await pings.countByImportId(result.importId!), result.rows);
    });

    test('cancelling leaves no rows and no record', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final cancel = ImportCancelToken()..isCancelled = true;
      final result = await service.commit(preview, cancelToken: cancel);

      expect(result.cancelled, isTrue);
      expect(result.ok, isFalse);
      expect(result.rows, 0);
      expect(await pings.count(), 0);
      expect(await imports.all(), isEmpty);
    });

    test('a live ping survives an import that deduped against it',
        () async {
      await pings.insert(Ping(
        timestampUtc: DateTime.utc(2026, 3, 1, 9, 0, 30),
        lat: 51.5074,
        lon: -0.1278,
        source: PingSource.scheduled,
      ));
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final result = await service.commit(preview);

      expect(result.rows, 7);
      expect(await pings.count(), 8);
      expect((await pings.recent()).single.source, PingSource.scheduled);
    });
  });

  group('undo + history', () {
    test('undo removes the rows and the record', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final result = await service.commit(preview);
      expect(await service.rowCount(result.importId!), 8);

      final removed = await service.undo(result.importId!);

      expect(removed, 8);
      expect(await pings.count(), 0);
      expect(await service.history(), isEmpty);
    });

    test('undo leaves other imports and live pings alone', () async {
      await pings.insert(Ping(
        timestampUtc: DateTime.utc(2026, 1, 1, 12),
        lat: 51.0,
        lon: -1.0,
        source: PingSource.scheduled,
      ));
      final first = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      final firstResult = await service.commit(first);
      final second = await service.preview(
        _fixture('ios_small.json'),
        ImportPreset.normal,
      );
      final secondResult = await service.commit(second);

      await service.undo(firstResult.importId!);

      expect(await service.history(), hasLength(1));
      expect(await pings.countByImportId(secondResult.importId!),
          secondResult.rows);
      expect((await pings.recent()).single.source, PingSource.scheduled);
    });

    test('history lists imports newest first', () async {
      final preview = await service.preview(
        _fixture('android_small.json'),
        ImportPreset.normal,
      );
      await service.commit(preview);
      final history = await service.history();
      expect(history, hasLength(1));
      expect(history.single.fileName, 'android_small.json');
    });

    test('undo of an unknown import id is a no-op', () async {
      expect(await service.undo(4242), 0);
    });
  });

  test('the worker respawns after dispose', () async {
    final first = await service.preview(
      _fixture('android_small.json'),
      ImportPreset.normal,
    );
    expect(first.projection.kept, 8);
    service.dispose();
    final second = await service.preview(
      _fixture('android_small.json'),
      ImportPreset.normal,
    );
    expect(second.projection.kept, 8);
  });
}
