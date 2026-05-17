import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/widgets/full_map_panel.dart';

Ping _p(int seconds) => Ping(
      timestampUtc: DateTime.utc(2026, 5, 17, 0, 0, seconds),
      lat: 1,
      lon: 2,
      source: PingSource.scheduled,
    );

void main() {
  group('choosePathRenderStrategy — filter / mode change always wipes', () {
    test('null prev key → fromScratch (first render after reset)', () {
      final out = choosePathRenderStrategy(
        prevRenderKey: null,
        currentRenderKey: 'path|null|null|true',
        prev: null,
        visible: [_p(1), _p(2)],
      );
      expect(out, PathRenderStrategy.fromScratch);
    });

    test('different key → fromScratch (this is the #2 bug fix)', () {
      // A pre-filter render at key K1; user picks a date range → K2.
      // Without the wipe, leftover circles from K1 would persist.
      final visible = [_p(10), _p(11)];
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'path|2026-05-01|2026-05-07|true',
        prev: visible,
        visible: visible,
      );
      expect(out, PathRenderStrategy.fromScratch);
    });

    test('mode flip (path→heatmap) → fromScratch', () {
      final visible = [_p(1)];
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'heatmap|null|null|true',
        prev: visible,
        visible: visible,
      );
      expect(out, PathRenderStrategy.fromScratch);
    });
  });

  group('choosePathRenderStrategy — same key, incremental paths', () {
    test('appending fixes → incrementalForward', () {
      final base = [_p(1), _p(2)];
      final extended = [base[0], base[1], _p(3)];
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'path|null|null|true',
        prev: base,
        visible: extended,
      );
      expect(out, PathRenderStrategy.incrementalForward);
    });

    test('truncating fixes → incrementalBackward', () {
      final base = [_p(1), _p(2), _p(3)];
      final shorter = [base[0], base[1]];
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'path|null|null|true',
        prev: base,
        visible: shorter,
      );
      expect(out, PathRenderStrategy.incrementalBackward);
    });

    test('identical list (same length, same identity) → noOp', () {
      final list = [_p(1), _p(2)];
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'path|null|null|true',
        prev: list,
        visible: list,
      );
      expect(out, PathRenderStrategy.noOp);
    });

    test('same length but different identity → fromScratch', () {
      // A fresh DAO read with the same range returns different Ping
      // instances; treat as a full rebuild rather than risk a stale-by-
      // identity incremental.
      final a = [_p(1), _p(2)];
      final b = [_p(1), _p(2)]; // identical content, different identity
      final out = choosePathRenderStrategy(
        prevRenderKey: 'path|null|null|true',
        currentRenderKey: 'path|null|null|true',
        prev: a,
        visible: b,
      );
      expect(out, PathRenderStrategy.fromScratch);
    });

    test('empty visible or empty prev → fromScratch', () {
      expect(
        choosePathRenderStrategy(
          prevRenderKey: 'k',
          currentRenderKey: 'k',
          prev: [_p(1)],
          visible: const [],
        ),
        PathRenderStrategy.fromScratch,
      );
      expect(
        choosePathRenderStrategy(
          prevRenderKey: 'k',
          currentRenderKey: 'k',
          prev: const [],
          visible: [_p(1)],
        ),
        PathRenderStrategy.fromScratch,
      );
    });
  });
}
