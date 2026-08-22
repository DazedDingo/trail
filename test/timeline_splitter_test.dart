import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/import/timeline_splitter.dart';

/// `test/fixtures/timeline/android_small.json`: a hand-written Android
/// `Timeline.json` in miniature — pretty-printed with CRLF line endings,
/// two `timelinePath` segments of three points, one `visit`, one
/// `activity`, one `timelineMemory` (whose label carries `{`, `[`, an
/// escaped `"`, an escaped `\` and one raw invalid UTF-8 byte), three
/// `rawSignals` (position acc 20, position acc 150, wifiScan), a
/// `userLocationProfile` with HOME + WORK, and two depth-1 scalars that
/// must be ignored. Degree signs are real `C2 B0` pairs, so 1-byte
/// chunking splits several of them across chunk boundaries.
///
/// `ios_small.json`: the bare-array dialect with `geo:` coordinates.
String fixturePath(String name) =>
    '${Directory.current.path}/test/fixtures/timeline/$name';

Uint8List fixtureBytes(String name) =>
    File(fixturePath(name)).readAsBytesSync();

/// Feeds [data] as fixed-size chunks; `size <= 0` means one whole chunk.
Stream<List<int>> chunked(Uint8List data, int size) async* {
  if (size <= 0) {
    yield data;
    return;
  }
  for (var i = 0; i < data.length; i += size) {
    yield Uint8List.sublistView(
      data,
      i,
      i + size > data.length ? data.length : i + size,
    );
  }
}

Future<List<TimelineElement>> split(Uint8List data, {int chunk = 0}) =>
    splitTimelineJson(chunked(data, chunk)).toList();

Future<List<TimelineElement>> splitString(String json, {int chunk = 0}) =>
    split(Uint8List.fromList(utf8.encode(json)), chunk: chunk);

List<String> sectionsOf(List<TimelineElement> e) =>
    e.map((x) => x.section).toList();

List<String> textOf(List<TimelineElement> e) =>
    e.map((x) => utf8.decode(x.bytes, allowMalformed: true)).toList();

void main() {
  group('splitTimelineJson · Android fixture', () {
    late Uint8List bytes;

    setUpAll(() => bytes = fixtureBytes('android_small.json'));

    const expectedSections = <String>[
      'semanticSegments',
      'semanticSegments',
      'semanticSegments',
      'semanticSegments',
      'semanticSegments',
      'rawSignals',
      'rawSignals',
      'rawSignals',
      'userLocationProfile',
    ];

    test('yields one element per array entry, ignoring depth-1 scalars',
        () async {
      final elements = await split(bytes);
      expect(sectionsOf(elements), expectedSections);
    });

    test('is chunk-boundary agnostic (1, 7, 4096, whole file)', () async {
      final reference = await split(bytes);
      for (final size in <int>[1, 7, 4096]) {
        final got = await split(bytes, chunk: size);
        expect(sectionsOf(got), sectionsOf(reference),
            reason: 'sections differ at chunk size $size');
        expect(got.length, reference.length);
        for (var i = 0; i < got.length; i++) {
          expect(got[i].bytes, reference[i].bytes,
              reason: 'element $i differs at chunk size $size');
          expect(got[i].endOffset, reference[i].endOffset,
              reason: 'endOffset $i differs at chunk size $size');
        }
      }
    });

    test('splits a multi-byte degree sign across a chunk boundary',
        () async {
      final firstDeg = bytes.indexOf(0xC2);
      expect(firstDeg, greaterThan(0));
      expect(bytes[firstDeg + 1], 0xB0);
      // Cut exactly between the two bytes of the `°`.
      final straddled = await splitTimelineJson(Stream<List<int>>.fromIterable([
        Uint8List.sublistView(bytes, 0, firstDeg + 1),
        Uint8List.sublistView(bytes, firstDeg + 1),
      ])).toList();
      final reference = await split(bytes);
      expect(textOf(straddled), textOf(reference));
    });

    test('every element is an exact slice of the source at endOffset',
        () async {
      final elements = await split(bytes, chunk: 13);
      var previous = 0;
      for (final e in elements) {
        expect(e.endOffset, greaterThan(previous));
        expect(e.endOffset, lessThanOrEqualTo(bytes.length));
        expect(
          e.bytes,
          Uint8List.sublistView(bytes, e.endOffset - e.bytes.length,
              e.endOffset),
        );
        previous = e.endOffset;
      }
    });

    test('elements are self-contained JSON that decodes one at a time',
        () async {
      final elements = await split(bytes, chunk: 1);

      final path = decodeElement(elements[0]) as Map<String, dynamic>;
      expect((path['timelinePath'] as List).length, 3);
      expect((path['timelinePath'] as List).first,
          containsPair('point', '51.5074°, -0.1278°'));

      final visit = decodeElement(elements[2]) as Map<String, dynamic>;
      expect(visit['visit']['topCandidate']['placeId'], 'ChIJ_fixture-123');

      final activity = decodeElement(elements[3]) as Map<String, dynamic>;
      expect(activity['activity']['distanceMeters'], 2345.6);

      final raw = decodeElement(elements[5]) as Map<String, dynamic>;
      expect(raw['position']['accuracyMeters'], 20);
      expect(raw['position']['LatLng'], '51.5074°, -0.1278°');

      final wifi = decodeElement(elements[7]) as Map<String, dynamic>;
      expect(wifi.containsKey('wifiScan'), isTrue);

      final profile = decodeElement(elements[8]) as Map<String, dynamic>;
      expect((profile['frequentPlaces'] as List).length, 2);
      expect(profile['frequentPlaces'][0]['label'], 'HOME');
    });

    test('braces, brackets and quotes inside strings do not split', () async {
      final elements = await split(bytes, chunk: 1);
      final memory = decodeElement(elements[4]) as Map<String, dynamic>;
      final label = memory['timelineMemory']['label'] as String;
      expect(label, contains('{trip}'));
      expect(label, contains('[south]'));
      expect(label, contains('"quoted"'));
      expect(label, contains(r'\'));
      expect(label, endsWith('"'));
    });

    test('invalid UTF-8 inside a string survives as U+FFFD', () async {
      final elements = await split(bytes, chunk: 1);
      expect(elements[4].bytes, contains(0xFF));
      final memory = decodeElement(elements[4]) as Map<String, dynamic>;
      expect(memory['timelineMemory']['raw'], 'bad-�-byte');
    });

    test('splitTimelineFile matches the in-memory stream', () async {
      final fromFile = await splitTimelineFile(
        fixturePath('android_small.json'),
      ).toList();
      final reference = await split(bytes);
      expect(sectionsOf(fromFile), sectionsOf(reference));
      expect(textOf(fromFile), textOf(reference));
      expect(fromFile.map((e) => e.endOffset).toList(),
          reference.map((e) => e.endOffset).toList());
    });
  });

  group('splitTimelineJson · iOS bare-array dialect', () {
    test('yields every root entry under section root', () async {
      final bytes = fixtureBytes('ios_small.json');
      final elements = await split(bytes);
      expect(sectionsOf(elements), <String>['root', 'root', 'root']);
      final visit = decodeElement(elements[1]) as Map<String, dynamic>;
      expect(visit['visit']['topCandidate']['placeID'], 'ChIJ_ios_fixture');
    });

    test('is chunk-boundary agnostic', () async {
      final bytes = fixtureBytes('ios_small.json');
      final reference = await split(bytes);
      for (final size in <int>[1, 7, 4096]) {
        expect(textOf(await split(bytes, chunk: size)), textOf(reference));
      }
    });

    test('yields scalar root entries verbatim, trimming whitespace',
        () async {
      final elements = await splitString('[ 1 , "a{b}" , null , true ]');
      expect(sectionsOf(elements), <String>['root', 'root', 'root', 'root']);
      expect(textOf(elements), <String>['1', '"a{b}"', 'null', 'true']);
    });

    test('handles nested arrays as single elements', () async {
      final elements = await splitString('[[1,2],[3],{"a":[4]}]', chunk: 1);
      expect(textOf(elements), <String>['[1,2]', '[3]', '{"a":[4]}']);
    });
  });

  group('splitTimelineJson · edge cases', () {
    test('empty document yields nothing', () async {
      expect(await splitString(''), isEmpty);
      expect(await splitString('   \r\n  '), isEmpty);
    });

    test('empty arrays and an empty root object yield nothing', () async {
      expect(await splitString('{}'), isEmpty);
      expect(await splitString('[]'), isEmpty);
      expect(
        await splitString('{"semanticSegments":[],"rawSignals":[]}'),
        isEmpty,
      );
    });

    test('empty arrays do not stop later sections', () async {
      final elements = await splitString(
        '{"semanticSegments":[],"rawSignals":[{"a":1}],'
        '"userLocationProfile":{}}',
        chunk: 1,
      );
      expect(sectionsOf(elements), <String>['rawSignals',
        'userLocationProfile']);
      expect(textOf(elements), <String>['{"a":1}', '{}']);
    });

    test('depth-1 scalars are ignored, whatever they contain', () async {
      final elements = await splitString(
        '{"a":1,"b":"{[:,]}","c":null,"d":true,"e":[{"x":1}]}',
        chunk: 1,
      );
      expect(sectionsOf(elements), <String>['e']);
      expect(textOf(elements), <String>['{"x":1}']);
    });

    test('a depth-1 object is yielded whole, once', () async {
      final elements = await splitString(
        '{"userLocationProfile":{"frequentPlaces":[{"label":"HOME"}]},'
        '"rawSignals":[1]}',
        chunk: 3,
      );
      expect(sectionsOf(elements),
          <String>['userLocationProfile', 'rawSignals']);
      expect(textOf(elements).first,
          '{"frequentPlaces":[{"label":"HOME"}]}');
    });

    test('nested keys never become sections', () async {
      final elements = await splitString(
        '{"semanticSegments":[{"rawSignals":[1,2],"visit":{"a":"b"}}]}',
        chunk: 1,
      );
      expect(sectionsOf(elements), <String>['semanticSegments']);
      expect(textOf(elements).single,
          '{"rawSignals":[1,2],"visit":{"a":"b"}}');
    });

    test('escaped quotes and backslashes keep the depth honest', () async {
      final elements = await splitString(
        r'{"s":[{"t":"a\"}]","u":"b\\"},{"t":"\\\\"}]}',
        chunk: 1,
      );
      expect(elements.length, 2);
      expect(textOf(elements).first, r'{"t":"a\"}]","u":"b\\"}');
      final first = decodeElement(elements.first) as Map<String, dynamic>;
      expect(first['t'], 'a"}]');
      expect(first['u'], r'b\');
    });

    test('a truncated final element is dropped, not half-emitted', () async {
      final elements =
          await splitString('{"rawSignals":[{"a":1},{"b":', chunk: 1);
      expect(textOf(elements), <String>['{"a":1}']);
    });

    test('a UTF-8 BOM before the root is tolerated', () async {
      final data = Uint8List.fromList(
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('{"rawSignals":[{"a":1}]}')],
      );
      expect(textOf(await split(data, chunk: 1)), <String>['{"a":1}']);
    });

    test('pretty-printed CRLF input matches its minified twin', () async {
      const minified = '{"rawSignals":[{"a":1},{"b":2}]}';
      const pretty = '{\r\n  "rawSignals" : [\r\n    { "a" : 1 },\r\n'
          '    { "b" : 2 }\r\n  ]\r\n}\r\n';
      expect(textOf(await splitString(pretty, chunk: 1)),
          <String>['{ "a" : 1 }', '{ "b" : 2 }']);
      expect(
        (await splitString(pretty)).length,
        (await splitString(minified)).length,
      );
    });
  });

  group('splitTimelineJson · bounded memory', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('timeline_split'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('10 000 elements over ~2 MB stream without accumulating',
        () async {
      final file = File('${tmp.path}/big.json');
      final sink = file.openWrite();
      sink.write('{"semanticSegments":[');
      for (var i = 0; i < 10000; i++) {
        if (i > 0) sink.write(',\r\n');
        final minute = (i % 60).toString().padLeft(2, '0');
        sink.write('{"startTime":"2026-03-01T10:$minute:00.000+01:00",'
            '"endTime":"2026-03-01T10:$minute:30.000+01:00",'
            '"timelinePath":[{"point":"51.5074°, -0.1278°",'
            '"time":"2026-03-01T10:$minute:00.000+01:00"}],'
            '"filler":"element-$i-padding-padding-padding-padding-padding"}');
      }
      sink.write(']}');
      await sink.close();
      expect(file.lengthSync(), greaterThan(2 * 1024 * 1024));

      var count = 0;
      var maxElementBytes = 0;
      var lastEnd = 0;
      await for (final e in splitTimelineFile(file.path)) {
        count++;
        if (e.bytes.length > maxElementBytes) maxElementBytes = e.bytes.length;
        expect(e.section, 'semanticSegments');
        expect(e.endOffset, greaterThan(lastEnd));
        lastEnd = e.endOffset;
      }

      expect(count, 10000);
      // The scanner holds one element at a time: if it accumulated, the
      // last element would be the size of the file.
      expect(maxElementBytes, lessThan(4096));
      expect(lastEnd, lessThanOrEqualTo(file.lengthSync()));
    });
  });
}
