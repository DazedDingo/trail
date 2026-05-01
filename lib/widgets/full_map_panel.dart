import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../models/ping.dart';
import '../providers/map_settings_provider.dart';
import '../providers/mbtiles_provider.dart';
import '../providers/pings_provider.dart';
import '../providers/tile_server_provider.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';

/// Reusable map panel with playback / heatmap / path / filter controls.
///
/// Lifted from `_MapScreenState` so the home screen and `/map` can share
/// the same MapLibre rig. Caller controls the vertical envelope via
/// [height]; internally the map uses an `Expanded` so the time slider +
/// control row sit at fixed heights and the map fills the rest.
///
/// Behaviour mirrors the original full-screen experience exactly: time
/// slider scrubs, play/pause/step/1×-16× cycle, heatmap + path-line
/// toggles, calendar date filter, blue-dot live-location toggle, link
/// to Regions. State + handlers were lifted 1:1.
class FullMapPanel extends ConsumerStatefulWidget {
  /// Required vertical envelope. The map fills whatever's left after the
  /// (fixed-height) control row + time slider + optional filter banner.
  /// `double.infinity` is fine inside an `Expanded` parent.
  final double height;

  /// Optional pre-applied filter — set when the panel is opened via
  /// `context.push('/map', extra: DateTimeRange(...))` from elsewhere
  /// (e.g. the stats screen's heatmap day-tap or trip card). The user
  /// can still clear or change it from the calendar action.
  final DateTimeRange? initialFilter;

  /// Optional "expand to full screen" callback. Surfaces an expand icon
  /// in the control row when provided (Home embeds the panel inline and
  /// wants the option to bounce to a full-screen variant). null hides
  /// the icon — `/map` already IS the full-screen variant so it doesn't
  /// need to expand any further.
  final VoidCallback? onExpand;

  const FullMapPanel({
    super.key,
    required this.height,
    this.initialFilter,
    this.onExpand,
  });

  @override
  ConsumerState<FullMapPanel> createState() => _FullMapPanelState();
}

class _FullMapPanelState extends ConsumerState<FullMapPanel> {
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
  late DateTimeRange? _dateFilter = widget.initialFilter;

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

  /// State of the most recent path-mode render. The slider value
  /// changes faster than maplibre_gl's annotation channel can clear
  /// + re-add hundreds of circles, so playback at high ping counts
  /// went choppy. Tracking these refs lets the next refresh decide
  /// between "incremental forward" (add the delta circles + nudge
  /// styling), "incremental backward" (pop trailing circles), or
  /// "full rebuild" (filter / mode change). Reset on style swap.
  List<Ping>? _renderedPathFixes;
  Line? _pathLine;
  List<Circle> _renderedCircles = [];
  String? _pathRenderKey;

  /// Single-flight serialization for [_refreshAnnotations]. See
  /// `map_screen.dart` history for why this exists — a 60 fps slider
  /// drag races on `_renderedCircles` without it.
  List<Ping>? _pendingRefreshFixes;
  ColorScheme? _pendingRefreshScheme;
  bool _refreshLoopActive = false;

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
    final pingsAsync = ref.watch(pingsByRangeProvider(_dateFilter));
    final activeRegion = ref.watch(activeRegionProvider).valueOrNull;
    final tileServerPort = ref.watch(tileServerProvider).valueOrNull;
    final liveDotState = ref.watch(liveLocationDotEnabledProvider);
    final liveDotOn = liveDotState.asData?.value ?? true;

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
      _heatmapMounted = false;
      _circleToPing.clear();
      _renderedPathFixes = null;
      _pathLine = null;
      _renderedCircles = [];
      _pathRenderKey = null;
    }

    return SizedBox(
      height: widget.height,
      child: pingsAsync.when(
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
                  'Tap the layers icon → Install.',
            );
          }
          return _buildBody(context, allFixes, activeRegion, liveDotOn,
              liveDotState.isLoading);
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
    bool liveDotOn,
    bool liveDotLoading,
  ) {
    final chrono = fixes;
    final first = chrono.first.timestampUtc;
    final last = chrono.last.timestampUtc;
    final sliderMax = _sliderMax ?? last;
    final visible = chrono
        .where((p) => !p.timestampUtc.isAfter(sliderMax))
        .toList(growable: false);

    return Column(
      children: [
        // Compact toggle row mirroring the original /map AppBar actions:
        // calendar filter, heatmap, path-line, live-dot, regions. Lives
        // inside the panel so the home screen can host the full map
        // experience without needing an AppBar of its own.
        _ControlRow(
          dateFilterActive: _dateFilter != null,
          showHeatmap: _showHeatmap,
          showPath: _showPath,
          liveDotOn: liveDotOn,
          liveDotLoading: liveDotLoading,
          onOpenFilter: _openDateFilterSheet,
          onToggleHeatmap: () {
            setState(() => _showHeatmap = !_showHeatmap);
            _refreshAnnotationsIfReady();
          },
          onTogglePath: () {
            setState(() => _showPath = !_showPath);
            _refreshAnnotationsIfReady();
          },
          onToggleLiveDot: () => ref
              .read(liveLocationDotEnabledProvider.notifier)
              .set(!liveDotOn),
          onOpenRegions: () => context.push('/regions'),
          onExpand: widget.onExpand,
        ),
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
    final showLiveDot =
        ref.watch(liveLocationDotEnabledProvider).valueOrNull ?? true;

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
          myLocationEnabled: showLiveDot,
          myLocationTrackingMode: MyLocationTrackingMode.none,
          attributionButtonPosition: AttributionButtonPosition.bottomRight,
          onMapCreated: (c) {
            _controller = c;
            c.onCircleTapped.add(_handleCircleTap);
          },
          onStyleLoadedCallback: () {
            _styleReady = true;
            _scheduleRefresh(
              visibleFixes,
              Theme.of(context).colorScheme,
            );
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
        if (visibleFixes.isNotEmpty)
          Positioned(
            left: 8,
            top: 8,
            child: _PlaybackHud(
              current: visibleFixes.last,
              previous: visibleFixes.length >= 2
                  ? visibleFixes[visibleFixes.length - 2]
                  : null,
            ),
          ),
      ],
    );
  }

  void _refreshAnnotationsIfReady() {
    if (!_styleReady || _controller == null) return;
    final pings = ref.read(pingsByRangeProvider(_dateFilter)).valueOrNull;
    if (pings == null) return;
    final chrono = pings
        .where((p) => p.lat != null && p.lon != null)
        .toList(growable: false);
    if (chrono.isEmpty) return;
    final sliderMax = _sliderMax ?? chrono.last.timestampUtc;
    final visible = chrono
        .where((p) => !p.timestampUtc.isAfter(sliderMax))
        .toList(growable: false);
    _scheduleRefresh(visible, Theme.of(context).colorScheme);
  }

  void _scheduleRefresh(List<Ping> visibleFixes, ColorScheme scheme) {
    _pendingRefreshFixes = visibleFixes;
    _pendingRefreshScheme = scheme;
    if (_refreshLoopActive) return;
    _refreshLoopActive = true;
    unawaited(_runRefreshLoop());
  }

  Future<void> _runRefreshLoop() async {
    try {
      while (_pendingRefreshFixes != null && mounted) {
        final fixes = _pendingRefreshFixes!;
        final scheme = _pendingRefreshScheme!;
        _pendingRefreshFixes = null;
        _pendingRefreshScheme = null;
        await _refreshAnnotations(fixes, scheme);
      }
    } finally {
      _refreshLoopActive = false;
    }
  }

  Future<void> _refreshAnnotations(
    List<Ping> visibleFixes,
    ColorScheme scheme,
  ) async {
    final c = _controller;
    if (c == null) return;
    final mode = _showHeatmap ? 'heatmap' : 'path';
    final renderKey = '$mode|${_dateFilter?.start}|${_dateFilter?.end}'
        '|$_showPath';
    final renderKeyChanged = renderKey != _pathRenderKey;

    if (renderKeyChanged) {
      await c.clearLines();
      await c.clearCircles();
      _circleToPing.clear();
      _renderedPathFixes = null;
      _pathLine = null;
      _renderedCircles = [];
      _pathRenderKey = renderKey;
    }

    if (visibleFixes.isEmpty) {
      await _setHeatmap(c, false, const [], scheme);
      return;
    }

    if (_showHeatmap) {
      await _setHeatmap(c, true, visibleFixes, scheme);
      return;
    }

    await _setHeatmap(c, false, const [], scheme);

    final prev = _renderedPathFixes;
    final samePrefix = !renderKeyChanged &&
        prev != null &&
        prev.isNotEmpty &&
        visibleFixes.isNotEmpty &&
        identical(prev.first, visibleFixes.first);

    if (samePrefix && visibleFixes.length == prev.length) {
      return;
    }

    if (samePrefix && visibleFixes.length > prev.length) {
      await _renderPathIncrementalForward(
          c, visibleFixes, prev.length, scheme);
    } else if (samePrefix && visibleFixes.length < prev.length) {
      await _renderPathIncrementalBackward(
          c, visibleFixes, prev.length, scheme);
    } else {
      await _renderPathFromScratch(c, visibleFixes, scheme);
    }
    _renderedPathFixes = visibleFixes;
  }

  Future<void> _renderPathFromScratch(
    MapLibreMapController c,
    List<Ping> visibleFixes,
    ColorScheme scheme,
  ) async {
    await c.clearLines();
    await c.clearCircles();
    _circleToPing.clear();
    _pathLine = null;
    _renderedCircles = [];

    final points = visibleFixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);

    if (_showPath && points.length >= 2) {
      _pathLine = await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 2,
        lineOpacity: 0.85,
      ));
    }
    for (var i = 0; i < points.length; i++) {
      final circle = await c.addCircle(
        _circleOptionsForIndex(i, points, scheme),
      );
      _circleToPing[circle.id] = visibleFixes[i];
      _renderedCircles.add(circle);
    }
  }

  Future<void> _renderPathIncrementalForward(
    MapLibreMapController c,
    List<Ping> visibleFixes,
    int oldLength,
    ColorScheme scheme,
  ) async {
    final newLength = visibleFixes.length;
    final points = visibleFixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);

    if (oldLength >= 2) {
      final oldPrev = _renderedCircles[oldLength - 2];
      await c.updateCircle(
          oldPrev, _smallOptions(points[oldLength - 2], scheme));
    }
    if (oldLength >= 1) {
      final oldHead = _renderedCircles[oldLength - 1];
      await c.updateCircle(
          oldHead, _prevOptions(points[oldLength - 1], scheme));
    }

    for (var i = oldLength; i < newLength - 1; i++) {
      final circle = await c.addCircle(_smallOptions(points[i], scheme));
      _circleToPing[circle.id] = visibleFixes[i];
      _renderedCircles.add(circle);
    }
    final head = await c.addCircle(_headOptions(points.last, scheme));
    _circleToPing[head.id] = visibleFixes.last;
    _renderedCircles.add(head);

    await _updatePathLine(c, points, scheme);
  }

  Future<void> _renderPathIncrementalBackward(
    MapLibreMapController c,
    List<Ping> visibleFixes,
    int oldLength,
    ColorScheme scheme,
  ) async {
    final newLength = visibleFixes.length;
    final points = visibleFixes
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList(growable: false);

    while (_renderedCircles.length > newLength) {
      final circle = _renderedCircles.removeLast();
      _circleToPing.remove(circle.id);
      try {
        await c.removeCircle(circle);
      } catch (_) {/* best-effort — platform may have already cleared */}
    }

    if (newLength >= 1) {
      final newHead = _renderedCircles[newLength - 1];
      await c.updateCircle(newHead, _headOptions(points.last, scheme));
    }
    if (newLength >= 2) {
      final newPrev = _renderedCircles[newLength - 2];
      await c.updateCircle(
        newPrev,
        _prevOptions(points[newLength - 2], scheme),
      );
    }

    if (_pathLine != null) {
      await c.removeLine(_pathLine!);
      _pathLine = null;
    }
    if (_showPath && newLength >= 2) {
      _pathLine = await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 2,
        lineOpacity: 0.85,
      ));
    }
  }

  Future<void> _updatePathLine(
    MapLibreMapController c,
    List<LatLng> points,
    ColorScheme scheme,
  ) async {
    if (!_showPath) return;
    if (points.length < 2) return;
    if (_pathLine == null) {
      _pathLine = await c.addLine(LineOptions(
        geometry: points,
        lineColor: scheme.primary.toHexStringRGB(),
        lineWidth: 2,
        lineOpacity: 0.85,
      ));
    } else {
      await c.updateLine(_pathLine!, LineOptions(geometry: points));
    }
  }

  CircleOptions _circleOptionsForIndex(
    int i,
    List<LatLng> points,
    ColorScheme scheme,
  ) {
    final last = points.length - 1;
    if (i == last) return _headOptions(points[i], scheme);
    if (i == last - 1) return _prevOptions(points[i], scheme);
    return _smallOptions(points[i], scheme);
  }

  CircleOptions _smallOptions(LatLng p, ColorScheme scheme) => CircleOptions(
        geometry: p,
        circleRadius: 3,
        circleColor: scheme.primary.toHexStringRGB(),
        circleStrokeWidth: 0.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeOpacity: 0.6,
      );

  CircleOptions _prevOptions(LatLng p, ColorScheme scheme) => CircleOptions(
        geometry: p,
        circleRadius: 3,
        circleColor: '#FFB300',
        circleStrokeWidth: 1,
        circleStrokeColor: '#FFFFFF',
        circleStrokeOpacity: 0.95,
      );

  /// Material Red Accent 400 (`#FF1744`) — vivid red that reads
  /// cleanly on any tile palette without needing extra size.
  static const _headFill = '#FF1744';

  CircleOptions _headOptions(LatLng p, ColorScheme scheme) => CircleOptions(
        geometry: p,
        circleRadius: 3,
        circleColor: _headFill,
        circleStrokeWidth: 1,
        circleStrokeColor: '#FFFFFF',
        circleStrokeOpacity: 0.95,
      );

  Future<void> _setHeatmap(
    MapLibreMapController c,
    bool show,
    List<Ping> visibleFixes,
    ColorScheme scheme,
  ) async {
    // Wrap every platform-channel call in defensive try/catch — maplibre_gl
    // 0.26's heatmap layer has been observed to crash the engine on some
    // Android Flutter combos (the symptom looked like Chrome briefly
    // opening then the app crashing). Failing this surface should never
    // take down the rest of Home; we degrade silently and reset the
    // _showHeatmap toggle so the user can try again or fall back to path
    // mode without the toggle getting stuck "on" but visually empty.
    try {
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
      final tertR = (scheme.tertiary.r * 255).round();
      final tertG = (scheme.tertiary.g * 255).round();
      final tertB = (scheme.tertiary.b * 255).round();
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
    } catch (e, st) {
      developer.log(
        'Heatmap toggle failed (show=$show, fixes=${visibleFixes.length}): $e',
        name: 'trail-map',
        stackTrace: st,
      );
      // Reset internal state so the next toggle starts from a known-good
      // baseline rather than trying to mount on top of a half-failed
      // attempt.
      _heatmapMounted = false;
      if (_showHeatmap) {
        if (mounted) {
          setState(() => _showHeatmap = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Heatmap unavailable on this device.'),
            ),
          );
        }
      }
    }
  }

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
      final pings =
          ref.read(pingsByRangeProvider(_dateFilter)).valueOrNull;
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
/// widget tree. See `_FullMapPanelState._stepTo` for context.
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

class _ControlRow extends StatelessWidget {
  final bool dateFilterActive;
  final bool showHeatmap;
  final bool showPath;
  final bool liveDotOn;
  final bool liveDotLoading;
  final VoidCallback onOpenFilter;
  final VoidCallback onToggleHeatmap;
  final VoidCallback onTogglePath;
  final VoidCallback onToggleLiveDot;
  final VoidCallback onOpenRegions;
  // Null when the panel already fills the screen (i.e. it IS the full
  // map screen). Non-null on Home, where the panel is embedded inline
  // and we want a one-tap escape hatch to a full-screen variant.
  final VoidCallback? onExpand;

  const _ControlRow({
    required this.dateFilterActive,
    required this.showHeatmap,
    required this.showPath,
    required this.liveDotOn,
    required this.liveDotLoading,
    required this.onOpenFilter,
    required this.onToggleHeatmap,
    required this.onTogglePath,
    required this.onToggleLiveDot,
    required this.onOpenRegions,
    this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: dateFilterActive
                ? 'Filter active — tap to change/clear'
                : 'Filter by date range',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(
              dateFilterActive
                  ? Icons.event_available
                  : Icons.date_range_outlined,
            ),
            onPressed: onOpenFilter,
          ),
          IconButton(
            tooltip: showHeatmap ? 'Hide heatmap' : 'Show heatmap',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(
              showHeatmap ? Icons.blur_on : Icons.blur_circular_outlined,
            ),
            onPressed: onToggleHeatmap,
          ),
          IconButton(
            tooltip: showPath ? 'Hide path line' : 'Show path line',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(showPath ? Icons.timeline : Icons.scatter_plot),
            onPressed: onTogglePath,
          ),
          IconButton(
            tooltip: liveDotOn
                ? 'Hide live location dot'
                : 'Show live location dot',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(
              liveDotOn ? Icons.my_location : Icons.location_disabled,
            ),
            onPressed: liveDotLoading ? null : onToggleLiveDot,
          ),
          IconButton(
            tooltip: 'Regions',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.layers_outlined),
            onPressed: onOpenRegions,
          ),
          if (onExpand != null)
            IconButton(
              tooltip: 'Open full screen',
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              icon: const Icon(Icons.open_in_full),
              onPressed: onExpand,
            ),
        ],
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

class _PlaybackHud extends StatelessWidget {
  final Ping current;
  final Ping? previous;
  const _PlaybackHud({required this.current, this.previous});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d HH:mm');
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(color: const Color(0xFFFF1744)),
                const SizedBox(width: 5),
                Text(
                  fmt.format(current.timestampUtc.toLocal()),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (previous != null) ...[
              const SizedBox(height: 1),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(color: const Color(0xFFFFB300)),
                  const SizedBox(width: 5),
                  Text(
                    '${fmt.format(previous!.timestampUtc.toLocal())} · '
                    '${_humanGap(current.timestampUtc.difference(previous!.timestampUtc))}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _humanGap(Duration d) {
    if (d.isNegative) d = -d;
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) {
      final m = d.inMinutes % 60;
      return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
    }
    return '${d.inDays}d';
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
