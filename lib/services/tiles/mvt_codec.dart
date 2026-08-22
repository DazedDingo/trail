import 'dart:convert';
import 'dart:typed_data';

/// Hand-rolled reader/writer for Mapbox Vector Tiles (`vector_tile.proto`
/// v2.1), used by the loopback tile server's overzoom path.
///
/// Why not `package:protobuf`: the schema is four messages wide, and the
/// server has to re-emit a layer's `keys`/`values` (and any extension
/// fields a producer such as `planetiler` may have written) *byte for
/// byte*. Carrying those as raw encoded field bytes is both simpler and
/// lossless compared to round-tripping them through generated classes.
///
/// The proto, for reference:
///
/// ```proto
/// message Tile {
///   repeated Layer layers = 3;
///   message Value {
///     optional string string_value = 1;
///     optional float  float_value  = 2;
///     optional double double_value = 3;
///     optional int64  int_value    = 4;
///     optional uint64 uint_value   = 5;
///     optional sint64 sint_value   = 6;
///     optional bool   bool_value   = 7;
///   }
///   message Feature {
///     optional uint64   id       = 1 [ default = 0 ];
///     repeated uint32   tags     = 2 [ packed = true ];
///     optional GeomType type     = 3 [ default = UNKNOWN ];
///     repeated uint32   geometry = 4 [ packed = true ];
///   }
///   message Layer {
///     required uint32  version  = 15 [ default = 1 ];
///     required string  name     = 1;
///     repeated Feature features = 2;
///     repeated string  keys     = 3;
///     repeated Value   values   = 4;
///     optional uint32  extent   = 5 [ default = 4096 ];
///   }
/// }
/// ```
///
/// Only `Feature` is decoded into a model; everything else on `Layer` is
/// either a scalar we need (name/version/extent) or raw passthrough.

/// Protobuf wire types we handle. Groups (3/4) are not part of MVT and
/// are rejected as malformed.
class MvtWireType {
  const MvtWireType._();

  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// `Tile.GeomType` values.
class MvtGeomType {
  const MvtGeomType._();

  static const int unknown = 0;
  static const int point = 1;
  static const int lineString = 2;
  static const int polygon = 3;
}

/// Geometry command ids (MVT spec 4.3.3).
class MvtCommand {
  const MvtCommand._();

  static const int moveTo = 1;
  static const int lineTo = 2;
  static const int closePath = 7;

  /// Packs a command id + repeat count into a command integer.
  static int encode(int id, int count) => (id & 0x7) | (count << 3);
}

/// Default `Layer.extent` (`vector_tile.proto`).
const int kMvtDefaultExtent = 4096;

/// `Layer.version` we assume when a layer omits the (required) field.
/// The proto's declared default is 1, but every producer in the wild
/// writes 2 and MapLibre rejects 1, so re-emitting 2 is the safer lie.
const int kMvtDefaultVersion = 2;

/// Zigzag-encodes [value] with 64-bit protobuf `sint` semantics.
///
/// Values that fit in 32 bits get the same encoding as the spec's 32-bit
/// zigzag, which is all MVT geometry parameters ever need.
int zigzagEncode(int value) => (value << 1) ^ (value >> 63);

/// Inverse of [zigzagEncode].
int zigzagDecode(int value) => (value >>> 1) ^ -(value & 1);

/// Number of bytes [value] occupies as a base-128 varint (unsigned
/// 64-bit interpretation, so negatives cost the full 10 bytes).
int varintSize(int value) {
  if (value < 0) return 10;
  var v = value;
  var n = 1;
  while (v >= 0x80) {
    v >>>= 7;
    n++;
  }
  return n;
}

/// An integer point in a tile's local coordinate space.
class IntPoint {
  const IntPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is IntPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'IntPoint($x, $y)';
}

/// Append-only protobuf writer over a growable byte buffer.
class MvtWriter {
  MvtWriter([int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity < 16 ? 16 : initialCapacity);

  Uint8List _buf;
  int _len = 0;

  /// Bytes written so far.
  int get length => _len;

  void _ensure(int extra) {
    final needed = _len + extra;
    if (needed <= _buf.length) return;
    var next = _buf.length * 2;
    while (next < needed) {
      next *= 2;
    }
    final grown = Uint8List(next);
    grown.setRange(0, _len, _buf);
    _buf = grown;
  }

  /// Writes a single raw byte.
  void writeByte(int byte) {
    _ensure(1);
    _buf[_len++] = byte & 0xFF;
  }

  /// Writes [bytes] verbatim (used to re-emit carried raw fields).
  void writeRaw(List<int> bytes) {
    _ensure(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  /// Writes an unsigned-64 base-128 varint.
  void writeVarint(int value) {
    var v = value;
    while ((v & ~0x7F) != 0) {
      writeByte((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    writeByte(v);
  }

  /// Writes a field key (`field << 3 | wireType`).
  void writeTag(int field, int wireType) =>
      writeVarint((field << 3) | wireType);

  /// Writes a varint-typed field.
  void writeVarintField(int field, int value) {
    writeTag(field, MvtWireType.varint);
    writeVarint(value);
  }

  /// Writes a 32-bit fixed field from its raw little-endian bit pattern.
  void writeFixed32Field(int field, int bits) {
    writeTag(field, MvtWireType.fixed32);
    for (var i = 0; i < 4; i++) {
      writeByte((bits >>> (8 * i)) & 0xFF);
    }
  }

  /// Writes a 64-bit fixed field from its raw little-endian bit pattern.
  void writeFixed64Field(int field, int bits) {
    writeTag(field, MvtWireType.fixed64);
    for (var i = 0; i < 8; i++) {
      writeByte((bits >>> (8 * i)) & 0xFF);
    }
  }

  /// Writes a length-delimited field carrying [payload].
  void writeBytesField(int field, List<int> payload) {
    writeTag(field, MvtWireType.lengthDelimited);
    writeVarint(payload.length);
    writeRaw(payload);
  }

  /// Writes a length-delimited field carrying the UTF-8 of [value].
  void writeStringField(int field, String value) =>
      writeBytesField(field, utf8.encode(value));

  /// Writes a packed repeated varint field. No-op when [values] is empty
  /// (protobuf cannot distinguish empty-packed from absent anyway).
  void writePackedVarintField(int field, List<int> values) {
    if (values.isEmpty) return;
    var size = 0;
    for (final v in values) {
      size += varintSize(v);
    }
    writeTag(field, MvtWireType.lengthDelimited);
    writeVarint(size);
    _ensure(size);
    for (final v in values) {
      writeVarint(v);
    }
  }

  /// Writes [sub]'s buffer as a length-delimited sub-message, without an
  /// intermediate copy.
  void writeMessageField(int field, MvtWriter sub) {
    writeTag(field, MvtWireType.lengthDelimited);
    writeVarint(sub._len);
    _ensure(sub._len);
    _buf.setRange(_len, _len + sub._len, sub._buf);
    _len += sub._len;
  }

  /// Copies out everything written so far.
  Uint8List toBytes() => _buf.sublist(0, _len);
}

/// Bounds-checked protobuf reader over a byte range.
class MvtReader {
  MvtReader(this.bytes, [int start = 0, int? end])
      : _pos = start,
        _end = end ?? bytes.length;

  final Uint8List bytes;
  int _pos;
  final int _end;

  /// Current read offset into [bytes].
  int get position => _pos;

  /// Exclusive end of this reader's range.
  int get end => _end;

  /// Whether any bytes remain in range.
  bool get hasMore => _pos < _end;

  /// Reads an unsigned-64 base-128 varint.
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) {
        throw const FormatException('MVT: truncated varint');
      }
      final b = bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('MVT: varint longer than 10 bytes');
      }
    }
  }

  /// Reads a length-delimited payload as a view (no copy).
  Uint8List readBytesView() {
    final len = readVarint();
    if (len < 0 || _pos + len > _end) {
      throw const FormatException('MVT: length-delimited field out of range');
    }
    final view = Uint8List.sublistView(bytes, _pos, _pos + len);
    _pos += len;
    return view;
  }

  /// Reads a length-delimited payload as UTF-8.
  String readString() => utf8.decode(readBytesView());

  /// Reads a length-delimited payload and returns a reader over it,
  /// advancing this reader past the sub-message.
  MvtReader subReader() {
    final len = readVarint();
    if (len < 0 || _pos + len > _end) {
      throw const FormatException('MVT: sub-message out of range');
    }
    final r = MvtReader(bytes, _pos, _pos + len);
    _pos += len;
    return r;
  }

  /// Skips the value of a field with the given [wireType].
  void skipField(int wireType) {
    switch (wireType) {
      case MvtWireType.varint:
        readVarint();
      case MvtWireType.fixed64:
        _advance(8);
      case MvtWireType.lengthDelimited:
        _advance(readVarint());
      case MvtWireType.fixed32:
        _advance(4);
      default:
        throw FormatException('MVT: unsupported wire type $wireType');
    }
  }

  void _advance(int n) {
    if (n < 0 || _pos + n > _end) {
      throw const FormatException('MVT: field runs past end of message');
    }
    _pos += n;
  }

  /// Copies the bytes from [start] up to the current position — used to
  /// capture a whole field (tag + payload) for verbatim re-emission.
  Uint8List rawSince(int start) => bytes.sublist(start, _pos);

  /// Reads a repeated scalar field that may be packed (wire type 2) or
  /// written one-value-per-tag (wire type 0), appending to [into].
  void readRepeatedVarintInto(int wireType, List<int> into) {
    if (wireType == MvtWireType.varint) {
      into.add(readVarint());
      return;
    }
    if (wireType != MvtWireType.lengthDelimited) {
      throw FormatException(
          'MVT: repeated scalar field with wire type $wireType');
    }
    final sub = subReader();
    while (sub.hasMore) {
      into.add(sub.readVarint());
    }
  }
}

/// One `Tile.Feature`. Geometry is kept as the raw packed command
/// integers; use [decodeGeometry] / [encodeGeometry] to move between
/// that and point lists.
class MvtFeature {
  MvtFeature({
    this.id,
    this.tags = const <int>[],
    this.type = MvtGeomType.unknown,
    this.geometryCommands = const <int>[],
    this.unknownFields = const <Uint8List>[],
  });

  /// `Feature.id`, or null when absent.
  final int? id;

  /// Flattened key/value index pairs into the layer's `keys`/`values`.
  final List<int> tags;

  /// One of [MvtGeomType].
  final int type;

  /// Raw `Feature.geometry` command integers.
  final List<int> geometryCommands;

  /// Fields we did not recognise, carried verbatim (tag + payload).
  final List<Uint8List> unknownFields;

  /// Decodes [geometryCommands] into parts.
  ///
  /// * `POINT` — a single part holding every point (a MULTIPOINT is one
  ///   `MoveTo` with count N; producers that emit N separate `MoveTo`s
  ///   are accepted and collapsed into the same part).
  /// * `LINESTRING` — one part per `MoveTo`.
  /// * `POLYGON` — one part per ring, in encounter order (exterior then
  ///   its holes, per the spec); the closing point is *not* repeated and
  ///   winding is left exactly as encoded.
  ///
  /// The cursor persists across parts within the feature, and `ClosePath`
  /// takes no parameters and does not move it (spec 4.3.3.3).
  ///
  /// Returns freshly allocated, mutable lists; callers may transform them
  /// in place.
  List<List<IntPoint>> decodeGeometry() {
    final g = geometryCommands;
    final parts = <List<IntPoint>>[];
    if (g.isEmpty) return parts;
    final isPoint = type == MvtGeomType.point;
    List<IntPoint>? current;
    var x = 0;
    var y = 0;
    var i = 0;
    while (i < g.length) {
      final cmd = g[i++];
      final id = cmd & 0x7;
      final count = cmd >> 3;
      if (id == MvtCommand.closePath) continue;
      if (id != MvtCommand.moveTo && id != MvtCommand.lineTo) {
        throw FormatException('MVT: unknown geometry command id $id');
      }
      if (count < 0 || i + count * 2 > g.length) {
        throw const FormatException('MVT: truncated geometry parameters');
      }
      for (var n = 0; n < count; n++) {
        x += zigzagDecode(g[i++]);
        y += zigzagDecode(g[i++]);
        if (current == null || (id == MvtCommand.moveTo && !isPoint)) {
          current = <IntPoint>[];
          parts.add(current);
        }
        current.add(IntPoint(x, y));
      }
    }
    return parts;
  }

  /// Inverse of [decodeGeometry]: packs [parts] into command integers for
  /// a feature of the given [type].
  ///
  /// Points collapse into one `MoveTo` of count N. Lines and polygons get
  /// `MoveTo(1)` + `LineTo(n-1)` per part, plus `ClosePath` for polygons.
  /// Empty parts are skipped; winding and ring order are preserved.
  static List<int> encodeGeometry(int type, List<List<IntPoint>> parts) {
    final out = <int>[];
    var cx = 0;
    var cy = 0;
    if (type == MvtGeomType.point) {
      var n = 0;
      for (final part in parts) {
        n += part.length;
      }
      if (n == 0) return out;
      out.add(MvtCommand.encode(MvtCommand.moveTo, n));
      for (final part in parts) {
        for (final p in part) {
          out.add(zigzagEncode(p.x - cx));
          out.add(zigzagEncode(p.y - cy));
          cx = p.x;
          cy = p.y;
        }
      }
      return out;
    }
    for (final part in parts) {
      if (part.isEmpty) continue;
      final first = part[0];
      out.add(MvtCommand.encode(MvtCommand.moveTo, 1));
      out.add(zigzagEncode(first.x - cx));
      out.add(zigzagEncode(first.y - cy));
      cx = first.x;
      cy = first.y;
      if (part.length > 1) {
        out.add(MvtCommand.encode(MvtCommand.lineTo, part.length - 1));
        for (var i = 1; i < part.length; i++) {
          final p = part[i];
          out.add(zigzagEncode(p.x - cx));
          out.add(zigzagEncode(p.y - cy));
          cx = p.x;
          cy = p.y;
        }
      }
      if (type == MvtGeomType.polygon) {
        out.add(MvtCommand.encode(MvtCommand.closePath, 1));
      }
    }
    return out;
  }
}

/// One `Tile.Layer`.
///
/// `keys` (field 3), `values` (field 4) and any field we do not model are
/// held as raw encoded field bytes (tag + payload) and written back out
/// verbatim, in the order they were read, so a re-encoded layer keeps its
/// attribute table bit-identical. The raw lists are shared, not copied,
/// when a layer is rebuilt.
class MvtLayer {
  MvtLayer({
    required this.name,
    this.version = kMvtDefaultVersion,
    this.extent = kMvtDefaultExtent,
    this.features = const <MvtFeature>[],
    this.rawKeyFields = const <Uint8List>[],
    this.rawValueFields = const <Uint8List>[],
    this.unknownFields = const <Uint8List>[],
  });

  final String name;
  final int version;
  final int extent;
  final List<MvtFeature> features;

  /// Raw encoded `keys` fields, in order.
  final List<Uint8List> rawKeyFields;

  /// Raw encoded `values` fields, in order.
  final List<Uint8List> rawValueFields;

  /// Raw encoded fields we do not model, in order.
  final List<Uint8List> unknownFields;
}

/// A decoded `Tile`.
class MvtTile {
  MvtTile({this.layers = const <MvtLayer>[]});

  final List<MvtLayer> layers;
}

/// Decodes an uncompressed MVT blob.
///
/// Throws [FormatException] on truncated or malformed input. Unknown
/// fields on `Tile` are skipped; unknown fields on `Layer` and `Feature`
/// are carried.
MvtTile decodeMvt(Uint8List data) {
  final r = MvtReader(data);
  final layers = <MvtLayer>[];
  while (r.hasMore) {
    final key = r.readVarint();
    final field = key >> 3;
    final wire = key & 0x7;
    if (field == 3 && wire == MvtWireType.lengthDelimited) {
      layers.add(_decodeLayer(r.subReader()));
    } else {
      r.skipField(wire);
    }
  }
  return MvtTile(layers: layers);
}

MvtLayer _decodeLayer(MvtReader r) {
  var name = '';
  var version = kMvtDefaultVersion;
  var extent = kMvtDefaultExtent;
  final features = <MvtFeature>[];
  final keys = <Uint8List>[];
  final values = <Uint8List>[];
  final unknown = <Uint8List>[];
  while (r.hasMore) {
    final start = r.position;
    final key = r.readVarint();
    final field = key >> 3;
    final wire = key & 0x7;
    if (field == 1 && wire == MvtWireType.lengthDelimited) {
      name = r.readString();
    } else if (field == 2 && wire == MvtWireType.lengthDelimited) {
      features.add(_decodeFeature(r.subReader()));
    } else if (field == 3 && wire == MvtWireType.lengthDelimited) {
      r.skipField(wire);
      keys.add(r.rawSince(start));
    } else if (field == 4 && wire == MvtWireType.lengthDelimited) {
      r.skipField(wire);
      values.add(r.rawSince(start));
    } else if (field == 5 && wire == MvtWireType.varint) {
      extent = r.readVarint();
    } else if (field == 15 && wire == MvtWireType.varint) {
      version = r.readVarint();
    } else {
      r.skipField(wire);
      unknown.add(r.rawSince(start));
    }
  }
  return MvtLayer(
    name: name,
    version: version,
    extent: extent,
    features: features,
    rawKeyFields: keys,
    rawValueFields: values,
    unknownFields: unknown,
  );
}

MvtFeature _decodeFeature(MvtReader r) {
  int? id;
  var type = MvtGeomType.unknown;
  List<int>? tags;
  List<int>? geometry;
  List<Uint8List>? unknown;
  while (r.hasMore) {
    final start = r.position;
    final key = r.readVarint();
    final field = key >> 3;
    final wire = key & 0x7;
    if (field == 1 && wire == MvtWireType.varint) {
      id = r.readVarint();
    } else if (field == 2) {
      r.readRepeatedVarintInto(wire, tags ??= <int>[]);
    } else if (field == 3 && wire == MvtWireType.varint) {
      type = r.readVarint();
    } else if (field == 4) {
      r.readRepeatedVarintInto(wire, geometry ??= <int>[]);
    } else {
      r.skipField(wire);
      (unknown ??= <Uint8List>[]).add(r.rawSince(start));
    }
  }
  return MvtFeature(
    id: id,
    tags: tags ?? const <int>[],
    type: type,
    geometryCommands: geometry ?? const <int>[],
    unknownFields: unknown ?? const <Uint8List>[],
  );
}

/// Encodes [tile] back to an uncompressed MVT blob.
///
/// Deterministic: the same model always produces the same bytes. Field
/// order is name, features, keys, values, extent, version, carried
/// unknowns — repeated fields are written packed, per the spec.
Uint8List encodeMvt(MvtTile tile) {
  final w = MvtWriter(1024);
  final lw = MvtWriter(1024);
  for (final layer in tile.layers) {
    lw._len = 0;
    _encodeLayer(layer, lw);
    w.writeMessageField(3, lw);
  }
  return w.toBytes();
}

void _encodeLayer(MvtLayer layer, MvtWriter w) {
  w.writeStringField(1, layer.name);
  final fw = MvtWriter(256);
  for (final f in layer.features) {
    fw._len = 0;
    _encodeFeature(f, fw);
    w.writeMessageField(2, fw);
  }
  for (final raw in layer.rawKeyFields) {
    w.writeRaw(raw);
  }
  for (final raw in layer.rawValueFields) {
    w.writeRaw(raw);
  }
  w.writeVarintField(5, layer.extent);
  w.writeVarintField(15, layer.version);
  for (final raw in layer.unknownFields) {
    w.writeRaw(raw);
  }
}

void _encodeFeature(MvtFeature f, MvtWriter w) {
  final id = f.id;
  if (id != null) w.writeVarintField(1, id);
  w.writePackedVarintField(2, f.tags);
  if (f.type != MvtGeomType.unknown) w.writeVarintField(3, f.type);
  w.writePackedVarintField(4, f.geometryCommands);
  for (final raw in f.unknownFields) {
    w.writeRaw(raw);
  }
}
