/// The Google Maps Timeline import's parsing isolate.
///
/// Everything expensive about an import — the byte-level split, the JSON
/// decode of every element, the mappers, the sort, the thinning and the
/// dedupe — runs here, off the UI isolate. **The worker never touches
/// the database** (CLAUDE.md gotcha 1): when it needs to know which
/// fixes Trail already has, it sends the file's time range to the main
/// isolate and waits for the rows to come back.
///
/// The protocol is plain `Map`/`List` only, so nothing here depends on
/// Flutter and every message survives the `SendPort` copy.
///
/// ```
/// main -> worker : {cmd: 'parse',    path, preset}
///                  {cmd: 'existing', fixes: [[ts, lat, lon], …]}
///                  {cmd: 'commit'} | {cmd: 'cancel'} | {cmd: 'shutdown'}
/// worker -> main : {type: 'ready',    port}
///                  {type: 'progress', bytes, total, counts}      (<= 10 Hz)
///                  {type: 'range',    tsMin, tsMax, candidates}
///                  {type: 'preview',  projection, counts, frequentPlaces,
///                                     byYear, fileTsMin, fileTsMax}
///                  {type: 'batch',    rows: [[ts,lat,lon,acc,alt,speed,note]]}
///                  {type: 'done',     rows, cancelled}
///                  {type: 'error',    message}
/// ```
///
/// After `preview` the worker keeps the kept-candidate list in memory,
/// so `commit` streams it straight out without re-reading the file.
///
/// `byYear` is the per-year audit the preview card renders — one row
/// `[year, inFile, kept, duplicates, path, visits, activities, raw,
/// firstMs, lastMs]`, newest year first (see [yearBreakdown]) — and
/// `fileTsMin`/`fileTsMax` are the first/last candidate in the WHOLE
/// file, before thinning, which is how the screen can say "the export
/// covers 2019–2026" even for the years it kept nothing from.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'import_thinning.dart';
import 'timeline_mappers.dart';
import 'timeline_models.dart';
import 'timeline_splitter.dart';

/// Rows per `batch` message. The DAO chunks its `Batch.commit` at 500;
/// this is the isolate-hop granularity, sized so a 100k-row import is
/// ~50 messages rather than 200.
const int kImportBatchRows = 2000;

/// Minimum gap between `progress` messages (<= 10 Hz).
const int kImportProgressIntervalMs = 100;

/// Message the worker sends when a `cancel` lands mid-parse.
const String kImportCancelledMessage = 'Import cancelled';

/// Isolate entry point. Spawn with
/// `Isolate.spawn(timelineImportWorker, receivePort.sendPort)`.
@pragma('vm:entry-point')
void timelineImportWorker(SendPort toMain) {
  final rp = ReceivePort();
  final worker = _ImportWorker(toMain);
  toMain.send(<String, Object?>{'type': 'ready', 'port': rp.sendPort});
  rp.listen((dynamic message) {
    if (message is! Map) return;
    switch (message['cmd']) {
      case 'parse':
        // Not awaited: `existing` has to be received *while* this runs.
        unawaited(worker.parse(
          message['path'] as String,
          message['preset'] as String,
        ));
      case 'existing':
        worker.provideExisting(message['fixes']);
      case 'commit':
        unawaited(worker.commit());
      case 'cancel':
        worker.cancel();
      case 'shutdown':
        rp.close();
    }
  });
}

class _ImportWorker {
  _ImportWorker(this._toMain);

  final SendPort _toMain;

  Completer<List<ExistingFix>>? _existing;
  List<ImportCandidate>? _kept;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    // Unblock a parse that is waiting on the main isolate's fixes.
    final pending = _existing;
    if (pending != null && !pending.isCompleted) {
      pending.complete(const <ExistingFix>[]);
    }
  }

  void provideExisting(Object? raw) {
    final pending = _existing;
    if (pending == null || pending.isCompleted) return;
    final fixes = <ExistingFix>[];
    if (raw is List) {
      for (final row in raw) {
        if (row is! List || row.length < 3) continue;
        fixes.add(ExistingFix(
          tsUtcMs: (row[0] as num).toInt(),
          lat: (row[1] as num).toDouble(),
          lon: (row[2] as num).toDouble(),
        ));
      }
    }
    pending.complete(fixes);
  }

  /// Parse -> map -> sort -> thin -> (ask main for existing fixes) ->
  /// dedupe -> preview. Never throws at the isolate boundary: every
  /// failure becomes an `error` message.
  Future<void> parse(String path, String presetName) async {
    _cancelled = false;
    _kept = null;
    try {
      final preset = ImportPreset.values.byName(presetName);
      final total = await File(path).length();
      final counts = ImportCounts();
      final candidates = <ImportCandidate>[];
      final places = <ImportFrequentPlace>[];
      var lastProgressMs = 0;
      var offset = 0;

      await for (final element in splitTimelineFile(path)) {
        if (_cancelled) {
          _send(<String, Object?>{
            'type': 'error',
            'message': kImportCancelledMessage,
          });
          return;
        }
        offset = element.endOffset;
        _mapElement(element, counts, candidates, places);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastProgressMs >= kImportProgressIntervalMs) {
          lastProgressMs = now;
          _progress(offset, total, counts);
        }
      }
      _progress(offset, total, counts);

      candidates.sort((a, b) => a.tsUtcMs.compareTo(b.tsUtcMs));
      final thinned = thinCandidates(candidates, preset);

      // The main isolate owns the DB (gotcha 1) — ask it for the fixes
      // Trail already has in this file's range.
      final pending = Completer<List<ExistingFix>>();
      _existing = pending;
      _send(<String, Object?>{
        'type': 'range',
        'tsMin': thinned.isEmpty ? null : thinned.first.tsUtcMs,
        'tsMax': thinned.isEmpty ? null : thinned.last.tsUtcMs,
        'candidates': candidates.length,
      });
      final existing = await pending.future;
      _existing = null;
      if (_cancelled) {
        _send(<String, Object?>{
          'type': 'error',
          'message': kImportCancelledMessage,
        });
        return;
      }

      final result = dedupeAgainstExisting(thinned, existing);
      final kept = result.kept;
      _kept = kept;
      // Computed here, where all three lists exist: the file's
      // candidates, the thinning survivors and the dedupe survivors.
      final byYear = yearBreakdown(
        candidates: candidates,
        keptBeforeDedupe: thinned,
        kept: kept,
      );
      _send(<String, Object?>{
        'type': 'preview',
        'projection': <String, Object?>{
          'candidates': candidates.length,
          'kept': kept.length,
          'duplicates': result.duplicates,
          'tsMin': kept.isEmpty ? null : kept.first.tsUtcMs,
          'tsMax': kept.isEmpty ? null : kept.last.tsUtcMs,
        },
        // `candidates` is sorted, so first/last is the file's own range.
        'fileTsMin': candidates.isEmpty ? null : candidates.first.tsUtcMs,
        'fileTsMax': candidates.isEmpty ? null : candidates.last.tsUtcMs,
        'byYear': <List<Object?>>[
          for (final row in byYear)
            <Object?>[
              row.year,
              row.candidatesInFile,
              row.keptAfterThinning,
              row.skippedAsDuplicate,
              row.pathPoints,
              row.visits,
              row.activities,
              row.rawPositions,
              row.firstTsUtcMs,
              row.lastTsUtcMs,
            ],
        ],
        'counts': counts.toJson(),
        'frequentPlaces': <Map<String, Object?>>[
          for (final p in places)
            <String, Object?>{'label': p.label, 'lat': p.lat, 'lon': p.lon},
        ],
      });
    } catch (e) {
      _send(<String, Object?>{'type': 'error', 'message': '$e'});
    }
  }

  /// Streams the kept candidates to the main isolate in batches. No
  /// re-parse: [parse] left them in memory.
  Future<void> commit() async {
    final kept = _kept;
    if (kept == null) {
      _send(<String, Object?>{
        'type': 'error',
        'message': 'No preview to commit',
      });
      return;
    }
    try {
      var sent = 0;
      for (var start = 0; start < kept.length; start += kImportBatchRows) {
        if (_cancelled) break;
        final end = math.min(start + kImportBatchRows, kept.length);
        _send(<String, Object?>{
          'type': 'batch',
          'rows': <List<Object?>>[
            for (var i = start; i < end; i++) _row(kept[i]),
          ],
        });
        sent = end;
        // Yield so a `cancel` posted while the previous batch was being
        // inserted lands before the next one goes out.
        await Future<void>.delayed(Duration.zero);
      }
      _send(<String, Object?>{
        'type': 'done',
        'rows': sent,
        'cancelled': _cancelled,
      });
    } catch (e) {
      _send(<String, Object?>{'type': 'error', 'message': '$e'});
    }
  }

  void _mapElement(
    TimelineElement element,
    ImportCounts counts,
    List<ImportCandidate> candidates,
    List<ImportFrequentPlace> places,
  ) {
    try {
      final decoded = decodeElement(element);
      if (decoded is! Map<String, dynamic>) {
        counts.ignoredElements++;
        return;
      }
      switch (element.section) {
        // The iOS dialect is a bare root array of semantic segments.
        case 'semanticSegments':
        case kTimelineRootSection:
          candidates.addAll(mapSemanticSegment(decoded, counts));
        case 'rawSignals':
          candidates.addAll(mapRawSignal(decoded, counts));
        case 'userLocationProfile':
          places.addAll(mapUserLocationProfile(decoded));
        default:
          // A section we don't know (format drift) — counted, never fatal.
          counts.ignoredElements++;
      }
    } catch (_) {
      counts.malformedElements++;
    }
  }

  void _progress(int bytes, int total, ImportCounts counts) {
    _send(<String, Object?>{
      'type': 'progress',
      'bytes': bytes,
      'total': total,
      'counts': counts.toJson(),
    });
  }

  List<Object?> _row(ImportCandidate c) => <Object?>[
        c.tsUtcMs,
        c.lat,
        c.lon,
        c.accuracyM,
        c.altitudeM,
        c.speedMps,
        c.note,
      ];

  void _send(Map<String, Object?> message) => _toMain.send(message);
}
