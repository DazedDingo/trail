import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/screens/map_screen.dart';

Ping _p(int hour) => Ping(
      timestampUtc: DateTime.utc(2026, 4, 18, hour),
      lat: 54.0,
      lon: -2.0,
      source: PingSource.scheduled,
    );

Ping _pAt(DateTime ts) =>
    Ping(timestampUtc: ts, lat: 54.0, lon: -2.0, source: PingSource.scheduled);

void main() {
  group('stepSliderTo', () {
    test('advances forward through unique timestamps', () {
      final chrono = [_p(0), _p(4), _p(8), _p(12)];
      expect(
        stepSliderTo(chrono, chrono[0].timestampUtc, 1),
        chrono[1].timestampUtc,
      );
      expect(
        stepSliderTo(chrono, chrono[1].timestampUtc, 1),
        chrono[2].timestampUtc,
      );
    });

    test('clamps at the end so end-of-playback fires the stop guard', () {
      final chrono = [_p(0), _p(4), _p(8)];
      // Stepping past the end returns the last ts; the timer's
      // `next.isAfter(current)` check then equals false → stop.
      expect(
        stepSliderTo(chrono, chrono.last.timestampUtc, 1),
        chrono.last.timestampUtc,
      );
    });

    test('regression: advances past duplicate ts_utc mid-trail', () {
      // Two pings landed on the same millisecond — a panic burst, or a
      // retry that hit the scheduled cadence. Pre-fix, the playback
      // timer paused at the dupe because _stepTo returned the dupe's
      // own timestamp, which equals `current` and trips the stop guard.
      final dupe = DateTime.utc(2026, 4, 18, 8);
      final chrono = [
        _p(0),
        _p(4),
        _pAt(dupe),
        _pAt(dupe),
        _p(12),
        _p(16),
      ];
      // Standing on the first dupe, stepping forward must escape the
      // dupe pair, not return the same timestamp.
      final next = stepSliderTo(chrono, dupe, 1);
      expect(next.isAfter(dupe), isTrue,
          reason:
              'forward step from a duplicate-timestamp position must yield a strictly later ts');
      expect(next, chrono[4].timestampUtc);
    });

    test('handles long runs of identical timestamps', () {
      // 5 pings on the same ms (extreme but possible during a panic
      // burst followed by an immediate retry).
      final dupe = DateTime.utc(2026, 4, 18, 8);
      final chrono = [
        _p(0),
        for (var i = 0; i < 5; i++) _pAt(dupe),
        _p(12),
      ];
      // Stepping forward from any of the dupes should escape the run.
      final next = stepSliderTo(chrono, dupe, 1);
      expect(next, chrono.last.timestampUtc);
    });

    test('empty chrono is a no-op', () {
      final t = DateTime.utc(2026, 4, 18, 8);
      expect(stepSliderTo(const [], t, 1), t);
    });

    test('binary search (0.14.0) matches the original linear walk on '
        'random lists with duplicates, for every cursor and delta', () {
      // Reference: the pre-0.14 implementation, verbatim.
      DateTime linear(List<Ping> chrono, DateTime current, int delta) {
        if (chrono.isEmpty) return current;
        var idx = 0;
        for (var i = 0; i < chrono.length; i++) {
          if (chrono[i].timestampUtc.isAfter(current)) break;
          idx = i;
        }
        final target = (idx + delta).clamp(0, chrono.length - 1);
        return chrono[target].timestampUtc;
      }

      final rng = Random(7);
      for (var trial = 0; trial < 200; trial++) {
        final n = 1 + rng.nextInt(25);
        var minute = 0;
        final chrono = <Ping>[];
        for (var i = 0; i < n; i++) {
          minute += rng.nextInt(3); // 0 keeps duplicate stamps in play
          chrono.add(_pAt(DateTime.utc(2026, 4, 18, 0, minute)));
        }
        for (var m = -1; m <= minute + 1; m++) {
          final cursor = DateTime.utc(2026, 4, 18, 0, m);
          for (final delta in [-5, -1, 0, 1, 5]) {
            expect(
              stepSliderTo(chrono, cursor, delta),
              linear(chrono, cursor, delta),
              reason: 'n=$n cursor=$m delta=$delta',
            );
          }
        }
      }
    });

    group('±5 jump (0.13.7 — fast-forward/rewind buttons)', () {
      test('forward jump skips 5 pings', () {
        final chrono = [for (var i = 0; i < 10; i++) _p(i)];
        // Standing on ping[2] (hour 2), jump +5 should land on ping[7].
        expect(
          stepSliderTo(chrono, chrono[2].timestampUtc, 5),
          chrono[7].timestampUtc,
        );
      });

      test('backward jump skips 5 pings', () {
        final chrono = [for (var i = 0; i < 10; i++) _p(i)];
        expect(
          stepSliderTo(chrono, chrono[8].timestampUtc, -5),
          chrono[3].timestampUtc,
        );
      });

      test('forward jump near the end clamps at the last fix', () {
        final chrono = [for (var i = 0; i < 10; i++) _p(i)];
        // Standing on ping[7], jump +5 would overshoot to index 12 →
        // clamped to last (index 9).
        expect(
          stepSliderTo(chrono, chrono[7].timestampUtc, 5),
          chrono[9].timestampUtc,
        );
      });

      test('backward jump near the start clamps at the first fix', () {
        final chrono = [for (var i = 0; i < 10; i++) _p(i)];
        expect(
          stepSliderTo(chrono, chrono[2].timestampUtc, -5),
          chrono[0].timestampUtc,
        );
      });
    });
  });
}
