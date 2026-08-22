import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/ping.dart';

/// Pure helpers behind the map panel's native pin layers.
///
/// Everything in here is a top-level function or a plain data holder so
/// it can be unit-tested without a `MapLibreMap` (CLAUDE.md gotcha 18)
/// and so the heavy JSON build can run inside `Isolate.run` — typed
/// data crosses isolates with a cheap buffer copy; a `List<Ping>` would
/// be deep-copied object by object.
///
/// Pipeline (see docs/PERF_PLAN.md §2 M1):
///   `List<Ping>` ─buildPinSnapshot─▶ [PinSnapshot] (chrono + [PinColumns]
///   + id→Ping) ─Isolate.run(buildPinsGeoJson)─▶ GeoJSON text
///   ─editGeoJsonSource─▶ native source. Slider ticks then only touch
///   [tsFilter] / [buildPinStyle] — constant cost regardless of N.

/// Literal empty FeatureCollection as text — the initial payload for
/// `editGeoJsonSource` and the "nothing to show" upload.
const String emptyFeatureCollection =
    '{"type":"FeatureCollection","features":[]}';

/// Same thing as a `Map`, for `addGeoJsonSource` (which only takes a
/// Map in maplibre_gl 0.26.0 — a String there would be treated as a
/// URL on Android and silently fail).
const Map<String, dynamic> emptyFeatureCollectionMap = <String, dynamic>{
  'type': 'FeatureCollection',
  'features': <dynamic>[],
};

/// Columnar snapshot of the fixes that have coordinates, in the order the
/// DAO returned them (time-ascending). Four parallel typed arrays so the
/// whole thing can be handed to an isolate as ~32 bytes/fix of raw
/// buffer rather than N boxed objects.
class PinColumns {
  /// `Ping.id` per fix. Rows without a rowid (shouldn't happen from the
  /// DAO, but the model allows it) get a unique negative placeholder so
  /// they still render and still map back via [PinSnapshot.byId].
  final Int64List ids;

  /// `timestampUtc.millisecondsSinceEpoch` per fix, ascending.
  final Int64List tsMs;
  final Float64List lats;
  final Float64List lons;

  const PinColumns({
    required this.ids,
    required this.tsMs,
    required this.lats,
    required this.lons,
  });

  static final PinColumns empty = PinColumns(
    ids: Int64List(0),
    tsMs: Int64List(0),
    lats: Float64List(0),
    lons: Float64List(0),
  );

  int get length => ids.length;
  bool get isEmpty => ids.isEmpty;
  bool get isNotEmpty => ids.isNotEmpty;
}

/// Everything the panel needs per provider value, built once per
/// `List<Ping>` identity (the provider hands back the same list instance
/// on every rebuild until the data actually changes).
class PinSnapshot {
  /// Fixes with usable coordinates, in DAO order (time-ascending).
  final List<Ping> chrono;

  /// Same fixes, columnar — see [PinColumns].
  final PinColumns cols;

  /// `id → Ping` for resolving a tapped feature back to its row.
  final Map<int, Ping> byId;

  const PinSnapshot({
    required this.chrono,
    required this.cols,
    required this.byId,
  });

  static final PinSnapshot empty = PinSnapshot(
    chrono: const [],
    cols: PinColumns.empty,
    byId: const {},
  );

  bool get isEmpty => chrono.isEmpty;
  bool get isNotEmpty => chrono.isNotEmpty;
  int get length => chrono.length;
}

/// True when a ping can be placed on the map: both coordinates present
/// and finite (a NaN would poison the whole GeoJSON upload — the native
/// parser rejects the entire FeatureCollection, not one feature).
bool hasUsableCoords(Ping p) {
  final lat = p.lat;
  final lon = p.lon;
  return lat != null && lon != null && lat.isFinite && lon.isFinite;
}

/// Placeholder id for a ping without a rowid at position [index] of the
/// chrono list. Negative so it can never collide with a real rowid.
int placeholderPinId(int index) => -(index + 1);

/// Builds the per-data snapshot from the raw provider list. O(n), no
/// intermediate `where().toList()` copies beyond the single `chrono`
/// list itself. Null/non-finite-coordinate rows are excluded here —
/// before anything columnar exists — so [PinColumns] never carries a
/// hole.
PinSnapshot buildPinSnapshot(List<Ping> pings) {
  var n = 0;
  for (final p in pings) {
    if (hasUsableCoords(p)) n++;
  }
  if (n == 0) return PinSnapshot.empty;

  final chrono = List<Ping>.filled(n, pings.first, growable: false);
  final ids = Int64List(n);
  final tsMs = Int64List(n);
  final lats = Float64List(n);
  final lons = Float64List(n);
  final byId = <int, Ping>{};

  var i = 0;
  for (final p in pings) {
    if (!hasUsableCoords(p)) continue;
    final id = p.id ?? placeholderPinId(i);
    chrono[i] = p;
    ids[i] = id;
    tsMs[i] = p.timestampUtc.millisecondsSinceEpoch;
    lats[i] = p.lat!;
    lons[i] = p.lon!;
    byId[id] = p;
    i++;
  }
  return PinSnapshot(
    chrono: chrono,
    cols: PinColumns(ids: ids, tsMs: tsMs, lats: lats, lons: lons),
    byId: byId,
  );
}

/// One Point Feature per fix, shaped exactly like
/// `{"type":"Feature","id":ID,"geometry":{"type":"Point","coordinates":[LON,LAT]},"properties":{"id":ID,"ts":TS_MS}}`.
///
/// Nothing else goes in `properties` — the annotation API used to stamp
/// seven style keys per point, which is most of why its payload was so
/// fat. Styling is done with data-driven expressions on `id`/`ts`.
/// Designed to run under `Isolate.run`.
String buildPinsGeoJson(PinColumns c) {
  final n = c.length;
  if (n == 0) return emptyFeatureCollection;
  // ~110 bytes per feature; pre-size to avoid repeated buffer growth.
  final sb = StringBuffer();
  sb.write('{"type":"FeatureCollection","features":[');
  for (var i = 0; i < n; i++) {
    if (i > 0) sb.write(',');
    final id = c.ids[i];
    sb
      ..write('{"type":"Feature","id":')
      ..write(id)
      ..write(',"geometry":{"type":"Point","coordinates":[')
      ..write(c.lons[i])
      ..write(',')
      ..write(c.lats[i])
      ..write(']},"properties":{"id":')
      ..write(id)
      ..write(',"ts":')
      ..write(c.tsMs[i])
      ..write('}}');
  }
  sb.write(']}');
  return sb.toString();
}

/// One two-point LineString Feature per consecutive pair. Each segment
/// carries `ts` of its LATER endpoint so the same [tsFilter] that hides
/// future pins also hides the segment leading to them. Empty collection
/// for fewer than two fixes. Designed to run under `Isolate.run`.
String buildSegmentsGeoJson(PinColumns c) {
  final n = c.length;
  if (n < 2) return emptyFeatureCollection;
  final sb = StringBuffer();
  sb.write('{"type":"FeatureCollection","features":[');
  for (var i = 1; i < n; i++) {
    if (i > 1) sb.write(',');
    sb
      ..write('{"type":"Feature","geometry":{"type":"LineString","coordinates":[[')
      ..write(c.lons[i - 1])
      ..write(',')
      ..write(c.lats[i - 1])
      ..write('],[')
      ..write(c.lons[i])
      ..write(',')
      ..write(c.lats[i])
      ..write(']]},"properties":{"ts":')
      ..write(c.tsMs[i])
      ..write('}}');
  }
  sb.write(']}');
  return sb.toString();
}

/// MapLibre filter expression selecting features whose `ts` property is
/// inside `[t0Ms, t1Ms]` inclusive. Applied to the pins, path and
/// heatmap layers on every slider tick instead of re-uploading data.
List<Object> tsFilter(int t0Ms, int t1Ms) => [
      'all',
      [
        '>=',
        ['get', 'ts'],
        t0Ms,
      ],
      [
        '<=',
        ['get', 'ts'],
        t1Ms,
      ],
    ];

/// Number of entries in the ascending [tsMs] that are `<= sliderMaxMs`
/// — i.e. how many pins the current time window shows. Binary search
/// (upper bound); duplicates and boundary values are counted correctly.
int visibleCount(Int64List tsMs, int sliderMaxMs) {
  var lo = 0;
  var hi = tsMs.length;
  while (lo < hi) {
    final mid = lo + ((hi - lo) >> 1);
    if (tsMs[mid] <= sliderMaxMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Index of the LAST entry whose timestamp is at-or-before [tMs], or
/// `-1` when every entry is later. With duplicate timestamps this
/// returns the last of the run — the pivot `stepSliderTo` needs so a
/// forward step always lands strictly later (see its doc comment).
int indexAtOrBefore(Int64List tsMs, int tMs) => visibleCount(tsMs, tMs) - 1;

/// Columnar twin of `stepSliderTo`: index of the fix [delta] steps away
/// from the one at-or-before [currentMs], clamped to `[0, n-1]`. Returns
/// `-1` for an empty list. A cursor before the first fix pivots on index
/// 0, matching the linear original.
int stepIndex(Int64List tsMs, int currentMs, int delta) {
  final n = tsMs.length;
  if (n == 0) return -1;
  final idx = math.max(0, indexAtOrBefore(tsMs, currentMs));
  return (idx + delta).clamp(0, n - 1);
}

/// Axis-aligned bounds of the first [count] fixes — the camera-fit box
/// for the visible prefix. [count] must be `1..length`.
({double minLat, double maxLat, double minLon, double maxLon}) visibleBounds(
  PinColumns c,
  int count,
) {
  assert(count >= 1 && count <= c.length);
  var minLat = c.lats[0], maxLat = minLat;
  var minLon = c.lons[0], maxLon = minLon;
  for (var i = 1; i < count; i++) {
    final lat = c.lats[i];
    final lon = c.lons[i];
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lon < minLon) minLon = lon;
    if (lon > maxLon) maxLon = lon;
  }
  return (minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
}

/// The slider cursor actually in effect. `null` (never touched, or
/// reset via "Latest") means **show everything** — the cursor sits on
/// the last fix. An explicit value is clamped into `[first, last]` so a
/// cursor left over from a previous data set (e.g. after a pin delete)
/// can't point outside the slider track while the HUD claims otherwise.
///
/// Used by build, the layer filter, the HUD and playback alike so they
/// can never disagree about what "visible" means (PERF_PLAN root cause
/// #4: build used `first`, refresh used `last`).
DateTime effectiveSliderMax(DateTime? selected, List<Ping> chrono) {
  assert(chrono.isNotEmpty, 'effectiveSliderMax needs at least one fix');
  final first = chrono.first.timestampUtc;
  final last = chrono.last.timestampUtc;
  if (selected == null) return last;
  if (selected.isBefore(first)) return first;
  if (selected.isAfter(last)) return last;
  return selected;
}

/// Data-driven paint expressions for the pins circle layer at one slider
/// position. Head pin (the cursor) is larger + red, the previous pin is
/// amber, everything else ramps from [dimHex] (oldest visible) to
/// [baseHex] (newest visible) by `ts`. One `setLayerProperties` per tick
/// applies the whole thing; nothing per-feature ever crosses the channel.
///
/// The ramp is only emitted when `t1Ms > t0Ms` — MapLibre's
/// `interpolate` requires strictly ascending stops, and a single visible
/// pin (or duplicate timestamps at both ends) would violate that.
class PinStyle {
  final Object radius;
  final Object color;
  final Object strokeWidth;
  final Object strokeOpacity;
  final String strokeColor;

  const PinStyle({
    required this.radius,
    required this.color,
    required this.strokeWidth,
    required this.strokeOpacity,
    this.strokeColor = '#FFFFFF',
  });
}

/// Radius bumped from 3 → 7 in 0.13.9 because the 3 px hit target was
/// basically untappable on a phone. 7 px is small enough that a typical
/// 4 h-cadence trail still reads as a string of dots, large enough that
/// a fingertip lands one reliably (the tap handler adds a fat-finger
/// margin on top — see `pickNearestPinId`).
const double kPinRadius = 7.0;

/// Head stays slightly larger for "you are here" emphasis.
const double kHeadPinRadius = 9.0;

/// Material Red Accent 400 — vivid red that reads cleanly on any tile
/// palette without needing extra size.
const String kHeadPinHex = '#FF1744';

/// Amber for the previous fix, matching the HUD's second row.
const String kPrevPinHex = '#FFB300';

PinStyle buildPinStyle({
  required int? headId,
  required int? prevId,
  required int t0Ms,
  required int t1Ms,
  required String baseHex,
  required String dimHex,
}) {
  final Object base = t1Ms > t0Ms
      ? [
          'interpolate',
          ['linear'],
          ['get', 'ts'],
          t0Ms,
          dimHex,
          t1Ms,
          baseHex,
        ]
      : baseHex;
  if (headId == null) {
    return PinStyle(
      radius: kPinRadius,
      color: base,
      strokeWidth: 0.5,
      strokeOpacity: 0.6,
    );
  }
  final isHead = [
    '==',
    ['get', 'id'],
    headId,
  ];
  if (prevId == null) {
    return PinStyle(
      radius: ['case', isHead, kHeadPinRadius, kPinRadius],
      color: ['case', isHead, kHeadPinHex, base],
      strokeWidth: ['case', isHead, 1, 0.5],
      strokeOpacity: ['case', isHead, 0.95, 0.6],
    );
  }
  final isPrev = [
    '==',
    ['get', 'id'],
    prevId,
  ];
  return PinStyle(
    radius: ['case', isHead, kHeadPinRadius, kPinRadius],
    color: ['case', isHead, kHeadPinHex, isPrev, kPrevPinHex, base],
    strokeWidth: ['case', isHead, 1, isPrev, 1, 0.5],
    strokeOpacity: ['case', isHead, 0.95, isPrev, 0.95, 0.6],
  );
}

/// Coerces whatever the platform hands back as a feature id into an
/// `int`. `queryRenderedFeatures` round-trips through native
/// `Feature.toJson()`: `properties.id` comes back as a JSON number (int
/// on Dart's side, possibly double if it ever exceeded 2^53) while the
/// top-level `id` is stringified by the Android SDK. Accept all three.
int? parsePinId(Object? raw) {
  if (raw is int) return raw;
  if (raw is double) {
    if (!raw.isFinite || raw != raw.roundToDouble()) return null;
    return raw.toInt();
  }
  if (raw is String) {
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(raw);
    if (asDouble != null) return parsePinId(asDouble);
  }
  return null;
}

/// Pin id of one decoded GeoJSON feature map — `properties.id` first
/// (what we wrote), top-level `id` as a fallback.
int? pinIdOfFeature(Map<dynamic, dynamic> feature) {
  final props = feature['properties'];
  if (props is Map) {
    final id = parsePinId(props['id']);
    if (id != null) return id;
  }
  return parsePinId(feature['id']);
}

/// Among the features a rect query returned, the id of the pin nearest
/// the tap (equirectangular distance — the rect is a few dozen pixels so
/// the flat-earth error is irrelevant). Features without a usable id or
/// geometry are skipped; a feature with no geometry but a valid id still
/// wins when it is the only candidate.
int? pickNearestPinId(List<dynamic> features, double tapLat, double tapLon) {
  int? best;
  var bestD = double.infinity;
  final cosLat = math.cos(tapLat * math.pi / 180);
  for (final f in features) {
    if (f is! Map) continue;
    final id = pinIdOfFeature(f);
    if (id == null) continue;
    var d = double.maxFinite;
    final geom = f['geometry'];
    if (geom is Map) {
      final coords = geom['coordinates'];
      if (coords is List && coords.length >= 2) {
        final lon = coords[0];
        final lat = coords[1];
        if (lon is num && lat is num) {
          final dx = (lon.toDouble() - tapLon) * cosLat;
          final dy = lat.toDouble() - tapLat;
          d = dx * dx + dy * dy;
        }
      }
    }
    if (d < bestD) {
      bestD = d;
      best = id;
    }
  }
  return best;
}
