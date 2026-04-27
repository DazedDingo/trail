import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart';

import '../models/ping.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';

/// Interactive map of the user's recent ping trail.
///
/// Renders a `MapLibreMap` over the user's active offline region — the
/// app is offline-only, so when no region is installed the widget shows
/// a placeholder pointing at Settings → Offline map → Regions instead
/// of mounting the map. Passing `activeRegion: null` at the callsite
/// keeps the widget usable in tests without spinning up a real file.
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
  MapController? _controller;
  Future<String?>? _styleFuture;
  // Diagnostics: surface the most recent MapLibre event so a "white map"
  // failure can be triaged without adb logcat. Once we see consistent
  // `MapEventStyleLoaded` in the field this overlay can come out (or
  // move behind a debug flag).
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
    }
    final oldFixes = _fixesOf(oldWidget.pings);
    final newFixes = _fixesOf(widget.pings);
    if (newFixes.isEmpty || _controller == null) return;
    final newestChanged = oldFixes.isEmpty ||
        oldFixes.first.timestampUtc != newFixes.first.timestampUtc;
    if (newestChanged) {
      _fitToPings(newFixes);
    }
  }

  static List<Ping> _fixesOf(List<Ping> pings) => pings
      .where((p) => p.lat != null && p.lon != null)
      .toList(growable: false);

  void _fitToPings(List<Ping> fixes) {
    final c = _controller;
    if (c == null || fixes.isEmpty) return;
    if (fixes.length == 1) {
      c.animateCamera(
        center: Geographic(lon: fixes.first.lon!, lat: fixes.first.lat!),
        zoom: 14,
      );
      return;
    }
    final bounds = LngLatBounds.fromPoints(
      fixes
          .map((p) => Geographic(lon: p.lon!, lat: p.lat!))
          .toList(growable: false),
    );
    c.fitBounds(
      bounds: bounds,
      padding: const EdgeInsets.all(32),
    );
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
          return _buildMap(context, fixes, snap.data!, scheme);
        },
      ),
    );
  }

  Widget _buildMap(
    BuildContext context,
    List<Ping> fixes,
    String styleJson,
    ColorScheme scheme,
  ) {
    final positions = fixes
        .map((p) => [p.lon!, p.lat!].xy)
        .toList(growable: false);
    final latest = positions.last;

    return Stack(
      children: [
        MapLibreMap(
          options: MapOptions(
            initStyle: styleJson,
            initCenter: Geographic(lon: latest.x, lat: latest.y),
            initZoom: 14,
            minZoom: 2,
            maxZoom: 18,
          ),
          onMapCreated: (c) {
            _controller = c;
            if (mounted) setState(() => _lastEvent = 'mapCreated');
          },
          onStyleLoaded: (_) {
            // Style is loaded — fit camera to the trail bbox once vector
            // tiles can render. Doing this in `onStyleLoaded` rather than
            // `onMapCreated` avoids a flicker where the camera fits while
            // the style is still parsing.
            _fitToPings(fixes);
            if (mounted) setState(() => _lastEvent = 'styleLoaded');
          },
          onEvent: (e) {
            if (!mounted) return;
            final name = e.runtimeType.toString().replaceFirst('MapEvent', '');
            setState(() => _lastEvent = name);
          },
          layers: [
            if (positions.length >= 2)
              PolylineLayer(
                polylines: [
                  Feature(geometry: LineString.from(positions)),
                ],
                color: scheme.primary.withValues(alpha: 0.85),
                width: 3,
              ),
            // All non-latest fixes — small primary-colour dots.
            if (positions.length > 1)
              CircleLayer(
                points: [
                  for (int i = 0; i < positions.length - 1; i++)
                    Feature(geometry: Point(positions[i])),
                ],
                radius: 4,
                color: scheme.primary,
                strokeWidth: 1,
                strokeColor: Colors.white.withValues(alpha: 0.85),
              ),
            // Latest fix — larger tertiary-colour dot, drawn after the
            // others so it always sits on top.
            CircleLayer(
              points: [Feature(geometry: Point(latest))],
              radius: 8,
              color: scheme.tertiary,
              strokeWidth: 2,
              strokeColor: Colors.white.withValues(alpha: 0.95),
            ),
          ],
        ),
        Positioned(
          left: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'last: $_lastEvent · '
              'fileExists: ${File(widget.activeRegion!.path).existsSync()} · '
              'tail: …${_pathTail(widget.activeRegion!.path)}',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
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
              onTap: () => _fitToPings(fixes),
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

  /// Last 60 chars of the path so the diagnostic overlay shows enough
  /// of the filename + parent dir to spot a wrong target without
  /// running off the screen on small phones.
  static String _pathTail(String path) {
    if (path.length <= 60) return path;
    return path.substring(path.length - 60);
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
