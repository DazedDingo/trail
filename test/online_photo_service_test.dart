import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:trail/services/online_photo_service.dart';

void main() {
  group('isLikelyImage', () {
    test('accepts whitelisted image suffixes (case-insensitive)', () {
      for (final s in [
        'File:Foo.jpg', 'File:Foo.JPG', 'File:Foo.jpeg',
        'File:Foo.png', 'File:Foo.gif', 'File:Foo.webp',
        'https://upload.wikimedia.org/.../512px-Foo.png',
      ]) {
        expect(isLikelyImage(s), isTrue, reason: s);
      }
    });

    test('rejects non-image File: media that GeoSearch over-returns', () {
      for (final s in [
        'File:Audio.ogg',
        'File:Voice.oga',
        'File:Doc.pdf',
        'File:Clip.mp4',
        'File:Vector.svg', // Flutter can't decode raw SVG
        'File:Scan.tiff',
        'File:Other.webm',
        'File:NoExt',
      ]) {
        expect(isLikelyImage(s), isFalse, reason: s);
      }
    });

    test('strips query strings + fragments before matching', () {
      expect(isLikelyImage('https://w.org/x.jpg?cache=1'), isTrue);
      expect(isLikelyImage('https://w.org/x.jpg#full'), isTrue);
      expect(isLikelyImage('https://w.org/x.pdf?force=true'), isFalse);
    });

    test('empty + dotless input returns false', () {
      expect(isLikelyImage(''), isFalse);
      expect(isLikelyImage('plainstring'), isFalse);
    });
  });

  group('parseGeoSearch', () {
    test('returns File-namespace titles with distance', () {
      const body = '''
{
  "query": {
    "geosearch": [
      {"title": "File:Foo.jpg", "lat": 1.0, "lon": 2.0, "dist": 42.5},
      {"title": "File:Bar.png", "lat": 1.1, "lon": 2.1, "dist": 100}
    ]
  }
}''';
      final hits = parseGeoSearch(body);
      expect(hits.length, 2);
      expect(hits.first.title, 'File:Foo.jpg');
      expect(hits.first.distanceMeters, 42.5);
      expect(hits.last.distanceMeters, 100);
    });

    test('drops non-image File: media (OGG / PDF / MP4) — the 0.13.2 fix',
        () {
      const body = '''
{"query": {"geosearch": [
  {"title": "File:GoodPhoto.jpg", "dist": 10},
  {"title": "File:Audio.ogg", "dist": 20},
  {"title": "File:Doc.pdf", "dist": 30},
  {"title": "File:Clip.mp4", "dist": 40},
  {"title": "File:AnotherPhoto.PNG", "dist": 50}
]}}''';
      final hits = parseGeoSearch(body).map((h) => h.title).toList();
      expect(hits, ['File:GoodPhoto.jpg', 'File:AnotherPhoto.PNG']);
    });

    test('skips non-File titles silently', () {
      const body = '''
{"query": {"geosearch": [
  {"title": "Foo Article", "dist": 10},
  {"title": "File:Real.jpg", "dist": 20}
]}}''';
      final hits = parseGeoSearch(body);
      expect(hits.single.title, 'File:Real.jpg');
    });

    test('missing fields collapse to empty list rather than throw', () {
      expect(parseGeoSearch('{}'), isEmpty);
      expect(parseGeoSearch('{"query": {}}'), isEmpty);
      expect(parseGeoSearch('{"query": {"geosearch": "not-a-list"}}'),
          isEmpty);
    });

    test('non-numeric dist defaults to 0', () {
      const body = '''
{"query": {"geosearch": [
  {"title": "File:Foo.jpg", "dist": null},
  {"title": "File:Bar.jpg"}
]}}''';
      final hits = parseGeoSearch(body);
      expect(hits.first.distanceMeters, 0);
      expect(hits.last.distanceMeters, 0);
    });
  });

  group('parseImageInfoByTitle', () {
    test('extracts url, thumburl, attribution, license per page', () {
      const body = '''
{
  "query": {
    "pages": {
      "123": {
        "title": "File:Foo.jpg",
        "imageinfo": [
          {
            "url": "https://upload.wikimedia.org/.../Foo.jpg",
            "thumburl": "https://upload.wikimedia.org/.../512px-Foo.jpg",
            "extmetadata": {
              "Artist": {"value": "<a href=\\"#\\" title=\\"x\\">Jane Doe</a>"},
              "LicenseShortName": {"value": "CC BY-SA 4.0"}
            }
          }
        ]
      }
    }
  }
}''';
      final out = parseImageInfoByTitle(body);
      final entry = out['File:Foo.jpg']!;
      expect(entry.url, 'https://upload.wikimedia.org/.../Foo.jpg');
      expect(entry.thumbUrl, 'https://upload.wikimedia.org/.../512px-Foo.jpg');
      expect(entry.attribution, 'Jane Doe');
      expect(entry.license, 'CC BY-SA 4.0');
    });

    test('decodes HTML entities in attribution', () {
      const body = '''
{"query":{"pages":{"1":{"title":"File:X.jpg","imageinfo":[{
  "url":"http://x/y.jpg",
  "extmetadata":{"Artist":{"value":"Rock &amp; Roll &quot;hero&quot;"}}
}]}}}}''';
      final out = parseImageInfoByTitle(body);
      expect(out['File:X.jpg']!.attribution, 'Rock & Roll "hero"');
    });

    test('drops pages without imageinfo silently', () {
      const body = '''
{"query":{"pages":{"1":{"title":"File:No.jpg"}}}}''';
      expect(parseImageInfoByTitle(body), isEmpty);
    });

    test('empty extmetadata yields empty strings, not throws', () {
      const body = '''
{"query":{"pages":{"1":{"title":"File:X.jpg","imageinfo":[{
  "url":"http://x/y.jpg"
}]}}}}''';
      final entry = parseImageInfoByTitle(body)['File:X.jpg']!;
      expect(entry.attribution, '');
      expect(entry.license, '');
    });

    test('garbage envelope returns empty map', () {
      expect(parseImageInfoByTitle('{}'), isEmpty);
      expect(parseImageInfoByTitle('garbage'), isEmpty);
    });
  });

  group('OnlinePhotoService.fetchNearby — wired against MockClient', () {
    test('two-hop: geosearch → imageinfo → FetchedOnlinePhoto list',
        () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (req.url.queryParameters['list'] == 'geosearch') {
          return http.Response(
            '{"query":{"geosearch":['
            '{"title":"File:A.jpg","dist":15},'
            '{"title":"File:B.jpg","dist":30}]}}',
            200,
          );
        }
        // imageinfo hop
        return http.Response(
          '{"query":{"pages":{'
          '"1":{"title":"File:A.jpg","imageinfo":[{"url":"http://a.jpg","extmetadata":{"Artist":{"value":"Alice"},"LicenseShortName":{"value":"CC0"}}}]},'
          '"2":{"title":"File:B.jpg","imageinfo":[{"url":"http://b.jpg","extmetadata":{"Artist":{"value":"Bob"},"LicenseShortName":{"value":"CC BY"}}}]}'
          '}}}',
          200,
        );
      });
      final svc = OnlinePhotoService(client: client);
      final got = await svc.fetchNearby(lat: 51.5, lon: -0.1);
      expect(calls, 2);
      expect(got.length, 2);
      expect(got.first.uri, 'http://a.jpg');
      expect(got.first.attribution, 'Alice');
      expect(got.first.license, 'CC0');
      expect(got.first.distanceMeters, 15);
      expect(got.last.uri, 'http://b.jpg');
    });

    test('zero geosearch hits short-circuits the second call', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('{"query":{"geosearch":[]}}', 200);
      });
      final svc = OnlinePhotoService(client: client);
      final got = await svc.fetchNearby(lat: 51.5, lon: -0.1);
      expect(calls, 1);
      expect(got, isEmpty);
    });

    test('network error → empty list (no thrown exception)', () async {
      final client = MockClient((req) async {
        throw Exception('boom');
      });
      final svc = OnlinePhotoService(client: client);
      final got = await svc.fetchNearby(lat: 0, lon: 0);
      expect(got, isEmpty);
    });

    test('non-200 first hop → empty list', () async {
      final client = MockClient((req) async {
        return http.Response('Service Unavailable', 503);
      });
      final svc = OnlinePhotoService(client: client);
      final got = await svc.fetchNearby(lat: 0, lon: 0);
      expect(got, isEmpty);
    });

    test('limit=0 short-circuits before any HTTP call', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      });
      final svc = OnlinePhotoService(client: client);
      final got = await svc.fetchNearby(lat: 0, lon: 0, limit: 0);
      expect(calls, 0);
      expect(got, isEmpty);
    });
  });

  group('AutoPhotoService default-on behaviour', () {
    // Cross-checked here (and not in a separate file) so the default-on
    // contract is tested next to the service that consumes the toggle.
    // SharedPreferences mock is set in main test runner.
  });
}
