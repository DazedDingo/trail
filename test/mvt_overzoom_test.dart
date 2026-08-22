import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/tiles/mvt_codec.dart';
import 'package:trail/services/tiles/mvt_overzoom.dart';

/// Set with `--dart-define=BENCH=true` to run the `bench`-tagged test.
const bool kRunBench = bool.fromEnvironment('BENCH');

MvtFeature pointFeature(List<IntPoint> points,
        {int? id, List<int> tags = const <int>[]}) =>
    MvtFeature(
      id: id,
      tags: tags,
      type: MvtGeomType.point,
      geometryCommands:
          MvtFeature.encodeGeometry(MvtGeomType.point, [points]),
    );

MvtFeature lineFeature(List<List<IntPoint>> parts,
        {int? id, List<int> tags = const <int>[]}) =>
    MvtFeature(
      id: id,
      tags: tags,
      type: MvtGeomType.lineString,
      geometryCommands:
          MvtFeature.encodeGeometry(MvtGeomType.lineString, parts),
    );

MvtFeature polygonFeature(List<List<IntPoint>> rings,
        {int? id, List<int> tags = const <int>[]}) =>
    MvtFeature(
      id: id,
      tags: tags,
      type: MvtGeomType.polygon,
      geometryCommands: MvtFeature.encodeGeometry(MvtGeomType.polygon, rings),
    );

Uint8List tileOf(List<MvtLayer> layers) => encodeMvt(MvtTile(layers: layers));

Uint8List oneLayerTile(List<MvtFeature> features,
        {String name = 'roads', int extent = 4096}) =>
    tileOf([MvtLayer(name: name, extent: extent, features: features)]);

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

/// Overzooms one zoom level into child (childX, childY) of tile 0/0/0.
Uint8List zoomIn(Uint8List parent, int childX, int childY, {int buffer = 64}) =>
    overzoomMvt(parent,
        parentZ: 0,
        parentX: 0,
        parentY: 0,
        childZ: 1,
        childX: childX,
        childY: childY,
        buffer: buffer);

void main() {
  group('scale and translate', () {
    test('k=1 doubles coordinates inside the child quadrant', () {
      final parent = oneLayerTile([
        pointFeature(const [IntPoint(100, 100)], id: 1),
      ]);
      final out = decodeMvt(zoomIn(parent, 0, 0));
      expect(out.layers.single.features.single.decodeGeometry(), [
        [const IntPoint(200, 200)],
      ]);
    });

    test('a point in the far quadrant lands in child (1, 1) only', () {
      final parent = oneLayerTile([
        pointFeature(const [IntPoint(3000, 3000)], id: 7),
      ]);
      final inFarChild = decodeMvt(zoomIn(parent, 1, 1));
      expect(inFarChild.layers.single.features.single.decodeGeometry(), [
        [const IntPoint(1904, 1904)], // 3000 * 2 - 1 * 4096
      ]);
      // ...and is far outside the near child, which loses its only feature
      // and therefore its only layer.
      expect(zoomIn(parent, 0, 0), isEmpty);
      expect(decodeMvt(zoomIn(parent, 0, 0)).layers, isEmpty);
    });

    test('multipoint keeps only the points inside the buffered rect', () {
      final parent = oneLayerTile([
        pointFeature(const [
          IntPoint(100, 100), // -> (200, 200), inside
          IntPoint(2080, 100), // -> (4160, 200), exactly on the buffer edge
          IntPoint(2100, 100), // -> (4200, 200), outside
        ], id: 3),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [const IntPoint(200, 200), const IntPoint(4160, 200)],
          ]);
    });

    test('buffer 0 clips to the extent exactly', () {
      final parent = oneLayerTile([
        pointFeature(const [IntPoint(2048, 2048)], id: 1), // -> (4096, 4096)
        pointFeature(const [IntPoint(2049, 2049)], id: 2), // -> (4098, 4098)
      ]);
      final out = decodeMvt(zoomIn(parent, 0, 0, buffer: 0));
      expect(out.layers.single.features.length, 1);
      expect(out.layers.single.features.single.id, 1);
    });

    test('k=8 (z6 -> z14) coordinates stay exact integers', () {
      final parent = tileOf([
        MvtLayer(name: 'roads', features: [
          pointFeature(const [IntPoint(80, 80)], id: 1),
          pointFeature(const [IntPoint(90, 90)], id: 2),
          lineFeature(const [
            [IntPoint(0, 0), IntPoint(4096, 4096)],
          ], id: 3),
        ]),
      ]);
      // 32 * 256 + 5 = 8197, 21 * 256 + 5 = 5381 -> offset (5, 5).
      final out = decodeMvt(overzoomMvt(parent,
          parentZ: 6,
          parentX: 32,
          parentY: 21,
          childZ: 14,
          childX: 8197,
          childY: 5381));
      final features = out.layers.single.features;
      expect(features.length, 3);
      expect(features[0].decodeGeometry(), [
        [const IntPoint(0, 0)], // 80 * 256 - 5 * 4096
      ]);
      expect(features[1].decodeGeometry(), [
        [const IntPoint(2560, 2560)], // 90 * 256 - 5 * 4096
      ]);
      expect(features[2].decodeGeometry(), [
        [const IntPoint(-64, -64), const IntPoint(4160, 4160)],
      ]);
    });
  });

  group('linestring clipping', () {
    test('clips at the buffered edge', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(100, 100), IntPoint(3000, 100)],
        ], id: 1),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [const IntPoint(200, 200), const IntPoint(4160, 200)],
          ]);
    });

    test('clips a line entering from outside', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(3000, 100), IntPoint(100, 100)],
        ], id: 1),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [const IntPoint(4160, 200), const IntPoint(200, 200)],
          ]);
    });

    test('merges consecutive surviving segments into one part', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [
            IntPoint(-1000, 100), // enters through the left buffer edge
            IntPoint(500, 100),
            IntPoint(1000, 300),
            IntPoint(1000, 4500), // exits through the bottom buffer edge
          ],
        ], id: 1),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [
              const IntPoint(-64, 200),
              const IntPoint(1000, 200),
              const IntPoint(2000, 600),
              const IntPoint(2000, 4160),
            ],
          ]);
    });

    test('a line that leaves and re-enters becomes two parts', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(100, 100), IntPoint(3000, 100), IntPoint(100, 300)],
        ], id: 1),
      ]);
      final parts = decodeMvt(zoomIn(parent, 0, 0))
          .layers
          .single
          .features
          .single
          .decodeGeometry();
      expect(parts, [
        [const IntPoint(200, 200), const IntPoint(4160, 200)],
        [const IntPoint(4160, 327), const IntPoint(200, 600)],
      ]);
    });

    test('a multi-part line keeps only the parts that survive', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(100, 100), IntPoint(200, 200)], // inside
          [IntPoint(3000, 3000), IntPoint(3500, 3500)], // outside
        ], id: 1),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [const IntPoint(200, 200), const IntPoint(400, 400)],
          ]);
    });

    test('a line wholly outside is dropped', () {
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(3000, 3000), IntPoint(3500, 3500)],
        ], id: 1),
      ]);
      expect(zoomIn(parent, 0, 0), isEmpty);
    });

    test('a segment that only grazes the corner is dropped', () {
      // Child coords (4160, -200) -> (4400, 40): never inside the rect.
      final parent = oneLayerTile([
        lineFeature(const [
          [IntPoint(2080, -100), IntPoint(2200, 20)],
        ], id: 1),
      ]);
      expect(zoomIn(parent, 0, 0), isEmpty);
    });
  });

  group('polygon clipping', () {
    test('a ring surrounding the child becomes the buffered rect', () {
      final ring = const [
        IntPoint(-200, -200),
        IntPoint(4200, -200),
        IntPoint(4200, 4200),
        IntPoint(-200, 4200),
      ];
      expect(signedArea(ring) > 0, isTrue, reason: 'exterior ring is CW');
      final parent = oneLayerTile([polygonFeature([ring], id: 1)]);
      final rings = decodeMvt(zoomIn(parent, 0, 0))
          .layers
          .single
          .features
          .single
          .decodeGeometry();
      expect(rings.length, 1);
      expect(rings.single, [
        const IntPoint(-64, 4160),
        const IntPoint(-64, -64),
        const IntPoint(4160, -64),
        const IntPoint(4160, 4160),
      ]);
      expect(signedArea(rings.single) > 0, isTrue,
          reason: 'winding is preserved');
    });

    test('a hole straddling the edge survives, after its exterior', () {
      const exterior = [
        IntPoint(-200, -200),
        IntPoint(4200, -200),
        IntPoint(4200, 4200),
        IntPoint(-200, 4200),
      ];
      const hole = [
        IntPoint(1800, 1000),
        IntPoint(1800, 2000),
        IntPoint(2500, 2000),
        IntPoint(2500, 1000),
      ];
      expect(signedArea(hole) < 0, isTrue, reason: 'hole is CCW');
      final parent =
          oneLayerTile([polygonFeature([exterior, hole], id: 1)]);
      final rings = decodeMvt(zoomIn(parent, 0, 0))
          .layers
          .single
          .features
          .single
          .decodeGeometry();
      expect(rings.length, 2);
      expect(signedArea(rings[0]) > 0, isTrue);
      expect(rings[1], [
        const IntPoint(4160, 2000),
        const IntPoint(3600, 2000),
        const IntPoint(3600, 4000),
        const IntPoint(4160, 4000),
      ]);
      expect(signedArea(rings[1]) < 0, isTrue,
          reason: 'the hole stays a hole');
    });

    test('a polygon wholly inside is passed through unclipped', () {
      final parent = oneLayerTile([
        polygonFeature(const [
          [IntPoint(10, 10), IntPoint(100, 10), IntPoint(100, 100)],
        ], id: 1),
      ]);
      expect(
          decodeMvt(zoomIn(parent, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [
              const IntPoint(20, 20),
              const IntPoint(200, 20),
              const IntPoint(200, 200)
            ],
          ]);
    });

    test('a polygon wholly outside is dropped', () {
      final parent = oneLayerTile([
        polygonFeature(const [
          [
            IntPoint(3000, 3000),
            IntPoint(4000, 3000),
            IntPoint(4000, 4000),
            IntPoint(3000, 4000)
          ],
        ], id: 1),
      ]);
      expect(zoomIn(parent, 0, 0), isEmpty);
    });

    test('a ring that collapses to a sliver on the edge is dropped', () {
      // Child coords: x from 4160 (exactly the buffer edge) to 5000.
      final parent = oneLayerTile([
        polygonFeature(const [
          [
            IntPoint(2080, 1000),
            IntPoint(2500, 1000),
            IntPoint(2500, 1500),
            IntPoint(2080, 1500)
          ],
        ], id: 1),
      ]);
      expect(zoomIn(parent, 0, 0), isEmpty);
    });

    test('a hole entirely outside the child is dropped, exterior kept', () {
      const exterior = [
        IntPoint(-200, -200),
        IntPoint(4200, -200),
        IntPoint(4200, 4200),
        IntPoint(-200, 4200),
      ];
      const hole = [
        IntPoint(3000, 3000),
        IntPoint(3000, 3500),
        IntPoint(3500, 3500),
        IntPoint(3500, 3000),
      ];
      final parent =
          oneLayerTile([polygonFeature([exterior, hole], id: 1)]);
      final rings = decodeMvt(zoomIn(parent, 0, 0))
          .layers
          .single
          .features
          .single
          .decodeGeometry();
      expect(rings.length, 1);
      expect(rings.single.length, 4);
    });
  });

  group('feature and layer bookkeeping', () {
    test('layers left with no features are dropped', () {
      final parent = tileOf([
        MvtLayer(name: 'roads', features: [
          pointFeature(const [IntPoint(100, 100)], id: 1),
        ]),
        MvtLayer(name: 'water', features: [
          pointFeature(const [IntPoint(3000, 3000)], id: 2),
        ]),
        MvtLayer(name: 'empty'),
      ]);
      final out = decodeMvt(zoomIn(parent, 0, 0));
      expect(out.layers.map((l) => l.name), ['roads']);
    });

    test('name, version, extent, keys and values pass through verbatim', () {
      final keyA = (MvtWriter()..writeStringField(3, 'class')).toBytes();
      final keyB = (MvtWriter()..writeStringField(3, 'name')).toBytes();
      final valueString = MvtWriter()..writeStringField(1, 'motorway');
      final valueBool = MvtWriter()..writeVarintField(7, 1);
      final valueDouble = MvtWriter()
        ..writeFixed64Field(3, 0x400921FB54442D18);
      final rawValues = <Uint8List>[
        (MvtWriter()..writeBytesField(4, valueString.toBytes())).toBytes(),
        (MvtWriter()..writeBytesField(4, valueBool.toBytes())).toBytes(),
        (MvtWriter()..writeBytesField(4, valueDouble.toBytes())).toBytes(),
      ];
      final extension =
          (MvtWriter()..writeStringField(11, 'planetiler')).toBytes();

      final parent = tileOf([
        MvtLayer(
          name: 'transportation',
          version: 2,
          extent: 512,
          rawKeyFields: [keyA, keyB],
          rawValueFields: rawValues,
          unknownFields: [extension],
          features: [
            pointFeature(const [IntPoint(100, 100)],
                id: 4294967297, tags: const [0, 0, 1, 1]),
          ],
        ),
      ]);

      final layer = decodeMvt(zoomIn(parent, 0, 0)).layers.single;
      expect(layer.name, 'transportation');
      expect(layer.version, 2);
      expect(layer.extent, 512);
      expect(layer.rawKeyFields, [keyA, keyB]);
      expect(layer.rawValueFields.length, 3);
      for (var i = 0; i < rawValues.length; i++) {
        expect(layer.rawValueFields[i], rawValues[i], reason: 'value $i');
      }
      expect(layer.unknownFields.single, extension);
      final feature = layer.features.single;
      expect(feature.id, 4294967297);
      expect(feature.tags, [0, 0, 1, 1]);
      expect(feature.type, MvtGeomType.point);
      expect(feature.decodeGeometry(), [
        [const IntPoint(200, 200)],
      ]);
    });

    test('UNKNOWN geometry passes through when inside, drops when clipped',
        () {
      final inside = oneLayerTile([
        MvtFeature(
          id: 1,
          geometryCommands:
              MvtFeature.encodeGeometry(MvtGeomType.lineString, const [
            [IntPoint(10, 10), IntPoint(20, 20)],
          ]),
        ),
      ]);
      expect(
          decodeMvt(zoomIn(inside, 0, 0))
              .layers
              .single
              .features
              .single
              .decodeGeometry(),
          [
            [const IntPoint(20, 20), const IntPoint(40, 40)],
          ]);

      final straddling = oneLayerTile([
        MvtFeature(
          id: 1,
          geometryCommands:
              MvtFeature.encodeGeometry(MvtGeomType.lineString, const [
            [IntPoint(10, 10), IntPoint(3000, 3000)],
          ]),
        ),
      ]);
      expect(zoomIn(straddling, 0, 0), isEmpty);
    });

    test('output is deterministic', () {
      final parent = tileOf([
        MvtLayer(name: 'roads', features: [
          pointFeature(const [IntPoint(100, 100)], id: 1),
          lineFeature(const [
            [IntPoint(-1000, 100), IntPoint(3000, 900)],
          ], id: 2),
          polygonFeature(const [
            [
              IntPoint(-200, -200),
              IntPoint(4200, -200),
              IntPoint(4200, 4200),
              IntPoint(-200, 4200)
            ],
          ], id: 3),
        ]),
      ]);
      final a = zoomIn(parent, 0, 0);
      final b = zoomIn(parent, 0, 0);
      expect(a, b);
      expect(encodeMvt(decodeMvt(a)), a);
    });

    test('an empty parent tile yields an empty child tile', () {
      expect(overzoomMvt(Uint8List(0),
              parentZ: 0, parentX: 0, parentY: 0, childZ: 1, childX: 1,
              childY: 0),
          isEmpty);
    });
  });

  group('argument validation', () {
    final parent = oneLayerTile([
      pointFeature(const [IntPoint(100, 100)], id: 1),
    ]);

    test('childZ must be greater than parentZ', () {
      expect(
          () => overzoomMvt(parent,
              parentZ: 5, parentX: 1, parentY: 1, childZ: 5, childX: 1,
              childY: 1),
          throwsArgumentError);
      expect(
          () => overzoomMvt(parent,
              parentZ: 5, parentX: 1, parentY: 1, childZ: 4, childX: 0,
              childY: 0),
          throwsArgumentError);
    });

    test('the child must lie inside the parent', () {
      expect(
          () => overzoomMvt(parent,
              parentZ: 1, parentX: 0, parentY: 0, childZ: 2, childX: 2,
              childY: 0),
          throwsArgumentError);
      expect(
          () => overzoomMvt(parent,
              parentZ: 1, parentX: 0, parentY: 0, childZ: 2, childX: 0,
              childY: 3),
          throwsArgumentError);
      // ...but every child of the parent's own quadrant is fine.
      for (var x = 0; x < 2; x++) {
        for (var y = 0; y < 2; y++) {
          expect(
              () => overzoomMvt(parent,
                  parentZ: 1, parentX: 0, parentY: 0, childZ: 2, childX: x,
                  childY: y),
              returnsNormally);
        }
      }
    });

    test('negative coordinates and buffers are rejected', () {
      expect(
          () => overzoomMvt(parent,
              parentZ: 0, parentX: 0, parentY: 0, childZ: 1, childX: 0,
              childY: 0, buffer: -1),
          throwsArgumentError);
      expect(
          () => overzoomMvt(parent,
              parentZ: -1, parentX: 0, parentY: 0, childZ: 1, childX: 0,
              childY: 0),
          throwsArgumentError);
    });

    test('an absurd zoom jump is rejected rather than overflowing', () {
      expect(
          () => overzoomMvt(parent,
              parentZ: 0, parentX: 0, parentY: 0, childZ: 40, childX: 0,
              childY: 0),
          throwsArgumentError);
    });
  });

  test(
    'benchmark: 5000 features / 100000 vertices overzooms in < 500 ms',
    () {
      final features = <MvtFeature>[];
      var seed = 12345;
      int next(int bound) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        return seed % bound;
      }

      for (var f = 0; f < 5000; f++) {
        var x = next(4096);
        var y = next(4096);
        final part = <IntPoint>[];
        for (var v = 0; v < 20; v++) {
          x = (x + next(400) - 200).clamp(-64, 4160);
          y = (y + next(400) - 200).clamp(-64, 4160);
          part.add(IntPoint(x, y));
        }
        features.add(lineFeature([part], id: f, tags: const [0, 0]));
      }
      final parent = oneLayerTile(features);

      final sw = Stopwatch()..start();
      final child = zoomIn(parent, 0, 0);
      sw.stop();
      expect(child, isNotEmpty);
      // ignore: avoid_print
      print('overzoom of ${parent.length} bytes took '
          '${sw.elapsedMilliseconds} ms -> ${child.length} bytes');
      expect(sw.elapsedMilliseconds, lessThan(500));
    },
    tags: ['bench'],
    skip: kRunBench ? false : 'run with --dart-define=BENCH=true --tags bench',
  );
}
