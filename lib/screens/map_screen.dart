import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/ping.dart';
import '../providers/mbtiles_provider.dart';
import '../providers/pings_provider.dart';
import '../providers/tile_server_provider.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';

/// Full-screen history map with time slider + path toggle + bbox-fit.
///
/// Uses `maplibre_gl` (the older battle-tested community plugin)
/// against a sideloaded `.mbtiles` or `.pmtiles` region. The newer
/// `maplibre` package was tried first but its local-file URL handling
/// on Android fails silently for both formats — see CHANGELOG entries
/// 0.8.0+30 through +37 for the diagnostic trail.
///
/// The app is offline-only: when no region is installed the screen
/// shows an empty state instead of rendering a map.
///
/// The time slider filters pings down to those at-or-before the
/// slider's timestamp; dragging back rewinds the trail. Playback
/// auto-advances one fix at a time at 1×/2×/4×/8×/16× speeds.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? _controller;
  Future<String?>? _styleFuture;
  String? _activeRegionPath;
  int? _tileServerPort;
  bool _styleReady = false;

  bool _showPath = true;
  bool _showHeatmap = false;
  DateTime? _sliderMax;
  bool _initialFitDone = false;

  /// Playback: advances `_sliderMax` one ping at a time until it reaches
  /// the last fix, then auto-pauses. Step interval = `_basePlaybackStep
  /// / _playbackSpeed`, so 1× shows each ping for ~350ms, 4× for ~90ms,
  /// 16× for ~22ms. Tuned so a week of 4h pings (42 fixes) plays in
  /// ~15s at 1× and ~1s at 16× — long enough to track movement, short
  /// enough not to feel like a stall.
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
    final tileServerPort = ref.watch(tileServerProvider).valueOrNull;

    final regionChanged = activeRegion?.path != _activeRegionPath;
    final portChanged = tileServerPort != _tileServerPort;
    if (regionChanged || portChanged || _styleFuture == null) {
      _activeRegionPath = activeRegion?.path;
      _tileServerPort = tileServerPort;
      _styleFuture = TrailStyle.loadForRegion(
        _activeRegionPath,
        tileServerPort: tileServerPort,
      );
      if (regionChanged) _initialFitDone = false;
      _styleReady = false;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trail map'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          IconButton(
            tooltip: _showHeatmap ? 'Hide heatmap' : 'Show heatmap',
            icon: Icon(
              _showHeatmap
                  ? Icons.blur_on
                  : Icons.blur_circular_outlined,
            ),
            onPressed: () {
              setState(() => _showHeatmap = !_showHeatmap);
              _refreshAnnotationsIfReady();
            },
          ),
          IconButton(
            tooltip: _showPath ? 'Hide path line' : 'Show path line',
            icon: Icon(_showPath ? Icons.timeline : Icons.scatter_plot),
            onPressed: () {
              setState(() => _showPath = !_showPath);
              _refreshAnnotationsIfReady();
            },
          ),
          IconButton(
            tooltip: 'Regions',
            icon: const Icon(Icons.layers_outlined),
            // Push so the back button returns to /map rather than
            // resetting the user to /home or /settings.
            onPressed: () => context.push('/regions'),
          ),
        ],
      ),
      body: pingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (pings) {
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
            _refreshAnnotationsIfReady();
          },
          onReset: () {
            _pausePlayback();
            setState(() => _sliderMax = null);
            _refreshAnnotationsIfReady();
          },
          onJumpToStart: () {
            _pausePlayback();
            setState(() => _sliderMax = chrono.first.timestampUtc);
            _refreshAnnotationsIfReady();
          },
          onStepPrev: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, -1));
            _refreshAnnotationsIfReady();
          },
          onStepNext: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, 1));
            _refreshAnnotationsIfReady();
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
    final initial = visibleFixes.isNotEmpty
        ? LatLng(visibleFixes.last.lat!, visibleFixes.last.lon!)
        : const LatLng(54, -2); // GB centroid fallback

    return Stack(
      children: [
        MapLibreMap(
          styleString: styleJson,
          initialCameraPosition: CameraPosition(target: initial, zoom: 13),
          minMaxZoomPreference: const MinMaxZoomPreference(2, 18),
          dragEnabled: true,
          compassEnabled: false,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          attributionButtonPosition: AttributionButtonPosition.bottomRight,
          onMapCreated: (c) => _controller = c,
          onStyleLoadedCallback: () {
            _styleReady = true;
            _refreshAnnotations(visibleFixes, Theme.of(context).colorScheme);
            if (!_initialFitDone && visibleFixes.isNotEmpty) {
              _initialFitDone = true;
              _fitToFixes(visibleFixes);
            }
          },
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _fitToFixes(visibleFixes),
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

  void _refreshAnnotationsIfReady() {
    if (!_styleReady || _controller == null) return;
    final pings = ref.read(allPingsProvider).valueOrNull;
    if (pings == null) return;
    final chrono = pings
        .where((p) => p.lat != null && p.lon != null)
        .toList(growable: false);
    if (chrono.isEmpty) return;
    final sliderMax = _sliderMax ?? chrono.last.timestampUtc;
    final visible = chrono
        .where((p) => !p.timestampUtc.isAfter(sliderMax))
        .toList(growable: false);
    _refreshAnnotations(visible, Theme.of(context).colorScheme);
  }

  /// Clears existing line/circle annotations and re-adds for the
  /// current visibility flags. We use clear+add (rather than a
  /// GeoJsonSource that we update in place) because the slider drives
  /// a fairly small number of points (~weeks of 4h pings = 42–500
  /// fixes); the perf cost is invisible at that scale and the code is
  /// substantially simpler. If the app ever stores 10k+ pings, swap to
  /// `setGeoJsonSource` against a single source.
  Future<void> _refreshAnnotations(
    List<Ping> visibleFixes,
    ColorScheme scheme,
  ) async {
    final c = _controller;
    if (c == null) return;
    await c.clearLines();
    await c.clearCircles();
    if (visibleFixes.isEmpty) return;
    final points = visibleFixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);

    if (_showHeatmap) {
      // Heatmap mode: one translucent blurred dot per fix; overlapping
      // circles produce hot spots at frequently-visited locations
      // automatically. Replaces the pre-MapLibre custom 0.001°-grid
      // bucketing.
      for (final p in points) {
        await c.addCircle(CircleOptions(
          geometry: p,
          circleRadius: 18,
          circleColor: scheme.tertiary.toHexStringRGB(),
          circleOpacity: 0.18,
          circleBlur: 0.5,
        ));
      }
      return;
    }

    if (_showPath && points.length >= 2) {
      await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 3,
        lineOpacity: 0.85,
      ));
    }
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
  }

  Future<void> _fitToFixes(List<Ping> visibleFixes) async {
    final c = _controller;
    if (c == null || visibleFixes.isEmpty) return;
    if (visibleFixes.length == 1) {
      await c.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(visibleFixes.first.lat!, visibleFixes.first.lon!),
          14,
        ),
      );
      return;
    }
    var minLat = visibleFixes.first.lat!, maxLat = minLat;
    var minLon = visibleFixes.first.lon!, maxLon = minLon;
    for (final p in visibleFixes) {
      if (p.lat! < minLat) minLat = p.lat!;
      if (p.lat! > maxLat) maxLat = p.lat!;
      if (p.lon! < minLon) minLon = p.lon!;
      if (p.lon! > maxLon) maxLon = p.lon!;
    }
    await c.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      left: 40,
      top: 40,
      right: 40,
      bottom: 40,
    ));
  }

  /// Move the slider one ping forward / backward along `chrono`. Pure
  /// dispatch to [stepSliderTo] — split out as a top-level so the
  /// playback dupe-timestamp fix can be unit-tested without spinning
  /// up a `MapLibreMap` (which `flutter_test` can't mount).
  DateTime _stepTo(List<Ping> chrono, DateTime current, int delta) =>
      stepSliderTo(chrono, current, delta);

  void _togglePlayback(List<Ping> chrono) {
    if (_playing) {
      _pausePlayback();
      return;
    }
    if (chrono.length < 2) return;
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
      milliseconds: (_basePlaybackStep.inMilliseconds / _playbackSpeed)
          .round()
          .clamp(16, 2000),
    );
    _playbackTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      final current = _sliderMax ?? chrono.last.timestampUtc;
      final next = _stepTo(chrono, current, 1);
      if (!next.isAfter(current)) {
        _pausePlayback();
        return;
      }
      setState(() => _sliderMax = next);
      _refreshAnnotationsIfReady();
    });
  }

  void _pausePlayback() {
    if (_playbackTimer == null && !_playing) return;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    if (_playing) setState(() => _playing = false);
  }

  /// Cycle 1× → 2× → 4× → 8× → 16× → 1×. Restart the active timer at
  /// the new cadence so speed changes are felt immediately.
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

/// Slider step logic — public so unit tests can hit it without a
/// widget tree. See `_MapScreenState._stepTo` for context.
///
/// Pivots on the **last** index whose timestamp is at-or-before
/// `current` (not the first one ≥ `current`). The earlier
/// first-match version broke playback on duplicate `ts_utc` rows
/// mid-trail (panic-burst pings, same-millisecond retries) — stepping
/// forward returned the dupe's own timestamp, the playback loop's
/// `next.isAfter(current)` guard fired, and the timer paused
/// spuriously around the dupe. Pivoting on the last match means a
/// forward step always lands on a strictly later index.
DateTime stepSliderTo(List<Ping> chrono, DateTime current, int delta) {
  if (chrono.isEmpty) return current;
  var idx = 0;
  for (var i = 0; i < chrono.length; i++) {
    if (chrono[i].timestampUtc.isAfter(current)) break;
    idx = i;
  }
  final target = (idx + delta).clamp(0, chrono.length - 1);
  return chrono[target].timestampUtc;
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
    final currentMs =
        current.millisecondsSinceEpoch - first.millisecondsSinceEpoch;
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
              value:
                  disabled ? 0 : currentMs.clamp(0, totalMs).toDouble(),
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
