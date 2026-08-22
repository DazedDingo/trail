import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:trail/db/database.dart';
import 'package:trail/db/ping_dao.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/providers/pings_provider.dart';

/// Provider-level wiring for the pings reads. Runs against an in-memory
/// `sqflite_common_ffi` DB injected through `TrailDatabase.useSharedForTest`
/// so the real providers (not the DAO) are what's under test.
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

Future<Database> _openMemDb() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  // Real production DDL (schema v4), not a mirror.
  await TrailDatabase.createSchemaForTest(db);
  return db;
}

Ping _fix(DateTime local, double lat) => Ping(
      timestampUtc: local.toUtc(),
      lat: lat,
      lon: -0.1,
      source: PingSource.scheduled,
    );

Ping _noFix(DateTime local) => Ping(
      timestampUtc: local.toUtc(),
      source: PingSource.noFix,
      note: 'timeout',
    );

void main() {
  group('mapRangeUtcBounds', () {
    test('single local day → [00:00, 23:59:59.999] of that day, in UTC',
        () {
      final day = DateTime(2026, 4, 20);
      final b = mapRangeUtcBounds(DateTimeRange(start: day, end: day));
      expect(b.startUtc, day.toUtc());
      expect(b.startUtc.isUtc, isTrue);
      expect(
        b.endUtc,
        DateTime(2026, 4, 20, 23, 59, 59, 999).toUtc(),
      );
      expect(b.endUtc.isUtc, isTrue);
    });

    test('multi-day range ends at the last millisecond of the end day', () {
      final b = mapRangeUtcBounds(DateTimeRange(
        start: DateTime(2026, 4, 18),
        end: DateTime(2026, 4, 20),
      ));
      expect(b.startUtc, DateTime(2026, 4, 18).toUtc());
      expect(b.endUtc, DateTime(2026, 4, 21).toUtc().subtract(
            const Duration(milliseconds: 1),
          ));
    });

    test('an end with a time-of-day is widened from that instant (legacy '
        'map behaviour, not the export rule)', () {
      final end = DateTime(2026, 4, 20, 15, 30);
      final b = mapRangeUtcBounds(DateTimeRange(start: DateTime(2026, 4, 20), end: end));
      expect(
        b.endUtc,
        end.add(const Duration(days: 1) - const Duration(milliseconds: 1)).toUtc(),
      );
    });
  });

  group('pings providers against an injected shared DB', () {
    late Database db;
    late ProviderContainer container;

    setUp(() async {
      db = await _openMemDb();
      TrailDatabase.useSharedForTest(db);
      container = ProviderContainer();
      final dao = PingDao(db);
      await dao.insert(_fix(DateTime(2026, 1, 1, 12), 51.1));
      await dao.insert(_noFix(DateTime(2026, 1, 1, 16)));
      await dao.insert(_fix(DateTime(2026, 1, 2, 12), 51.2));
      await dao.insert(_fix(DateTime(2026, 1, 3, 12), 51.3));
    });

    tearDown(() async {
      container.dispose();
      TrailDatabase.resetSharedForTest();
      await db.close();
    });

    test('allPingsProvider returns EVERY row, no_fix included, oldest-first',
        () async {
      final all = await container.read(allPingsProvider.future);
      expect(all, hasLength(4));
      expect(all.map((p) => p.source), contains(PingSource.noFix));
      expect(all.map((p) => p.timestampUtc).toList(),
          all.map((p) => p.timestampUtc).toList()..sort());
    });

    test('pingsByRangeProvider(null) returns fixes only, oldest-first',
        () async {
      final fixes = await container.read(pingsByRangeProvider(null).future);
      expect(fixes.map((p) => p.lat), [51.1, 51.2, 51.3]);
      expect(fixes.every((p) => p.lat != null && p.lon != null), isTrue);
      expect(fixes.map((p) => p.source), isNot(contains(PingSource.noFix)));
    });

    test('pingsByRangeProvider(range) clips to whole local days', () async {
      final range = DateTimeRange(
        start: DateTime(2026, 1, 2),
        end: DateTime(2026, 1, 2),
      );
      final fixes = await container.read(pingsByRangeProvider(range).future);
      expect(fixes.map((p) => p.lat), [51.2]);
    });

    test('a range member is released once nothing watches it; '
        'allPingsProvider is retained', () async {
      final member = pingsByRangeProvider(null);
      final sub = container.listen(member, (_, __) {});
      await container.read(member.future);
      await container.read(allPingsProvider.future);
      Iterable<ProviderBase<Object?>> alive() =>
          container.getAllProviderElements().map((e) => e.origin);
      expect(alive(), contains(member));

      sub.close();
      await container.pump();
      expect(alive(), isNot(contains(member)));
      expect(alive(), contains(allPingsProvider));
    });

    test('invalidating the family re-queries after a write', () async {
      final member = pingsByRangeProvider(null);
      final sub = container.listen(member, (_, __) {});
      expect(await container.read(member.future), hasLength(3));

      await PingDao(db).insert(_fix(DateTime(2026, 1, 4, 12), 51.4));
      container.invalidate(pingsByRangeProvider);
      expect(
        (await container.read(member.future)).map((p) => p.lat),
        [51.1, 51.2, 51.3, 51.4],
      );
      sub.close();
    });
  });
}
