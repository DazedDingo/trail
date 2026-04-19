import 'package:flutter/material.dart';

import '../models/ping.dart';

/// A tiny, offline, tile-free "map" of the user's ping trail.
///
/// The design constraint ruled out online map tiles (Trail is offline-first,
/// no internet dependency). So the visualisation is a pure `CustomPaint`:
/// coordinates are normalised to the screen-rect bounding box and rendered
/// as a connected path with dots at each fix.
///
/// What it gives up vs a real map (no basemap, no street context) it buys
/// back in being honest about Trail's data model — you see the shape of
/// the route and can spot long gaps, which is the point of a heartbeat log.
class TrailMap extends StatelessWidget {
  final List<Ping> pings;
  final double height;

  const TrailMap({
    super.key,
    required this.pings,
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    final fixes = pings
        .where((p) => p.lat != null && p.lon != null)
        .toList(growable: false);
    final scheme = Theme.of(context).colorScheme;

    if (fixes.length < 2) {
      return Container(
        height: height,
        alignment: Alignment.center,
        decoration: _frame(scheme),
        child: Text(
          fixes.isEmpty
              ? 'No fixes yet — trail will appear after a few pings.'
              : 'Only one fix — trail needs at least two points.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Container(
      height: height,
      decoration: _frame(scheme),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _TrailPainter(
          fixes: fixes,
          lineColor: scheme.primary,
          dotColor: scheme.primary,
          latestColor: scheme.tertiary,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  BoxDecoration _frame(ColorScheme scheme) => BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant,
          width: 1,
        ),
      );
}

class _TrailPainter extends CustomPainter {
  final List<Ping> fixes;
  final Color lineColor;
  final Color dotColor;
  final Color latestColor;

  _TrailPainter({
    required this.fixes,
    required this.lineColor,
    required this.dotColor,
    required this.latestColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Bounding box of the trail. An eighth-of-a-box margin keeps edge
    // points off the stroke and prevents a one-point-wide trail from
    // collapsing into a single pixel line.
    double minLat = fixes.first.lat!;
    double maxLat = minLat;
    double minLon = fixes.first.lon!;
    double maxLon = minLon;
    for (final p in fixes) {
      if (p.lat! < minLat) minLat = p.lat!;
      if (p.lat! > maxLat) maxLat = p.lat!;
      if (p.lon! < minLon) minLon = p.lon!;
      if (p.lon! > maxLon) maxLon = p.lon!;
    }
    final latSpan = (maxLat - minLat).abs();
    final lonSpan = (maxLon - minLon).abs();
    // Pad degenerate (all-at-one-location) cases so the dot renders
    // centered instead of NaN'ing the projection.
    final latRange = latSpan < 1e-6 ? 1e-6 : latSpan;
    final lonRange = lonSpan < 1e-6 ? 1e-6 : lonSpan;

    const pad = 12.0;
    final plotW = size.width - pad * 2;
    final plotH = size.height - pad * 2;

    Offset project(double lat, double lon) {
      // Flip latitude so higher values render toward the top of the canvas
      // (standard map orientation; canvas y grows downward).
      final nx = (lon - minLon) / lonRange;
      final ny = 1.0 - (lat - minLat) / latRange;
      return Offset(pad + nx * plotW, pad + ny * plotH);
    }

    final points = fixes.map((p) => project(p.lat!, p.lon!)).toList();

    final pathPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.65)
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, pathPaint);

    final dotPaint = Paint()..color = dotColor.withValues(alpha: 0.85);
    for (int i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 2.5, dotPaint);
    }

    // Latest fix gets a larger accent marker so it's obvious where the
    // user currently is relative to the rest of the trail.
    // `fixes` is DESC by timestamp (matching recentPingsProvider), so the
    // newest fix is at index 0.
    canvas.drawCircle(
      points.first,
      6,
      Paint()..color = latestColor,
    );
    canvas.drawCircle(
      points.first,
      6,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _TrailPainter oldDelegate) {
    if (oldDelegate.fixes.length != fixes.length) return true;
    if (oldDelegate.fixes.isEmpty) return false;
    // Compare the newest fix only — good enough for the 4h cadence.
    return oldDelegate.fixes.first.timestampUtc != fixes.first.timestampUtc;
  }
}
