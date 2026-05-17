import 'package:flutter_test/flutter_test.dart';
import 'package:trail/widgets/full_map_panel.dart';

void main() {
  group('kPlaybackSpeeds', () {
    test('exposes the 0.25, 0.5, 1, 2, 4, 8, 16 cycle in slow→fast order',
        () {
      expect(kPlaybackSpeeds, [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]);
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
    });

    test('wraps past 16× back to 0.25×', () {
      expect(nextPlaybackSpeed(16.0), 0.25);
    });

    test('snaps off-cycle inputs to the closest cycle entry first', () {
      // 0.3 is closer to 0.25 than to 0.5 → next is 0.5
      expect(nextPlaybackSpeed(0.3), 0.5);
      // 14 is closer to 16 than to 8 → wraps to 0.25
      expect(nextPlaybackSpeed(14.0), 0.25);
      // Equidistant between 8 and 16 → first-match wins (8) → next is 16
      expect(nextPlaybackSpeed(12.0), 16.0);
    });
  });

  group('playbackInterval', () {
    const baseStep = Duration(milliseconds: 350);

    test('1× returns the base step', () {
      expect(playbackInterval(baseStep, 1.0),
          const Duration(milliseconds: 350));
    });

    test('2× halves the interval, 16× scales by 16', () {
      expect(playbackInterval(baseStep, 2.0),
          const Duration(milliseconds: 175));
      expect(playbackInterval(baseStep, 16.0),
          const Duration(milliseconds: 22));
    });

    test('0.5× doubles, 0.25× quadruples — within the clamp', () {
      expect(playbackInterval(baseStep, 0.5),
          const Duration(milliseconds: 700));
      expect(playbackInterval(baseStep, 0.25),
          const Duration(milliseconds: 1400));
    });

    test('clamps the floor at one display frame (16 ms)', () {
      // Speed so high the math would compute < 16 ms — clamp must catch it.
      expect(playbackInterval(baseStep, 1000.0),
          const Duration(milliseconds: 16));
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

  group('formatPlaybackSpeedLabel', () {
    test('integer speeds drop the decimal', () {
      expect(formatPlaybackSpeedLabel(1.0), '1×');
      expect(formatPlaybackSpeedLabel(2.0), '2×');
      expect(formatPlaybackSpeedLabel(16.0), '16×');
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
