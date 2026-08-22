import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/scheduler/workmanager_scheduler.dart';
import 'package:workmanager/workmanager.dart';

/// `enqueuePeriodic` writes `trail_scheduler_last_enqueued_min_v1` right
/// after `registerPeriodicTask` succeeds (PERF_PLAN §3 #12 part B), so the
/// periodic tick can skip a redundant re-registration when the cadence
/// hasn't changed (`SchedulerPolicy.shouldReenqueuePeriodic`, tested in
/// `scheduler_worker_policy_test.dart`).
///
/// Under `flutter test` `WorkmanagerPlatform.instance` defaults to a
/// placeholder that throws `UnimplementedError` on every method (see
/// `workmanager_scheduler_init_test.dart`), so `registerPeriodicTask`
/// never actually succeeds there. Here we install a fake
/// `WorkmanagerPlatform` (the package's own plugin-platform-interface
/// pattern — extend without overriding the constructor, which mints a
/// valid verification token automatically) so the call succeeds and the
/// marker write is genuinely exercised end to end.
class _FakeWorkmanagerPlatform extends WorkmanagerPlatform {
  Duration? lastFrequency;

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
  }) async {
    lastFrequency = frequency;
  }
}

void main() {
  late _FakeWorkmanagerPlatform fakePlatform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkmanagerScheduler.resetInitializationForTest();
    // Skip the real native `initialize` round-trip — same seam
    // `workmanager_scheduler_init_test.dart` uses.
    WorkmanagerScheduler.nativeInitialize = () async {};
    fakePlatform = _FakeWorkmanagerPlatform();
    WorkmanagerPlatform.instance = fakePlatform;
  });

  tearDown(WorkmanagerScheduler.resetInitializationForTest);

  test('lastEnqueuedMinutes is null before anything has been enqueued',
      () async {
    expect(await WorkmanagerScheduler.lastEnqueuedMinutes(), isNull);
  });

  test('enqueuePeriodic records the effective cadence in minutes on success',
      () async {
    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: const Duration(hours: 4),
    );
    expect(fakePlatform.lastFrequency, const Duration(hours: 4));
    expect(await WorkmanagerScheduler.lastEnqueuedMinutes(), 240);
  });

  test('a later call with a different cadence overwrites the marker',
      () async {
    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: const Duration(hours: 4),
    );
    await WorkmanagerScheduler.enqueuePeriodic(
      frequency: const Duration(hours: 8),
    );
    expect(await WorkmanagerScheduler.lastEnqueuedMinutes(), 480);
  });
}
