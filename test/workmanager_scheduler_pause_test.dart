import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/panic/panic_service.dart';
import 'package:trail/services/scheduler/worker_run_log.dart';
import 'package:trail/services/scheduler/workmanager_scheduler.dart';
import 'package:trail/services/startup_gates.dart';

/// `_callbackDispatcher` itself is not directly testable — it is a
/// top-level closure `Workmanager().executeTask` invokes natively, and
/// there is no WorkManager platform implementation under `flutter test`
/// (see the seam notes in `workmanager_scheduler_init_test.dart`). The
/// startup-blocked guard it runs first is extracted into two plain
/// functions instead — [shouldPauseWorker] and
/// [pauseWorkerForStartupFailure] — so the pause behaviour can be pinned
/// without driving the dispatcher.
void main() {
  group('shouldPauseWorker', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('false when the flag has never been set', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(shouldPauseWorker(prefs), isFalse);
    });

    test('true once the startup-blocked flag is set', () async {
      SharedPreferences.setMockInitialValues({startupBlockedKey: true});
      final prefs = await SharedPreferences.getInstance();
      expect(shouldPauseWorker(prefs), isTrue);
    });

    test('false once the flag is cleared again', () async {
      SharedPreferences.setMockInitialValues({startupBlockedKey: false});
      final prefs = await SharedPreferences.getInstance();
      expect(shouldPauseWorker(prefs), isFalse);
    });
  });

  group('pauseWorkerForStartupFailure', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('records a "paused" WorkerRunLog entry and reports success',
        () async {
      final result =
          await pauseWorkerForStartupFailure(WorkmanagerScheduler.periodicTaskName);
      expect(result, isTrue);

      final runs = await WorkerRunLog.recent();
      expect(runs, hasLength(1));
      expect(runs.single.task, WorkmanagerScheduler.periodicTaskName);
      expect(runs.single.outcome, 'paused');
      expect(runs.single.note, contains('startup failed on last launch'));
    });

    test('the panic task is paused the same way — no DB-free sub-path exists',
        () async {
      final result =
          await pauseWorkerForStartupFailure(PanicService.panicTaskName);
      expect(result, isTrue);
      final runs = await WorkerRunLog.recent();
      expect(runs.single.task, PanicService.panicTaskName);
      expect(runs.single.outcome, 'paused');
    });
  });
}
