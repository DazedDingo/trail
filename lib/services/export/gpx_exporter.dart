import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/ping.dart';

/// GPX 1.1 exporter. Includes Trail-specific data as `<extensions>` and puts
/// notes + source in `<desc>` so apps like OsmAnd display them.
///
/// Skips `no_fix` rows (by definition they lack coordinates and GPX requires
/// lat/lon on `<wpt>`).
class GpxExporter {
  Future<String> export(List<Ping> pings, {DateTime? now}) async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'trail_export_$ts.gpx'));
    await file.writeAsString(build(pings, now: now));
    return file.path;
  }

  /// Pure-in-memory GPX builder — exposed for testing and for callers that
  /// want the XML without a temp file. [now] is injectable so the
  /// `<metadata><time>` timestamp is deterministic in tests.
  String build(List<Ping> pings, {DateTime? now}) {
    final stamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Trail" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata>')
      ..writeln('    <name>Trail export</name>')
      ..writeln('    <time>$stamp</time>')
      ..writeln('  </metadata>');
    for (final pg in pings) {
      if (pg.lat == null || pg.lon == null) continue;
      buf.writeln('  <wpt lat="${pg.lat}" lon="${pg.lon}">');
      if (pg.altitude != null) buf.writeln('    <ele>${pg.altitude}</ele>');
      buf.writeln('    <time>${pg.timestampUtc.toIso8601String()}</time>');
      final desc = _desc(pg);
      if (desc.isNotEmpty) buf.writeln('    <desc>${_xml(desc)}</desc>');
      buf.writeln('    <type>${pg.source.dbValue}</type>');
      buf.writeln('  </wpt>');
    }
    buf.writeln('</gpx>');
    return buf.toString();
  }

  String _desc(Ping p) {
    final parts = <String>[];
    if (p.accuracy != null) parts.add('acc=${p.accuracy!.toStringAsFixed(1)}m');
    if (p.speed != null) parts.add('speed=${p.speed!.toStringAsFixed(1)}m/s');
    if (p.heading != null) parts.add('hdg=${p.heading!.toStringAsFixed(0)}');
    if (p.batteryPct != null) parts.add('batt=${p.batteryPct}%');
    if (p.networkState != null) parts.add('net=${p.networkState}');
    if (p.cellId != null) parts.add('cell=${p.cellId}');
    if (p.wifiSsid != null) parts.add('wifi=${p.wifiSsid}');
    if (p.note != null) parts.add('note=${p.note}');
    return parts.join(' ');
  }

  String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
