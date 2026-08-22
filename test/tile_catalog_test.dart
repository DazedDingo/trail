import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/tile_catalog.dart';
import 'package:trail/services/tiles/tile_schema.dart';

/// A minimal well-formed catalog row.
Map<String, dynamic> _row({
  String id = 'dartmoor',
  String url =
      'https://github.com/DazedDingo/trail/releases/download/t/dartmoor.mbtiles',
  Object? schema,
}) =>
    <String, dynamic>{
      'id': id,
      'name': 'Dartmoor',
      'description': 'Dartmoor · Devon · National Park',
      'url': url,
      'sizeBytes': 2641920,
      if (schema != null) 'schema': schema,
    };

void main() {
  group('TilesetEntry.fromJson', () {
    test('reads a v2 entry, schema and all', () {
      final e = TilesetEntry.fromJson(_row(schema: 'protomaps'))!;
      expect(e.id, 'dartmoor');
      expect(e.sizeBytes, 2641920);
      expect(e.schema, TileSchema.protomaps);
    });

    test('a v1 entry with no schema key reads as OpenMapTiles', () {
      // Every catalog entry predating 0.16.0 was built by planetiler's
      // OMT profile; defaulting the other way would draw them blank.
      expect(TilesetEntry.fromJson(_row())!.schema, TileSchema.openmaptiles);
    });

    test('an unrecognised schema value falls back rather than dropping '
        'the row', () {
      expect(
        TilesetEntry.fromJson(_row(schema: 'martian'))!.schema,
        TileSchema.openmaptiles,
      );
      expect(
        TilesetEntry.fromJson(_row(schema: 7))!.schema,
        TileSchema.openmaptiles,
      );
    });

    test('a row missing a required field is dropped', () {
      final bad = _row()..remove('url');
      expect(TilesetEntry.fromJson(bad), isNull);
      expect(TilesetEntry.fromJson(<String, dynamic>{}), isNull);
    });

    test('a non-integer sizeBytes reads as zero, not an exception', () {
      final row = _row()..['sizeBytes'] = 'big';
      expect(TilesetEntry.fromJson(row)!.sizeBytes, 0);
    });
  });

  group('TilesetEntry.filename', () {
    test('keeps the .pmtiles extension the URL actually serves', () {
      // It used to hard-code `<id>.mbtiles`, which made TileArchive.open
      // pick the SQLite reader for a PMTiles download.
      final e = TilesetEntry.fromJson(_row(
        id: 'gb-z13',
        url: 'https://example.com/dl/v3/gb-z13.pmtiles',
      ))!;
      expect(e.filename, 'gb-z13.pmtiles');
    });

    test('keeps a .mbtiles download as .mbtiles', () {
      expect(TilesetEntry.fromJson(_row())!.filename, 'dartmoor.mbtiles');
    });

    test('a name that differs from the id is honoured', () {
      final e = TilesetEntry.fromJson(_row(
        id: 'uk',
        url: 'https://example.com/great-britain-z14.pmtiles',
      ))!;
      expect(e.filename, 'great-britain-z14.pmtiles');
    });

    test('a query string does not confuse the segment', () {
      final e = TilesetEntry.fromJson(_row(
        url: 'https://example.com/d/dartmoor.pmtiles?token=abc',
      ))!;
      expect(e.filename, 'dartmoor.pmtiles');
    });

    test('an extension-less URL falls back to <id>.mbtiles', () {
      final e = TilesetEntry.fromJson(_row(
        id: 'mystery',
        url: 'https://example.com/download',
      ))!;
      expect(e.filename, 'mystery.mbtiles');
    });
  });

  group('docs/tilesets.json', () {
    test('is a v2 catalog every entry of which parses', () {
      // The file the app fetches at runtime — a typo here is invisible
      // until the catalog sheet comes up empty on a device.
      final root = jsonDecode(File('docs/tilesets.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(root['version'], 2);
      final regions = (root['regions'] as List).cast<Map<String, dynamic>>();
      expect(regions, isNotEmpty);
      for (final region in regions) {
        final entry = TilesetEntry.fromJson(region);
        expect(entry, isNotNull, reason: '${region['id']} failed to parse');
        expect(region['schema'], anyOf('openmaptiles', 'protomaps'));
        expect(entry!.filename, endsWith('tiles'));
      }
    });
  });
}
