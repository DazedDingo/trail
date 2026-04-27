import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/ping.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';

/// Interactive map of the user's recent ping trail.
///
/// Renders a `MapLibreMap` (via `maplibre_gl`, the older battle-tested
/// community plugin) over the user's active offline region. The newer
/// `maplibre` package was tried first but its local-file URL handling
/// on Android silently fails for both `.pmtiles` and `.mbtiles` —
/// confirmed via the diagnostic mode through 0.8.0+37. Switched to
/// `maplibre_gl` for known-working local-MBTiles support.
///
/// The app is offline-only: when no region is installed the widget
/// shows an "install a region" placeholder instead of mounting the
/// map.
class TrailMap extends StatefulWidget {
  final List<Ping> pings;
  final double height;
  final TilesRegion? activeRegion;

  const TrailMap({
    super.key,
    required this.pings,
    this.height = 260,
    this.activeRegion,
  });

  @override
  State<TrailMap> createState() => _TrailMapState();
}

class _TrailMapState extends State<TrailMap> {
  MapLibreMapController? _controller;
  Future<String?>? _styleFuture;
  bool _styleReady = false;
  String _lastEvent = 'mounting…';

  @override
  void initState() {
    super.initState();
    _styleFuture = TrailStyle.loadForRegion(widget.activeRegion?.path);
  }

  @override
  void didUpdateWidget(covariant TrailMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeRegion?.path != widget.activeRegion?.path) {
      _styleFuture = TrailStyle.loadForRegion(widget.activeRegion?.path);
      _styleReady = false;
    }
    final oldFixes = _fixesOf(oldWidget.pings);
    final newFixes = _fixesOf(widget.pings);
    if (newFixes.isEmpty || _controller == null || !_styleReady) return;
    final newestChanged = oldFixes.isEmpty ||
        oldFixes.first.timestampUtc != newFixes.first.timestampUtc;
    if (newestChanged) {
      _refreshAnnotations(newFixes);
    }
  }

  static List<Ping> _fixesOf(List<Ping> pings) => pings
      .where((p) => p.lat != null && p.lon != null)
      .toList(growable: false);

  Future<void> _refreshAnnotations(List<Ping> fixes) async {
    final c = _controller;
    if (c == null) return;
    // Snapshot the colour scheme synchronously — async gaps below mean
    // we can't safely re-read `Theme.of(context)` later, and the colour
    // values shouldn't change mid-refresh anyway.
    final scheme = Theme.of(context).colorScheme;
    await c.clearLines();
    await c.clearCircles();
    if (fixes.isEmpty) return;
    final points = fixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);
    if (points.length >= 2) {
      await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 3,
        lineOpacity: 0.85,
      ));
    }
    // Trail dots — small primary-colour markers for older fixes, larger
    // tertiary marker for the latest.
    for (var i = 0; i < points.length - 1; i++) {
      await c.addCircle(CircleOptions(
        geometry: points[i],
        circleRadius: 4,
        circleColor: scheme.primary.toHexStringRGB(),
        circleStrokeWidth: 1,
        circleStrokeColor: '#FFFFFF',
        circleStrokeOpacity: 0.85,
      ));
    }
    await c.addCircle(CircleOptions(
      geometry: points.last,
      circleRadius: 8,
      circleColor: scheme.tertiary.toHexStringRGB(),
      circleStrokeWidth: 2,
      circleStrokeColor: '#FFFFFF',
      circleStrokeOpacity: 0.95,
    ));
    _fitToPoints(points);
  }

  Future<void> _fitToPoints(List<LatLng> points) async {
    final c = _controller;
    if (c == null || points.isEmpty) return;
    if (points.length == 1) {
      await c.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 14),
      );
      return;
    }
    var minLat = points.first.latitude, maxLat = minLat;
    var minLon = points.first.longitude, maxLon = minLon;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    await c.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      left: 32,
      top: 32,
      right: 32,
      bottom: 32,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final fixes = _fixesOf(widget.pings);
    final scheme = Theme.of(context).colorScheme;

    if (fixes.isEmpty) {
      return _PlaceholderFrame(
        height: widget.height,
        scheme: scheme,
        message: 'No fixes yet — trail will appear after a few pings.',
      );
    }
    if (widget.activeRegion == null) {
      return _PlaceholderFrame(
        height: widget.height,
        scheme: scheme,
        message:
            'Install an offline map region to see your trail. '
            'Settings → Offline map → Regions.',
      );
    }

    return Container(
      height: widget.height,
      decoration: _frame(scheme),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<String?>(
        future: _styleFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _buildMap(context, fixes, snap.data!);
        },
      ),
    );
  }

  Widget _buildMap(BuildContext context, List<Ping> fixes, String styleJson) {
    final initial = LatLng(fixes.last.lat!, fixes.last.lon!);
    return Stack(
      children: [
        MapLibreMap(
          styleString: styleJson,
          initialCameraPosition: CameraPosition(target: initial, zoom: 14),
          minMaxZoomPreference: const MinMaxZoomPreference(2, 18),
          dragEnabled: true,
          compassEnabled: false,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          attributionButtonPosition: AttributionButtonPosition.bottomRight,
          onMapCreated: (c) {
            _controller = c;
            if (mounted) setState(() => _lastEvent = 'mapCreated');
          },
          onStyleLoadedCallback: () {
            _styleReady = true;
            _refreshAnnotations(fixes);
            if (mounted) setState(() => _lastEvent = 'styleLoaded');
          },
        ),
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: _DiagnosticOverlay(
            lastEvent: _lastEvent,
            regionPath: widget.activeRegion!.path,
          ),
        ),
        Positioned(
          right: 6,
          top: 6,
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _fitToPoints(
                fixes
                    .map((p) => LatLng(p.lat!, p.lon!))
                    .toList(growable: false),
              ),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.center_focus_strong,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      ],
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

class _DiagnosticOverlay extends StatelessWidget {
  final String lastEvent;
  final String regionPath;
  const _DiagnosticOverlay({
    required this.lastEvent,
    required this.regionPath,
  });

  static String _pathTail(String path) {
    if (path.length <= 60) return path;
    return path.substring(path.length - 60);
  }

  @override
  Widget build(BuildContext context) {
    final exists = File(regionPath).existsSync();
    final dump =
        'last: $lastEvent\nfileExists: $exists\npath: $regionPath';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: dump));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Map diagnostic copied'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(6),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              height: 1.25,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('last: $lastEvent'),
                Text('fileExists: $exists'),
                Text(
                  'tail: …${_pathTail(regionPath)}',
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                const Text(
                  '(tap to copy full path)',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white70,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceholderFrame extends StatelessWidget {
  final double height;
  final ColorScheme scheme;
  final String message;

  const _PlaceholderFrame({
    required this.height,
    required this.scheme,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
