import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/scheduler/scheduler_policy.dart';

/// Covers the two pure decision seams added for PERF_PLAN §3 #12
/// (background worker efficiency): whether the periodic WorkManager task
/// needs re-registering this tick, and whether the in-worker Wikimedia
/// auto-photo fetch is safe to run this tick.
void main() {
  group('SchedulerPolicy.shouldReenqueuePeriodic', () {
    test('re-enqueues when no marker has ever been recorded (null)', () {
      expect(
        SchedulerPolicy.shouldReenqueuePeriodic(
          effective: const Duration(hours: 4),
          lastEnqueuedMinutes: null,
        ),
        isTrue,
      );
    });

    test('does NOT re-enqueue when the marker matches the effective cadence',
        () {
      expect(
        SchedulerPolicy.shouldReenqueuePeriodic(
          effective: const Duration(hours: 4),
          lastEnqueuedMinutes: 240,
        ),
        isFalse,
      );
    });

    test('re-enqueues when the marker differs from the effective cadence',
        () {
      // e.g. low-battery doubled 4h -> 8h since the marker was written.
      expect(
        SchedulerPolicy.shouldReenqueuePeriodic(
          effective: const Duration(hours: 8),
          lastEnqueuedMinutes: 240,
        ),
        isTrue,
      );
    });

    test('re-enqueues on a cadence downgrade too (8h marker, 4h effective)',
        () {
      expect(
        SchedulerPolicy.shouldReenqueuePeriodic(
          effective: const Duration(hours: 4),
          lastEnqueuedMinutes: 480,
        ),
        isTrue,
      );
    });

    test('matches at every cadence option, not just the default', () {
      for (final c in PingCadence.values) {
        expect(
          SchedulerPolicy.shouldReenqueuePeriodic(
            effective: c.value,
            lastEnqueuedMinutes: c.minutes,
          ),
          isFalse,
          reason: '${c.label} should be a no-op re-enqueue check',
        );
      }
    });
  });

  group('SchedulerPolicy.shouldAutoFetchPhotos', () {
    test('wifi always qualifies regardless of charging state', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'wifi',
          isCharging: false,
        ),
        isTrue,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'wifi',
          isCharging: true,
        ),
        isTrue,
      );
    });

    test('ethernet always qualifies regardless of charging state', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'ethernet',
          isCharging: false,
        ),
        isTrue,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'ethernet',
          isCharging: true,
        ),
        isTrue,
      );
    });

    test('mobile only qualifies while charging', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'mobile',
          isCharging: true,
        ),
        isTrue,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'mobile',
          isCharging: false,
        ),
        isFalse,
      );
    });

    test('none never qualifies, charging or not', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'none',
          isCharging: true,
        ),
        isFalse,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'none',
          isCharging: false,
        ),
        isFalse,
      );
    });

    test('unknown never qualifies, charging or not', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'unknown',
          isCharging: true,
        ),
        isFalse,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: 'unknown',
          isCharging: false,
        ),
        isFalse,
      );
    });

    test('null network state never qualifies, charging or not', () {
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: null,
          isCharging: true,
        ),
        isFalse,
      );
      expect(
        SchedulerPolicy.shouldAutoFetchPhotos(
          networkState: null,
          isCharging: false,
        ),
        isFalse,
      );
    });
  });
}
