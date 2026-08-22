import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/tiles/mvt_codec.dart';

/// Encodes a single varint on its own.
Uint8List varintBytes(int value) => (MvtWriter()..writeVarint(value)).toBytes();

/// Reads a single varint from [bytes].
int readVarint(List<int> bytes) => MvtReader(Uint8List.fromList(bytes)).readVarint();

/// A raw `Layer.keys` field (tag + payload) for [key].
Uint8List keyField(String key) => (MvtWriter()..writeStringField(3, key)).toBytes();

/// A raw `Layer.values` field wrapping a hand-built `Tile.Value`.
Uint8List valueField(void Function(MvtWriter) build) {
  final value = MvtWriter();
  build(value);
  final w = MvtWriter();
  w.writeBytesField(4, value.toBytes());
  return w.toBytes();
}

int floatBits(double v) =>
    (ByteData(4)..setFloat32(0, v, Endian.little)).getUint32(0, Endian.little);

int doubleBits(double v) =>
    (ByteData(8)..setFloat64(0, v, Endian.little)).getUint64(0, Endian.little);

/// Shoelace sum; positive means an MVT exterior ring (y grows downwards).
int signedArea(List<IntPoint> ring) {
  var sum = 0;
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i];
    final b = ring[(i + 1) % ring.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum;
}

void main() {
  group('varint', () {
    test('encodes the canonical short forms', () {
      expect(varintBytes(0), [0x00]);
      expect(varintBytes(1), [0x01]);
      expect(varintBytes(127), [0x7F]);
      expect(varintBytes(128), [0x80, 0x01]);
      expect(varintBytes(300), [0xAC, 0x02]);
      expect(varintBytes(16383), [0xFF, 0x7F]);
      expect(varintBytes(16384), [0x80, 0x80, 0x01]);
    });

    test('round-trips 64-bit edge cases', () {
      const cases = <int>[
        0,
        1,
        2,
        127,
        128,
        300,
        65535,
        2147483647, // 2^31 - 1
        2147483648, // 2^31
        4294967296, // 2^32
        9007199254740991, // 2^53 - 1
        9007199254740992, // 2^53
        4611686018427387904, // 2^62
        9223372036854775807, // maxInt
        -1,
        -2,
        -2147483648,
        -9223372036854775808, // minInt
      ];
      for (final v in cases) {
        final bytes = varintBytes(v);
        expect(bytes.length, varintSize(v), reason: 'size of $v');
        expect(readVarint(bytes), v, reason: 'round-trip of $v');
      }
    });

    test('negative values take the full ten bytes (uint64 semantics)', () {
      expect(varintBytes(-1),
          [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]);
      expect(varintBytes(-9223372036854775808),
          [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]);
      expect(varintSize(-1), 10);
    });

    test('a truncated varint throws', () {
      expect(() => readVarint([0x80]), throwsFormatException);
      expect(() => readVarint(<int>[]), throwsFormatException);
    });

    test('a varint longer than ten bytes throws', () {
      expect(
          () => readVarint([
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, //
                0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01,
              ]),
          throwsFormatException);
    });
  });

  group('zigzag', () {
    test('matches the protobuf table', () {
      expect(zigzagEncode(0), 0);
      expect(zigzagEncode(-1), 1);
      expect(zigzagEncode(1), 2);
      expect(zigzagEncode(-2), 3);
      expect(zigzagEncode(2), 4);
      expect(zigzagDecode(0), 0);
      expect(zigzagDecode(1), -1);
      expect(zigzagDecode(2), 1);
      expect(zigzagDecode(3), -2);
      expect(zigzagDecode(4), 2);
    });

    test('handles 32-bit boundaries the way the MVT spec expects', () {
      expect(zigzagEncode(2147483647), 4294967294);
      expect(zigzagEncode(-2147483648), 4294967295);
      expect(zigzagEncode(2147483648), 4294967296);
      expect(zigzagDecode(4294967296), 2147483648);
    });

    test('round-trips 64-bit edge cases', () {
      const cases = <int>[
        0,
        1,
        -1,
        2147483648,
        -2147483648,
        9007199254740991,
        -9007199254740991,
        4611686018427387904,
        -4611686018427387904,
        9223372036854775807,
        -9223372036854775808,
      ];
      for (final v in cases) {
        expect(zigzagDecode(zigzagEncode(v)), v, reason: 'round-trip of $v');
      }
    });
  });

  group('geometry', () {
    test('decodes the spec 2.1 point example', () {
      final f = MvtFeature(
          type: MvtGeomType.point, geometryCommands: const [9, 50, 34]);
      expect(f.decodeGeometry(), [
        [const IntPoint(25, 17)],
      ]);
      expect(
          MvtFeature.encodeGeometry(MvtGeomType.point, f.decodeGeometry()),
          [9, 50, 34]);
    });

    test('decodes the spec 2.1 multipoint example', () {
      final f = MvtFeature(
          type: MvtGeomType.point, geometryCommands: const [17, 10, 14, 3, 9]);
      final parts = f.decodeGeometry();
      expect(parts, [
        [const IntPoint(5, 7), const IntPoint(3, 2)],
      ]);
      expect(MvtFeature.encodeGeometry(MvtGeomType.point, parts),
          [17, 10, 14, 3, 9]);
    });

    test('decodes the spec 2.1 linestring example', () {
      final f = MvtFeature(
          type: MvtGeomType.lineString,
          geometryCommands: const [9, 4, 4, 18, 0, 16, 16, 0]);
      final parts = f.decodeGeometry();
      expect(parts, [
        [const IntPoint(2, 2), const IntPoint(2, 10), const IntPoint(10, 10)],
      ]);
      expect(MvtFeature.encodeGeometry(MvtGeomType.lineString, parts),
          [9, 4, 4, 18, 0, 16, 16, 0]);
    });

    test('decodes the spec 2.1 polygon example', () {
      final f = MvtFeature(
          type: MvtGeomType.polygon,
          geometryCommands: const [9, 6, 12, 18, 10, 12, 24, 44, 15]);
      final parts = f.decodeGeometry();
      expect(parts, [
        [const IntPoint(3, 6), const IntPoint(8, 12), const IntPoint(20, 34)],
      ]);
      expect(MvtFeature.encodeGeometry(MvtGeomType.polygon, parts),
          [9, 6, 12, 18, 10, 12, 24, 44, 15]);
    });

    test('the cursor persists across parts of a multi-linestring', () {
      const parts = [
        [IntPoint(2, 2), IntPoint(2, 10), IntPoint(10, 10)],
        [IntPoint(1, 1), IntPoint(3, 5)],
      ];
      // Second MoveTo is relative to (10, 10), not to the origin.
      const expected = [9, 4, 4, 18, 0, 16, 16, 0, 9, 17, 17, 10, 4, 8];
      expect(MvtFeature.encodeGeometry(MvtGeomType.lineString, parts),
          expected);
      expect(
          MvtFeature(
                  type: MvtGeomType.lineString, geometryCommands: expected)
              .decodeGeometry(),
          parts);
    });

    test('polygon with a hole keeps ring order and winding', () {
      const exterior = [
        IntPoint(0, 0),
        IntPoint(10, 0),
        IntPoint(10, 10),
        IntPoint(0, 10),
      ];
      const hole = [
        IntPoint(2, 2),
        IntPoint(2, 8),
        IntPoint(8, 8),
        IntPoint(8, 2),
      ];
      expect(signedArea(exterior) > 0, isTrue, reason: 'exterior is CW');
      expect(signedArea(hole) < 0, isTrue, reason: 'hole is CCW');
      const expected = [
        9, 0, 0, 26, 20, 0, 0, 20, 19, 0, 15, //
        9, 4, 15, 26, 0, 12, 12, 0, 0, 11, 15,
      ];
      final encoded =
          MvtFeature.encodeGeometry(MvtGeomType.polygon, [exterior, hole]);
      expect(encoded, expected);
      final parts =
          MvtFeature(type: MvtGeomType.polygon, geometryCommands: encoded)
              .decodeGeometry();
      expect(parts, [exterior, hole]);
      expect(signedArea(parts[0]) > 0, isTrue);
      expect(signedArea(parts[1]) < 0, isTrue);
    });

    test('ClosePath does not move the cursor', () {
      // Two rings: the second MoveTo is relative to the last LineTo point
      // (0, 10), not to the ring's first point (0, 0).
      final parts = MvtFeature(
        type: MvtGeomType.polygon,
        geometryCommands: const [
          9, 0, 0, 26, 20, 0, 0, 20, 19, 0, 15, //
          9, 4, 15, 26, 0, 12, 12, 0, 0, 11, 15,
        ],
      ).decodeGeometry();
      expect(parts[1].first, const IntPoint(2, 2));
    });

    test('empty geometry decodes to no parts and encodes to nothing', () {
      expect(MvtFeature(type: MvtGeomType.point).decodeGeometry(), isEmpty);
      expect(MvtFeature.encodeGeometry(MvtGeomType.point, const []), isEmpty);
      expect(
          MvtFeature.encodeGeometry(
              MvtGeomType.lineString, [<IntPoint>[], <IntPoint>[]]),
          isEmpty);
    });

    test('separate MoveTos collapse into one part for POINT features', () {
      // Liberal read: some producers emit MoveTo(1) per point.
      final f = MvtFeature(
          type: MvtGeomType.point,
          geometryCommands: const [9, 10, 14, 9, 3, 9]);
      expect(f.decodeGeometry(), [
        [const IntPoint(5, 7), const IntPoint(3, 2)],
      ]);
    });

    test('unknown commands and truncated parameters throw', () {
      expect(
          () => MvtFeature(
                  type: MvtGeomType.point, geometryCommands: const [11, 1, 1])
              .decodeGeometry(),
          throwsFormatException);
      expect(
          () => MvtFeature(
                  type: MvtGeomType.point, geometryCommands: const [9, 1])
              .decodeGeometry(),
          throwsFormatException);
    });
  });

  group('tile round-trip', () {
    late Uint8List roadsKeys0;
    late Uint8List roadsKeys1;
    late List<Uint8List> roadsValues;
    late MvtTile tile;
    late Uint8List bytes;

    setUp(() {
      roadsKeys0 = keyField('class');
      roadsKeys1 = keyField('name');
      roadsValues = <Uint8List>[
        valueField((w) => w.writeStringField(1, 'motorway')),
        valueField((w) => w.writeFixed32Field(2, floatBits(1.5))),
        valueField((w) => w.writeFixed64Field(3, doubleBits(3.14159))),
        valueField((w) => w.writeVarintField(4, -7)),
        valueField((w) => w.writeVarintField(5, 1099511627776)),
        valueField((w) => w.writeVarintField(6, zigzagEncode(-12345))),
        valueField((w) => w.writeVarintField(7, 1)),
      ];
      tile = MvtTile(layers: [
        MvtLayer(
          name: 'roads',
          extent: 4096,
          rawKeyFields: [roadsKeys0, roadsKeys1],
          rawValueFields: roadsValues,
          features: [
            MvtFeature(
              id: 1,
              tags: const [0, 0, 1, 6],
              type: MvtGeomType.point,
              geometryCommands: MvtFeature.encodeGeometry(
                  MvtGeomType.point, const [
                [IntPoint(25, 17)]
              ]),
            ),
            MvtFeature(
              id: 2,
              tags: const [1, 1],
              type: MvtGeomType.lineString,
              geometryCommands: MvtFeature.encodeGeometry(
                  MvtGeomType.lineString, const [
                [IntPoint(2, 2), IntPoint(2, 10), IntPoint(10, 10)],
                [IntPoint(1, 1), IntPoint(3, 5)],
              ]),
            ),
            MvtFeature(
              id: 9007199254740993,
              type: MvtGeomType.polygon,
              geometryCommands: MvtFeature.encodeGeometry(
                  MvtGeomType.polygon, const [
                [
                  IntPoint(0, 0),
                  IntPoint(10, 0),
                  IntPoint(10, 10),
                  IntPoint(0, 10)
                ],
                [IntPoint(2, 2), IntPoint(2, 8), IntPoint(8, 8), IntPoint(8, 2)]
              ]),
            ),
          ],
        ),
        MvtLayer(
          name: 'water',
          version: 2,
          extent: 512,
          rawKeyFields: [keyField('intermittent')],
          rawValueFields: [valueField((w) => w.writeVarintField(7, 0))],
          features: [
            MvtFeature(
              tags: const [0, 0],
              type: MvtGeomType.polygon,
              geometryCommands: MvtFeature.encodeGeometry(
                  MvtGeomType.polygon, const [
                [
                  IntPoint(0, 0),
                  IntPoint(512, 0),
                  IntPoint(512, 512),
                  IntPoint(0, 512)
                ]
              ]),
            ),
          ],
        ),
      ]);
      bytes = encodeMvt(tile);
    });

    test('decodes every scalar back', () {
      final out = decodeMvt(bytes);
      expect(out.layers.length, 2);
      expect(out.layers[0].name, 'roads');
      expect(out.layers[0].version, 2);
      expect(out.layers[0].extent, 4096);
      expect(out.layers[0].features.length, 3);
      expect(out.layers[1].name, 'water');
      expect(out.layers[1].extent, 512);
      expect(out.layers[1].features.length, 1);
    });

    test('carries keys and values as raw bytes, in order', () {
      final layer = decodeMvt(bytes).layers[0];
      expect(layer.rawKeyFields.length, 2);
      expect(layer.rawKeyFields[0], roadsKeys0);
      expect(layer.rawKeyFields[1], roadsKeys1);
      expect(layer.rawValueFields.length, 7);
      for (var i = 0; i < roadsValues.length; i++) {
        expect(layer.rawValueFields[i], roadsValues[i], reason: 'value $i');
      }
      expect(layer.unknownFields, isEmpty);
    });

    test('keeps ids, tags, types and geometry', () {
      final fs = decodeMvt(bytes).layers[0].features;
      expect(fs[0].id, 1);
      expect(fs[0].tags, [0, 0, 1, 6]);
      expect(fs[0].type, MvtGeomType.point);
      expect(fs[0].decodeGeometry(), [
        [const IntPoint(25, 17)],
      ]);
      expect(fs[1].id, 2);
      expect(fs[1].tags, [1, 1]);
      expect(fs[1].decodeGeometry().length, 2);
      expect(fs[2].id, 9007199254740993);
      expect(fs[2].tags, isEmpty);
      expect(fs[2].type, MvtGeomType.polygon);
      expect(fs[2].decodeGeometry().length, 2);
      expect(decodeMvt(bytes).layers[1].features[0].id, isNull);
    });

    test('re-encoding is byte-for-byte identical and deterministic', () {
      expect(encodeMvt(decodeMvt(bytes)), bytes);
      expect(encodeMvt(decodeMvt(encodeMvt(decodeMvt(bytes)))), bytes);
      expect(encodeMvt(tile), bytes);
    });

    test('an empty tile round-trips', () {
      final empty = encodeMvt(MvtTile());
      expect(empty, isEmpty);
      expect(decodeMvt(empty).layers, isEmpty);
    });

    test('a layer with no features round-trips', () {
      final one = encodeMvt(MvtTile(layers: [MvtLayer(name: 'empty')]));
      final out = decodeMvt(one);
      expect(out.layers.single.name, 'empty');
      expect(out.layers.single.features, isEmpty);
      expect(out.layers.single.extent, kMvtDefaultExtent);
      expect(encodeMvt(out), one);
    });
  });

  group('liberal decoding', () {
    test('accepts non-packed tags and geometry, and re-emits them packed',
        () {
      final f = MvtWriter();
      f.writeVarintField(1, 42);
      f.writeVarintField(2, 0);
      f.writeVarintField(2, 1);
      f.writeVarintField(3, MvtGeomType.point);
      for (final g in const [9, 50, 34]) {
        f.writeVarintField(4, g);
      }
      final l = MvtWriter();
      l.writeVarintField(15, 2);
      l.writeVarintField(5, 4096);
      l.writeBytesField(2, f.toBytes());
      l.writeStringField(1, 'poi');
      final t = MvtWriter();
      t.writeBytesField(3, l.toBytes());

      final out = decodeMvt(t.toBytes());
      final layer = out.layers.single;
      expect(layer.name, 'poi');
      expect(layer.version, 2);
      expect(layer.extent, 4096);
      final feature = layer.features.single;
      expect(feature.id, 42);
      expect(feature.tags, [0, 1]);
      expect(feature.geometryCommands, [9, 50, 34]);
      expect(feature.decodeGeometry(), [
        [const IntPoint(25, 17)],
      ]);

      // Round two: written packed, and still decodes to the same model.
      final repacked = encodeMvt(out);
      expect(repacked.contains(0x22), isTrue,
          reason: 'field 4, wire type 2 (packed geometry)');
      final again = decodeMvt(repacked).layers.single.features.single;
      expect(again.tags, [0, 1]);
      expect(again.geometryCommands, [9, 50, 34]);
    });

    test('accepts a mix of packed and non-packed values for one field', () {
      final f = MvtWriter();
      f.writeVarintField(3, MvtGeomType.lineString);
      f.writePackedVarintField(4, const [9, 4, 4]);
      for (final g in const [18, 0, 16, 16, 0]) {
        f.writeVarintField(4, g);
      }
      final l = MvtWriter();
      l.writeStringField(1, 'roads');
      l.writeBytesField(2, f.toBytes());
      final t = MvtWriter();
      t.writeBytesField(3, l.toBytes());
      final feature = decodeMvt(t.toBytes()).layers.single.features.single;
      expect(feature.geometryCommands, [9, 4, 4, 18, 0, 16, 16, 0]);
    });

    test('carries unknown layer fields and skips unknown tile fields', () {
      final extension = (MvtWriter()..writeStringField(9, 'planetiler'))
          .toBytes();
      final l = MvtWriter();
      l.writeStringField(1, 'roads');
      l.writeRaw(extension);
      l.writeVarintField(5, 4096);
      l.writeVarintField(15, 2);
      final t = MvtWriter();
      t.writeVarintField(1, 7); // unknown Tile field — skipped
      t.writeBytesField(3, l.toBytes());
      t.writeFixed32Field(8, 0xDEADBEEF); // unknown Tile field — skipped

      final out = decodeMvt(t.toBytes());
      expect(out.layers.length, 1);
      expect(out.layers.single.unknownFields.single, extension);
      // ...and the extension survives a re-encode.
      final again = decodeMvt(encodeMvt(out));
      expect(again.layers.single.unknownFields.single, extension);
    });

    test('carries unknown feature fields', () {
      final f = MvtWriter();
      f.writeVarintField(3, MvtGeomType.point);
      f.writePackedVarintField(4, const [9, 50, 34]);
      f.writeStringField(12, 'extra');
      final l = MvtWriter();
      l.writeStringField(1, 'poi');
      l.writeBytesField(2, f.toBytes());
      final t = MvtWriter();
      t.writeBytesField(3, l.toBytes());

      final feature = decodeMvt(t.toBytes()).layers.single.features.single;
      expect(feature.unknownFields.length, 1);
      expect(utf8.decode(feature.unknownFields.single.sublist(2)), 'extra');
      final again =
          decodeMvt(encodeMvt(decodeMvt(t.toBytes()))).layers.single.features
              .single;
      expect(again.unknownFields.single, feature.unknownFields.single);
    });

    test('rejects malformed input', () {
      // Length-delimited field that runs off the end.
      expect(() => decodeMvt(Uint8List.fromList([0x1A, 0x7F])),
          throwsFormatException);
      // Group wire types are not part of MVT.
      expect(() => decodeMvt(Uint8List.fromList([0x0B])),
          throwsFormatException);
    });
  });

  group('IntPoint', () {
    test('has value equality', () {
      expect(const IntPoint(1, 2), const IntPoint(1, 2));
      expect(const IntPoint(1, 2).hashCode, const IntPoint(1, 2).hashCode);
      expect(const IntPoint(1, 2), isNot(const IntPoint(2, 1)));
      expect(const IntPoint(-3, 4).toString(), 'IntPoint(-3, 4)');
    });
  });
}
