import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'keystore_key.dart';

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
  static const _fileName = 'trail.db';
  static const _schemaVersion = 1;

  /// Cached handle for the UI isolate. Kept as a `Future` (not a resolved
  /// `Database`) so parallel first-callers all await the same open — avoids
  /// the race where four FutureProviders each trigger their own open.
  static Future<Database>? _shared;

  /// Absolute path to the SQLCipher DB file. Exposed so the rekey /
  /// recovery flows can reason about "does a DB already exist?" without
  /// duplicating the path logic.
  static Future<String> dbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  /// Open (or create) the encrypted DB. Caller owns the returned handle and
  /// is responsible for `close()`. Use in background isolates only — in the
  /// UI isolate use [shared] to avoid concurrent-open races on the same file.
  ///
  /// Throws [PassphraseNeededException] when passphrase mode is active
  /// (salt file present) but no key is stored in secure storage yet — i.e.
  /// the auto-backup restore path before the user has re-entered their
  /// passphrase.
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

  static Future<Database> _openWithKey(String passphrase) async {
    final path = await dbPath();
    return openDatabase(
      path,
      password: passphrase,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
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
    final db = await openDatabase(path, password: currentKey);
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
        note TEXT
      );
    ''');
    await db.execute(
      'CREATE INDEX idx_pings_ts_utc ON pings(ts_utc DESC);',
    );
    await db.execute('''
      CREATE TABLE emergency_contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone_e164 TEXT NOT NULL
      );
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // No-op in Phase 1 — schema is v1. Future phases append new tables /
    // ALTER statements here, guarded by oldVersion checks.
  }
}
