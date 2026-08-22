import 'package:sqflite_sqlcipher/sqflite.dart';

/// One row per completed Google Maps Timeline import batch (schema v5,
/// 0.16.0). `fileHash` is the sha256 of the file's first 1 MiB + `':'` +
/// the file's byte length, computed by the import service — this class
/// just carries it and the `imports.file_hash` column enforces
/// uniqueness so a byte-identical re-import is refused at the DB layer.
class ImportRecord {
  final int? id;
  final DateTime importedAtUtc;
  final String? fileName;
  final String fileHash;
  final String preset;
  final int rowCount;
  final DateTime? tsMinUtc;
  final DateTime? tsMaxUtc;

  const ImportRecord({
    this.id,
    required this.importedAtUtc,
    this.fileName,
    required this.fileHash,
    required this.preset,
    required this.rowCount,
    this.tsMinUtc,
    this.tsMaxUtc,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'imported_at_utc': importedAtUtc.toUtc().millisecondsSinceEpoch,
        'file_name': fileName,
        'file_hash': fileHash,
        'preset': preset,
        'row_count': rowCount,
        'ts_min_utc': tsMinUtc?.toUtc().millisecondsSinceEpoch,
        'ts_max_utc': tsMaxUtc?.toUtc().millisecondsSinceEpoch,
      };

  factory ImportRecord.fromMap(Map<String, Object?> m) => ImportRecord(
        id: m['id'] as int?,
        importedAtUtc: DateTime.fromMillisecondsSinceEpoch(
          m['imported_at_utc'] as int,
          isUtc: true,
        ),
        fileName: m['file_name'] as String?,
        fileHash: m['file_hash'] as String,
        preset: m['preset'] as String,
        rowCount: (m['row_count'] as num).toInt(),
        tsMinUtc: (m['ts_min_utc'] as num?) != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (m['ts_min_utc'] as num).toInt(),
                isUtc: true,
              )
            : null,
        tsMaxUtc: (m['ts_max_utc'] as num?) != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (m['ts_max_utc'] as num).toInt(),
                isUtc: true,
              )
            : null,
      );
}

/// CRUD for the `imports` table (schema v5). Stateless — same convention
/// as [PingDao]: pass in a `Database` per call, no cached handle.
///
/// `insert` relies on SQLite's own `UNIQUE(file_hash)` constraint to
/// refuse a byte-identical re-import: a conflicting insert surfaces as a
/// `DatabaseException` (sqflite's default `ConflictAlgorithm` is
/// `ConflictAlgorithm.none`, i.e. SQLite's own `ABORT`) rather than a
/// typed result. Callers that want a friendly "already imported" message
/// should check [byHash] first — that's also the natural place to fetch
/// the existing record for the message.
class ImportDao {
  final Database db;
  ImportDao(this.db);

  /// Inserts one import record. Returns the new row id. Throws
  /// [DatabaseException] if [record]'s `fileHash` collides with an
  /// existing row.
  Future<int> insert(ImportRecord record) async {
    final map = record.toMap()..remove('id');
    return db.insert('imports', map);
  }

  /// The previous import with this exact file hash, or `null` if this
  /// file has never been imported before.
  Future<ImportRecord?> byHash(String fileHash) async {
    final rows = await db.query(
      'imports',
      where: 'file_hash = ?',
      whereArgs: [fileHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ImportRecord.fromMap(rows.first);
  }

  /// Most-recently-completed import, or `null` on a fresh install / no
  /// imports yet. Feeds the "Undo last import" action.
  Future<ImportRecord?> latest() async {
    final rows = await db.query(
      'imports',
      orderBy: 'imported_at_utc DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ImportRecord.fromMap(rows.first);
  }

  /// Every import record, newest first.
  Future<List<ImportRecord>> all() async {
    final rows = await db.query('imports', orderBy: 'imported_at_utc DESC');
    return rows.map(ImportRecord.fromMap).toList();
  }

  /// Deletes one import record. Does NOT delete the `pings` rows it
  /// produced — callers pair this with `PingDao.deleteByImportId` (undo)
  /// or leave the pings in place and only drop the bookkeeping row.
  /// Returns the deleted row count (0 or 1).
  Future<int> delete(int id) async {
    return db.delete('imports', where: 'id = ?', whereArgs: [id]);
  }
}
