import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/bounded_map.dart';

void main() {
  group('mapBounded', () {
    test('results come back in input order even when later items finish '
        'first', () async {
      final items = [5, 4, 3, 2, 1];
      final out = await mapBounded(
        items,
        (ms) async {
          await Future<void>.delayed(Duration(milliseconds: ms));
          return 'done-$ms';
        },
        maxConcurrent: 5,
      );
      expect(out, ['done-5', 'done-4', 'done-3', 'done-2', 'done-1']);
    });

    test('never has more than maxConcurrent calls in flight', () async {
      final gates = List.generate(6, (_) => Completer<int>());
      final started = <int>[];
      final result = mapBounded(
        List.generate(6, (i) => i),
        (i) {
          started.add(i);
          return gates[i].future;
        },
        maxConcurrent: 3,
      );
      // Workers start synchronously up to the cap.
      expect(started, [0, 1, 2]);

      gates[1].complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3], reason: 'one slot freed → one more start');

      gates[0].complete(0);
      gates[2].complete(2);
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3, 4, 5]);

      for (var i = 3; i < 6; i++) {
        gates[i].complete(i);
      }
      expect(await result, [0, 1, 2, 3, 4, 5]);
    });

    test('empty input resolves to an empty list without calling fn',
        () async {
      var calls = 0;
      final out = await mapBounded<int, int>(
        const [],
        (i) async => calls++,
        maxConcurrent: 4,
      );
      expect(out, isEmpty);
      expect(calls, 0);
    });

    test('a cap larger than the list starts everything at once', () async {
      var inFlight = 0, peak = 0;
      await mapBounded(
        [1, 2, 3],
        (i) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          inFlight--;
          return i;
        },
        maxConcurrent: 100,
      );
      expect(peak, 3);
    });

    test('an error from fn propagates', () async {
      expect(
        mapBounded(
          [1, 2, 3],
          (i) async {
            if (i == 2) throw StateError('boom');
            return i;
          },
          maxConcurrent: 2,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a non-positive cap', () {
      expect(
        () => mapBounded([1], (i) async => i, maxConcurrent: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
