import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/scheduler/workmanager_scheduler.dart';
import 'package:workmanager/workmanager.dart';

/// Swallows every platform call. Without it the enqueue paths below reach
/// `workmanager_linux` (endorsed since workmanager 0.10, and `flutter
/// test`'s host platform IS Linux), which writes real systemd user timers
/// into `~/.config/systemd/user`. Same `noSuchMethod` shape as the fake in
/// `workmanager_scheduler_marker_test.dart`.
class _NoopWorkmanagerPlatform
    with MockPlatformInterfaceMixin
    implements WorkmanagerPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// `WorkmanagerScheduler.initialize()` left the startup critical path in
/// 0.14.1 (it now runs in a post-first-frame callback), which only works
/// if (a) it is memoised so concurrent / repeated callers share one
/// native registration and (b) every enqueue path waits for it — the
/// lock screen's opportunistic `enqueuePeriodic` fires in the very same
/// post-frame phase. These tests pin both properties through the
/// `nativeInitialize` seam; there is no WorkManager platform
/// implementation under `flutter test`.
void main() {
  late int nativeCalls;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    WorkmanagerScheduler.resetInitializationForTest();
    nativeCalls = 0;
    WorkmanagerScheduler.nativeInitialize = () async {
      nativeCalls++;
    };
    // `Workmanager()`'s constructor resets `WorkmanagerPlatform.instance`
    // to the host implementation, so warm the singleton first and install
    // the no-op afterwards.
    Workmanager();
    WorkmanagerPlatform.instance = _NoopWorkmanagerPlatform();
  });

  tearDown(WorkmanagerScheduler.resetInitializationForTest);

  test('initialize is memoised — concurrent + repeat calls register once',
      () async {
    await Future.wait([
      WorkmanagerScheduler.initialize(),
      WorkmanagerScheduler.initialize(),
      WorkmanagerScheduler.initialize(),
    ]);
    await WorkmanagerScheduler.initialize();
    expect(nativeCalls, 1);
  });

  test('a failed initialize is not cached — the next call retries',
      () async {
    var attempts = 0;
    WorkmanagerScheduler.nativeInitialize = () async {
      attempts++;
      if (attempts == 1) throw StateError('plugin not ready');
    };
    await expectLater(WorkmanagerScheduler.initialize(), throwsStateError);
    await WorkmanagerScheduler.initialize();
    expect(attempts, 2);
  });

  test('enqueuePeriodic waits for initialize before touching the plugin',
      () async {
    final gate = Completer<void>();
    WorkmanagerScheduler.nativeInitialize = () => gate.future;
    var settled = false;
    // The register call goes to `_NoopWorkmanagerPlatform` and completes
    // immediately, so `settled` flipping is proof the gate opened — it can
    // only be reached *after* `initialize` resolves.
    final pending = WorkmanagerScheduler.enqueuePeriodic(
      frequency: const Duration(hours: 4),
    ).then<void>((_) => settled = true, onError: (_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse,
        reason: 'must not reach registerPeriodicTask before init completes');
    gate.complete();
    await pending;
    expect(settled, isTrue);
  });

  test('cancelAll + enqueueRetry + enqueueBoot are gated the same way',
      () async {
    final gate = Completer<void>();
    WorkmanagerScheduler.nativeInitialize = () => gate.future;
    var settled = 0;
    final futures = [
      WorkmanagerScheduler.cancelAll(),
      WorkmanagerScheduler.enqueueRetry(),
      WorkmanagerScheduler.enqueueBoot(),
    ].map((f) => f.then<void>((_) => settled++, onError: (_) => settled++));
    await Future<void>.delayed(Duration.zero);
    expect(settled, 0);
    gate.complete();
    await Future.wait(futures);
    expect(settled, 3);
  });
}
