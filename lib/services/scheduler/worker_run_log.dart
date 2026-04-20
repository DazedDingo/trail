import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Rolling last-20 log of WorkManager-dispatcher runs.
///
/// Mirrors what `SchedulerEventsLog.kt` does for exact alarms — this one
/// lives on the Dart side because `_callbackDispatcher` in
/// `workmanager_scheduler.dart` is Dart, and it's where we can observe the
/// run's outcome (row inserted, no_fix, low-battery skip, retry enqueued).
/// The diagnostics screen reads these so the user can answer "did my 4h
/// worker fire 6h ago, or did the OS skip it entirely?" without adb.
///
/// Persisted in `SharedPreferences` under [_key] so the log survives app
/// kill — and so the UI isolate can read what the WorkManager isolate
/// wrote. SharedPreferences is safe from both isolates because the plugin
/// acquires an in-process lock per access; neither side caches.
class WorkerRunLog {
  static const _key = 'trail_worker_runs_v1';
  static const maxEntries = 20;

  /// Append an entry, trimming the oldest if we're at [maxEntries].
  static Future<void> record({
    required String task,
    required String outcome,
    String? note,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _read(prefs);
    list.insert(0, {
      'tsMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      'task': task,
      'outcome': outcome,
      if (note != null) 'note': note,
    });
    final trimmed = list.take(maxEntries).toList(growable: false);
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  /// Newest-first. Empty list on a fresh install.
  static Future<List<WorkerRun>> recent() async {
    final prefs = await SharedPreferences.getInstance();
    return _read(prefs).map(WorkerRun.fromJson).toList(growable: false);
  }

  static List<Map<String, dynamic>> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

/// One WorkManager dispatcher run, as seen by the Dart side.
class WorkerRun {
  final DateTime timestamp;
  /// Raw task name from the WorkManager callback (`trail_scheduled_ping`,
  /// `trail_retry_ping`, `trail_boot_ping`, `trail_panic`).
  final String task;
  /// `ok` (row written with coords), `no_fix` (row written with null
  /// coords — permission denied, timeout, etc.), `low_battery_skip`
  /// (policy skipped the fix), `error` (caught exception),
  /// `awaiting_passphrase` (DB locked post-restore).
  final String outcome;
  final String? note;

  const WorkerRun({
    required this.timestamp,
    required this.task,
    required this.outcome,
    this.note,
  });

  factory WorkerRun.fromJson(Map<String, dynamic> j) => WorkerRun(
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (j['tsMs'] as num).toInt(),
        ),
        task: j['task'] as String? ?? 'unknown',
        outcome: j['outcome'] as String? ?? 'unknown',
        note: j['note'] as String?,
      );
}
