import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/map/pin_geojson.dart';
import 'package:trail/widgets/full_map_panel.dart';

void main() {
  group('kPlaybackSpeeds', () {
    test(
        'exposes the 0.25, 0.5, 1, 2, 4, 8, 16, 64, 256, 1024, 4096 cycle '
        'in slow→fast order', () {
      expect(kPlaybackSpeeds, [
        0.25,
        0.5,
        1.0,
        2.0,
        4.0,
        8.0,
        16.0,
        64.0,
        256.0,
        1024.0,
        4096.0,
      ]);
    });

    test('cycle holds exactly 11 entries', () {
      expect(kPlaybackSpeeds.length, 11);
    });

    test('is strictly ascending', () {
      for (var i = 1; i < kPlaybackSpeeds.length; i++) {
        expect(kPlaybackSpeeds[i], greaterThan(kPlaybackSpeeds[i - 1]));
      }
    });
  });

  group('nextPlaybackSpeed', () {
    test('walks each step in order', () {
      expect(nextPlaybackSpeed(0.25), 0.5);
      expect(nextPlaybackSpeed(0.5), 1.0);
      expect(nextPlaybackSpeed(1.0), 2.0);
      expect(nextPlaybackSpeed(2.0), 4.0);
      expect(nextPlaybackSpeed(4.0), 8.0);
      expect(nextPlaybackSpeed(8.0), 16.0);
      expect(nextPlaybackSpeed(16.0), 64.0);
      expect(nextPlaybackSpeed(64.0), 256.0);
      expect(nextPlaybackSpeed(256.0), 1024.0);
      expect(nextPlaybackSpeed(1024.0), 4096.0);
    });

    test('wraps past 4096× back to 0.25×', () {
      expect(nextPlaybackSpeed(4096.0), 0.25);
    });

    test('snaps off-cycle inputs to the closest cycle entry first', () {
      // 0.3 is closer to 0.25 than to 0.5 → next is 0.5
      expect(nextPlaybackSpeed(0.3), 0.5);
      // 14 is closer to 16 than to 8 → next is 64
      expect(nextPlaybackSpeed(14.0), 64.0);
      // Equidistant between 8 and 16 → first-match wins (8) → next is 16
      expect(nextPlaybackSpeed(12.0), 16.0);
      // 700 is closer to 1024 than to 256 → next is 4096
      expect(nextPlaybackSpeed(700.0), 4096.0);
      // Beyond the new top of the cycle → snaps to 4096 → wraps
      expect(nextPlaybackSpeed(1000000.0), 0.25);
    });

    test('one full lap of the cycle returns to the slowest speed', () {
      var s = kPlaybackSpeeds.first;
      for (var i = 0; i < kPlaybackSpeeds.length; i++) {
        s = nextPlaybackSpeed(s);
      }
      expect(s, kPlaybackSpeeds.first);
    });
  });

  group('playbackInterval', () {
    const baseStep = Duration(milliseconds: 350);

    test('1× returns the base step', () {
      expect(playbackInterval(baseStep, 1.0),
          const Duration(milliseconds: 350));
    });

    test('2× halves the interval, 8× scales by 8', () {
      expect(playbackInterval(baseStep, 2.0),
          const Duration(milliseconds: 175));
      expect(playbackInterval(baseStep, 8.0),
          const Duration(milliseconds: 44));
    });

    test('16× on the 350 ms base step hits the 33 ms floor', () {
      // 350 / 16 ≈ 22 ms — below what a setFilter round-trip can apply
      // per frame, so it is clamped (0.14.0 raised the floor from 16).
      expect(playbackInterval(baseStep, 16.0),
          const Duration(milliseconds: 33));
    });

    test('0.5× doubles, 0.25× quadruples — within the clamp', () {
      expect(playbackInterval(baseStep, 0.5),
          const Duration(milliseconds: 700));
      expect(playbackInterval(baseStep, 0.25),
          const Duration(milliseconds: 1400));
    });

    test('clamps the floor at two display frames (33 ms)', () {
      // Speed so high the math would compute < 33 ms — clamp must catch it.
      expect(playbackInterval(baseStep, 1000.0),
          const Duration(milliseconds: 33));
    });

    test('clamps the ceiling at 4 s — slow speeds on tiny base steps', () {
      expect(playbackInterval(const Duration(milliseconds: 200), 0.001),
          const Duration(milliseconds: 4000));
    });

    test('defensive: speed=0 collapses to 1× rather than infinite interval',
        () {
      expect(playbackInterval(baseStep, 0),
          const Duration(milliseconds: 350));
    });
  });

  group('playbackStepsPerTick', () {
    const baseStep = Duration(milliseconds: 350);

    test('above the floor the timer carries the speed — one step per tick',
        () {
      // 350 / 1 = 350 ms, 350 / 8 = 44 ms: both above the 33 ms floor,
      // so the interval alone is still honest.
      expect(playbackStepsPerTick(baseStep, 0.25), 1);
      expect(playbackStepsPerTick(baseStep, 1.0), 1);
      expect(playbackStepsPerTick(baseStep, 2.0), 1);
      expect(playbackStepsPerTick(baseStep, 8.0), 1);
    });

    test('16× clamps, so the tick starts advancing more than one fix', () {
      // 350 / 16 = 21.9 ms → 33 / 21.9 = 1.51 → 2.
      expect(playbackStepsPerTick(baseStep, 16.0), 2);
    });

    test('64× advances 6 fixes per 33 ms tick (≈ 182 fixes/s)', () {
      // 350 / 64 = 5.47 ms → 33 / 5.47 = 6.03 → 6.
      expect(playbackStepsPerTick(baseStep, 64.0), 6);
    });

    test('256× advances 24 fixes per tick (≈ 727 fixes/s)', () {
      // 350 / 256 = 1.37 ms → 33 / 1.37 = 24.1 → 24.
      expect(playbackStepsPerTick(baseStep, 256.0), 24);
    });

    test('1024× advances 97 fixes per tick (≈ 2939 fixes/s)', () {
      // 350 / 1024 = 0.3418 ms → 33 / 0.3418 = 96.55 → 97.
      expect(playbackStepsPerTick(baseStep, 1024.0), 97);
    });

    test('4096× advances 386 fixes per tick (≈ 11 697 fixes/s)', () {
      // 350 / 4096 = 0.0854 ms → 33 / 0.0854 = 386.19 → 386.
      expect(playbackStepsPerTick(baseStep, 4096.0), 386);
    });

    test('faster speeds never advance fewer fixes than slower ones', () {
      var previous = 0;
      for (final s in kPlaybackSpeeds) {
        final steps = playbackStepsPerTick(baseStep, s);
        expect(steps, greaterThanOrEqualTo(previous), reason: 'speed $s');
        previous = steps;
      }
    });

    test(
        'gotcha 23 regression: 16×, 64× and 256× no longer run at the '
        'same pace', () {
      // Same clamped interval for all three — the whole point is that
      // the step count is what now differs.
      expect(playbackInterval(baseStep, 16.0),
          playbackInterval(baseStep, 256.0));
      final steps = [16.0, 64.0, 256.0]
          .map((s) => playbackStepsPerTick(baseStep, s))
          .toList();
      expect(steps.toSet().length, 3, reason: '$steps');
    });

    test('a custom floor moves the threshold', () {
      // With a 100 ms floor even 4× (87.5 ms) still fits in one tick;
      // 8× (43.75 ms) does not.
      const floor = Duration(milliseconds: 100);
      expect(playbackStepsPerTick(baseStep, 2.0, floor: floor), 1);
      expect(playbackStepsPerTick(baseStep, 4.0, floor: floor), 1);
      expect(playbackStepsPerTick(baseStep, 8.0, floor: floor), 2);
    });

    test('never returns less than 1 — a zero-step tick would stall', () {
      for (final s in [0.001, 0.25, 1.0, 1e6]) {
        expect(playbackStepsPerTick(baseStep, s), greaterThanOrEqualTo(1));
      }
    });

    test('defensive: speed <= 0 collapses to 1×; zero base/floor → 1', () {
      expect(playbackStepsPerTick(baseStep, 0), 1);
      expect(playbackStepsPerTick(baseStep, -4), 1);
      expect(playbackStepsPerTick(Duration.zero, 256.0), 1);
      expect(playbackStepsPerTick(baseStep, 256.0, floor: Duration.zero), 1);
    });
  });

  group('playbackTickPlan', () {
    const baseStep = Duration(milliseconds: 350);

    // Fixes per second the plan actually produces.
    double rate(({int steps, Duration interval}) p) =>
        p.steps / (p.interval.inMilliseconds / 1000);

    test('1× — one step on the plain base interval', () {
      final p = playbackTickPlan(baseStep, 1.0);
      expect(p.steps, 1);
      expect(p.interval, const Duration(milliseconds: 350));
    });

    test('16× — 2 steps every 44 ms, not 2 every 33 ms', () {
      // 2 × 350 / 16 = 43.75 → 44 ms. The steps-only version left this
      // at the 33 ms floor and ran a third too fast.
      final p = playbackTickPlan(baseStep, 16.0);
      expect(p.steps, 2);
      expect(p.interval, const Duration(milliseconds: 44));
      expect(p.interval, isNot(playbackInterval(baseStep, 16.0)));
    });

    test('64× — 6 steps every 33 ms', () {
      // 6 × 350 / 64 = 32.8 → 33 ms (also the floor).
      final p = playbackTickPlan(baseStep, 64.0);
      expect(p.steps, 6);
      expect(p.interval, const Duration(milliseconds: 33));
    });

    test('256× — 24 steps every 33 ms', () {
      // 24 × 350 / 256 = 32.8 → 33 ms.
      final p = playbackTickPlan(baseStep, 256.0);
      expect(p.steps, 24);
      expect(p.interval, const Duration(milliseconds: 33));
    });

    test('1024× — 97 steps every 33 ms', () {
      // 97 × 350 / 1024 = 33.15 → 33 ms.
      final p = playbackTickPlan(baseStep, 1024.0);
      expect(p.steps, 97);
      expect(p.interval, const Duration(milliseconds: 33));
    });

    test('4096× — 386 steps every 33 ms', () {
      // 386 × 350 / 4096 = 32.98 → 33 ms.
      final p = playbackTickPlan(baseStep, 4096.0);
      expect(p.steps, 386);
      expect(p.interval, const Duration(milliseconds: 33));
    });

    test('the effective pace is the nominal speed, within 2%', () {
      // One step per base step is 1× by definition: 1000 / 350 fixes/s.
      const unitRate = 1000 / 350;
      for (final speed in kPlaybackSpeeds) {
        final actual = rate(playbackTickPlan(baseStep, speed));
        final nominal = unitRate * speed;
        expect((actual - nominal).abs() / nominal, lessThan(0.02),
            reason: '$speed×: $actual fixes/s vs nominal $nominal');
      }
    });

    test('16× really is 16× — the pre-fix plan was ~21×', () {
      final actual = rate(playbackTickPlan(baseStep, 16.0));
      // Old behaviour: 2 steps on the clamped 33 ms interval.
      final oldWay = 2 / (playbackInterval(baseStep, 16.0).inMilliseconds / 1000);
      expect(actual, closeTo(1000 / 350 * 16, 1.0));
      expect(oldWay, greaterThan(actual * 1.3));
    });

    test('below the floor the plan is exactly playbackInterval', () {
      for (final speed in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]) {
        final p = playbackTickPlan(baseStep, speed);
        expect(p.steps, 1, reason: '$speed');
        expect(p.interval, playbackInterval(baseStep, speed), reason: '$speed');
      }
    });

    test('steps always match playbackStepsPerTick', () {
      for (final speed in kPlaybackSpeeds) {
        expect(playbackTickPlan(baseStep, speed).steps,
            playbackStepsPerTick(baseStep, speed),
            reason: '$speed');
      }
    });

    test('the interval never drops below the floor or above 4 s', () {
      for (final speed in [...kPlaybackSpeeds, 1e6]) {
        final ms = playbackTickPlan(baseStep, speed).interval.inMilliseconds;
        expect(ms, greaterThanOrEqualTo(33), reason: '$speed');
        expect(ms, lessThanOrEqualTo(4000), reason: '$speed');
      }
      // Slow speed on a tiny base step still hits the ceiling.
      expect(playbackTickPlan(const Duration(milliseconds: 200), 0.001).interval,
          const Duration(milliseconds: 4000));
    });

    test('a custom floor moves both halves of the plan', () {
      const floor = Duration(milliseconds: 100);
      final p = playbackTickPlan(baseStep, 8.0, floor: floor);
      // 350 / 8 = 43.75 ms → 100 / 43.75 = 2.29 → 2 steps,
      // re-timed to 2 × 43.75 = 87.5 → 88, clamped up to the 100 ms floor.
      expect(p.steps, 2);
      expect(p.interval, const Duration(milliseconds: 100));
    });

    test('defensive: speed <= 0 and a zero base step collapse to 1×', () {
      expect(playbackTickPlan(baseStep, 0),
          (steps: 1, interval: const Duration(milliseconds: 350)));
      expect(playbackTickPlan(baseStep, -4),
          (steps: 1, interval: const Duration(milliseconds: 350)));
      expect(playbackTickPlan(Duration.zero, 256.0).steps, 1);
    });

    test(
        'end-of-list clamp: a 1024×/4096× step size never overshoots or '
        'skips the final index', () {
      // `_stepFrom` in the panel wraps exactly this primitive
      // (`stepIndex`) with `plan.steps` as the delta — a short trail
      // near the end of playback must land ON the last fix, not run
      // off the end of the list or skip past it.
      final ts = Int64List.fromList(List<int>.generate(10, (i) => i * 1000));
      for (final speed in [1024.0, 4096.0]) {
        final steps = playbackStepsPerTick(baseStep, speed);
        expect(stepIndex(ts, ts[5], steps), ts.length - 1, reason: '$speed×');
        // Already sitting on the last index: clamps in place rather
        // than throwing or wrapping around to the front.
        expect(stepIndex(ts, ts.last, steps), ts.length - 1, reason: '$speed×');
      }
    });
  });

  group('formatPlaybackSpeedLabel', () {
    test('integer speeds drop the decimal', () {
      expect(formatPlaybackSpeedLabel(1.0), '1×');
      expect(formatPlaybackSpeedLabel(2.0), '2×');
      expect(formatPlaybackSpeedLabel(16.0), '16×');
      expect(formatPlaybackSpeedLabel(64.0), '64×');
      expect(formatPlaybackSpeedLabel(256.0), '256×');
      expect(formatPlaybackSpeedLabel(1024.0), '1024×');
      expect(formatPlaybackSpeedLabel(4096.0), '4096×');
    });

    test('0.5 renders as 0.5×, not 0.50×', () {
      expect(formatPlaybackSpeedLabel(0.5), '0.5×');
    });

    test('0.25 renders as 0.25×, not 0.3× (aliasing guard)', () {
      expect(formatPlaybackSpeedLabel(0.25), '0.25×');
    });

    test('every cycle entry produces a unique label', () {
      final labels =
          kPlaybackSpeeds.map(formatPlaybackSpeedLabel).toSet();
      expect(labels.length, kPlaybackSpeeds.length,
          reason: 'two speeds collapsing to the same label would make '
              'the HUD chip silently lie about which speed is active');
    });
  });
}
