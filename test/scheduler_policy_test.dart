import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/scheduler/scheduler_policy.dart';

Ping _noFix({String? note, int? batt}) => Ping(
      timestampUtc: DateTime.utc(2026, 4, 15),
      batteryPct: batt,
      source: PingSource.noFix,
      note: note,
    );

Ping _ok({int? batt, PingSource source = PingSource.scheduled}) => Ping(
      timestampUtc: DateTime.utc(2026, 4, 15),
      lat: 51.5,
      lon: -0.1,
      batteryPct: batt,
      source: source,
    );

void main() {
  group('SchedulerPolicy.shouldSkipForLowBattery', () {
    test('skips when battery is strictly under 5%', () {
      expect(SchedulerPolicy.shouldSkipForLowBattery(1), isTrue);
      expect(SchedulerPolicy.shouldSkipForLowBattery(4), isTrue);
    });

    test('does NOT skip at exactly 5% (threshold is <5, not <=5)', () {
      expect(SchedulerPolicy.shouldSkipForLowBattery(5), isFalse);
    });

    test('does NOT skip on null — sensor unavailable is not "dead"', () {
      expect(SchedulerPolicy.shouldSkipForLowBattery(null), isFalse);
    });

    test('does NOT skip on 0 — treated as unknown, not critical', () {
      // Some devices/emulators report 0 when the battery API isn't wired
      // up. Skipping on that would silently drop every ping on those
      // devices.
      expect(SchedulerPolicy.shouldSkipForLowBattery(0), isFalse);
    });

    test('full / high battery never triggers skip', () {
      expect(SchedulerPolicy.shouldSkipForLowBattery(50), isFalse);
      expect(SchedulerPolicy.shouldSkipForLowBattery(100), isFalse);
    });
  });

  group('SchedulerPolicy.nextCadence — default base (4h)', () {
    test('returns 8h when battery is strictly under 20%', () {
      expect(SchedulerPolicy.nextCadence(5), const Duration(hours: 8));
      expect(SchedulerPolicy.nextCadence(19), const Duration(hours: 8));
    });

    test('returns 4h at exactly 20% (threshold is <20, not <=20)', () {
      expect(SchedulerPolicy.nextCadence(20), const Duration(hours: 4));
    });

    test('returns 4h for healthy battery', () {
      expect(SchedulerPolicy.nextCadence(50), const Duration(hours: 4));
      expect(SchedulerPolicy.nextCadence(100), const Duration(hours: 4));
    });

    test('returns 4h on null — over-ping beats silent 8h downgrade', () {
      expect(SchedulerPolicy.nextCadence(null), const Duration(hours: 4));
    });

    test('returns 4h on 0 — unknown reading, not "nearly dead"', () {
      expect(SchedulerPolicy.nextCadence(0), const Duration(hours: 4));
    });

    test('low-battery branch still triggers when also below skip threshold',
        () {
      // battery=3 passes shouldSkipForLowBattery, but if the caller somehow
      // bypassed that check and asked for a cadence, we still want 8h —
      // never 4h.
      expect(SchedulerPolicy.nextCadence(3), const Duration(hours: 8));
    });
  });

  group('SchedulerPolicy.nextCadence — custom base (user cadence)', () {
    test('30min base stays at 30min on healthy battery', () {
      expect(
        SchedulerPolicy.nextCadence(60, base: PingCadence.min30.value),
        const Duration(minutes: 30),
      );
    });

    test('30min base doubles to 1h below 20% battery', () {
      expect(
        SchedulerPolicy.nextCadence(10, base: PingCadence.min30.value),
        const Duration(hours: 1),
      );
    });

    test('1h base doubles to 2h below 20% battery', () {
      expect(
        SchedulerPolicy.nextCadence(15, base: PingCadence.hour1.value),
        const Duration(hours: 2),
      );
    });

    test('null battery returns the base unchanged — no silent slowdown', () {
      expect(
        SchedulerPolicy.nextCadence(null, base: PingCadence.min30.value),
        const Duration(minutes: 30),
      );
    });
  });

  group('PingCadence enum', () {
    test('hour4 is the default (matches SchedulerPolicy.defaultCadence)', () {
      expect(PingCadence.hour4.value, SchedulerPolicy.defaultCadence);
    });

    test('fromWire falls back to hour4 on unknown / null input', () {
      expect(PingCadence.fromWire(null), PingCadence.hour4);
      expect(PingCadence.fromWire('garbage'), PingCadence.hour4);
    });

    test('fromWire round-trips every canonical wire form', () {
      for (final c in PingCadence.values) {
        expect(PingCadence.fromWire(c.wire), c);
      }
    });

    test('minutes getter matches the Duration', () {
      expect(PingCadence.min30.minutes, 30);
      expect(PingCadence.hour1.minutes, 60);
      expect(PingCadence.hour2.minutes, 120);
      expect(PingCadence.hour4.minutes, 240);
    });

    test('all cadences are ≥ 15 min (WorkManager periodic minimum)', () {
      for (final c in PingCadence.values) {
        expect(c.value >= const Duration(minutes: 15), isTrue,
            reason: '${c.label} would be rejected by WorkManager');
      }
    });
  });

  group('SchedulerPolicy.shouldRetry', () {
    test('no-fix with permission_denied note → retry', () {
      expect(
          SchedulerPolicy.shouldRetry(_noFix(note: 'permission_denied')),
          isTrue);
    });

    test('no-fix with no note → retry', () {
      expect(SchedulerPolicy.shouldRetry(_noFix()), isTrue);
    });

    test('no-fix that was a low-battery skip → NEVER retry', () {
      // Retrying would just re-skip and waste a wakeup.
      expect(
          SchedulerPolicy.shouldRetry(
              _noFix(note: SchedulerPolicy.skipNote)),
          isFalse);
    });

    test('scheduled (successful fix) → no retry', () {
      expect(SchedulerPolicy.shouldRetry(_ok()), isFalse);
    });

    test('panic source → no retry (panic has its own flow)', () {
      expect(
          SchedulerPolicy.shouldRetry(_ok(source: PingSource.panic)), isFalse);
    });

    test('boot source → no retry (boot already chains into scheduled)', () {
      expect(SchedulerPolicy.shouldRetry(_ok(source: PingSource.boot)),
          isFalse);
    });
  });

  group('SchedulerPolicy — threshold + constant invariants', () {
    test('skip threshold is strictly below low-battery threshold', () {
      // If these ever cross the battery-5/battery-20 test cases above would
      // silently become meaningless. Fail loudly instead.
      expect(SchedulerPolicy.skipBatteryThreshold,
          lessThan(SchedulerPolicy.lowBatteryThreshold));
    });

    test('nextCadence always stretches the base under low battery', () {
      // The invariant this replaces ("lowBatteryCadence > defaultCadence")
      // is now expressed as: for every supported base, low-battery
      // returns a strictly longer duration than the base itself.
      for (final c in PingCadence.values) {
        final stretched = SchedulerPolicy.nextCadence(10, base: c.value);
        expect(stretched, greaterThan(c.value),
            reason: 'low-battery must never shorten cadence for ${c.label}');
      }
    });

    test('skipNote is a stable string — export + shouldRetry both depend '
        'on this exact value', () {
      expect(SchedulerPolicy.skipNote, 'skipped_low_battery');
    });
  });

  group('SchedulerPolicy — WorkManager constraint invariants', () {
    // These are regression guards, not logic tests. If any of these flip to
    // true, Android WorkManager will silently defer our worker — exactly
    // when the user most needs the log (long hikes, draining batteries,
    // low storage during multi-day trips). SchedulerPolicy.skip/retry/
    // nextCadence is the ONLY allowed battery-throttling mechanism.
    test('requiresBatteryNotLow stays false — worker must run on low battery',
        () {
      expect(SchedulerPolicy.requiresBatteryNotLow, isFalse);
    });

    test('requiresCharging stays false — app runs untethered by design', () {
      expect(SchedulerPolicy.requiresCharging, isFalse);
    });

    test(
        'requiresDeviceIdle stays false — user could be actively using the '
        'phone and still want a ping logged', () {
      expect(SchedulerPolicy.requiresDeviceIdle, isFalse);
    });

    test(
        'requiresStorageNotLow stays false — encrypted DB grows slowly, '
        'blocking on storage pressure is the wrong call', () {
      expect(SchedulerPolicy.requiresStorageNotLow, isFalse);
    });

    test('requiresNetwork stays false — scheduled pings are offline-first',
        () {
      expect(SchedulerPolicy.requiresNetwork, isFalse);
    });
  });
}
