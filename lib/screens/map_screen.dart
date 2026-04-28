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

  /// Optional explicit start/end filter; both null means "show every
  /// ping ever logged". When set, the time slider's range and the
  /// rendered annotations are clamped to this window. Cleared by
  /// tapping the calendar icon → "Clear filter".
  DateTimeRange? _dateFilter;

  /// Maps each rendered Circle annotation back to the underlying Ping
  /// row so taps can pop a detail sheet. Cleared on every
  /// `_refreshAnnotations` call (clearCircles wipes the platform side
  /// too) and re-built as circles are added back.
  final Map<String, Ping> _circleToPing = {};

  /// Whether the heatmap GeoJSON source + layer are currently mounted
  /// on the platform side. Tracked so we don't try to add twice or
  /// remove a non-existent layer.
  bool _heatmapMounted = false;
  static const _heatmapSourceId = 'trail-heatmap-src';
  static const _heatmapLayerId = 'trail-heatmap-lyr';

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
      // Style swap → fresh controller → any platform-side annotation
      // state we tracked is gone. Reset our bookkeeping so we don't
      // try to remove/update layers on the new instance that don't
      // exist there.
      _heatmapMounted = false;
      _circleToPing.clear();
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
            tooltip: _dateFilter == null
                ? 'Filter by date range'
                : 'Filter active — tap to change/clear',
            icon: Icon(
              _dateFilter == null
                  ? Icons.date_range_outlined
                  : Icons.event_available,
            ),
            onPressed: _openDateFilterSheet,
          ),
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
          final allFixes = pings
              .where((p) => p.lat != null && p.lon != null)
              .toList(growable: false);
          if (allFixes.isEmpty) {
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
          // Apply the optional date filter. The filtered list is what
          // the slider, annotation refresh, and bbox-fit all see; the
          // unfiltered tail outside the window is invisible to the
          // map for as long as the filter is active.
          final fixes = _dateFilter == null
              ? allFixes
              : allFixes
                  .where((p) =>
                      !p.timestampUtc.isBefore(_dateFilter!.start) &&
                      !p.timestampUtc
                          .isAfter(_dateFilter!.end.add(
                              const Duration(days: 1) -
                                  const Duration(milliseconds: 1))))
                  .toList(growable: false);
          if (fixes.isEmpty) {
            return _EmptyState(
              message:
                  'No fixes in '
                  '${_formatRange(_dateFilter!)}. '
                  'Tap the calendar icon to clear or change the filter.',
            );
          }
          return _buildBody(context, fixes, activeRegion);
        },
      ),
    );
  }

  Future<void> _openDateFilterSheet() async {
    final allPings = ref.read(allPingsProvider).valueOrNull ?? const [];
    final fixes = allPings
        .where((p) => p.lat != null && p.lon != null)
        .toList(growable: false);
    final earliest = fixes.isEmpty
        ? DateTime.now().toUtc().subtract(const Duration(days: 365))
        : fixes.first.timestampUtc;
    final latest = fixes.isEmpty
        ? DateTime.now().toUtc()
        : fixes.last.timestampUtc;
    final initial = _dateFilter ??
        DateTimeRange(
          start: latest.subtract(const Duration(days: 7)).toLocal(),
          end: latest.toLocal(),
        );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: earliest.toLocal().subtract(const Duration(days: 1)),
      lastDate: latest.toLocal().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: initial.start.isBefore(earliest.toLocal())
            ? earliest.toLocal()
            : initial.start,
        end: initial.end.isAfter(latest.toLocal())
            ? latest.toLocal()
            : initial.end,
      ),
      helpText: 'Filter trail by date',
      saveText: 'Apply',
    );
    if (picked == null) return;
    if (!mounted) return;
    _pausePlayback();
    setState(() {
      _dateFilter = picked;
      _sliderMax = null;
      _initialFitDone = false; // re-fit camera to the new bbox
    });
    _refreshAnnotationsIfReady();
  }

  void _clearDateFilter() {
    if (_dateFilter == null) return;
    _pausePlayback();
    setState(() {
      _dateFilter = null;
      _sliderMax = null;
      _initialFitDone = false;
    });
    _refreshAnnotationsIfReady();
  }

  String _formatRange(DateTimeRange r) {
    final fmt = DateFormat.yMMMd();
    return '${fmt.format(r.start)} – ${fmt.format(r.end)}';
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
        if (_dateFilter != null)
          _DateFilterBanner(
            range: _dateFilter!,
            label: _formatRange(_dateFilter!),
            onClear: _clearDateFilter,
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
          // Native blue-dot live-location indicator. Trail's logger
          // already has fine-location permission so the plugin's
          // FusedLocationProvider source spins up immediately.
          // Tracking mode none = show the dot but don't auto-pan,
          // since the user is reviewing trail history.
          myLocationEnabled: true,
          myLocationTrackingMode: MyLocationTrackingMode.none,
          attributionButtonPosition: AttributionButtonPosition.bottomRight,
          onMapCreated: (c) {
            _controller = c;
            // Wire tap-to-inspect — every Circle annotation we add
            // gets recorded in `_circleToPing`; tapping the rendered
            // circle pops a detail sheet for that ping.
            c.onCircleTapped.add(_handleCircleTap);
          },
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
    _circleToPing.clear();
    if (visibleFixes.isEmpty) {
      await _setHeatmap(c, false, const [], scheme);
      return;
    }
    final points = visibleFixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);

    if (_showHeatmap) {
      // Real maplibre-native heatmap layer driven by a GeoJSON source.
      // Replaces the pre-0.9.1 per-ping CircleLayer fudge — proper
      // density-weighted Gaussian blending, scales to thousands of
      // fixes without a thousand annotations on the platform side.
      await _setHeatmap(c, true, visibleFixes, scheme);
      return;
    }

    await _setHeatmap(c, false, const [], scheme);

    if (_showPath && points.length >= 2) {
      await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 3,
        lineOpacity: 0.85,
      ));
    }
    for (var i = 0; i < points.length - 1; i++) {
      final circle = await c.addCircle(CircleOptions(
        geometry: points[i],
        circleRadius: 4,
        circleColor: scheme.primary.toHexStringRGB(),
        circleStrokeWidth: 1,
        circleStrokeColor: '#FFFFFF',
        circleStrokeOpacity: 0.85,
      ));
      _circleToPing[circle.id] = visibleFixes[i];
    }
    final lastCircle = await c.addCircle(CircleOptions(
      geometry: points.last,
      circleRadius: 8,
      circleColor: scheme.tertiary.toHexStringRGB(),
      circleStrokeWidth: 2,
      circleStrokeColor: '#FFFFFF',
      circleStrokeOpacity: 0.95,
    ));
    _circleToPing[lastCircle.id] = visibleFixes.last;
  }

  /// Mount or unmount the heatmap source + layer. Idempotent — checks
  /// `_heatmapMounted` so a no-op call doesn't fight the platform side.
  /// When mounting, builds a GeoJSON FeatureCollection from the
  /// visible fixes and a tertiary-tinted density gradient.
  Future<void> _setHeatmap(
    MapLibreMapController c,
    bool show,
    List<Ping> visibleFixes,
    ColorScheme scheme,
  ) async {
    if (!show) {
      if (!_heatmapMounted) return;
      try {
        await c.removeLayer(_heatmapLayerId);
      } catch (_) {/* layer already gone */}
      try {
        await c.removeSource(_heatmapSourceId);
      } catch (_) {/* source already gone */}
      _heatmapMounted = false;
      return;
    }
    final geo = {
      'type': 'FeatureCollection',
      'features': [
        for (final p in visibleFixes)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [p.lon, p.lat],
            },
            'properties': const <String, Object?>{},
          },
      ],
    };
    if (_heatmapMounted) {
      await c.setGeoJsonSource(_heatmapSourceId, geo);
      return;
    }
    await c.addGeoJsonSource(_heatmapSourceId, geo);
    final tertHex = scheme.tertiary.toHexStringRGB();
    final tertR = scheme.tertiary.r.round();
    final tertG = scheme.tertiary.g.round();
    final tertB = scheme.tertiary.b.round();
    await c.addHeatmapLayer(
      _heatmapSourceId,
      _heatmapLayerId,
      HeatmapLayerProperties(
        heatmapRadius: 30,
        heatmapIntensity: 1,
        heatmapOpacity: 0.7,
        heatmapColor: [
          'interpolate',
          ['linear'],
          ['heatmap-density'],
          0.0, 'rgba($tertR,$tertG,$tertB,0)',
          0.2, 'rgba($tertR,$tertG,$tertB,0.4)',
          0.6, tertHex,
          1.0, '#ffffff',
        ],
      ),
    );
    _heatmapMounted = true;
  }

  /// Tap handler for trail-ping circles — pops a bottom sheet with the
  /// underlying ping's full row (timestamp, accuracy, battery, etc.).
  /// Heatmap circles are not in the mapping (different code path)
  /// so taps on them silently do nothing.
  void _handleCircleTap(Circle circle) {
    final ping = _circleToPing[circle.id];
    if (ping == null) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: _PingDetailSheet(ping: ping),
      ),
    );
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

class _DateFilterBanner extends StatelessWidget {
  final DateTimeRange range;
  final String label;
  final VoidCallback onClear;
  const _DateFilterBanner({
    required this.range,
    required this.label,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.event_available,
                size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Filter: $label',
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              child: const Text('Clear'),
            ),
          ],
        ),
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

class _PingDetailSheet extends StatelessWidget {
  final Ping ping;
  const _PingDetailSheet({required this.ping});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEE MMM d, HH:mm:ss');
    final tsLocal = ping.timestampUtc.toLocal();
    final lat = ping.lat?.toStringAsFixed(5) ?? '—';
    final lon = ping.lon?.toStringAsFixed(5) ?? '—';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            fmt.format(tsLocal),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            ping.source.name,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          _row('Lat / Lon', '$lat, $lon'),
          if (ping.accuracy != null)
            _row('Accuracy', '±${ping.accuracy!.toStringAsFixed(0)} m'),
          if (ping.altitude != null)
            _row('Altitude', '${ping.altitude!.toStringAsFixed(0)} m'),
          if (ping.speed != null)
            _row('Speed', '${ping.speed!.toStringAsFixed(1)} m/s'),
          if (ping.batteryPct != null)
            _row('Battery', '${ping.batteryPct}%'),
          if (ping.networkState != null)
            _row('Network', ping.networkState!),
          if (ping.cellId != null) _row('Cell', ping.cellId!),
          if (ping.wifiSsid != null) _row('Wi-Fi', ping.wifiSsid!),
          if (ping.note != null) _row('Note', ping.note!),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
