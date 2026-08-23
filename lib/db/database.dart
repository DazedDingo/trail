import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../services/key_escrow.dart';
import 'keystore_key.dart';

/// One `trail.db.locked-*` file left behind by
/// [TrailDatabase.setAsideForRecovery], with its size on disk.
typedef LockedLog = ({String name, int bytes});

/// The name [TrailDatabase.setAsideForRecovery] moves the current DB to:
/// `trail.db.locked-20260822-1435`. Pure so the naming contract can be
/// asserted without touching the filesystem (CLAUDE.md gotcha 18); [at]
/// is used as given (callers pass local time, which is what the user
/// sees in a file manager).
String lockedDbName(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${at.year.toString().padLeft(4, '0')}'
      '${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}';
  return '${TrailDatabase.dbFileName}.locked-$stamp';
}

/// Whether [name] is one of the set-aside logs [lockedDbName] produces.
/// Deliberately does not match the `-wal` / `-shm` siblings — the
/// diagnostics list shows one line per log, not three.
bool isLockedDbName(String name) =>
    name.startsWith('${TrailDatabase.dbFileName}.locked-') &&
    !name.endsWith('-wal') &&
    !name.endsWith('-shm');

/// Thrown when the app starts up and the on-disk DB is encrypted with a
/// passphrase that isn't yet available in this install — i.e. the
/// post-restore path. The caller (UI startup gate, background scheduler)
/// decides whether to route to the passphrase-entry screen (UI) or skip
/// the ping and log an "awaiting unlock" marker (scheduler).
class PassphraseNeededException implements Exception {
  const PassphraseNeededException();
  @override
  String toString() =>
      'PassphraseNeededException: restored DB requires backup passphrase';
}

/// Singleton wrapper around the encrypted SQLite database.
///
/// Two consumers:
/// 1. The Flutter UI isolate (main), which keeps a long-lived handle via
///    [shared]. All UI providers share one handle — opening four concurrent
///    SQLCipher connections on the same file raced key derivation + schema
///    create on first install and surfaced as a generic "database exception"
///    on the home screen.
/// 2. The WorkManager background isolate, which opens + closes per job via
///    [open]. That isolate cannot share handles with the UI isolate because
///    they live in separate Dart VMs.
class TrailDatabase {
  /// Public so [lockedDbName] / [isLockedDbName] can build and match the
  /// set-aside names off the one source of truth.
  static const dbFileName = 'trail.db';
  // v2 (0.12.0): adds `pings.comment` (for the "How is it?" reply-attach
  // flow) and a new `ping_photos` table (for online auto-fetched + user-
  // supplied photos, many-per-ping). Migration is additive; the existing
  // pings table is untouched, the new column defaults to NULL.
  // v3 (0.13.3): adds `area_photos` — a per-cell cache of online photo
  // lookups so repeat visits to the same place don't re-hit Wikimedia.
  // Cell key is the quantized lat/lon (3 decimals ≈ ~110 m at the
  // equator). Also additive — existing data untouched.
  // v4 (0.14.1): adds `idx_pings_ts_fix`, a PARTIAL covering index on
  // (ts_utc, lat, lon) WHERE lat/lon IS NOT NULL. The map only ever draws
  // fixes, so its range read (`PingDao.fixesByDateRange`) walks fix rows
  // alone, and `latestSuccessful` stops scanning every no_fix row of a
  // stationary streak. Index-only — no row data changes. `ANALYZE` runs
  // once after the step so the planner has row estimates for it.
  // v5 (0.16.0): Google Maps Timeline import bookkeeping. Adds
  // `pings.import_id` (nullable FK, no `REFERENCES`/cascade — imports can
  // be deleted independently of the pings table's own FK-off convention,
  // see `PingPhotoDao`'s comment on the same tradeoff) plus a new
  // `imports` table (one row per completed import: hash for re-import
  // dedupe, thinning preset, row count, ts range for the "undo last
  // import" flow) and a partial index on `pings.import_id` so
  // `deleteByImportId`/`countByImportId` don't scan the whole table.
  // Additive — existing rows get `import_id = NULL`.
  static const _schemaVersion = 5;

  /// Cached handle for the UI isolate. Kept as a `Future` (not a resolved
  /// `Database`) so parallel first-callers all await the same open — avoids
  /// the race where four FutureProviders each trigger their own open.
  static Future<Database>? _shared;

  /// Absolute path to the SQLCipher DB file. Exposed so the rekey /
  /// recovery flows can reason about "does a DB already exist?" without
  /// duplicating the path logic.
  static Future<String> dbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, dbFileName);
  }

  /// Open (or create) the encrypted DB. Caller owns the returned handle and
  /// is responsible for `close()`. Use in background isolates only — in the
  /// UI isolate use [shared] to avoid concurrent-open races on the same file.
  ///
  /// Throws [PassphraseNeededException] when passphrase mode is active
  /// (salt file present) but no key is stored in secure storage yet — i.e.
  /// the auto-backup restore path before the user has re-entered their
  /// passphrase. Throws [KeyMissingException] when a DB file exists but
  /// there is neither a key nor a salt to re-derive one — the recovery
  /// screen (`/recover`) owns that case.
  static Future<Database> open() async {
    final passphrase = await KeystoreKey.getOrCreate();
    if (passphrase == null) throw const PassphraseNeededException();
    return _openWithKey(passphrase);
  }

  /// Open the DB with an explicit key. Used by the unlock flow to
  /// validate a freshly-derived passphrase before persisting it — if
  /// the key is wrong, SQLCipher surfaces `file is not a database`
  /// on the first query and the caller can retry the prompt.
  static Future<Database> openWithKey(String passphrase) =>
      _openWithKey(passphrase);

  /// One-shot "does this key open the log?" probe: open, run the cheapest
  /// query that forces SQLCipher to touch a page, close. Returns normally
  /// on success and throws whatever SQLCipher raised otherwise — a wrong
  /// key surfaces as `file is not a database` on the first query, not on
  /// the open.
  ///
  /// The unlock/recovery flows must not persist a key they have not
  /// proven, so this is deliberately the only thing that happens before
  /// `KeystoreKey.persist`. The handle is closed in a `finally`: leaving
  /// a second connection open on the same file races the shared handle's
  /// key derivation (see `_openWithKey`).
  static Future<void> openWithKeyForVerification(String passphrase) async {
    final db = await _openWithKey(passphrase);
    try {
      await db.rawQuery('SELECT count(*) FROM pings');
    } finally {
      await db.close();
    }
  }

  static Future<Database> _openWithKey(String passphrase) async {
    final path = await dbPath();
    final db = await openDatabase(
      path,
      password: passphrase,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async {
        // WAL mode — concurrent reader/writer support so the
        // WorkManager worker's per-tick insert doesn't block UI
        // queries on the same path. SQLCipher 3+ supports WAL; the
        // PRAGMA runs *after* the encryption key is provided so the
        // mode-switch operates on the unlocked DB. Idempotent on
        // every open.
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      // `singleInstance: true` (sqflite's default) makes the platform
      // plugin return the *same* native database handle whenever
      // openDatabase is called for the same path — even from a
      // different isolate. The WorkManager worker opens the DB at
      // every cadence tick and closes it in a `finally`, which would
      // then tear down the UI isolate's shared handle: the next
      // `recentPingsProvider` query fails with "database is closed".
      // Each isolate gets its own native handle now; close-in-worker
      // no longer touches the UI's.
      singleInstance: false,
    );
    escrowKeyAfterOpen(passphrase);
    return db;
  }

  /// Mirror [passphrase] into Trail's own key escrow, fire-and-forget.
  ///
  /// Called only once `openDatabase` has returned — SQLCipher surfaces a
  /// wrong key as a throw on the first query, so "the open succeeded" is
  /// the only proof we get that this key really decrypts this file, and
  /// escrowing an unverified key would just enshrine a bad one.
  ///
  /// Deliberately **not awaited**: the escrow is a hedge, not a
  /// dependency, and the open path is on the startup critical path
  /// (gotcha 30 — two awaits, everything else post-frame).
  /// [KeyEscrow.mirrorAfterOpen] swallows every failure, including the
  /// `MissingPluginException` the WorkManager isolate raises because our
  /// channel handler lives in `MainActivity` and that isolate has none.
  @visibleForTesting
  static void escrowKeyAfterOpen(String passphrase) {
    unawaited(KeyEscrow.instance.mirrorAfterOpen(passphrase));
  }

  /// UI-isolate handle. Memoised on first call — subsequent callers share the
  /// same `Database`. Never `close()` this handle; it lives for the app's
  /// lifetime.
  ///
  /// Throws [PassphraseNeededException] under the same conditions as
  /// [open]. Callers should catch the exception at a provider boundary
  /// and route the user to `/unlock`.
  static Future<Database> shared() => _shared ??= open();

  /// Call after the user has unlocked the DB with their passphrase, or
  /// after a rekey. Closes the current shared handle (if any) and drops
  /// the memoised reference so the next [shared] call re-opens with
  /// whatever key is now in secure storage.
  ///
  /// Closing the handle matters for rekey in particular: sqflite's
  /// `singleInstance: true` (default) makes `openDatabase` return the
  /// already-open shared Database, which means the rekey's
  /// `finally { db.close() }` would otherwise tear down the handle
  /// every UI provider is still holding a Dart reference to — next query
  /// from the home screen hits "database_closed".
  static Future<void> invalidateShared() async {
    final s = _shared;
    _shared = null;
    if (s == null) return;
    try {
      final db = await s;
      await db.close();
    } catch (_) {
      // Handle may already be closed, or its open Future may have failed
      // with PassphraseNeededException — either way there's nothing to
      // close and swallowing is safe.
    }
  }

  /// Moves the current `trail.db` (and its `-wal` / `-shm` siblings)
  /// aside as `trail.db.locked-<yyyyMMdd-HHmm>` so [open] is free to
  /// create a fresh, empty log. **Nothing is deleted** — the encrypted
  /// bytes stay on the phone, so a user who later recovers their key (or
  /// hands the file to a developer) can still get the history back.
  ///
  /// Returns the new file name, or `null` when there was no DB to move.
  /// Used by the `/recover` screen's "Start a new log" action; the shared
  /// handle is dropped first so no open file descriptor survives the
  /// rename.
  static Future<String?> setAsideForRecovery({DateTime? now}) async {
    final path = await dbPath();
    final file = File(path);
    if (!await file.exists()) return null;
    await invalidateShared();
    final dir = p.dirname(path);
    final name = lockedDbName(now ?? DateTime.now());
    await file.rename(p.join(dir, name));
    for (final suffix in const ['-wal', '-shm']) {
      final sibling = File('$path$suffix');
      if (await sibling.exists()) {
        await sibling.rename(p.join(dir, '$name$suffix'));
      }
    }
    return name;
  }

  /// The set-aside logs still on disk, newest name first. Surfaced on the
  /// diagnostics screen so a "Start a new log" recovery never becomes an
  /// invisible pile of megabytes.
  static Future<List<LockedLog>> lockedAsideLogs() async {
    try {
      final dir = Directory(p.dirname(await dbPath()));
      if (!await dir.exists()) return const [];
      final out = <LockedLog>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!isLockedDbName(name)) continue;
        out.add((name: name, bytes: await entity.length()));
      }
      out.sort((a, b) => b.name.compareTo(a.name));
      return out;
    } catch (_) {
      // Diagnostics must never throw on a storage hiccup.
      return const [];
    }
  }

  /// Re-encrypts the DB in-place with a new passphrase. Used by the
  /// "set up backup passphrase" flow to migrate from the Keystore-random
  /// key to a user-derived key without rewriting every row. SQLCipher's
  /// `PRAGMA rekey` does the work page-by-page atomically.
  ///
  /// Caller must pass the current key (whatever `open()` returned at
  /// startup) so this method can open a handle; after rekey completes,
  /// the new key should be persisted via [KeystoreKey.persist] and
  /// [invalidateShared] called so subsequent reads use the new key.
  static Future<void> rekey({
    required String currentKey,
    required String newKey,
  }) async {
    final path = await dbPath();
    final db = await openDatabase(
      path,
      password: currentKey,
      // Independent native handle — see `_openWithKey` for the
      // singleInstance rationale. Rekey closes its own handle in
      // the finally block below; that close must not propagate.
      singleInstance: false,
    );
    try {
      // SQLCipher doesn't parameterise PRAGMA values, but newKey comes
      // from our own base64url-encoded PBKDF2 output — no user text
      // reaches this string unescaped. Still: escape any quotes as a
      // belt-and-braces against a future change to key format.
      final escaped = newKey.replaceAll("'", "''");
      await db.rawQuery("PRAGMA rekey = '$escaped'");
    } finally {
      await db.close();
    }
  }

  /// Test-only hook: drop the cached handle so the next `shared()` re-opens.
  @visibleForTesting
  static void resetSharedForTest() {
    _shared = null;
  }

  /// Test-only hook: make [shared] resolve to [db] (an in-memory
  /// `sqflite_common_ffi` handle) so Riverpod providers that go through
  /// `TrailDatabase.shared()` can be exercised without SQLCipher or the
  /// Keystore. Pair with [resetSharedForTest] in `tearDown`.
  @visibleForTesting
  static void useSharedForTest(Database db) {
    _shared = Future.value(db);
  }

  /// Test-only: run the production `onCreate` DDL against an arbitrary
  /// handle. The migration tests exercise the real statements rather than
  /// a hand-mirrored copy (the DAO tests still mirror the schema — gotcha
  /// 20 — because they predate this hook and assert against it).
  @visibleForTesting
  static Future<void> createSchemaForTest(Database db) =>
      _onCreate(db, _schemaVersion);

  /// Test-only: run the production `onUpgrade` chain from [from] up to
  /// the current [_schemaVersion] against an arbitrary handle.
  @visibleForTesting
  static Future<void> upgradeSchemaForTest(Database db, {required int from}) =>
      _onUpgrade(db, from, _schemaVersion);

  /// Test-only: the schema version `openDatabase` is asked for.
  @visibleForTesting
  static int get schemaVersionForTest => _schemaVersion;

  /// Runs SQLite's `PRAGMA integrity_check`. A healthy DB returns a single
  /// row `{ 'integrity_check': 'ok' }`; anything else is a corruption
  /// signal (the result set lists every malformed index / orphaned row).
  /// Used by the diagnostics screen so the user can verify the encrypted
  /// DB isn't silently corrupt without reaching for adb.
  ///
  /// Uses the shared UI handle, not a fresh one — a second SQLCipher
  /// connection on the same file races key derivation (see the 0.1.3
  /// bug note in CLAUDE.md).
  static Future<List<String>> integrityCheck() async {
    final db = await shared();
    final rows = await db.rawQuery('PRAGMA integrity_check');
    return rows
        .map((r) => r.values.first?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static Future<void> _onCreate(Database db, int version) async {
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
        comment TEXT,
        import_id INTEGER
      );
    ''');
    await db.execute(
      'CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);',
    );
    await db.execute(_pingsTsFixIndexSql);
    await db.execute(_pingsImportIndexSql);
    await db.execute('''
      CREATE TABLE emergency_contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone_e164 TEXT NOT NULL
      );
    ''');
    await db.execute(_pingPhotosCreateSql);
    await db.execute(_pingPhotosIndexSql);
    await db.execute(_areaPhotosCreateSql);
    await db.execute(_areaPhotosIndexSql);
    await db.execute(_importsCreateSql);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // v1 → v2: add the "How is it?" comment column and the ping_photos
      // join table. Both are additive — existing rows stay untouched, the
      // new column defaults to NULL. Use a transaction so partial failure
      // doesn't leave the DB half-migrated (caller may retry on next open).
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE pings ADD COLUMN comment TEXT;');
        await txn.execute(_pingPhotosCreateSql);
        await txn.execute(_pingPhotosIndexSql);
      });
    }
    if (oldVersion < 3) {
      // v2 → v3: add the area_photos cell-cache. Backfills + per-ping
      // auto-fetch now check the cache first; only fresh cells round-
      // trip to Wikimedia. Additive — existing ping_photos rows are
      // untouched. Migration in its own transaction.
      await db.transaction((txn) async {
        await txn.execute(_areaPhotosCreateSql);
        await txn.execute(_areaPhotosIndexSql);
      });
    }
    if (oldVersion < 4) {
      // v3 → v4: partial covering index for the map's fixes-only read
      // and `latestSuccessful`. Index-only, so the only failure mode is
      // "index missing" — `IF NOT EXISTS` makes a retried migration a
      // no-op rather than an error. ANALYZE follows (outside the DDL
      // transaction, still inside sqflite's open transaction) so the
      // planner sees the new index's row count straight away instead of
      // guessing from defaults; it is the only ANALYZE the app ever runs.
      await db.transaction((txn) async {
        await txn.execute(_pingsTsFixIndexSql);
      });
      await db.execute('ANALYZE;');
    }
    if (oldVersion < 5) {
      // v4 → v5: Timeline import bookkeeping. SQLite's `ALTER TABLE ADD
      // COLUMN` has no `IF NOT EXISTS` form (unlike `CREATE TABLE` /
      // `CREATE INDEX`), so the column-existence check below is what
      // makes a retried migration a no-op instead of a "duplicate
      // column name" error; the new table and its index still lean on
      // `IF NOT EXISTS` like `idx_pings_ts_fix` (v4). Additive —
      // existing rows get `import_id = NULL`.
      await db.transaction((txn) async {
        final cols = await txn.rawQuery('PRAGMA table_info(pings)');
        final hasImportId = cols.any((c) => c['name'] == 'import_id');
        if (!hasImportId) {
          await txn.execute('ALTER TABLE pings ADD COLUMN import_id INTEGER;');
        }
        await txn.execute(_importsCreateSql);
        await txn.execute(_pingsImportIndexSql);
      });
    }
  }

  // ─── idx_pings_ts_fix (v4) ───────────────────────────────────────────
  //
  // Partial (only rows with a usable lat/lon — i.e. actual fixes) and
  // covering for the (ts_utc, lat, lon) triple. The map's read
  // (`PingDao.fixesByDateRange`) and `PingDao.latestSuccessful` carry the
  // identical `lat IS NOT NULL AND lon IS NOT NULL` predicate, which is
  // what lets SQLite's planner choose this index over `idx_pings_ts_utc`
  // (verified with EXPLAIN QUERY PLAN in `database_migration_test.dart`
  // and `ping_dao_test.dart`). The predicate text must stay byte-identical
  // between the index and the DAO queries — SQLite proves implication
  // syntactically, not semantically.
  static const _pingsTsFixIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_pings_ts_fix ON pings(ts_utc, lat, lon) '
      'WHERE lat IS NOT NULL AND lon IS NOT NULL;';

  // ─── ping_photos schema (v2) ─────────────────────────────────────────
  //
  // One row per photo attached to a ping. A pin can have many photos:
  //   - online-fetched (source = 'wikimedia') auto-populated after each
  //     ping when the user has online-photos enabled.
  //   - user-supplied (source = 'user_camera' / 'user_gallery') attached
  //     explicitly via the gallery sheet's "Add your photo" entry.
  //
  // `uri` is the absolute resolvable URL (https://... for online,
  // file://... for user). `attribution` + `license` are required for
  // online (Wikimedia Commons license terms); user photos store the
  // empty string. `fetched_at` is the wall-clock time the photo was
  // discovered/captured, not the photo's own timestamp.
  // `ordinal` is the display order in the gallery, 0-indexed.
  static const _pingPhotosCreateSql = '''
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
  ''';

  static const _pingPhotosIndexSql =
      'CREATE INDEX idx_ping_photos_ping_id ON ping_photos(ping_id);';

  // ─── area_photos schema (v3) ─────────────────────────────────────────
  //
  // Per-cell cache of Wikimedia Commons photo lookups. A cell is the
  // (lat, lon) pair rounded to 3 decimals (~110 m at the equator). The
  // cache lets repeat visits to the same place reuse the photo set
  // without re-hitting Wikimedia, and each ping inside a cell gets a
  // rotated slice of the cached photos so picture-mode playback shows
  // variety across visits to the same spot.
  //
  // `(cell_lat, cell_lon)` is not declared UNIQUE — concurrent first-
  // visits could insert duplicates, but the lookup query stays correct
  // either way. The dispatcher writes inside a transaction that re-
  // checks for an existing entry first, so duplicates are rare in
  // practice. A future cleanup migration can dedupe if needed.
  static const _areaPhotosCreateSql = '''
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
  ''';

  static const _areaPhotosIndexSql =
      'CREATE INDEX idx_area_photos_cell ON area_photos(cell_lat, cell_lon);';

  // ─── imports schema (v5) ───────────────────────────────────────────
  //
  // One row per completed Timeline import batch. `file_hash` (sha256 of
  // the first 1 MiB + ':' + the file's byte length, computed by the
  // import service — this table just stores + uniquely constrains it)
  // is how a byte-identical re-import is refused outright. `preset` is
  // the thinning preset name (`normal` / `coarse` / `full`) the user
  // picked. `ts_min_utc` / `ts_max_utc` bound the imported rows' time
  // range for the preview + "undo last import" summary; both are
  // nullable because a batch could in principle contain zero fix rows
  // (shouldn't happen in practice — every kept candidate has a
  // timestamp — but the columns don't assume it).
  static const _importsCreateSql = '''
    CREATE TABLE IF NOT EXISTS imports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      imported_at_utc INTEGER NOT NULL,
      file_name TEXT,
      file_hash TEXT NOT NULL UNIQUE,
      preset TEXT NOT NULL,
      row_count INTEGER NOT NULL,
      ts_min_utc INTEGER,
      ts_max_utc INTEGER
    );
  ''';

  // Partial index — only rows belonging to an import are worth indexing;
  // the vast majority of `pings` rows have `import_id IS NULL` and would
  // otherwise bloat the index for zero benefit. Serves
  // `PingDao.deleteByImportId` / `PingDao.countByImportId` (`EXPLAIN
  // QUERY PLAN` pinned in `database_migration_test.dart`).
  static const _pingsImportIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_pings_import ON pings(import_id) '
      'WHERE import_id IS NOT NULL;';
}
