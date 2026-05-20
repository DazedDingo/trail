import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import '../providers/map_settings_provider.dart';
import '../providers/mbtiles_provider.dart';
import '../providers/pings_provider.dart';
import '../providers/tile_server_provider.dart';
import '../services/mbtiles_service.dart';
import '../services/trail_style.dart';
import 'inline_date_filter_panel.dart';
import 'ping_photos_gallery.dart';
import 'slideshow_view.dart';

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

  /// Whether the inline date-filter panel is expanded. Tapping the
  /// calendar icon in the control row flips this; chips inside the
  /// panel apply a range and close it. Replaces the full-screen
  /// `showDateRangePicker` modal as the default entry point (the
  /// modal is still reachable via the panel's "Custom range…" chip
  /// for granular two-ended selection).
  bool _calendarOpen = false;

  /// Picture-mode playback. When true, the map body is replaced with a
  /// `SlideshowView` slaved to the same `_sliderMax` cursor that drives
  /// path-mode annotations. Toggling does NOT reset playback state —
  /// the timer, current frame, and speed cycle keep their values so the
  /// user can flip back and forth mid-trail without losing position.
  bool _slideshowMode = false;

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

  /// Drop every piece of annotation-tracking state so the next render
  /// starts from a clean slate. Used by both `_openDateFilterSheet` and
  /// `_clearDateFilter` — the bug they're fixing is that without this
  /// reset, stale `_renderedCircles` references survive across map
  /// remounts (which happen when `pingsByRangeProvider`'s family key
  /// changes and `pingsAsync.when` flips through `loading` to `data`,
  /// disposing the MapLibreMap and recreating it). The old controller's
  /// in-flight refresh would race with the new controller's
  /// `onStyleLoaded` → `_scheduleRefresh`, and the previous filter's
  /// circles could leak onto the new map.
  void _resetAnnotationTrackingOnFilterChange() {
    _styleReady = false;
    _controller = null;
    _heatmapMounted = false;
    _circleToPing.clear();
    _renderedPathFixes = null;
    _pathLine = null;
    _renderedCircles = [];
    _pathRenderKey = null;
    // Drop any pending refresh job — the new controller will get its
    // own _scheduleRefresh from onStyleLoadedCallback once it mounts.
    _pendingRefreshFixes = null;
    _pendingRefreshScheme = null;
  }

  /// Toggle the inline date-filter panel. Replaces the previous
  /// `showDateRangePicker` modal as the calendar icon's tap handler.
  /// The panel itself surfaces preset chips + a "Custom range…" expander
  /// that opens the system picker for two-ended selection.
  void _toggleCalendar() {
    if (!mounted) return;
    setState(() => _calendarOpen = !_calendarOpen);
  }

  /// Applied range — null means "no filter". Resets annotation tracking
  /// so the new range renders cleanly (the same state-reset path the
  /// previous modal flow used; see `_resetAnnotationTrackingOnFilterChange`
  /// for the rationale).
  void _applyDateFilter(DateTimeRange? range) {
    if (!mounted) return;
    _pausePlayback();
    setState(() {
      _dateFilter = range;
      _sliderMax = null;
      _initialFitDone = false;
      _calendarOpen = false;
      _resetAnnotationTrackingOnFilterChange();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshAnnotationsIfReady();
    });
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
    // **Default cursor is the earliest fix in the filter, not the
    // latest.** Playback meaningfully starts from the beginning of
    // the visible window; staying at the end meant the user had to
    // tap "Jump to first" before every play. The "Latest" reset
    // button still gets the user back to "show everything" with one
    // tap.
    final sliderMax = _sliderMax ?? first;
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
          calendarOpen: _calendarOpen,
          showHeatmap: _showHeatmap,
          showPath: _showPath,
          liveDotOn: liveDotOn,
          liveDotLoading: liveDotLoading,
          slideshowMode: _slideshowMode,
          onOpenFilter: _toggleCalendar,
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
          onToggleSlideshow: () =>
              setState(() => _slideshowMode = !_slideshowMode),
          onExpand: widget.onExpand,
        ),
        InlineDateFilterPanel(
          open: _calendarOpen,
          currentRange: _dateFilter,
          now: DateTime.now(),
          earliestPing: chrono.isEmpty
              ? DateTime.now().toUtc().subtract(const Duration(days: 365))
              : chrono.first.timestampUtc,
          latestPing:
              chrono.isEmpty ? DateTime.now().toUtc() : chrono.last.timestampUtc,
          onApply: _applyDateFilter,
          onClose: () {
            if (mounted) setState(() => _calendarOpen = false);
          },
        ),
        Expanded(
          child: _slideshowMode
              ? SlideshowView(
                  visibleFixes: visible,
                  sliderMax: sliderMax,
                  hasAnyFixes: chrono.isNotEmpty,
                )
              : FutureBuilder<String?>(
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
          onRwd5: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, -5));
            _refreshAnnotationsIfReady();
          },
          onFwd5: () {
            _pausePlayback();
            setState(() => _sliderMax = _stepTo(chrono, sliderMax, 5));
            _refreshAnnotationsIfReady();
          },
          onTogglePlay: () => _togglePlayback(chrono),
          onPickSpeed: _pickSpeed,
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
    // Capture the previous key BEFORE we mutate it — the strategy
    // helper below relies on the comparison to decide between
    // from-scratch and incremental render paths.
    final prevRenderKey = _pathRenderKey;
    final renderKeyChanged = renderKey != prevRenderKey;

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
    final strategy = choosePathRenderStrategy(
      prevRenderKey: prevRenderKey,
      currentRenderKey: renderKey,
      prev: prev,
      visible: visibleFixes,
    );
    switch (strategy) {
      case PathRenderStrategy.noOp:
        return;
      case PathRenderStrategy.incrementalForward:
        await _renderPathIncrementalForward(
            c, visibleFixes, prev!.length, scheme);
      case PathRenderStrategy.incrementalBackward:
        await _renderPathIncrementalBackward(
            c, visibleFixes, prev!.length, scheme);
      case PathRenderStrategy.fromScratch:
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
    // Pressing play after playback ended (cursor at the last fix) or
    // from a fresh-open state with no explicit cursor rewinds to the
    // very first fix in the filter. Default cursor is also first now
    // (see `_buildBody`), so this is the only place that needs the
    // edge-case rewind when the user replayed once already.
    final atEnd = _sliderMax != null &&
        !_sliderMax!.isBefore(chrono.last.timestampUtc);
    if (atEnd) {
      setState(() => _sliderMax = chrono.first.timestampUtc);
    }
    _startPlaybackTimer(chrono);
    setState(() => _playing = true);
  }

  void _startPlaybackTimer(List<Ping> chrono) {
    _playbackTimer?.cancel();
    final interval = playbackInterval(_basePlaybackStep, _playbackSpeed);
    _playbackTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      // Fallback to the EARLIEST fix when the slider has never been
      // touched. The previous fallback was `chrono.last`, which made
      // the first tick of a fresh play immediately bail out via the
      // `!next.isAfter(current)` guard — exactly the "playback won't
      // start" bug that motivated the "start at earliest" UX change.
      final current = _sliderMax ?? chrono.first.timestampUtc;
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

  void _pickSpeed(double next) {
    if (next == _playbackSpeed) return;
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

/// The three possible render strategies for the path-mode annotation
/// pass. Exposed for unit tests so the decision tree is locked.
enum PathRenderStrategy {
  /// Filter / mode / path-toggle changed — wipe every existing line
  /// and circle, then add the new fixes from scratch.
  fromScratch,

  /// Same render key, visibleFixes extends the previous list — add
  /// just the new tail circles + nudge the previous head's styling.
  incrementalForward,

  /// Same render key, visibleFixes is a prefix of the previous list —
  /// pop trailing circles + reset path line.
  incrementalBackward,

  /// Same render key + same fix count + same prefix — already
  /// rendered, nothing to do.
  noOp,
}

/// Picks the render strategy for the next path-mode refresh. The
/// "same-prefix" test uses `identical(prev.first, visible.first)`
/// deliberately — different DAO reads produce different `Ping`
/// instances even for the same row, so identity tells us "yes this is
/// the same in-memory list, just one step longer / shorter".
PathRenderStrategy choosePathRenderStrategy({
  required String? prevRenderKey,
  required String currentRenderKey,
  required List<Ping>? prev,
  required List<Ping> visible,
}) {
  if (currentRenderKey != prevRenderKey) {
    return PathRenderStrategy.fromScratch;
  }
  if (prev == null || prev.isEmpty || visible.isEmpty) {
    return PathRenderStrategy.fromScratch;
  }
  if (!identical(prev.first, visible.first)) {
    return PathRenderStrategy.fromScratch;
  }
  if (visible.length == prev.length) return PathRenderStrategy.noOp;
  if (visible.length > prev.length) {
    return PathRenderStrategy.incrementalForward;
  }
  return PathRenderStrategy.incrementalBackward;
}

/// Ordered playback-speed cycle. Tapping the speed chip in the playback
/// HUD walks through these values; tapping past the fastest wraps to the
/// slowest. Order is **slow → fast** so the chip's label reads naturally
/// as the user increases speed. Sub-1× speeds were added in 0.12.0 so
/// the user can study high-frequency panic-burst pings frame by frame.
const List<double> kPlaybackSpeeds = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0];

/// Returns the next speed in [kPlaybackSpeeds] after [current], wrapping
/// past 16× back to 0.25×. Tolerates a [current] that isn't in the cycle
/// (e.g. a persisted value from a future build with more speeds) by
/// snapping to the closest cycle entry first.
double nextPlaybackSpeed(double current) {
  var bestIdx = 0;
  var bestDelta = double.infinity;
  for (var i = 0; i < kPlaybackSpeeds.length; i++) {
    final d = (kPlaybackSpeeds[i] - current).abs();
    if (d < bestDelta) {
      bestDelta = d;
      bestIdx = i;
    }
  }
  return kPlaybackSpeeds[(bestIdx + 1) % kPlaybackSpeeds.length];
}

/// Computes the Timer.periodic interval for a given playback speed.
/// Clamps to `[16ms, 4000ms]` — the lower bound matches one display
/// frame at 60Hz so faster speeds don't queue overlapping callbacks; the
/// upper bound (4s) lets the 0.25× speed render naturally
/// (`350ms / 0.25 = 1400ms` per step, well inside the cap) while still
/// catching pathological inputs (e.g. speed=0 returning Infinity).
///
/// Pure + exported so unit tests can hit it without a widget tree.
Duration playbackInterval(Duration baseStep, double speed) {
  if (speed <= 0) speed = 1.0; // defensive — speed=0 → infinity loop
  return Duration(
    milliseconds:
        (baseStep.inMilliseconds / speed).round().clamp(16, 4000),
  );
}

/// Human-facing label for the playback HUD's speed chip. Integer speeds
/// render as `2×`, `16×`; sub-integer speeds with one decimal (`0.5×`)
/// unless they need two (`0.25×`). Kept consistent with the cycle so the
/// chip never collapses two different speeds to the same label.
String formatPlaybackSpeedLabel(double speed) {
  if (speed == speed.roundToDouble()) {
    return '${speed.toStringAsFixed(0)}×';
  }
  // Match the cycle's two distinct sub-1× speeds explicitly — anything
  // tightening from 0.25 to 0.2 would alias against 0.25.
  if ((speed * 100).round() % 10 != 0) {
    return '${speed.toStringAsFixed(2)}×';
  }
  return '${speed.toStringAsFixed(1)}×';
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
  /// True while the InlineDateFilterPanel is expanded. Flips the
  /// calendar icon to the "close" affordance so the row's button
  /// reads as a toggle, not a one-way modal launcher.
  final bool calendarOpen;
  final bool showHeatmap;
  final bool showPath;
  final bool liveDotOn;
  final bool liveDotLoading;
  /// Picture-mode playback toggle. True swaps the map body for the
  /// SlideshowView; the same play/pause + speed cycle drives both.
  final bool slideshowMode;
  final VoidCallback onOpenFilter;
  final VoidCallback onToggleHeatmap;
  final VoidCallback onTogglePath;
  final VoidCallback onToggleLiveDot;
  final VoidCallback onOpenRegions;
  final VoidCallback onToggleSlideshow;
  // Null when the panel already fills the screen (i.e. it IS the full
  // map screen). Non-null on Home, where the panel is embedded inline
  // and we want a one-tap escape hatch to a full-screen variant.
  final VoidCallback? onExpand;

  const _ControlRow({
    required this.dateFilterActive,
    required this.calendarOpen,
    required this.showHeatmap,
    required this.showPath,
    required this.liveDotOn,
    required this.liveDotLoading,
    required this.slideshowMode,
    required this.onOpenFilter,
    required this.onToggleHeatmap,
    required this.onTogglePath,
    required this.onToggleLiveDot,
    required this.onToggleSlideshow,
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
            tooltip: calendarOpen
                ? 'Close date filter'
                : (dateFilterActive
                    ? 'Filter active — tap to change/clear'
                    : 'Filter by date range'),
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(
              calendarOpen
                  ? Icons.event_busy_outlined
                  : (dateFilterActive
                      ? Icons.event_available
                      : Icons.date_range_outlined),
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
            tooltip:
                slideshowMode ? 'Back to map view' : 'Picture slideshow',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: Icon(
              slideshowMode ? Icons.map_outlined : Icons.slideshow_outlined,
            ),
            onPressed: onToggleSlideshow,
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
  final VoidCallback onRwd5;
  final VoidCallback onFwd5;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onPickSpeed;

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
    required this.onRwd5,
    required this.onFwd5,
    required this.onTogglePlay,
    required this.onPickSpeed,
  });

  @override
  Widget build(BuildContext context) {
    final totalMs = last.millisecondsSinceEpoch - first.millisecondsSinceEpoch;
    final currentMs =
        current.millisecondsSinceEpoch - first.millisecondsSinceEpoch;
    final disabled = totalMs <= 0;
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('MMM d, HH:mm');
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
              _Jump5Button(
                tooltip: 'Rewind 5 fixes',
                icon: Icons.fast_rewind,
                onPressed: disabled ? null : onRwd5,
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
              _Jump5Button(
                tooltip: 'Fast-forward 5 fixes',
                icon: Icons.fast_forward,
                onPressed: disabled ? null : onFwd5,
              ),
              const SizedBox(width: 4),
              _SpeedPickerButton(
                current: playbackSpeed,
                onPick: onPickSpeed,
                disabled: disabled,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Skip N pings" button with a small `5` badge stacked over the icon
/// so the user can read at a glance how much each tap moves the
/// cursor. We deliberately don't expose N as a setting yet — five is
/// the right step for the typical 4-hour cadence (a full day's worth
/// of context) but could be revisited if someone runs the 30 min
/// cadence and the jump feels too short.
class _Jump5Button extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _Jump5Button({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          Positioned(
            right: -6,
            bottom: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '5',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Speed picker — replaces the prior "tap-to-cycle" chip with a direct
/// `PopupMenuButton<double>` of every entry in [kPlaybackSpeeds]. One
/// tap opens the menu; a second tap picks the target speed. The chip
/// itself still shows the current speed (`2×`, `0.25×`, …) so the
/// HUD reads the same as before when the menu is closed.
class _SpeedPickerButton extends StatelessWidget {
  final double current;
  final ValueChanged<double> onPick;
  final bool disabled;

  const _SpeedPickerButton({
    required this.current,
    required this.onPick,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<double>(
      enabled: !disabled,
      tooltip: 'Playback speed',
      initialValue: current,
      onSelected: onPick,
      position: PopupMenuPosition.over,
      itemBuilder: (ctx) => [
        for (final s in kPlaybackSpeeds)
          PopupMenuItem<double>(
            value: s,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: s == current
                      ? Icon(Icons.check, size: 16, color: scheme.primary)
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: 4),
                Text(formatPlaybackSpeedLabel(s)),
              ],
            ),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(minWidth: 56, minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatPlaybackSpeedLabel(current),
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: scheme.onSecondaryContainer,
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

class _PingDetailSheet extends ConsumerWidget {
  final Ping ping;
  const _PingDetailSheet({required this.ping});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          // Photos gallery — auto-fetched + user-attached. Hidden on
          // pings with no rowid (shouldn't happen for circle taps, but
          // defensive). Sheet stays open after add/remove so the user
          // can attach multiple in one session.
          if (ping.id != null) PingPhotosGallery(pingId: ping.id!),
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
          if (ping.comment != null && ping.comment!.isNotEmpty)
            _row('Comment', ping.comment!),
          if (ping.id != null) ...[
            const SizedBox(height: 12),
            _DeletePingButton(ping: ping),
          ],
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

/// Destructive "Delete this pin" affordance pinned to the bottom of the
/// pin-detail sheet. Confirms first — pin deletion is unrecoverable
/// because the only redo path is "wait for the next scheduled fix",
/// which lands at a different timestamp and almost certainly different
/// coords. Cascades to `ping_photos` rows in the same DB transaction
/// (SQLCipher's FK enforcement is off; see `PingDao.deleteById`).
class _DeletePingButton extends ConsumerStatefulWidget {
  final Ping ping;
  const _DeletePingButton({required this.ping});

  @override
  ConsumerState<_DeletePingButton> createState() => _DeletePingButtonState();
}

class _DeletePingButtonState extends ConsumerState<_DeletePingButton> {
  bool _deleting = false;

  Future<void> _confirmAndDelete() async {
    final ping = widget.ping;
    final fmt = DateFormat('EEE MMM d, HH:mm:ss');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this pin?'),
        content: Text(
          'Removes the ${fmt.format(ping.timestampUtc.toLocal())} ping + '
          'any attached photos. Cannot be undone — the only way to '
          '"redo" is to wait for the next scheduled fix.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    final id = ping.id;
    if (id == null) {
      // Defensive — the sheet only renders the button when ping.id is
      // non-null, but a race against the parent setState shouldn't crash.
      return;
    }
    try {
      final db = await TrailDatabase.shared();
      await PingDao(db).deleteById(id);
      // Invalidate every provider that hangs off the pings table so the
      // map, history, and trip-detection all pick up the gap immediately.
      ref.invalidate(allPingsProvider);
      ref.invalidate(recentPingsProvider);
      ref.invalidate(pingsByRangeProvider);
      if (mounted) Navigator.of(context).pop(); // close the detail sheet
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete pin: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: _deleting ? null : _confirmAndDelete,
        icon: _deleting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(scheme.error),
                ),
              )
            : Icon(Icons.delete_outline, size: 18, color: scheme.error),
        label: Text(
          _deleting ? 'Deleting…' : 'Delete this pin',
          style: TextStyle(color: scheme.error),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
        ),
      ),
    );
  }
}
