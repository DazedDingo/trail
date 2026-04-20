import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/scheduler/worker_run_log.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WorkerRunLog', () {
    test('recent() returns empty on a fresh install', () async {
      expect(await WorkerRunLog.recent(), isEmpty);
    });

    test('record() + recent() round-trips a single entry', () async {
      await WorkerRunLog.record(
        task: 'trail_scheduled_ping',
        outcome: 'ok',
        note: 'battery 42%',
      );
      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(1));
      expect(runs.single.task, 'trail_scheduled_ping');
      expect(runs.single.outcome, 'ok');
      expect(runs.single.note, 'battery 42%');
      // Timestamp within last 2s of now, in UTC.
      expect(
        DateTime.now().toUtc().difference(runs.single.timestamp).inSeconds,
        lessThan(2),
      );
    });

    test('note is optional and round-trips as null', () async {
      await WorkerRunLog.record(
        task: 'trail_retry_ping',
        outcome: 'no_fix',
      );
      final runs = await WorkerRunLog.recent();
      expect(runs.single.note, isNull);
    });

    test('recent() returns newest-first', () async {
      await WorkerRunLog.record(task: 'a', outcome: 'ok');
      await WorkerRunLog.record(task: 'b', outcome: 'ok');
      await WorkerRunLog.record(task: 'c', outcome: 'ok');
      final runs = await WorkerRunLog.recent();
      expect(runs.map((r) => r.task).toList(), ['c', 'b', 'a']);
    });

    test('trims to maxEntries (20), dropping oldest', () async {
      for (var i = 0; i < 25; i++) {
        await WorkerRunLog.record(task: 'task_$i', outcome: 'ok');
      }
      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(WorkerRunLog.maxEntries));
      // Newest is task_24, oldest surviving is task_5.
      expect(runs.first.task, 'task_24');
      expect(runs.last.task, 'task_5');
    });

    test('malformed JSON in prefs returns empty (no throw)', () async {
      SharedPreferences.setMockInitialValues({
        'trail_worker_runs_v1': 'not valid json {[',
      });
      expect(await WorkerRunLog.recent(), isEmpty);
    });

    test('non-list JSON in prefs returns empty', () async {
      SharedPreferences.setMockInitialValues({
        'trail_worker_runs_v1': jsonEncode({'oops': 'object, not list'}),
      });
      expect(await WorkerRunLog.recent(), isEmpty);
    });

    test('list with non-map entries is filtered out', () async {
      SharedPreferences.setMockInitialValues({
        'trail_worker_runs_v1': jsonEncode([
          'garbage',
          42,
          {'tsMs': 1700000000000, 'task': 't', 'outcome': 'ok'},
        ]),
      });
      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(1));
      expect(runs.single.task, 't');
    });

    test('WorkerRun.fromJson tolerates missing task/outcome (falls back)',
        () async {
      SharedPreferences.setMockInitialValues({
        'trail_worker_runs_v1': jsonEncode([
          {'tsMs': 1700000000000},
        ]),
      });
      final runs = await WorkerRunLog.recent();
      expect(runs.single.task, 'unknown');
      expect(runs.single.outcome, 'unknown');
    });

    test('recording after a trim keeps the newest 20 stable', () async {
      for (var i = 0; i < 20; i++) {
        await WorkerRunLog.record(task: 'fill_$i', outcome: 'ok');
      }
      await WorkerRunLog.record(task: 'new', outcome: 'ok');
      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(20));
      expect(runs.first.task, 'new');
      // fill_0 got pushed out, fill_1 is now the oldest.
      expect(runs.last.task, 'fill_1');
    });
  });
}
