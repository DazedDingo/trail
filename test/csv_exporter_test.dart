import 'package:flutter_test/flutter_test.dart';
import 'package:trail/models/ping.dart';
import 'package:trail/services/export/csv_exporter.dart';

Ping _p({
  DateTime? ts,
  double? lat,
  double? lon,
  double? acc,
  double? alt,
  double? heading,
  double? speed,
  int? batt,
  String? net,
  String? cell,
  String? ssid,
  PingSource source = PingSource.scheduled,
  String? note,
}) =>
    Ping(
      timestampUtc: ts ?? DateTime.utc(2026, 4, 15, 12, 0),
      lat: lat,
      lon: lon,
      accuracy: acc,
      altitude: alt,
      heading: heading,
      speed: speed,
      batteryPct: batt,
      networkState: net,
      cellId: cell,
      wifiSsid: ssid,
      source: source,
      note: note,
    );

void main() {
  group('CsvExporter.build', () {
    final exp = CsvExporter();

    test('header row matches the declared column order', () {
      final out = exp.build([]);
      expect(out.trim(), CsvExporter.header);
    });

    test('header has exactly 13 columns — guards against silent drift', () {
      expect(CsvExporter.header.split(',').length, 13);
    });

    test('every data row has exactly 13 fields (column alignment guard)', () {
      final out = exp.build([
        _p(lat: 51.5, lon: -0.12, acc: 8.0, net: 'wifi'),
        _p(source: PingSource.noFix, note: 'no_signal'),
      ]);
      final lines = out.trim().split('\n');
      expect(lines.length, 3); // header + 2 rows
      for (final line in lines.skip(1)) {
        // A quoted field can hide commas — but none of our test values need
        // quoting. So a naive split is correct here.
        expect(line.split(',').length, 13);
      }
    });

    test('null optional fields serialize as empty strings, not the word "null"',
        () {
      final out = exp.build([_p(source: PingSource.noFix)]);
      expect(out, isNot(contains('null')));
      expect(out.trim().split('\n')[1],
          startsWith('2026-04-15T12:00:00.000Z,,,,,,,,,,,no_fix,'));
    });

    test('PingSource enum serializes as its db string for every variant', () {
      final out = exp.build([
        _p(source: PingSource.scheduled),
        _p(source: PingSource.panic),
        _p(source: PingSource.boot),
        _p(source: PingSource.noFix),
      ]);
      final sources = out
          .trim()
          .split('\n')
          .skip(1)
          .map((line) => line.split(',')[11])
          .toList();
      expect(sources, ['scheduled', 'panic', 'boot', 'no_fix']);
    });

    test('note with a comma is quoted so downstream parsers see one field',
        () {
      final out = exp.build([_p(note: 'hiked, then ran')]);
      expect(out, contains('"hiked, then ran"'));
    });

    test('note with a double quote escapes it as "" per RFC 4180', () {
      final out = exp.build([_p(note: 'she said "hi"')]);
      expect(out, contains('"she said ""hi"""'));
    });

    test('note with a newline is quoted so the row is not split', () {
      final out = exp.build([_p(note: 'line1\nline2')]);
      expect(out, contains('"line1\nline2"'));
      // Bare newline outside the quoted region would break CSV parsers. The
      // only newline between this row's content and the terminating writeln
      // must be the one INSIDE the quoted note. So after the note's closing
      // quote there must be exactly one newline before EOF.
      expect(out.endsWith('"\n'), isTrue);
    });

    test(
        'note without any reserved characters is emitted unquoted '
        '(no over-quoting)', () {
      final out = exp.build([_p(note: 'plain')]);
      expect(out, contains(',plain\n'));
      expect(out, isNot(contains(',"plain"')));
    });

    test('timestamp is ISO-8601 with a trailing Z (UTC marker)', () {
      final out = exp.build([
        _p(ts: DateTime.utc(2026, 1, 2, 3, 4, 5, 678)),
      ]);
      expect(out, contains('2026-01-02T03:04:05.678Z'));
    });

    test('equator coords (0, 0) survive as "0" not as empty — real location',
        () {
      final out = exp.build([_p(lat: 0.0, lon: 0.0)]);
      final row = out.trim().split('\n')[1].split(',');
      expect(row[1], '0.0');
      expect(row[2], '0.0');
    });

    test('empty ping list still writes the header (exported file is valid)',
        () {
      final out = exp.build([]);
      expect(out.trim().split('\n'), [CsvExporter.header]);
    });

    test('numeric fields preserve sign and precision', () {
      final out =
          exp.build([_p(lat: -33.8688, lon: 151.2093, acc: 4.25, speed: 0.0)]);
      expect(out, contains('-33.8688,151.2093,4.25'));
      expect(out, contains('0.0'));
    });
  });
}
