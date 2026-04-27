import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:maplibre/maplibre.dart';

import '../models/ping.dart';
import '../providers/mbtiles_provider.dart';
import '../providers/pings_provider.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';

/// Full-screen history map with time slider + path toggle + bbox-fit.
///
/// Uses `MapLibreMap` against a sideloaded `.pmtiles` region — the app
/// is offline-only, so when no region is installed the screen shows an
/// empty state pointing to Settings → Offline map → Regions instead of
/// rendering a map.
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
  MapController? _controller;
  Future<String?>? _styleFuture;
  String? _activeRegionPath;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pingsAsync = ref.watch(allPingsProvider);
    final activeRegion = ref.watch(activeRegionProvider).valueOrNull;

    // Lazily (re)load the style JSON whenever the active region changes.
    if (activeRegion?.path != _activeRegionPath) {
      _activeRegionPath = activeRegion?.path;
      _styleFuture = TrailStyle.loadForRegion(_activeRegionPath);
      _initialFitDone = false;
    }

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
            return const _EmptyState(
              message: 'No fixes yet — trail will appear after a few pings.',
            );
          }
          if (activeRegion == null) {
            return const _EmptyState(
              message:
                  'Install an offline map region to see your trail. '
                  'Tap the Regions icon (top right) → Install.',
            );
          }
          return _buildBody(context, fixes, activeRegion);
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<Ping> fixes,
    TilesRegion region,
  ) {
    // Already chronological (oldest-first) thanks to allPingsProvider.
    final chrono = fixes;
    final first = chrono.first.timestampUtc;
    final last = chrono.last.timestampUtc;
    final sliderMax = _sliderMax ?? last;
    final visible = chrono
        .where((p) => !p.timestampUtc.isAfter(sliderMax))
        .toList(growable: false);

    return Column(
      children: [
        Expanded(
          child: FutureBuilder<String?>(
            future: _styleFuture,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return _buildMap(context, visible, snap.data!, region);
            },
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

  Widget _buildMap(
    BuildContext context,
    List<Ping> visibleFixes,
    String styleJson,
    TilesRegion region,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final positions = visibleFixes
        .map((p) => [p.lon!, p.lat!].xy)
        .toList(growable: false);
    final hasMultiple = positions.length >= 2;
    final latest = positions.isNotEmpty ? positions.last : null;
    final initial = latest ?? [-2.0, 54.0].xy; // fallback: middle of GB

    return Stack(
      children: [
        MapLibreMap(
          options: MapOptions(
            initStyle: styleJson,
            initCenter: Geographic(lon: initial.x, lat: initial.y),
            initZoom: 13,
            minZoom: 2,
            maxZoom: 18,
          ),
          onMapCreated: (c) {
            _controller = c;
          },
          onStyleLoaded: (_) {
            // Fit to all visible fixes once vector tiles can render.
            // `_initialFitDone` keeps subsequent slider drags from
            // re-snapping the camera back to the bbox.
            if (!_initialFitDone && positions.isNotEmpty) {
              _initialFitDone = true;
              _fit(positions);
            }
          },
          layers: _layersFor(positions, hasMultiple, latest, scheme),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Offline: ${region.name} · © OpenMapTiles © OSM contributors',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _fit(positions),
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
    );
  }

  /// Builds the declarative layer stack for the current visibility flags.
  ///
  /// Heatmap mode renders one blurred translucent CircleLayer over every
  /// fix — overlapping circles naturally produce hot spots at
  /// frequently-visited locations. This replaces the 0.7.1+24-era custom
  /// 0.001°-grid bucketing (which rendered hundreds of `CircleMarker`
  /// widgets in Dart-land); native GPU-rendered circles handle 10k+
  /// pings without breaking a sweat and never need re-bucketing on pan.
  List<Layer> _layersFor(
    List<Position> positions,
    bool hasMultiple,
    Position? latest,
    ColorScheme scheme,
  ) {
    if (_showHeatmap) {
      return [
        if (positions.isNotEmpty)
          CircleLayer(
            points: [
              for (final pos in positions) Feature(geometry: Point(pos)),
            ],
            radius: 18,
            color: scheme.tertiary.withValues(alpha: 0.35),
            blur: 0.5,
          ),
      ];
    }
    return [
      if (_showPath && hasMultiple)
        PolylineLayer(
          polylines: [Feature(geometry: LineString.from(positions))],
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
      if (latest != null)
        CircleLayer(
          points: [Feature(geometry: Point(latest))],
          radius: 8,
          color: scheme.tertiary,
          strokeWidth: 2,
          strokeColor: Colors.white.withValues(alpha: 0.95),
        ),
    ];
  }

  void _fit(List<Position> positions) {
    final c = _controller;
    if (c == null || positions.isEmpty) return;
    if (positions.length == 1) {
      c.animateCamera(
        center: Geographic(lon: positions.first.x, lat: positions.first.y),
        zoom: 14,
      );
      return;
    }
    final bounds = LngLatBounds.fromPoints(
      positions
          .map((p) => Geographic(lon: p.x, lat: p.y))
          .toList(growable: false),
    );
    c.fitBounds(
      bounds: bounds,
      padding: const EdgeInsets.all(40),
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
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
