import 'dart:typed_data';

import 'mvt_codec.dart';

/// Overzoom: synthesise a child vector tile from an ancestor tile.
///
/// MapLibre Native treats a 404 inside a source's zoom range as an empty
/// tile rather than falling back to the parent, so when an archive only
/// holds tiles up to z12 the loopback tile server has to build z13+ tiles
/// itself: scale the ancestor's geometry by `1 << (childZ - parentZ)`,
/// translate it into the child's origin, and clip it to the child's
/// extent (plus a buffer so lines and polygons crossing the edge still
/// join up with the neighbouring tile).
///
/// Everything is integer-exact: `child = parent * s - offset * extent`,
/// where `s = 1 << k` and `offset` is the child's index within the
/// parent's `s x s` grid. Only clipped intersections go through doubles,
/// and those are rounded to the nearest integer on the way back out.

/// Re-projects [parentMvt] (the tile at parentZ/parentX/parentY) into the
/// child tile childZ/childX/childY and returns the encoded, uncompressed
/// child tile.
///
/// [buffer] is in tile-extent units and widens the clip rectangle to
/// `[-buffer, extent + buffer]` on both axes (MVT's usual 64/4096).
///
/// Feature ids, tags and types are untouched; layer name, version,
/// extent, keys and values pass through byte for byte. Layers left with
/// no features are dropped, as are features whose geometry falls entirely
/// outside the clip rectangle.
///
/// Throws [ArgumentError] if `childZ <= parentZ`, if the child tile does
/// not lie inside the parent, or if any coordinate is negative.
Uint8List overzoomMvt(
  Uint8List parentMvt, {
  required int parentZ,
  required int parentX,
  required int parentY,
  required int childZ,
  required int childX,
  required int childY,
  int buffer = 64,
}) {
  if (childZ <= parentZ) {
    throw ArgumentError.value(
        childZ, 'childZ', 'must be greater than parentZ ($parentZ)');
  }
  if (parentZ < 0 || parentX < 0 || parentY < 0 || childX < 0 || childY < 0) {
    throw ArgumentError.value(
        parentZ, 'parentZ', 'tile coordinates must be non-negative');
  }
  if (buffer < 0) {
    throw ArgumentError.value(buffer, 'buffer', 'must be non-negative');
  }
  final k = childZ - parentZ;
  if (k > 30) {
    throw ArgumentError.value(
        childZ, 'childZ', 'more than 30 zoom levels above parentZ ($parentZ)');
  }
  if ((childX >> k) != parentX || (childY >> k) != parentY) {
    throw ArgumentError(
        'child tile $childZ/$childX/$childY is not inside parent '
        '$parentZ/$parentX/$parentY');
  }

  final s = 1 << k;
  final offsetX = childX - (parentX << k);
  final offsetY = childY - (parentY << k);

  final parent = decodeMvt(parentMvt);
  final scratch = Float64List(4);
  final outLayers = <MvtLayer>[];

  for (final layer in parent.layers) {
    final extent = layer.extent;
    final lo = (-buffer).toDouble();
    final hi = (extent + buffer).toDouble();
    final loI = -buffer;
    final hiI = extent + buffer;
    final dx = offsetX * extent;
    final dy = offsetY * extent;

    final outFeatures = <MvtFeature>[];
    for (final feature in layer.features) {
      final parts = feature.decodeGeometry();
      if (parts.isEmpty) continue;

      // Transform in place (only the IntPoints are re-allocated) and
      // collect the feature's bounding box for the fast paths.
      var minX = 0;
      var minY = 0;
      var maxX = 0;
      var maxY = 0;
      var seen = false;
      for (final part in parts) {
        for (var i = 0; i < part.length; i++) {
          final p = part[i];
          final nx = p.x * s - dx;
          final ny = p.y * s - dy;
          part[i] = IntPoint(nx, ny);
          if (!seen) {
            minX = maxX = nx;
            minY = maxY = ny;
            seen = true;
          } else {
            if (nx < minX) minX = nx;
            if (nx > maxX) maxX = nx;
            if (ny < minY) minY = ny;
            if (ny > maxY) maxY = ny;
          }
        }
      }
      if (!seen) continue;

      // Wholly outside the clip rectangle — drop without clipping.
      if (minX > hiI || maxX < loI || minY > hiI || maxY < loI) continue;

      final List<List<IntPoint>> clipped;
      if (minX >= loI && maxX <= hiI && minY >= loI && maxY <= hiI) {
        // Wholly inside — the transform was all it needed.
        clipped = parts;
      } else if (feature.type == MvtGeomType.point) {
        clipped = _clipPoints(parts, loI, hiI);
      } else if (feature.type == MvtGeomType.lineString) {
        clipped = _clipLines(parts, lo, hi, scratch);
      } else if (feature.type == MvtGeomType.polygon) {
        clipped = _clipRings(parts, lo, hi);
      } else {
        // UNKNOWN geometry: we cannot clip what we cannot interpret, and
        // it is already known not to be wholly inside. Drop it.
        continue;
      }
      if (clipped.isEmpty) continue;

      outFeatures.add(MvtFeature(
        id: feature.id,
        tags: feature.tags,
        type: feature.type,
        geometryCommands: MvtFeature.encodeGeometry(feature.type, clipped),
        unknownFields: feature.unknownFields,
      ));
    }

    if (outFeatures.isEmpty) continue;
    outLayers.add(MvtLayer(
      name: layer.name,
      version: layer.version,
      extent: layer.extent,
      features: outFeatures,
      rawKeyFields: layer.rawKeyFields,
      rawValueFields: layer.rawValueFields,
      unknownFields: layer.unknownFields,
    ));
  }

  return encodeMvt(MvtTile(layers: outLayers));
}

/// Keeps the points inside the closed rectangle `[lo, hi]^2`, collapsed
/// into a single part (an MVT MULTIPOINT is one `MoveTo` run).
List<List<IntPoint>> _clipPoints(
    List<List<IntPoint>> parts, int lo, int hi) {
  final kept = <IntPoint>[];
  for (final part in parts) {
    for (final p in part) {
      if (p.x >= lo && p.x <= hi && p.y >= lo && p.y <= hi) kept.add(p);
    }
  }
  return kept.isEmpty ? const <List<IntPoint>>[] : <List<IntPoint>>[kept];
}

/// Liang-Barsky per segment, re-joining consecutive surviving segments
/// into polylines. Parts left with fewer than two distinct points are
/// dropped.
List<List<IntPoint>> _clipLines(
    List<List<IntPoint>> parts, double lo, double hi, Float64List scratch) {
  final out = <List<IntPoint>>[];
  for (final part in parts) {
    if (part.length < 2) continue;
    List<IntPoint>? current;
    for (var i = 0; i + 1 < part.length; i++) {
      if (!_clipSegment(part[i], part[i + 1], lo, hi, scratch)) {
        current = _flushLine(current, out);
        continue;
      }
      final a = IntPoint(scratch[0].round(), scratch[1].round());
      final b = IntPoint(scratch[2].round(), scratch[3].round());
      if (current != null && current.last == a) {
        if (b != a) current.add(b);
      } else {
        _flushLine(current, out);
        current = <IntPoint>[a];
        if (b != a) current.add(b);
      }
    }
    _flushLine(current, out);
  }
  return out;
}

List<IntPoint>? _flushLine(List<IntPoint>? current, List<List<IntPoint>> out) {
  if (current != null && current.length >= 2) out.add(current);
  return null;
}

/// Clips one segment against `[lo, hi]^2`, writing `x0, y0, x1, y1` of
/// the surviving span into [out]. Returns false when nothing survives.
bool _clipSegment(
    IntPoint a, IntPoint b, double lo, double hi, Float64List out) {
  final x0 = a.x.toDouble();
  final y0 = a.y.toDouble();
  final dx = (b.x - a.x).toDouble();
  final dy = (b.y - a.y).toDouble();
  var t0 = 0.0;
  var t1 = 1.0;
  for (var edge = 0; edge < 4; edge++) {
    final double p;
    final double q;
    if (edge == 0) {
      p = -dx;
      q = x0 - lo;
    } else if (edge == 1) {
      p = dx;
      q = hi - x0;
    } else if (edge == 2) {
      p = -dy;
      q = y0 - lo;
    } else {
      p = dy;
      q = hi - y0;
    }
    if (p == 0) {
      if (q < 0) return false;
      continue;
    }
    final r = q / p;
    if (p < 0) {
      if (r > t1) return false;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return false;
      if (r < t1) t1 = r;
    }
  }
  out[0] = x0 + t0 * dx;
  out[1] = y0 + t0 * dy;
  out[2] = x0 + t1 * dx;
  out[3] = y0 + t1 * dy;
  return true;
}

/// Sutherland-Hodgman per ring against the four edges of `[lo, hi]^2`.
///
/// Vertex order (and therefore winding, and therefore exterior-vs-hole)
/// is preserved, and ring order is kept so an exterior ring still comes
/// before its holes. A ring that surrounds the rectangle comes back as
/// the rectangle. Rings left with fewer than three distinct points are
/// dropped.
List<List<IntPoint>> _clipRings(
    List<List<IntPoint>> parts, double lo, double hi) {
  final out = <List<IntPoint>>[];
  for (final ring in parts) {
    if (ring.length < 3) continue;
    var input = List<double>.filled(ring.length * 2, 0, growable: true);
    for (var i = 0; i < ring.length; i++) {
      input[i * 2] = ring[i].x.toDouble();
      input[i * 2 + 1] = ring[i].y.toDouble();
    }
    for (var edge = 0; edge < 4 && input.isNotEmpty; edge++) {
      final clipped = <double>[];
      final n = input.length >> 1;
      var px = input[(n - 1) * 2];
      var py = input[(n - 1) * 2 + 1];
      var pIn = _inside(edge, px, py, lo, hi);
      for (var i = 0; i < n; i++) {
        final cx = input[i * 2];
        final cy = input[i * 2 + 1];
        final cIn = _inside(edge, cx, cy, lo, hi);
        if (cIn != pIn) _intersect(edge, px, py, cx, cy, lo, hi, clipped);
        if (cIn) {
          clipped.add(cx);
          clipped.add(cy);
        }
        px = cx;
        py = cy;
        pIn = cIn;
      }
      input = clipped;
    }
    if (input.length < 6) continue;
    final rounded = <IntPoint>[];
    for (var i = 0; i < input.length; i += 2) {
      final p = IntPoint(input[i].round(), input[i + 1].round());
      if (rounded.isNotEmpty && rounded.last == p) continue;
      rounded.add(p);
    }
    while (rounded.length > 1 && rounded.first == rounded.last) {
      rounded.removeLast();
    }
    if (rounded.length < 3) continue;
    out.add(rounded);
  }
  return out;
}

bool _inside(int edge, double x, double y, double lo, double hi) {
  if (edge == 0) return x >= lo;
  if (edge == 1) return x <= hi;
  if (edge == 2) return y >= lo;
  return y <= hi;
}

void _intersect(int edge, double px, double py, double cx, double cy,
    double lo, double hi, List<double> out) {
  if (edge == 0 || edge == 1) {
    final ex = edge == 0 ? lo : hi;
    final t = (ex - px) / (cx - px);
    out.add(ex);
    out.add(py + t * (cy - py));
  } else {
    final ey = edge == 2 ? lo : hi;
    final t = (ey - py) / (cy - py);
    out.add(px + t * (cx - px));
    out.add(ey);
  }
}
