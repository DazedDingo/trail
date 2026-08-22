import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:trail/services/coverage/coverage_planner.dart';
import 'package:trail/services/coverage/tile_server_client.dart';
import 'package:trail/services/mbtiles_service.dart';
import 'package:trail/services/tile_downloader.dart';

/// Points `getApplicationDocumentsDirectory()` at a temp dir so
/// [TileDownloader] writes its archive somewhere disposable — same fake
/// `mbtiles_service_test.dart` uses.
class _TempDocsPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempDocsPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  const box = CoverageBox(west: -2.5, south: 51.0, east: -2.0, north: 51.5);

  group('URL building', () {
    test('health and extract URLs hang off the base URL', () {
      final client = TileServerClient(
        baseUrl: 'https://host:8443/',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(client.healthUri().toString(), 'https://host:8443/v1/health');
      final uri = client.extractUri(box);
      expect(uri.path, '/v1/extract');
      expect(uri.queryParameters['bbox'], '-2.5,51,-2,51.5');
      expect(uri.queryParameters['minzoom'], '7');
      expect(uri.queryParameters['maxzoom'], '14');
      expect(uri.queryParameters.containsKey('dry_run'), isFalse);
      client.close();
    });

    test('dry_run=1 is only present on the dry-run URL', () {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        client.extractUri(box, dryRun: true).queryParameters['dry_run'],
        '1',
      );
      client.close();
    });

    test('a blank token means no Authorization header at all', () {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: null,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(client.authHeaders, isEmpty);
      client.close();
    });
  });

  group('health', () {
    test('parses ok + planet date and sends no auth header', () async {
      Map<String, String>? seen;
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 'secret',
        client: MockClient((req) async {
          seen = req.headers;
          expect(req.url.path, '/v1/health');
          return http.Response(
            '{"ok":true,"planet":"protomaps","planetDate":"20260822"}',
            200,
          );
        }),
      );
      final health = await client.health();
      expect(health.ok, isTrue);
      expect(health.planet, 'protomaps');
      expect(health.planetDate, '20260822');
      expect(seen!.containsKey('Authorization'), isFalse);
      client.close();
    });

    test('a 503 becomes a TileServerException carrying the server message',
        () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient(
          (_) async => http.Response('{"error":"planet rebuilding"}', 503),
        ),
      );
      await expectLater(
        client.health(),
        throwsA(isA<TileServerException>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.message, 'message', 'planet rebuilding')),
      );
      client.close();
    });

    test('an unreachable host surfaces as status 0', () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient((_) async => throw const SocketException('nope')),
      );
      await expectLater(
        client.health(),
        throwsA(isA<TileServerException>()
            .having((e) => e.status, 'status', 0)
            .having((e) => e.isUnreachable, 'isUnreachable', isTrue)),
      );
      client.close();
    });
  });

  group('dryRun', () {
    test('parses tiles, bytes and planet date and sends the bearer token',
        () async {
      late Uri seenUrl;
      Map<String, String>? seenHeaders;
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 'secret',
        client: MockClient((req) async {
          seenUrl = req.url;
          seenHeaders = req.headers;
          return http.Response(
            '{"tiles":75,"bytes":1782579,"planetDate":"20260822"}',
            200,
          );
        }),
      );
      final result = await client.dryRun(box);
      expect(result.tiles, 75);
      expect(result.bytes, 1782579);
      expect(result.planetDate, '20260822');
      expect(seenUrl.queryParameters['dry_run'], '1');
      expect(seenHeaders!['Authorization'], 'Bearer secret');
      client.close();
    });

    test('401 becomes TileServerException(401) flagged as an auth failure',
        () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 'wrong',
        client: MockClient(
          (_) async => http.Response('{"error":"bad token"}', 401),
        ),
      );
      await expectLater(
        client.dryRun(box),
        throwsA(isA<TileServerException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.isAuth, 'isAuth', isTrue)),
      );
      client.close();
    });

    test('413 is flagged as too-large so the planner can drop one box',
        () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient(
          (_) async => http.Response('{"error":"bbox too big"}', 413),
        ),
      );
      await expectLater(
        client.dryRun(box),
        throwsA(isA<TileServerException>()
            .having((e) => e.isTooLarge, 'isTooLarge', isTrue)),
      );
      client.close();
    });

    test('a non-JSON 200 body is an error, not a silent zero', () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient((_) async => http.Response('<html>oops</html>', 200)),
      );
      await expectLater(
        client.dryRun(box),
        throwsA(isA<TileServerException>()
            .having((e) => e.message, 'message', 'Malformed JSON response')),
      );
      client.close();
    });

    test('a non-JSON error body falls back to the status line', () async {
      final client = TileServerClient(
        baseUrl: 'https://host:8443',
        token: 't',
        client: MockClient((_) async => http.Response('<html>502</html>', 502)),
      );
      await expectLater(
        client.dryRun(box),
        throwsA(isA<TileServerException>()
            .having((e) => e.message, 'message', 'HTTP 502')),
      );
      client.close();
    });
  });

  group('downloadExtract', () {
    late Directory tempRoot;
    late HttpServer server;
    late List<HttpRequest> requests;
    String? dispositionHeader;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // flutter_test installs an HttpOverrides that 400s every request;
      // TileDownloader streams over a real dart:io HttpClient, so this
      // group needs the real one back.
      HttpOverrides.global = null;
      tempRoot = await Directory.systemTemp.createTemp('coverage_dl_test_');
      PathProviderPlatform.instance = _TempDocsPathProvider(tempRoot.path);
      requests = [];
      dispositionHeader =
          'attachment; filename="coverage-lat+51.25_lon-002.25-z7-14-20260822.pmtiles"';
      // A real loopback server: TileDownloader streams through dart:io's
      // HttpClient, which MockClient can't intercept, and this also
      // exercises the header round-trip end to end.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requests.add(req);
        if (dispositionHeader != null) {
          req.response.headers.set('content-disposition', dispositionHeader!);
        }
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.add(List<int>.filled(2048, 7));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    TileServerClient makeClient() => TileServerClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          token: 'secret',
          client: MockClient((_) async => http.Response('{}', 200)),
        );

    test('sends the bearer token and writes into <docs>/tiles', () async {
      final client = makeClient();
      var lastReceived = 0;
      final region = await client.downloadExtract(
        box,
        planetDate: '20260822',
        onProgress: (received, total) => lastReceived = received,
      );
      expect(requests.single.headers.value('authorization'), 'Bearer secret');
      expect(requests.single.uri.queryParameters['bbox'], '-2.5,51,-2,51.5');
      expect(requests.single.uri.queryParameters.containsKey('dry_run'),
          isFalse);
      expect(lastReceived, 2048);
      expect(region.bytes, 2048);
      expect(
        region.path,
        endsWith('coverage-lat+51.25_lon-002.25-z7-14-20260822.pmtiles'),
      );
      expect(File(region.path).existsSync(), isTrue);
      // The name is what makes the loopback serve it first.
      expect(inferRoleFromFileName(region.name), TileRole.coverage);
      client.close();
    });

    test('with no planet date the Content-Disposition name is used',
        () async {
      final client = makeClient();
      final region = await client.downloadExtract(box);
      expect(
        region.path,
        endsWith('coverage-lat+51.25_lon-002.25-z7-14-20260822.pmtiles'),
      );
      client.close();
    });

    test('a cancel token aborts and leaves no file behind', () async {
      final client = makeClient();
      final cancel = TileDownloadCancelToken()..isCancelled = true;
      await expectLater(
        client.downloadExtract(box, planetDate: '20260822',
            cancelToken: cancel),
        throwsA(isA<TileDownloadCancelled>()),
      );
      final tiles = Directory('${tempRoot.path}/tiles');
      expect(
        tiles.existsSync() ? tiles.listSync() : const <FileSystemEntity>[],
        isEmpty,
      );
      client.close();
    });
  });

  group('filenameFromContentDisposition', () {
    test('quoted filename', () {
      expect(
        filenameFromContentDisposition(
            'attachment; filename="coverage-x-z7-14-20260822.pmtiles"'),
        'coverage-x-z7-14-20260822.pmtiles',
      );
    });

    test('unquoted filename', () {
      expect(
        filenameFromContentDisposition('attachment; filename=region.mbtiles'),
        'region.mbtiles',
      );
    });

    test('RFC 5987 filename* wins and is percent-decoded', () {
      expect(
        filenameFromContentDisposition(
          'attachment; filename="fallback.pmtiles"; '
          "filename*=UTF-8''coverage%2Dbath.pmtiles",
        ),
        'coverage-bath.pmtiles',
      );
    });

    test('path components are stripped', () {
      expect(
        filenameFromContentDisposition(
            'attachment; filename="../../etc/evil.pmtiles"'),
        'evil.pmtiles',
      );
      expect(
        filenameFromContentDisposition(
            r'attachment; filename="C:\temp\evil.pmtiles"'),
        'evil.pmtiles',
      );
    });

    test('absent, empty or nameless headers return null', () {
      expect(filenameFromContentDisposition(null), isNull);
      expect(filenameFromContentDisposition(''), isNull);
      expect(filenameFromContentDisposition('attachment'), isNull);
      expect(filenameFromContentDisposition('attachment; filename=""'), isNull);
    });
  });
}
