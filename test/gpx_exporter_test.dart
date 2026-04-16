import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/export/gpx_exporter.dart';

Ping _p({
  DateTime? ts,
  double? lat,
  double? lon,
  double? acc,
  double? alt,
  PingSource source = PingSource.scheduled,
  String? note,
  String? ssid,
  int? batt,
}) =>
    Ping(
      timestampUtc: ts ?? DateTime.utc(2026, 4, 15, 12, 0),
      lat: lat,
      lon: lon,
      accuracy: acc,
      altitude: alt,
      batteryPct: batt,
      wifiSsid: ssid,
      source: source,
      note: note,
    );

void main() {
  group('GpxExporter.build', () {
    final exp = GpxExporter();
    final fixedNow = DateTime.utc(2026, 4, 16, 9, 0);

    test('starts with XML declaration + gpx 1.1 root', () {
      final out = exp.build([], now: fixedNow);
      expect(out, startsWith('<?xml version="1.0" encoding="UTF-8"?>\n'));
      expect(out, contains('<gpx version="1.1" creator="Trail"'));
      expect(out, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(out.trim(), endsWith('</gpx>'));
    });

    test('metadata block uses the injected `now` for determinism', () {
      final out = exp.build([], now: fixedNow);
      expect(out, contains('<time>2026-04-16T09:00:00.000Z</time>'));
    });

    test('skips rows without coordinates — GPX requires lat/lon on <wpt>',
        () {
      final out = exp.build([
        _p(source: PingSource.noFix),
        _p(ts: DateTime.utc(2026, 4, 15), lat: 51.5, lon: -0.12),
      ], now: fixedNow);
      // Only one <wpt> should appear.
      expect('<wpt '.allMatches(out).length, 1);
      // And its lat/lon should be the successful fix's.
      expect(out, contains('<wpt lat="51.5" lon="-0.12">'));
    });

    test('empty ping list emits a valid (empty) GPX document', () {
      final out = exp.build([], now: fixedNow);
      expect(out.contains('<wpt'), isFalse);
      expect(out.trim().endsWith('</gpx>'), isTrue);
    });

    test('omits <ele> when altitude is null — invalid GPX otherwise', () {
      final out = exp.build([_p(lat: 1.0, lon: 2.0)], now: fixedNow);
      expect(out, isNot(contains('<ele>')));
    });

    test('includes <ele> when altitude is set', () {
      final out = exp.build(
          [_p(lat: 1.0, lon: 2.0, alt: 123.4)],
          now: fixedNow);
      expect(out, contains('<ele>123.4</ele>'));
    });

    test('omits <desc> entirely when there is nothing descriptive', () {
      final out = exp.build([_p(lat: 1.0, lon: 2.0)], now: fixedNow);
      expect(out, isNot(contains('<desc>')));
    });

    test('writes <type> with the db value so exports round-trip by source',
        () {
      final out = exp.build([
        _p(lat: 1.0, lon: 2.0, source: PingSource.panic),
        _p(lat: 3.0, lon: 4.0, source: PingSource.boot),
      ], now: fixedNow);
      expect(out, contains('<type>panic</type>'));
      expect(out, contains('<type>boot</type>'));
    });

    test('XML-escapes ampersand, angle brackets, and quotes inside <desc>',
        () {
      final out = exp.build([
        _p(lat: 1.0, lon: 2.0, note: 'Ben & Jerry said "<hi>"'),
      ], now: fixedNow);
      // Raw user text must not leak into the tree.
      expect(out, isNot(contains('Ben & Jerry')));
      expect(out, isNot(contains('"<hi>"')));
      // The escaped form should be present.
      expect(out, contains('&amp;'));
      expect(out, contains('&lt;hi&gt;'));
      expect(out, contains('&quot;'));
    });

    test('desc packs available fields with compact key=value syntax', () {
      final out = exp.build([
        _p(lat: 1.0, lon: 2.0, acc: 7.0, batt: 88, ssid: 'home', note: 'n'),
      ], now: fixedNow);
      final descMatch =
          RegExp(r'<desc>([^<]*)</desc>').firstMatch(out);
      expect(descMatch, isNotNull);
      final desc = descMatch!.group(1)!;
      expect(desc, contains('acc=7.0m'));
      expect(desc, contains('batt=88%'));
      expect(desc, contains('wifi=home'));
      expect(desc, contains('note=n'));
    });

    test('per-wpt <time> uses the ping timestamp (NOT the export now)', () {
      final out = exp.build([
        _p(ts: DateTime.utc(2024, 6, 1, 15), lat: 1.0, lon: 2.0),
      ], now: fixedNow);
      expect(out, contains('<time>2024-06-01T15:00:00.000Z</time>'));
    });

    test('every emitted <wpt> is balanced with a closing </wpt>', () {
      final out = exp.build([
        _p(lat: 1.0, lon: 2.0),
        _p(lat: 3.0, lon: 4.0, alt: 10.0, note: 'x'),
        _p(source: PingSource.noFix), // skipped
      ], now: fixedNow);
      expect('<wpt '.allMatches(out).length,
          equals('</wpt>'.allMatches(out).length));
    });
  });
}
