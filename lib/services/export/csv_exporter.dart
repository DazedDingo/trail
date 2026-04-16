import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/ping.dart';

/// Streaming CSV writer. Pure-Dart, no dependencies — keeps APK small.
class CsvExporter {
  static const header =
      'timestamp_utc,lat,lon,accuracy_m,altitude_m,heading_deg,'
      'speed_mps,battery_pct,network_state,cell_id,wifi_ssid,source,note';

  /// Writes a CSV of [pings] to a temp file and returns the file path.
  Future<String> export(List<Ping> pings) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'trail_export_$ts.csv'));
    await file.writeAsString(build(pings));
    return file.path;
  }

  /// Pure-in-memory CSV builder — exposed for testing and for callers that
  /// want the bytes without a temp file.
  String build(List<Ping> pings) {
    final buf = StringBuffer()..writeln(header);
    for (final pg in pings) {
      buf.writeln([
        pg.timestampUtc.toIso8601String(),
        pg.lat ?? '',
        pg.lon ?? '',
        pg.accuracy ?? '',
        pg.altitude ?? '',
        pg.heading ?? '',
        pg.speed ?? '',
        pg.batteryPct ?? '',
        _csvEscape(pg.networkState),
        _csvEscape(pg.cellId),
        _csvEscape(pg.wifiSsid),
        pg.source.dbValue,
        _csvEscape(pg.note),
      ].join(','));
    }
    return buf.toString();
  }

  String _csvEscape(String? v) {
    if (v == null) return '';
    final needsQuote = v.contains(',') || v.contains('"') || v.contains('\n');
    if (!needsQuote) return v;
    final escaped = v.replaceAll('"', '""');
    return '"$escaped"';
  }
}
