import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/scheduler/workmanager_scheduler.dart';
import 'package:workmanager/workmanager.dart';

/// `enqueuePeriodic` writes `trail_scheduler_last_enqueued_min_v1` right
/// after `registerPeriodicTask` succeeds (PERF_PLAN §3 #12 part B), so the
/// periodic tick can skip a redundant re-registration when the cadence
/// hasn't changed (`SchedulerPolicy.shouldReenqueuePeriodic`, tested in
/// `scheduler_worker_policy_test.dart`).
///
/// Under `flutter test` the host platform is Linux, and workmanager 0.10
/// endorses `workmanager_linux` — whose `registerPeriodicTask` writes a
/// real systemd **user timer** to `~/.config/systemd/user`. So we install
/// a fake `WorkmanagerPlatform` (the package's own
/// plugin-platform-interface pattern — extend without overriding the
/// constructor, which mints a valid verification token automatically):
/// the call succeeds, the marker write is genuinely exercised end to end,
/// and the developer's session manager is left alone.
class _FakeWorkmanagerPlatform
    with MockPlatformInterfaceMixin
    implements WorkmanagerPlatform {
  Duration? lastFrequency;

  // `noSuchMethod` instead of a hand-written override: the platform
  // interface grows optional named parameters between minor versions
  // (0.9.x added `foregroundServiceConfig`), and pubspec.lock is not
  // committed, so an explicit signature is a compile error waiting to
  // happen on CI / a fresh worktree. Every call succeeds; only
  // `registerPeriodicTask`'s `frequency` is recorded.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #registerPeriodicTask) {
      lastFrequency = invocation.namedArguments[#frequency] as Duration?;
    }
    return Future<void>.value();
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
    // Construct the `Workmanager()` singleton BEFORE installing the fake:
    // its private constructor runs `_ensurePlatformImplementation`, which
    // overwrites `WorkmanagerPlatform.instance` with the host (Linux)
    // implementation. It only runs once per isolate, so warming it here
    // means the fake below survives.
    Workmanager();
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
