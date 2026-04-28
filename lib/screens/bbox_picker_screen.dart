import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../providers/mbtiles_provider.dart';
import '../providers/tile_server_provider.dart';
import '../services/trail_style.dart';

/// Modal map picker for the "Custom area" build flow. Pops with a
/// bbox string (`minLon,minLat,maxLon,maxLat`, 4 decimal places) when
/// the user taps "Use this area"; with `null` if they back out.
///
/// Mounts a `MapLibreMap` against the currently active region's style
/// (so the user can see streets to orient themselves). When no region
/// is active the picker still works — MapLibre just shows the
/// background colour without raster context. The build flow doesn't
/// need rendered tiles to capture bounds.
class BboxPickerScreen extends ConsumerStatefulWidget {
  const BboxPickerScreen({super.key});

  /// Push and await — Returns `null` if the user cancelled.
  static Future<String?> pick(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BboxPickerScreen()),
    );
  }

  @override
  ConsumerState<BboxPickerScreen> createState() => _BboxPickerScreenState();
}

class _BboxPickerScreenState extends ConsumerState<BboxPickerScreen> {
  MapLibreMapController? _controller;
  Future<String?>? _styleFuture;
  String? _activeRegionPath;
  int? _tileServerPort;

  @override
  Widget build(BuildContext context) {
    final activeRegion = ref.watch(activeRegionProvider).valueOrNull;
    final tileServerPort = ref.watch(tileServerProvider).valueOrNull;

    if (activeRegion?.path != _activeRegionPath ||
        tileServerPort != _tileServerPort ||
        _styleFuture == null) {
      _activeRegionPath = activeRegion?.path;
      _tileServerPort = tileServerPort;
      _styleFuture = TrailStyle.loadForRegion(
        _activeRegionPath,
        tileServerPort: tileServerPort,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick area'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          FutureBuilder<String?>(
            future: _styleFuture,
            builder: (context, snap) {
              return MapLibreMap(
                styleString: snap.data ?? MapLibreStyles.demo,
                initialCameraPosition: const CameraPosition(
                  // Centred roughly on the UK by default.
                  target: LatLng(54, -2),
                  zoom: 6,
                ),
                minMaxZoomPreference: const MinMaxZoomPreference(2, 18),
                dragEnabled: true,
                compassEnabled: false,
                rotateGesturesEnabled: false,
                tiltGesturesEnabled: false,
                myLocationEnabled: true,
                myLocationTrackingMode: MyLocationTrackingMode.none,
                attributionButtonPosition:
                    AttributionButtonPosition.bottomRight,
                onMapCreated: (c) => _controller = c,
              );
            },
          ),
          // Centre crosshair so it's obvious that "use this area" =
          // the rectangle currently visible. Pure paint, no
          // interaction.
          IgnorePointer(
            child: Center(
              child: Icon(
                Icons.add,
                size: 32,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
          // Faint frame to hint at the bbox shape that'll be captured.
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.6),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  'Pan and zoom to centre your area, then tap "Use this '
                  'area". The captured bbox is whatever is fully visible '
                  'on screen.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: FilledButton.icon(
              icon: const Icon(Icons.crop_square),
              label: const Text('Use this area'),
              onPressed: _capture,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null) return;
    final LatLngBounds bounds = await c.getVisibleRegion();
    final sw = bounds.southwest;
    final ne = bounds.northeast;
    final bbox = [sw.longitude, sw.latitude, ne.longitude, ne.latitude]
        .map((v) => v.toStringAsFixed(4))
        .join(',');
    if (!mounted) return;
    Navigator.of(context).pop(bbox);
  }
}
