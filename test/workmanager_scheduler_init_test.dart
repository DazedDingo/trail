import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/scheduler/workmanager_scheduler.dart';

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
    WorkmanagerScheduler.resetInitializationForTest();
    nativeCalls = 0;
    WorkmanagerScheduler.nativeInitialize = () async {
      nativeCalls++;
    };
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
    // Without a platform implementation the register call itself throws
    // `UnimplementedError` — which is exactly the signal we want: it can
    // only be reached *after* the gate opens.
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
