import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../models/ping.dart';
import '../providers/mbtiles_provider.dart';
import '../providers/pings_provider.dart';
import '../services/mbtiles_service.dart';

/// Full-screen history map with time slider + path toggle + bbox-fit.
///
/// Tile source preference, in order:
///   1. Active MBTiles region (fully offline) — picked in Regions screen.
///   2. OpenStreetMap online tiles — fallback when nothing is installed.
///
/// The time slider filters pings down to those logged at-or-before the
/// slider's timestamp; dragging it back in time rewinds the trail.
/// Playback controls (0.7.1+24) auto-advance the slider one fix at a
/// time — play/pause, step prev/next, jump-to-start, and a 1×/2×/4×/
/// 8×/16× speed cycle. The discrete per-ping step keeps each fix
/// visible for the same fraction of the animation, regardless of gaps
/// between pings.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _controller = MapController();
  bool _showPath = true;
  bool _showHeatmap = false;
  DateTime? _sliderMax;
  bool _initialFitDone = false;

  /// Playback: advances `_sliderMax` one ping at a time until it reaches
  /// the last fix, then auto-pauses. Step interval = `_basePlaybackStep /
  /// _playbackSpeed`, so 1× shows each ping for ~350ms, 4× for ~90ms, 16×
  /// for ~22ms. Tuned so a week of 4h pings (42 fixes) plays in ~15s at 1×
  /// and ~1s at 16× — long enough to track movement, short enough not to
  /// feel like a stall.
  bool _playing = false;
  double _playbackSpeed = 1.0;
  Timer? _playbackTimer;
  static const _basePlaybackStep = Duration(milliseconds: 350);

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pingsAsync = ref.watch(allPingsProvider);
    final activeRegion = ref.watch(activeRegionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail map'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home'),
        ),
        actions: [
          IconButton(
            tooltip: _showHeatmap ? 'Hide heatmap' : 'Show heatmap',
            icon: Icon(
              _showHeatmap
                  ? Icons.blur_on
                  : Icons.blur_circular_outlined,
            ),
            onPressed: () => setState(() => _showHeatmap = !_showHeatmap),
          ),
          IconButton(
            tooltip: _showPath ? 'Hide path line' : 'Show path line',
            icon: Icon(_showPath ? Icons.timeline : Icons.scatter_plot),
            onPressed: () => setState(() => _showPath = !_showPath),
          ),
          IconButton(
            tooltip: 'Regions',
            icon: const Icon(Icons.layers_outlined),
            onPressed: () => context.go('/regions'),
          ),
        ],
      ),
      body: pingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (pings) {
          // `allPingsProvider` returns oldest-first. Drop null-coord
          // rows up front so the slider's visibleCount reflects real
          // fixes, not "no_fix"/boot rows that never plot anywhere.
          final fixes = pings
              .where((p) => p.lat != null && p.lon != null)
              .toList(growable: false);
          if (fixes.isEmpty) {
            return const _EmptyState();
          }
          return _buildMap(context, fixes, activeRegion.valueOrNull);
        },
      ),
    );
  }

  Widget _buildMap(
    BuildContext context,
    List<Ping> fixes,
    MBTilesRegion? region,
  ) {
    // Already chronological (oldest-first) thanks to allPingsProvider.
    final chrono = fixes;
    final first = chrono.first.timestampUtc;
    final last = chrono.last.timestampUtc;
    final sliderMax = _sliderMax ?? last;
    final visible = chrono
        .where((p) => !p.timestampUtc.isAfter(sliderMax))
        .toList(growable: false);

    final points =
        visible.map((p) => LatLng(p.lat!, p.lon!)).toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    final hasMultiple = points.length >= 2;
    final latest = points.isNotEmpty ? points.last : null;

    // Lazy bbox-fit after first paint. `addPostFrameCallback` is the
    // only safe place to touch MapController in initial build.
    if (!_initialFitDone && points.isNotEmpty) {
      _initialFitDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit(points));
    }

    return Column(
      children: [
        Expanded(
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: latest ?? const LatLng(0, 0),
              initialZoom: 13,
              minZoom: 2,
              maxZoom: 18,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.flingAnimation |
                    InteractiveFlag.scrollWheelZoom,
              ),
            ),
            children: [
              _tileLayer(region),
              if (_showHeatmap && points.isNotEmpty)
                MarkerLayer(
                  markers: _buildHeatmapMarkers(points, scheme),
                ),
              if (_showPath && hasMultiple && !_showHeatmap)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: points,
                      strokeWidth: 3,
                      color: scheme.primary.withValues(alpha: 0.85),
                    ),
                  ],
                ),
              if (!_showHeatmap)
                MarkerLayer(
                  markers: [
                    for (int i = 0; i < points.length - 1; i++)
                      Marker(
                        point: points[i],
                        width: 10,
                        height: 10,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.85),
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                    if (latest != null)
                      Marker(
                        point: latest,
                        width: 22,
                        height: 22,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.tertiary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.95),
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              _attribution(region),
              Positioned(
                right: 8,
                top: 8,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _fit(points),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.center_focus_strong,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _TimeSlider(
          first: first,
          last: last,
          current: sliderMax,
          visibleCount: visible.length,
          totalCount: chrono.length,
          playing: _playing,
          playbackSpeed: _playbackSpeed,
          onChanged: (v) {
            _pausePlayback();
            setState(() => _sliderMax = v);
          },
          onReset: () {
            _pausePlayback();
            setState(() => _sliderMax = null);
          },
          onJumpToStart: () {
            _pausePlayback();
            setState(() => _sliderMax = chrono.first.timestampUtc);
          },
          onStepPrev: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, -1));
          },
          onStepNext: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, 1));
          },
          onTogglePlay: () => _togglePlayback(chrono),
          onCycleSpeed: _cycleSpeed,
        ),
      ],
    );
  }

  /// Move the slider one ping forward / backward along `chrono`.
  /// Keeping this as discrete-per-ping (not per-millisecond) means step
  /// buttons always advance the *visible trail* by exactly one marker,
  /// even when gaps between pings are irregular.
  DateTime _stepTo(List<Ping> chrono, DateTime current, int delta) {
    final idx = chrono.indexWhere((p) => !p.timestampUtc.isBefore(current));
    // indexWhere returns -1 if `current` is after every ping (shouldn't
    // happen given _sliderMax is clamped, but treat as "at end").
    final effective = idx < 0 ? chrono.length - 1 : idx;
    final target = (effective + delta).clamp(0, chrono.length - 1);
    return chrono[target].timestampUtc;
  }

  void _togglePlayback(List<Ping> chrono) {
    if (_playing) {
      _pausePlayback();
      return;
    }
    if (chrono.length < 2) return;
    // If we're already at the end, restart from the beginning — otherwise
    // tapping play when the slider is pinned to the last ping is a no-op.
    if (_sliderMax != null &&
        !_sliderMax!.isBefore(chrono.last.timestampUtc)) {
      setState(() => _sliderMax = chrono.first.timestampUtc);
    }
    _startPlaybackTimer(chrono);
    setState(() => _playing = true);
  }

  void _startPlaybackTimer(List<Ping> chrono) {
    _playbackTimer?.cancel();
    final interval = Duration(
      milliseconds:
          (_basePlaybackStep.inMilliseconds / _playbackSpeed).round().clamp(16, 2000),
    );
    _playbackTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      final current = _sliderMax ?? chrono.last.timestampUtc;
      final next = _stepTo(chrono, current, 1);
      if (!next.isAfter(current)) {
        // Reached the end — stop.
        _pausePlayback();
        return;
      }
      setState(() => _sliderMax = next);
    });
  }

  void _pausePlayback() {
    if (_playbackTimer == null && !_playing) return;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    if (_playing) setState(() => _playing = false);
  }

  /// Cycle through 1× → 2× → 4× → 8× → 16× → 1×. Restarts the active
  /// timer at the new cadence so speed changes are felt immediately
  /// rather than taking effect on the next cycle.
  void _cycleSpeed() {
    final next = switch (_playbackSpeed) {
      1.0 => 2.0,
      2.0 => 4.0,
      4.0 => 8.0,
      8.0 => 16.0,
      _ => 1.0,
    };
    setState(() => _playbackSpeed = next);
    if (_playing) {
      // Re-arm the timer at the new interval. Need the full `chrono` list
      // again — pull it from the provider's current value rather than
      // plumbing it through, since playback is only live when pings exist.
      final pings = ref.read(allPingsProvider).valueOrNull;
      if (pings != null) {
        final fixes = pings
            .where((p) => p.lat != null && p.lon != null)
            .toList(growable: false);
        _startPlaybackTimer(fixes);
      }
    }
  }

  Widget _tileLayer(MBTilesRegion? region) {
    if (region != null) {
      return TileLayer(
        tileProvider: MbTilesTileProvider.fromPath(path: region.path),
        maxZoom: 18,
      );
    }
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.dazeddingo.trail',
      maxZoom: 19,
    );
  }

  Widget _attribution(MBTilesRegion? region) {
    final text = region != null
        ? 'Offline: ${region.name}'
        : '© OpenStreetMap';
    return Positioned(
      left: 8,
      bottom: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }

  /// Grid-based heatmap: bucket every fix into a ~0.001° cell (~100 m at
  /// the equator, proportionally less near the poles — fine for "how
  /// often do I come to this spot"), then render each cell as one
  /// translucent circle whose opacity + radius tracks cell density.
  /// Cheap enough to render every pan; not as pretty as a real KDE but
  /// needs zero extra packages and survives 10k+ pings without chugging.
  List<Marker> _buildHeatmapMarkers(List<LatLng> points, ColorScheme scheme) {
    if (points.isEmpty) return const [];
    const gridSize = 0.001; // degrees
    final counts = <String, ({LatLng point, int count})>{};
    for (final p in points) {
      final latBucket = (p.latitude / gridSize).round();
      final lonBucket = (p.longitude / gridSize).round();
      final key = '$latBucket,$lonBucket';
      final existing = counts[key];
      counts[key] = (
        point: LatLng(latBucket * gridSize, lonBucket * gridSize),
        count: (existing?.count ?? 0) + 1,
      );
    }
    final maxCount =
        counts.values.map((e) => e.count).fold<int>(0, (a, b) => a > b ? a : b);
    final markers = <Marker>[];
    for (final cell in counts.values) {
      // Normalise to [0, 1] — single-visit cells still draw at low
      // opacity so sparse tracks are visible alongside dense hubs.
      final norm = maxCount <= 1 ? 1.0 : cell.count / maxCount;
      final radius = 16.0 + norm * 24.0;
      markers.add(
        Marker(
          point: cell.point,
          width: radius * 2,
          height: radius * 2,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  scheme.tertiary.withValues(alpha: 0.55 * norm + 0.2),
                  scheme.tertiary.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  void _fit(List<LatLng> points) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      _controller.move(points.first, 14);
      return;
    }
    final bounds = LatLngBounds.fromPoints(points);
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(40),
        maxZoom: 15,
      ),
    );
  }
}

class _TimeSlider extends StatelessWidget {
  final DateTime first;
  final DateTime last;
  final DateTime current;
  final int visibleCount;
  final int totalCount;
  final bool playing;
  final double playbackSpeed;
  final ValueChanged<DateTime> onChanged;
  final VoidCallback onReset;
  final VoidCallback onJumpToStart;
  final VoidCallback onStepPrev;
  final VoidCallback onStepNext;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;

  const _TimeSlider({
    required this.first,
    required this.last,
    required this.current,
    required this.visibleCount,
    required this.totalCount,
    required this.playing,
    required this.playbackSpeed,
    required this.onChanged,
    required this.onReset,
    required this.onJumpToStart,
    required this.onStepPrev,
    required this.onStepNext,
    required this.onTogglePlay,
    required this.onCycleSpeed,
  });

  @override
  Widget build(BuildContext context) {
    final totalMs = last.millisecondsSinceEpoch - first.millisecondsSinceEpoch;
    final currentMs = current.millisecondsSinceEpoch - first.millisecondsSinceEpoch;
    // If all pings happened at the exact same millisecond (test fixtures,
    // fresh install with one ping), the slider has nothing to slide.
    final disabled = totalMs <= 0;
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('MMM d, HH:mm');
    final speedLabel = playbackSpeed == playbackSpeed.roundToDouble()
        ? '${playbackSpeed.toStringAsFixed(0)}×'
        : '${playbackSpeed.toStringAsFixed(1)}×';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${fmt.format(current.toLocal())} · '
                  '$visibleCount / $totalCount fixes shown',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(onPressed: onReset, child: const Text('Latest')),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
            ),
            child: Slider(
              min: 0,
              max: totalMs <= 0 ? 1 : totalMs.toDouble(),
              value: disabled
                  ? 0
                  : currentMs.clamp(0, totalMs).toDouble(),
              onChanged: disabled
                  ? null
                  : (v) => onChanged(
                        first.add(Duration(milliseconds: v.toInt())),
                      ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Jump to first fix',
                visualDensity: VisualDensity.compact,
                onPressed: disabled ? null : onJumpToStart,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: 'Previous fix',
                visualDensity: VisualDensity.compact,
                onPressed: disabled ? null : onStepPrev,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton.filledTonal(
                tooltip: playing ? 'Pause playback' : 'Play through pings',
                onPressed: disabled ? null : onTogglePlay,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: 'Next fix',
                visualDensity: VisualDensity.compact,
                onPressed: disabled ? null : onStepNext,
                icon: const Icon(Icons.chevron_right),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: disabled ? null : onCycleSpeed,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(speedLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No fixes yet — trail will appear after a few pings.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
