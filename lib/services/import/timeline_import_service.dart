/// Orchestrates a Google Maps Timeline import: the UI-isolate half of
/// the pipeline described in docs/TIMELINE_IMPORT.md.
///
/// Division of labour (CLAUDE.md gotcha 1): the worker isolate does all
/// the parsing and never opens the database; this service owns both DAOs
/// and answers the worker's one question ("which fixes do you already
/// have between X and Y?"). One isolate stays alive from [preview]
/// through [commit], so committing never re-reads the file; [dispose]
/// kills it (and a later call transparently spawns a new one).
///
/// Atomicity: [commit] writes the `imports` bookkeeping row first, then
/// streams batches into `PingDao.insertImportedBatch`. If anything fails
/// — a cancel, an insert error, a worker error — every row written for
/// that import id is deleted along with the record, so from the user's
/// point of view an import either happened or it didn't.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../db/import_dao.dart';
import '../../db/ping_dao.dart';
import '../../models/ping.dart';
import 'import_file_hash.dart';
import 'import_thinning.dart';
import 'timeline_import_worker.dart';
import 'timeline_models.dart';

/// Widening applied to the existing-fix read so a candidate at the very
/// edge of the file's range still sees the neighbour it duplicates —
/// same window `dedupeAgainstExisting` uses (±60 s).
const int kImportDedupeWindowMs = 60000;

/// Cap on the points handed to the map-coverage planner after an import.
/// The whole import can be 100k rows; the planner only needs enough to
/// find the clusters.
const int kImportMaxSamplePoints = 5000;

/// Anything the import could not do, surfaced with a message the screen
/// can show verbatim.
class ImportException implements Exception {
  const ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown by [TimelineImportService.preview] when this exact file has
/// already been imported (`imports.file_hash` hit). Carries the previous
/// record so the screen can offer "Undo that import".
class AlreadyImportedException implements Exception {
  const AlreadyImportedException(this.record);
  final ImportRecord record;
  @override
  String toString() =>
      'Already imported on ${record.importedAtUtc.toIso8601String()}';
}

/// Co-operative cancel flag, same shape as `TileDownloadCancelToken`.
class ImportCancelToken {
  bool isCancelled = false;
}

/// Which half of the import a progress event describes.
enum ImportPhase { parsing, inserting }

/// One progress tick. [current]/[total] are bytes while [ImportPhase.parsing]
/// and rows while [ImportPhase.inserting].
class ImportProgress {
  const ImportProgress({
    required this.phase,
    required this.current,
    this.total,
    this.counts,
  });

  final ImportPhase phase;
  final int current;
  final int? total;

  /// Live parse accounting; null during the insert phase.
  final ImportCounts? counts;

  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (current / t).clamp(0.0, 1.0);
  }
}

/// Dry-run result: what an import of this file at this preset would do.
class ImportPreview {
  const ImportPreview({
    required this.path,
    required this.fileName,
    required this.fileHash,
    required this.preset,
    required this.projection,
    required this.counts,
    required this.frequentPlaces,
  });

  final String path;
  final String fileName;
  final String fileHash;
  final ImportPreset preset;
  final ImportProjection projection;
  final ImportCounts counts;
  final List<ImportFrequentPlace> frequentPlaces;
}

/// Outcome of [TimelineImportService.commit].
class ImportResult {
  const ImportResult({
    required this.importId,
    required this.rows,
    this.cancelled = false,
    this.error,
    this.tsMinUtc,
    this.tsMaxUtc,
    this.sampledPoints = const [],
  });

  /// `imports.id` of the batch — `null` when nothing was recorded.
  final int? importId;
  final int rows;
  final bool cancelled;
  final String? error;
  final DateTime? tsMinUtc;
  final DateTime? tsMaxUtc;

  /// Stride-sampled subset (<= [kImportMaxSamplePoints]) of the rows that
  /// landed, for the map-coverage planner.
  final List<({double lat, double lon})> sampledPoints;

  bool get ok => !cancelled && error == null;
}

/// How the service starts its worker. Overridable so a test can inject a
/// fake isolate; the default spawns [timelineImportWorker].
typedef TimelineWorkerSpawn = Future<Isolate> Function(SendPort toService);

class TimelineImportService {
  TimelineImportService({
    required PingDao pingDao,
    required ImportDao importDao,
    TimelineWorkerSpawn? spawn,
  })  : _pings = pingDao,
        _imports = importDao,
        _spawn = spawn ?? _defaultSpawn;

  static Future<Isolate> _defaultSpawn(SendPort toService) => Isolate.spawn(
        timelineImportWorker,
        toService,
        debugName: 'trail-timeline-import',
      );

  final PingDao _pings;
  final ImportDao _imports;
  final TimelineWorkerSpawn _spawn;

  Isolate? _isolate;
  ReceivePort? _receive;
  Future<SendPort>? _worker;
  Completer<SendPort>? _ready;

  // Active operation state. Only one preview/commit runs at a time — the
  // screen's buttons are disabled while either is in flight.
  Completer<ImportPreview>? _previewCompleter;
  Completer<ImportResult>? _commitCompleter;
  void Function(ImportProgress)? _onProgress;
  ImportCancelToken? _cancelToken;
  String _path = '';
  String _hash = '';
  ImportPreset _preset = ImportPreset.normal;

  int? _importId;
  int _inserted = 0;
  int _expectedRows = 0;
  int _tsMin = 0;
  int _tsMax = 0;
  int _sampleStride = 1;
  int _sampleCursor = 0;
  final List<({double lat, double lon})> _sampled = [];
  Future<void> _inserts = Future<void>.value();
  Object? _insertError;

  // --- public API --------------------------------------------------------

  /// Dry-run: hash the file, refuse a re-import, then parse + thin +
  /// dedupe it in the worker and report what would happen.
  ///
  /// Throws [AlreadyImportedException] when this file's hash is already
  /// in `imports`, and [ImportException] for anything else (unreadable
  /// file, malformed document, cancel).
  Future<ImportPreview> preview(
    String path,
    ImportPreset preset, {
    void Function(ImportProgress)? onProgress,
    ImportCancelToken? cancelToken,
  }) async {
    if (_previewCompleter != null || _commitCompleter != null) {
      throw const ImportException('An import is already running');
    }
    final String hash;
    try {
      hash = await importFileHash(path);
    } on FileSystemException catch (e) {
      throw ImportException(
          'Could not read the file: ${e.osError?.message ?? e.message}');
    }
    final previous = await _imports.byHash(hash);
    if (previous != null) throw AlreadyImportedException(previous);

    final worker = await _ensureWorker();
    _path = path;
    _hash = hash;
    _preset = preset;
    _onProgress = onProgress;
    _cancelToken = cancelToken;
    final completer = Completer<ImportPreview>();
    _previewCompleter = completer;
    worker.send(<String, Object?>{
      'cmd': 'parse',
      'path': path,
      'preset': preset.name,
    });
    return completer.future;
  }

  /// Writes the previewed rows. All-or-nothing: on cancel or failure the
  /// rows and the bookkeeping record are removed again.
  Future<ImportResult> commit(
    ImportPreview preview, {
    void Function(ImportProgress)? onProgress,
    ImportCancelToken? cancelToken,
  }) async {
    if (_commitCompleter != null) {
      throw const ImportException('An import is already running');
    }
    final worker = await _ensureWorker();
    final int importId;
    try {
      importId = await _imports.insert(ImportRecord(
        importedAtUtc: DateTime.now().toUtc(),
        fileName: preview.fileName,
        fileHash: preview.fileHash,
        preset: preview.preset.name,
        rowCount: 0,
      ));
    } catch (e) {
      throw ImportException('Could not start the import: $e');
    }

    _onProgress = onProgress;
    _cancelToken = cancelToken;
    _importId = importId;
    _inserted = 0;
    _expectedRows = preview.projection.kept;
    _tsMin = 0;
    _tsMax = 0;
    _sampled.clear();
    _sampleCursor = 0;
    _sampleStride =
        math.max(1, (_expectedRows / kImportMaxSamplePoints).ceil());
    _inserts = Future<void>.value();
    _insertError = null;

    final completer = Completer<ImportResult>();
    _commitCompleter = completer;
    worker.send(<String, Object?>{'cmd': 'commit'});
    return completer.future;
  }

  /// Removes one import: its `pings` rows first, then the record.
  /// Returns the number of pings deleted.
  Future<int> undo(int importId) async {
    final rows = await _pings.deleteByImportId(importId);
    await _imports.delete(importId);
    return rows;
  }

  /// Every past import, newest first.
  Future<List<ImportRecord>> history() => _imports.all();

  /// Rows currently attributed to one import (the undo confirmation's
  /// "this will remove N pings").
  Future<int> rowCount(int importId) => _pings.countByImportId(importId);

  /// Kills the worker isolate. Safe to call more than once; the next
  /// [preview] spawns a fresh one.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
    _worker = null;
    _ready = null;
    _failActive('Import worker stopped');
  }

  // --- worker plumbing ---------------------------------------------------

  Future<SendPort> _ensureWorker() {
    final existing = _worker;
    if (existing != null) return existing;
    final spawned = _spawnWorker();
    _worker = spawned;
    return spawned.catchError((Object e) {
      _worker = null;
      throw ImportException('Could not start the import worker: $e');
    });
  }

  Future<SendPort> _spawnWorker() async {
    final rp = ReceivePort();
    _receive = rp;
    final ready = Completer<SendPort>();
    _ready = ready;
    rp.listen(_onMessage);
    _isolate = await _spawn(rp.sendPort);
    return ready.future;
  }

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['type']) {
      case 'ready':
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          ready.complete(raw['port'] as SendPort);
        }
      case 'progress':
        _onProgress?.call(ImportProgress(
          phase: ImportPhase.parsing,
          current: (raw['bytes'] as num?)?.toInt() ?? 0,
          total: (raw['total'] as num?)?.toInt(),
          counts: _countsFrom(raw['counts']),
        ));
      case 'range':
        unawaited(_answerRange(raw));
      case 'preview':
        _completePreview(raw);
      case 'batch':
        _enqueueInsert(raw['rows']);
      case 'done':
        unawaited(_finishCommit(raw));
      case 'error':
        _failActive('${raw['message']}');
    }
  }

  /// The worker asked which fixes Trail already has. This is the only
  /// DB read in the pipeline that the worker depends on, and it happens
  /// here, on the isolate that owns the handle.
  Future<void> _answerRange(Map<dynamic, dynamic> raw) async {
    try {
      final send = await _ensureWorker();
      final tsMin = (raw['tsMin'] as num?)?.toInt();
      final tsMax = (raw['tsMax'] as num?)?.toInt();
      var fixes = const <List<Object?>>[];
      if (tsMin != null && tsMax != null) {
        final rows = await _pings.existingFixesInRange(
          tsMin - kImportDedupeWindowMs,
          tsMax + kImportDedupeWindowMs,
        );
        fixes = <List<Object?>>[
          for (final r in rows) <Object?>[r.tsUtcMs, r.lat, r.lon],
        ];
      }
      send.send(<String, Object?>{'cmd': 'existing', 'fixes': fixes});
    } catch (e) {
      _failActive('Could not read existing pings: $e');
    }
  }

  void _completePreview(Map<dynamic, dynamic> raw) {
    final completer = _previewCompleter;
    if (completer == null || completer.isCompleted) return;
    _previewCompleter = null;
    final projection = raw['projection'] as Map;
    completer.complete(ImportPreview(
      path: _path,
      fileName: p.basename(_path),
      fileHash: _hash,
      preset: _preset,
      projection: ImportProjection(
        candidates: (projection['candidates'] as num).toInt(),
        kept: (projection['kept'] as num).toInt(),
        duplicates: (projection['duplicates'] as num).toInt(),
        tsMinUtcMs: (projection['tsMin'] as num?)?.toInt(),
        tsMaxUtcMs: (projection['tsMax'] as num?)?.toInt(),
      ),
      counts: _countsFrom(raw['counts']) ?? ImportCounts(),
      frequentPlaces: <ImportFrequentPlace>[
        for (final place in (raw['frequentPlaces'] as List? ?? const []))
          if (place is Map)
            ImportFrequentPlace(
              label: place['label'] as String? ?? 'UNKNOWN',
              lat: (place['lat'] as num).toDouble(),
              lon: (place['lon'] as num).toDouble(),
            ),
      ],
    ));
  }

  /// Batches are inserted strictly in order — chained rather than
  /// awaited inline, because `_onMessage` is a synchronous listener.
  void _enqueueInsert(Object? rows) {
    final importId = _importId;
    if (importId == null || rows is! List) return;
    if (_cancelToken?.isCancelled ?? false) {
      _cancelWorker();
      return;
    }
    final pings = <Ping>[];
    for (final row in rows) {
      if (row is! List || row.length < 7) continue;
      final ts = (row[0] as num).toInt();
      _tsMin = _tsMin == 0 ? ts : math.min(_tsMin, ts);
      _tsMax = math.max(_tsMax, ts);
      pings.add(Ping(
        timestampUtc: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
        lat: (row[1] as num).toDouble(),
        lon: (row[2] as num).toDouble(),
        accuracy: (row[3] as num?)?.toDouble(),
        altitude: (row[4] as num?)?.toDouble(),
        speed: (row[5] as num?)?.toDouble(),
        source: PingSource.imported,
        note: row[6] as String?,
        importId: importId,
      ));
    }
    _inserts = _inserts.then((_) async {
      if (_insertError != null) return;
      if (_cancelToken?.isCancelled ?? false) return;
      try {
        await _pings.insertImportedBatch(pings, importId: importId);
        _inserted += pings.length;
        for (final ping in pings) {
          if (_sampleCursor % _sampleStride == 0 &&
              _sampled.length < kImportMaxSamplePoints) {
            _sampled.add((lat: ping.lat!, lon: ping.lon!));
          }
          _sampleCursor++;
        }
        _onProgress?.call(ImportProgress(
          phase: ImportPhase.inserting,
          current: _inserted,
          total: _expectedRows,
        ));
      } catch (e) {
        _insertError = e;
      }
    });
  }

  Future<void> _finishCommit(Map<dynamic, dynamic> raw) async {
    final completer = _commitCompleter;
    if (completer == null || completer.isCompleted) return;
    _commitCompleter = null;
    final importId = _importId;
    _importId = null;
    await _inserts;

    final cancelled =
        (raw['cancelled'] == true) || (_cancelToken?.isCancelled ?? false);
    final error = _insertError;
    if (importId == null) {
      completer.complete(const ImportResult(importId: null, rows: 0));
      return;
    }
    if (cancelled || error != null) {
      await _rollback(importId);
      completer.complete(ImportResult(
        importId: null,
        rows: 0,
        cancelled: cancelled,
        error: error == null ? null : '$error',
      ));
      return;
    }

    final tsMin = _inserted == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(_tsMin, isUtc: true);
    final tsMax = _inserted == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(_tsMax, isUtc: true);
    await _finalizeRecord(
      importId,
      rows: _inserted,
      tsMin: tsMin,
      tsMax: tsMax,
    );
    completer.complete(ImportResult(
      importId: importId,
      rows: _inserted,
      tsMinUtc: tsMin,
      tsMaxUtc: tsMax,
      sampledPoints: List.unmodifiable(_sampled),
    ));
  }

  /// `ImportDao` is insert/read/delete only (it mirrors `PingDao`'s
  /// stateless style and has no update), so the one field the import
  /// back-fills — the row count and range it could not know before the
  /// insert — is written through the DAO's own handle.
  Future<void> _finalizeRecord(
    int importId, {
    required int rows,
    DateTime? tsMin,
    DateTime? tsMax,
  }) async {
    await _imports.db.update(
      'imports',
      <String, Object?>{
        'row_count': rows,
        'ts_min_utc': tsMin?.millisecondsSinceEpoch,
        'ts_max_utc': tsMax?.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [importId],
    );
  }

  Future<void> _rollback(int importId) async {
    try {
      await _pings.deleteByImportId(importId);
      await _imports.delete(importId);
    } catch (_) {
      // Nothing better to do: the record stays and the user can undo it
      // from Settings -> Timeline imports.
    }
  }

  void _cancelWorker() {
    final worker = _worker;
    if (worker == null) return;
    unawaited(worker.then(
      (send) => send.send(<String, Object?>{'cmd': 'cancel'}),
      onError: (Object _) {},
    ));
  }

  void _failActive(String message) {
    final preview = _previewCompleter;
    _previewCompleter = null;
    if (preview != null && !preview.isCompleted) {
      preview.completeError(ImportException(message));
    }
    final commit = _commitCompleter;
    _commitCompleter = null;
    final importId = _importId;
    _importId = null;
    if (commit != null && !commit.isCompleted) {
      if (importId != null) unawaited(_rollback(importId));
      commit.complete(ImportResult(
        importId: null,
        rows: 0,
        error: message,
      ));
    }
  }

  ImportCounts? _countsFrom(Object? raw) {
    if (raw is! Map) return null;
    int at(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return ImportCounts()
      ..pathPoints = at('pathPoints')
      ..visits = at('visits')
      ..activities = at('activities')
      ..rawPositions = at('rawPositions')
      ..ignoredElements = at('ignoredElements')
      ..malformedElements = at('malformedElements')
      ..rawRejectedAccuracy = at('rawRejectedAccuracy');
  }
}
