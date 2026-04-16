import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';

void main() {
  group('PingSource', () {
    test('round-trips through DB value', () {
      for (final s in PingSource.values) {
        expect(PingSource.fromDb(s.dbValue), s);
      }
    });

    test('falls back to scheduled for unknown', () {
      expect(PingSource.fromDb('nonsense'), PingSource.scheduled);
    });
  });

  group('Ping serialization', () {
    test('toMap / fromMap round-trip', () {
      final t = DateTime.utc(2026, 4, 15, 12, 30);
      final p = Ping(
        timestampUtc: t,
        lat: 51.5,
        lon: -0.12,
        accuracy: 8.5,
        altitude: 20.0,
        heading: 45.0,
        speed: 1.2,
        batteryPct: 83,
        networkState: 'wifi',
        cellId: 'LTE:12345',
        wifiSsid: 'home',
        source: PingSource.scheduled,
        note: null,
      );
      final round = Ping.fromMap(p.toMap()..['id'] = 1);
      expect(round.lat, 51.5);
      expect(round.lon, -0.12);
      expect(round.batteryPct, 83);
      expect(round.source, PingSource.scheduled);
      expect(round.timestampUtc, t);
    });

    test('preserves no_fix rows with null coords', () {
      final p = Ping(
        timestampUtc: DateTime.utc(2026, 1, 1),
        batteryPct: 3,
        source: PingSource.noFix,
        note: 'skipped_low_battery',
      );
      final round = Ping.fromMap(p.toMap());
      expect(round.source, PingSource.noFix);
      expect(round.lat, isNull);
      expect(round.note, 'skipped_low_battery');
    });

    test('fromMap defaults missing source to scheduled — safety fallback', () {
      final round = Ping.fromMap({
        'ts_utc': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        'lat': 1.0,
        'lon': 2.0,
        // 'source' intentionally missing.
      });
      expect(round.source, PingSource.scheduled);
    });

    test('equator coords (0, 0) are NOT silently dropped as null', () {
      final p = Ping(
        timestampUtc: DateTime.utc(2026, 1, 1),
        lat: 0.0,
        lon: 0.0,
        source: PingSource.scheduled,
      );
      final round = Ping.fromMap(p.toMap());
      expect(round.lat, 0.0);
      expect(round.lon, 0.0);
    });

    test('fromMap parses int columns that arrived as num (sqflite quirk)', () {
      final round = Ping.fromMap({
        'ts_utc': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        // battery_pct can arrive as double 83.0 from some codecs.
        'battery_pct': 83.0,
        'source': 'scheduled',
      });
      expect(round.batteryPct, 83);
    });

    test('timestamp round-trip preserves microsecond-free UTC instant', () {
      final t = DateTime.utc(2026, 6, 15, 9, 30, 45, 123);
      final p = Ping(timestampUtc: t, source: PingSource.scheduled);
      expect(Ping.fromMap(p.toMap()).timestampUtc, t);
    });
  });

  group('PingSource edge cases', () {
    test('fromDb treats empty string as scheduled (same as unknown)', () {
      expect(PingSource.fromDb(''), PingSource.scheduled);
    });

    test('dbValue strings are stable — exports and queries depend on them',
        () {
      expect(PingSource.scheduled.dbValue, 'scheduled');
      expect(PingSource.panic.dbValue, 'panic');
      expect(PingSource.boot.dbValue, 'boot');
      expect(PingSource.noFix.dbValue, 'no_fix');
    });
  });
}
