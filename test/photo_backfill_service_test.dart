import 'package:flutter_test/flutter_test.dart';

import 'package:trail/models/ping.dart';
import 'package:trail/services/photo_backfill_service.dart';

Ping _p({
  required int id,
  double? lat = 51.5,
  double? lon = -0.1,
  PingSource source = PingSource.scheduled,
}) =>
    Ping(
      id: id,
      timestampUtc: DateTime.utc(2026, 5, 17),
      lat: lat,
      lon: lon,
      source: source,
    );

void main() {
  group('selectEligibleForBackfill', () {
    test('returns pings with coords + no wikimedia row', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1), _p(id: 2)],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [1, 2]);
    });

    test('skips pings that already have wikimedia photos', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1), _p(id: 2), _p(id: 3)],
        const {2},
      );
      expect(out.map((p) => p.id).toList(), [1, 3]);
    });

    test('skips no_fix rows even when no wikimedia row exists', () {
      final out = selectEligibleForBackfill(
        [_p(id: 1, source: PingSource.noFix)],
        const <int>{},
      );
      expect(out, isEmpty);
    });

    test('skips rows with null lat or lon', () {
      final out = selectEligibleForBackfill(
        [
          _p(id: 1, lat: null),
          _p(id: 2, lon: null),
          _p(id: 3),
        ],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [3]);
    });

    test('skips rows with null id (defensive against pre-persist state)',
        () {
      final out = selectEligibleForBackfill(
        [
          Ping(
            timestampUtc: DateTime.utc(2026, 5, 17),
            lat: 1,
            lon: 2,
            source: PingSource.scheduled,
          ),
        ],
        const <int>{},
      );
      expect(out, isEmpty);
    });

    test('preserves input order', () {
      final out = selectEligibleForBackfill(
        [_p(id: 5), _p(id: 1), _p(id: 9)],
        const <int>{},
      );
      expect(out.map((p) => p.id).toList(), [5, 1, 9]);
    });

    test('returns empty on empty input', () {
      expect(
          selectEligibleForBackfill(const [], const <int>{}), isEmpty);
    });

    test('user-supplied photos do NOT block backfill eligibility', () {
      // The "wikimediaPhotoPingIds" set deliberately tracks wikimedia
      // rows only — a manual user photo doesn't replace what the auto-
      // fetcher would have found. Test by passing an empty wikimedia
      // set (the user-supplied row exists in production but isn't in
      // this set), expecting the ping is still eligible.
      final out = selectEligibleForBackfill(
        [_p(id: 1)],
        const <int>{},
      );
      expect(out, hasLength(1));
    });
  });

  group('PhotoBackfillProgress.fraction', () {
    test('total=0 → 1.0 (no work, treat as complete)', () {
      const p = PhotoBackfillProgress(
          processed: 0, total: 0, photosAdded: 0);
      expect(p.fraction, 1.0);
    });

    test('processed/total ratio', () {
      const p = PhotoBackfillProgress(
          processed: 3, total: 12, photosAdded: 5);
      expect(p.fraction, 0.25);
    });
  });
}
