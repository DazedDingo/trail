import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:math' show Point;

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
import '../services/map/pin_geojson.dart';
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
///
/// **Rendering model (0.14.0, PERF_PLAN M1).** Pins are NOT annotations.
/// Every fix in the selected range is uploaded once as a GeoJSON source
/// (`trail-pins-src`, one Point feature with `id` + `ts` properties) plus
/// a companion segments source (`trail-segs-src`, one two-point
/// LineString per consecutive pair tagged with the later `ts`). Native
/// circle / line / heatmap style layers draw them. The time slider never
/// re-uploads: it calls `setFilter` with a `ts` window and one
/// `setLayerProperties` carrying data-driven head/previous styling, so a
/// tick costs the same whether the range holds 100 or 100 000 fixes.
/// The GeoJSON text is built in `Isolate.run` so the UI isolate never
/// JSON-encodes the collection. See `services/map/pin_geojson.dart`.
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

  /// True once `onStyleLoadedCallback` has run for the live controller
  /// AND the pin/segment sources + layers are installed on it. Every
  /// platform call gates on this — before it, the style has nothing of
  /// ours to filter or fill.
  bool _styleReady = false;

  /// Monotonic id per mounted `MapLibreMap`. `onMapCreated` stamps the
  /// controller with the epoch of the map that produced it; the host
  /// widget's `dispose` hands the epoch back so a late teardown of an
  /// OLD map (slideshow toggle, region swap) can't null out the
  /// controller of its replacement.
  int _mapEpoch = 0;
  int _controllerEpoch = -1;

  bool _showPath = true;
  bool _showHeatmap = false;

  /// Whether the heatmap style layer is currently mounted on the
  /// platform side. It shares the pins source, so mounting is just one
  /// `addHeatmapLayer`; tracked so we don't add twice / remove a ghost.
  bool _heatmapMounted = false;

  DateTime? _sliderMax;
  bool _initialFitDone = false;

  /// Optional explicit start/end filter; both null means "show every
  /// ping ever logged". When set, the time slider's range and the
  /// rendered layers are clamped to this window. Cleared by tapping
  /// the calendar icon → "Clear filter".
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
  /// the pin layers. Toggling does NOT reset playback state — the
  /// timer, current frame, and speed cycle keep their values so the
  /// user can flip back and forth mid-trail without losing position.
  bool _slideshowMode = false;

  /// Identity of the provider list [_snap] was built from. The provider
  /// returns the same `List<Ping>` instance on every rebuild until the
  /// data really changes, so `identical` is the cheap "is this new
  /// data?" test for both the snapshot and the upload.
  List<Ping>? _lastPings;
  PinSnapshot _snap = PinSnapshot.empty;

  /// Upload bookkeeping. `_uploadGen` is bumped whenever a new upload
  /// starts OR the current one becomes moot (range change, controller
  /// gone); an in-flight upload compares its captured generation after
  /// every await and drops out if it has been superseded.
  /// `_uploadedListIdentity` is the list instance the live sources hold,
  /// so a rebuild with the identical list never re-uploads.
  int _uploadGen = 0;
  List<Ping>? _uploadedListIdentity;

  static const _pinsSrc = 'trail-pins-src';
  static const _segsSrc = 'trail-segs-src';
  static const _pinsLayer = 'trail-pins-lyr';
  static const _pathLayer = 'trail-path-lyr';
  static const _heatmapLayerId = 'trail-heatmap-lyr';

  /// Fat-finger margin around a tap, in logical pixels. 0.13.9 grew the
  /// pins to 7 px so they could be tapped at all; the native rect query
  /// lets us go further and accept a tap anywhere inside a 48 × 48 dp
  /// box (Material's minimum touch target), picking the nearest pin.
  static const _kTapPadLogicalPx = 24.0;

  /// Below this many fixes the GeoJSON build runs inline — spawning an
  /// isolate costs more than a few hundred `StringBuffer` writes.
  static const _kIsolateThreshold = 256;

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
      // A new style means a new map; whatever controller we hold is
      // about to be torn down with it.
      _forgetController();
    }

    final pings = pingsAsync.valueOrNull;
    if (pings != null && !identical(pings, _lastPings)) {
      _lastPings = pings;
      _snap = buildPinSnapshot(pings);
      // New data ⇒ (re)upload. Platform calls can't start from inside
      // build; wait for the frame. No-op until the style is ready, in
      // which case `_onStyleLoaded` picks it up instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeUpload();
      });
    }

    return SizedBox(
      height: widget.height,
      child: pingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (_) {
          if (_snap.isEmpty) {
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
          return _buildBody(context, activeRegion, liveDotOn,
              liveDotState.isLoading);
        },
      ),
    );
  }

  /// The controller we hold is dead or about to be. Never call this for
  /// a *data* change — that is exactly the pre-0.14 bug where a cached
  /// range nulled the controller, the map didn't remount, and pins never
  /// rendered again. Data changes go through [_invalidateUpload].
  void _forgetController() {
    _controller = null;
    _controllerEpoch = -1;
    _styleReady = false;
    _heatmapMounted = false;
    _invalidateUpload();
  }

  /// Whatever the live sources hold is stale: make the next
  /// [_maybeUpload] re-upload and any in-flight upload drop its result.
  /// Leaves the controller alone.
  void _invalidateUpload() {
    _uploadGen++;
    _uploadedListIdentity = null;
  }

  /// Toggle the inline date-filter panel. Replaces the previous
  /// `showDateRangePicker` modal as the calendar icon's tap handler.
  /// The panel itself surfaces preset chips + a "Custom range…" expander
  /// that opens the system picker for two-ended selection.
  void _toggleCalendar() {
    if (!mounted) return;
    setState(() => _calendarOpen = !_calendarOpen);
  }

  /// Applied range — null means "no filter". The provider family key
  /// changes, the new list arrives (from cache or SQL), `build` notices
  /// the new identity and schedules an upload through the live
  /// controller. Nothing about the map itself is reset here.
  void _applyDateFilter(DateTimeRange? range) {
    if (!mounted) return;
    _pausePlayback();
    setState(() {
      _dateFilter = range;
      _sliderMax = null;
      _initialFitDone = false;
      _calendarOpen = false;
    });
    _invalidateUpload();
  }

  Widget _buildBody(
    BuildContext context,
    TilesRegion region,
    bool liveDotOn,
    bool liveDotLoading,
  ) {
    final snap = _snap;
    final chrono = snap.chrono;
    final first = chrono.first.timestampUtc;
    final last = chrono.last.timestampUtc;
    final sliderMax = effectiveSliderMax(_sliderMax, chrono);
    final shown = visibleCount(snap.cols.tsMs, sliderMax.millisecondsSinceEpoch);

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
          onToggleHeatmap: _toggleHeatmap,
          onTogglePath: _togglePath,
          onToggleLiveDot: () => ref
              .read(liveLocationDotEnabledProvider.notifier)
              .set(!liveDotOn),
          onOpenRegions: () => context.push('/regions'),
          onToggleSlideshow: _toggleSlideshow,
          onExpand: widget.onExpand,
        ),
        InlineDateFilterPanel(
          open: _calendarOpen,
          currentRange: _dateFilter,
          now: DateTime.now(),
          earliestPing: first,
          latestPing: last,
          onApply: _applyDateFilter,
          onClose: () {
            if (mounted) setState(() => _calendarOpen = false);
          },
        ),
        Expanded(
          child: _slideshowMode
              ? SlideshowView(
                  visibleFixes: chrono.sublist(0, shown),
                  sliderMax: sliderMax,
                  hasAnyFixes: chrono.isNotEmpty,
                )
              : FutureBuilder<String?>(
                  future: _styleFuture,
                  builder: (context, style) {
                    if (!style.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return _buildMap(context, shown, style.data!, region);
                  },
                ),
        ),
        _TimeSlider(
          first: first,
          last: last,
          current: sliderMax,
          visibleCount: shown,
          totalCount: chrono.length,
          playing: _playing,
          playbackSpeed: _playbackSpeed,
          onChanged: (v) {
            _pausePlayback();
            _setSliderMax(v);
          },
          onReset: () {
            _pausePlayback();
            _setSliderMax(null);
          },
          onJumpToStart: () {
            _pausePlayback();
            _setSliderMax(first);
          },
          onStepPrev: () => _stepBy(-1),
          onStepNext: () => _stepBy(1),
          onRwd5: () => _stepBy(-5),
          onFwd5: () => _stepBy(5),
          onTogglePlay: _togglePlayback,
          onPickSpeed: _pickSpeed,
        ),
      ],
    );
  }

  Widget _buildMap(
    BuildContext context,
    int shown,
    String styleJson,
    TilesRegion region,
  ) {
    final snap = _snap;
    final initial = shown > 0
        ? LatLng(snap.cols.lats[shown - 1], snap.cols.lons[shown - 1])
        : const LatLng(54, -2); // GB centroid fallback
    final showLiveDot =
        ref.watch(liveLocationDotEnabledProvider).valueOrNull ?? true;

    return Stack(
      children: [
        _MapHost(
          onMount: () => ++_mapEpoch,
          onUnmount: _onMapUnmounted,
          child: MapLibreMap(
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
              _controllerEpoch = _mapEpoch;
              _styleReady = false;
            },
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: _handleMapTap,
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
              onTap: () => _fitToVisible(animate: true),
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
        if (shown > 0)
          Positioned(
            left: 8,
            top: 8,
            child: _PlaybackHud(
              current: snap.chrono[shown - 1],
              previous: shown >= 2 ? snap.chrono[shown - 2] : null,
            ),
          ),
      ],
    );
  }

  void _onMapUnmounted(int epoch) {
    if (epoch != _controllerEpoch) return;
    _forgetController();
  }

  // ---------------------------------------------------------------------
  // Style lifecycle: sources + layers live exactly as long as the style.
  // ---------------------------------------------------------------------

  /// Runs on every style load of the live controller — first mount,
  /// region swap, return from slideshow mode. The style starts with none
  /// of our content (gotcha 19: nothing of ours may be added from
  /// `onMapCreated`), so install sources + layers, then push the data.
  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    await _installLayers(c, scheme);
    if (!mounted || !identical(c, _controller)) return;
    _styleReady = true;
    _heatmapMounted = false;
    // Fresh style ⇒ the sources are empty regardless of what we uploaded
    // to the previous one.
    _uploadedListIdentity = null;
    _maybeUpload();
    if (_showHeatmap) unawaited(_setHeatmap(c, true, scheme));
    unawaited(_fitIfPending(animate: true));
  }

  Future<void> _installLayers(
    MapLibreMapController c,
    ColorScheme scheme,
  ) async {
    final filter = _currentFilter();
    final primaryHex = scheme.primary.toHexStringRGB();

    // Each step is individually guarded: if a source/layer already exists
    // (a second onStyleLoaded for the same style) the add throws, and we
    // still want the remaining pieces installed.
    Future<void> step(String what, Future<void> Function() f) async {
      try {
        await f();
      } catch (e, st) {
        developer.log('$what failed: $e', name: 'trail-map', stackTrace: st);
      }
    }

    await step(
      'addGeoJsonSource($_pinsSrc)',
      () => c.addGeoJsonSource(_pinsSrc, emptyFeatureCollectionMap),
    );
    await step(
      'addGeoJsonSource($_segsSrc)',
      () => c.addGeoJsonSource(_segsSrc, emptyFeatureCollectionMap),
    );
    // Line layer first so the pins draw on top of it.
    await step(
      'addLineLayer($_pathLayer)',
      () => c.addLineLayer(
        _segsSrc,
        _pathLayer,
        LineLayerProperties(
          lineColor: primaryHex,
          lineWidth: 2,
          lineOpacity: 0.85,
          lineCap: 'round',
          lineJoin: 'round',
          visibility: _showPath && !_showHeatmap ? 'visible' : 'none',
        ),
        filter: filter,
        enableInteraction: false,
      ),
    );
    // `enableInteraction: false` on purpose: with it on, a direct hit on
    // a pin fires `feature#onTap` and SUPPRESSES `onMapClick`, so the
    // fat-finger query in [_handleMapTap] would never see those taps.
    // Taps are resolved entirely by the rect query instead.
    await step(
      'addCircleLayer($_pinsLayer)',
      () => c.addCircleLayer(
        _pinsSrc,
        _pinsLayer,
        CircleLayerProperties(
          circleRadius: kPinRadius,
          circleColor: primaryHex,
          circleStrokeWidth: 0.5,
          circleStrokeColor: '#FFFFFF',
          circleStrokeOpacity: 0.6,
          visibility: _showHeatmap ? 'none' : 'visible',
        ),
        filter: filter,
        enableInteraction: false,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Data upload: once per list identity, off the UI isolate.
  // ---------------------------------------------------------------------

  void _maybeUpload() {
    final c = _controller;
    if (c == null || !_styleReady) return;
    final pings = _lastPings;
    if (pings == null || identical(pings, _uploadedListIdentity)) return;
    _uploadedListIdentity = pings;
    final gen = ++_uploadGen;
    unawaited(_upload(c, _snap.cols, gen));
  }

  Future<void> _upload(
    MapLibreMapController c,
    PinColumns cols,
    int gen,
  ) async {
    try {
      final String pins;
      final String segs;
      if (cols.isEmpty) {
        pins = emptyFeatureCollection;
        segs = emptyFeatureCollection;
      } else if (cols.length < _kIsolateThreshold) {
        pins = buildPinsGeoJson(cols);
        segs = buildSegmentsGeoJson(cols);
      } else {
        // Typed-data columns cross the isolate boundary as a buffer copy;
        // the result strings come back via Isolate.exit (no copy).
        final both = await Isolate.run(() => _buildBothGeoJson(cols));
        pins = both[0];
        segs = both[1];
      }
      if (gen != _uploadGen || !mounted || !identical(c, _controller)) return;
      final okPins = await c.editGeoJsonSource(_pinsSrc, pins);
      if (gen != _uploadGen || !mounted || !identical(c, _controller)) return;
      final okSegs = await c.editGeoJsonSource(_segsSrc, segs);
      if (!okPins || !okSegs) {
        developer.log(
          'editGeoJsonSource returned false (pins=$okPins segs=$okSegs, '
          'fixes=${cols.length}) — source missing from style?',
          name: 'trail-map',
        );
      }
      if (gen != _uploadGen || !mounted) return;
      await _syncTimeWindow();
      await _fitIfPending(animate: false);
    } catch (e, st) {
      developer.log(
        'Pin upload failed (gen=$gen, fixes=${cols.length}): $e',
        name: 'trail-map',
        stackTrace: st,
      );
      // Let the next trigger (toggle, range change, style load) retry.
      if (gen == _uploadGen) _uploadedListIdentity = null;
    }
  }

  // ---------------------------------------------------------------------
  // Time window: the only thing a slider tick touches.
  // ---------------------------------------------------------------------

  /// Current `ts` window for the layer filters, or null with no data.
  List<Object>? _currentFilter() {
    final snap = _snap;
    if (snap.isEmpty) return null;
    final t1 = effectiveSliderMax(_sliderMax, snap.chrono).millisecondsSinceEpoch;
    return tsFilter(snap.cols.tsMs[0], t1);
  }

  void _setSliderMax(DateTime? v) {
    if (!mounted) return;
    setState(() => _sliderMax = v);
    _scheduleSync();
  }

  void _scheduleSync() {
    unawaited(_syncTimeWindow());
  }

  /// Push the current window + head/previous styling to the live layers.
  /// Two to four ~100-byte platform calls; no data, no re-upload.
  Future<void> _syncTimeWindow() async {
    final c = _controller;
    if (c == null || !_styleReady || !mounted) return;
    final snap = _snap;
    if (snap.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final cols = snap.cols;
    final t0 = cols.tsMs[0];
    final t1 = effectiveSliderMax(_sliderMax, snap.chrono).millisecondsSinceEpoch;
    final n = visibleCount(cols.tsMs, t1);
    final filter = tsFilter(t0, t1);
    final style = buildPinStyle(
      headId: n >= 1 ? cols.ids[n - 1] : null,
      prevId: n >= 2 ? cols.ids[n - 2] : null,
      t0Ms: t0,
      t1Ms: t1,
      baseHex: scheme.primary.toHexStringRGB(),
      dimHex: _dimPinHex(scheme),
    );
    try {
      await Future.wait<void>([
        c.setFilter(_pinsLayer, filter),
        if (_showPath) c.setFilter(_pathLayer, filter),
        if (_heatmapMounted) c.setFilter(_heatmapLayerId, filter),
        // setLayerProperties sends nulls too (they reset to default), so
        // every paint property we care about is listed every time.
        c.setLayerProperties(
          _pinsLayer,
          CircleLayerProperties(
            circleRadius: style.radius,
            circleColor: style.color,
            circleStrokeWidth: style.strokeWidth,
            circleStrokeColor: style.strokeColor,
            circleStrokeOpacity: style.strokeOpacity,
          ),
        ),
      ]);
    } catch (e, st) {
      developer.log(
        'Time-window sync failed: $e',
        name: 'trail-map',
        stackTrace: st,
      );
    }
  }

  /// Oldest-visible end of the age ramp: primary pulled halfway toward
  /// the surface so the trail fades into the map as it ages.
  static String _dimPinHex(ColorScheme scheme) =>
      Color.lerp(scheme.primary, scheme.surface, 0.55)!.toHexStringRGB();

  // ---------------------------------------------------------------------
  // Layer toggles.
  // ---------------------------------------------------------------------

  void _toggleHeatmap() {
    setState(() => _showHeatmap = !_showHeatmap);
    final c = _controller;
    if (c == null || !_styleReady) return;
    unawaited(_setHeatmap(c, _showHeatmap, Theme.of(context).colorScheme));
  }

  void _togglePath() {
    setState(() => _showPath = !_showPath);
    final c = _controller;
    if (c == null || !_styleReady) return;
    unawaited(_applyPathVisibility(c));
  }

  void _toggleSlideshow() {
    // The map unmounts while the slideshow is up; `_MapHost.onUnmount`
    // drops the controller and a fresh style load re-installs everything
    // on the way back. Playback state is deliberately left alone.
    setState(() => _slideshowMode = !_slideshowMode);
  }

  Future<void> _applyPathVisibility(MapLibreMapController c) async {
    try {
      if (_showPath && !_showHeatmap) {
        // The filter is only kept in sync while the path is visible, so
        // catch it up before showing it.
        final filter = _currentFilter();
        if (filter != null) await c.setFilter(_pathLayer, filter);
        await c.setLayerVisibility(_pathLayer, true);
      } else {
        await c.setLayerVisibility(_pathLayer, false);
      }
    } catch (e, st) {
      developer.log('Path toggle failed: $e',
          name: 'trail-map', stackTrace: st);
    }
  }

  Future<void> _setHeatmap(
    MapLibreMapController c,
    bool show,
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
        if (_heatmapMounted) {
          try {
            await c.removeLayer(_heatmapLayerId);
          } catch (_) {/* layer already gone */}
          _heatmapMounted = false;
        }
        await c.setLayerVisibility(_pinsLayer, true);
        await c.setLayerVisibility(_pathLayer, _showPath);
        return;
      }
      if (!_heatmapMounted) {
        final tertHex = scheme.tertiary.toHexStringRGB();
        final tertR = (scheme.tertiary.r * 255).round();
        final tertG = (scheme.tertiary.g * 255).round();
        final tertB = (scheme.tertiary.b * 255).round();
        // Same source as the pins — no second upload. The layer gets its
        // own copy of the time filter (addHeatmapLayer has no `filter`
        // parameter in 0.26.0, so it is applied right after).
        await c.addHeatmapLayer(
          _pinsSrc,
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
      final filter = _currentFilter();
      if (filter != null) await c.setFilter(_heatmapLayerId, filter);
      await c.setLayerVisibility(_pinsLayer, false);
      await c.setLayerVisibility(_pathLayer, false);
    } catch (e, st) {
      developer.log(
        'Heatmap toggle failed (show=$show, fixes=${_snap.length}): $e',
        name: 'trail-map',
        stackTrace: st,
      );
      // Reset internal state so the next toggle starts from a known-good
      // baseline rather than trying to mount on top of a half-failed
      // attempt, and put the pins back.
      _heatmapMounted = false;
      try {
        await c.setLayerVisibility(_pinsLayer, true);
        await c.setLayerVisibility(_pathLayer, _showPath);
      } catch (_) {/* best effort */}
      if (_showHeatmap && mounted) {
        setState(() => _showHeatmap = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Heatmap unavailable on this device.'),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------
  // Taps.
  // ---------------------------------------------------------------------

  /// Every tap on the map lands here (our layers are non-interactive, so
  /// nothing swallows the click upstream). Ask the renderer which pins
  /// are drawn inside a fat-finger box around the point, pick the
  /// nearest, resolve it to its `Ping` and open the detail sheet.
  ///
  /// Coordinate space: on Android `onMapClick`'s `point` is the raw
  /// `MapView` pixel (device pixels, no density division in the plugin)
  /// and `queryRenderedFeatures` takes its rect in the same space, so the
  /// margin is scaled by the device pixel ratio and the centre is used
  /// as-is.
  void _handleMapTap(Point<double> point, LatLng latLng) {
    unawaited(_resolveTap(point, latLng));
  }

  Future<void> _resolveTap(Point<double> point, LatLng latLng) async {
    final c = _controller;
    if (c == null || !_styleReady || !mounted || _snap.isEmpty) return;
    final pad = _kTapPadLogicalPx * MediaQuery.devicePixelRatioOf(context);
    final rect = Rect.fromCenter(
      center: Offset(point.x, point.y),
      width: 2 * pad,
      height: 2 * pad,
    );
    List<dynamic> features;
    try {
      features = await c.queryRenderedFeaturesInRect(rect, [_pinsLayer], null);
    } catch (e, st) {
      developer.log('Pin tap query failed: $e',
          name: 'trail-map', stackTrace: st);
      return;
    }
    if (!mounted || features.isEmpty) return;
    final id = pickNearestPinId(features, latLng.latitude, latLng.longitude);
    if (id == null) return;
    final ping = _snap.byId[id];
    if (ping == null) return;
    _openPing(ping);
  }

  void _openPing(Ping ping) {
    // **Tap = jump to that pin's time, then show details.** Pre-0.13.9
    // the tap only opened the sheet; the slider stayed wherever the
    // user had left it, so re-tapping a different pin gave you the
    // details of a different pin but the trail / heatmap below was
    // still anchored at the previous time. Now tap also moves the
    // cursor, which means:
    //   - Slideshow mode jumps to that pin's photo.
    //   - "Visible fixes" prefix re-clamps to <= this ping.
    //   - The detail sheet at the bottom is for the same pin the user
    //     just tapped — no implicit time mismatch.
    // Playback is paused on tap so a manual selection doesn't fight
    // the auto-advance timer.
    if (!_arePingTimesEqual(_sliderMax, ping.timestampUtc)) {
      _pausePlayback();
      _setSliderMax(ping.timestampUtc);
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: _PingDetailSheet(ping: ping),
      ),
    );
  }

  /// Defensive equality — both DateTimes are UTC by construction, but
  /// `==` on `DateTime` is reference-and-ms-equality, which is what we
  /// want here. Wrapped so tests can mock the comparison if needed.
  bool _arePingTimesEqual(DateTime? a, DateTime b) => a != null && a == b;

  // ---------------------------------------------------------------------
  // Camera.
  // ---------------------------------------------------------------------

  /// One-shot fit after a style load or a range change. Gotcha 19: fit
  /// only on those events, never on slider ticks — the user must be able
  /// to pan freely during playback.
  Future<void> _fitIfPending({required bool animate}) async {
    if (_initialFitDone) return;
    if (_controller == null || !_styleReady || _snap.isEmpty) return;
    _initialFitDone = true;
    await _fitToVisible(animate: animate);
  }

  Future<void> _fitToVisible({required bool animate}) async {
    final c = _controller;
    final snap = _snap;
    if (c == null || snap.isEmpty) return;
    final n = visibleCount(
      snap.cols.tsMs,
      effectiveSliderMax(_sliderMax, snap.chrono).millisecondsSinceEpoch,
    );
    if (n == 0) return;
    final CameraUpdate update;
    if (n == 1) {
      update = CameraUpdate.newLatLngZoom(
        LatLng(snap.cols.lats[0], snap.cols.lons[0]),
        14,
      );
    } else {
      final b = visibleBounds(snap.cols, n);
      update = CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(b.minLat, b.minLon),
          northeast: LatLng(b.maxLat, b.maxLon),
        ),
        left: 40,
        top: 40,
        right: 40,
        bottom: 40,
      );
    }
    try {
      if (animate) {
        await c.animateCamera(update);
      } else {
        await c.moveCamera(update);
      }
    } catch (e, st) {
      developer.log('Camera fit failed: $e',
          name: 'trail-map', stackTrace: st);
    }
  }

  // ---------------------------------------------------------------------
  // Slider stepping + playback.
  // ---------------------------------------------------------------------

  /// Move the slider [delta] pings along the chrono list. Pure dispatch to
  /// [stepSliderTo] — a top-level so the playback dupe-timestamp fix can
  /// be unit-tested without spinning up a `MapLibreMap` (which
  /// `flutter_test` can't mount).
  DateTime _stepTo(List<Ping> chrono, DateTime current, int delta) =>
      stepSliderTo(chrono, current, delta);

  void _stepBy(int delta) {
    final chrono = _snap.chrono;
    if (chrono.isEmpty) return;
    _pausePlayback();
    final current = effectiveSliderMax(_sliderMax, chrono);
    _setSliderMax(_stepTo(chrono, current, delta));
  }

  void _togglePlayback() {
    if (_playing) {
      _pausePlayback();
      return;
    }
    final chrono = _snap.chrono;
    if (chrono.length < 2) return;
    // Pressing play with the cursor at the last fix — which includes the
    // fresh-open state, where "no cursor" means "show everything" —
    // rewinds to the very first fix in the filter so playback runs the
    // whole window.
    final current = effectiveSliderMax(_sliderMax, chrono);
    if (!current.isBefore(chrono.last.timestampUtc)) {
      _setSliderMax(chrono.first.timestampUtc);
    }
    _startPlaybackTimer();
    setState(() => _playing = true);
  }

  void _startPlaybackTimer() {
    _playbackTimer?.cancel();
    final interval = playbackInterval(_basePlaybackStep, _playbackSpeed);
    _playbackTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      // Read the snapshot per tick so a data change mid-playback (pin
      // delete, range swap) is picked up instead of stepping a dead list.
      final chrono = _snap.chrono;
      if (chrono.isEmpty) {
        _pausePlayback();
        return;
      }
      final current = effectiveSliderMax(_sliderMax, chrono);
      final next = _stepTo(chrono, current, 1);
      if (!next.isAfter(current)) {
        _pausePlayback();
        return;
      }
      _setSliderMax(next);
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
    if (_playing) _startPlaybackTimer();
  }
}

/// Isolate entry for the upload: both collections from one spawn.
List<String> _buildBothGeoJson(PinColumns cols) =>
    [buildPinsGeoJson(cols), buildSegmentsGeoJson(cols)];

/// Thin lifecycle shim around the platform-view map. `MapLibreMap` has
/// no "disposed" callback, and the panel must stop talking to a
/// controller the moment its platform view is gone (slideshow toggle,
/// region swap) — calls on a dead controller throw, and an in-flight
/// upload would otherwise land on nothing. See `_FullMapPanelState._mapEpoch`.
class _MapHost extends StatefulWidget {
  final int Function() onMount;
  final void Function(int epoch) onUnmount;
  final Widget child;

  const _MapHost({
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });

  @override
  State<_MapHost> createState() => _MapHostState();
}

class _MapHostState extends State<_MapHost> {
  late final int _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = widget.onMount();
  }

  @override
  void dispose() {
    widget.onUnmount(_epoch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
