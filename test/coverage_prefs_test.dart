import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/coverage/coverage_planner.dart';
import 'package:trail/services/coverage/coverage_prefs.dart';
import 'package:trail_secure_store/trail_secure_store.dart';

/// Cross-isolate prefs for the map-detail feature. Same contract as
/// `WorkerRunLog` (CLAUDE.md gotcha 11): no caching, and malformed JSON
/// reads as empty rather than throwing — the WorkManager isolate writes
/// the pending queue while the UI isolate writes the extents, and
/// neither may be able to brick the other.
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('extents', () {
    test('round-trips path, zooms and bounds', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(
          path: '/t/coverage-bath.pmtiles',
          minZoom: 7,
          maxZoom: 14,
          bounds: CoverageBox(west: -2.5, south: 51.3, east: -2.2, north: 51.5),
        ),
        ArchiveExtent(path: '/t/mystery.pmtiles', minZoom: 0, maxZoom: 6),
      ]);
      final read = await CoveragePrefs.readExtents();
      expect(read.length, 2);
      expect(read.first.path, '/t/coverage-bath.pmtiles');
      expect(read.first.minZoom, 7);
      expect(read.first.maxZoom, 14);
      expect(read.first.bounds!.west, -2.5);
      expect(read.first.bounds!.north, 51.5);
      expect(read.last.bounds, isNull);
    });

    test('never written reads as empty', () async {
      expect(await CoveragePrefs.readExtents(), isEmpty);
    });

    test('malformed JSON reads as empty, not a throw', () async {
      SharedPreferences.setMockInitialValues(
        {CoveragePrefs.extentsKey: 'not json at all'},
      );
      expect(await CoveragePrefs.readExtents(), isEmpty);
    });

    test('a malformed entry is skipped, the rest survive', () {
      const raw = '[{"path":123},'
          '{"path":"/t/a.pmtiles","minZoom":0,"maxZoom":14,"bounds":[1,2,3]},'
          '{"path":"/t/b.pmtiles","minZoom":0,"maxZoom":14,"bounds":[1,2,3,4]}]';
      final read = CoveragePrefs.decodeExtents(raw);
      expect(read.map((e) => e.path), ['/t/a.pmtiles', '/t/b.pmtiles']);
      // A 3-element bounds list is dropped, not guessed at.
      expect(read.first.bounds, isNull);
      expect(read.last.bounds, isNotNull);
    });

    test('writing an empty list clears the previous extents', () async {
      await CoveragePrefs.writeExtents(const [
        ArchiveExtent(path: '/t/a.pmtiles', minZoom: 0, maxZoom: 14),
      ]);
      await CoveragePrefs.writeExtents(const []);
      expect(await CoveragePrefs.readExtents(), isEmpty);
    });
  });

  group('pending queue', () {
    test('addPending stores lat/lon/ts', () async {
      await CoveragePrefs.addPending(
        51.38,
        -2.36,
        now: DateTime.utc(2026, 8, 22, 12),
      );
      final pending = await CoveragePrefs.readPending();
      expect(pending.length, 1);
      expect(pending.single.lat, 51.38);
      expect(pending.single.lon, -2.36);
      expect(pending.single.tsMs, DateTime.utc(2026, 8, 22, 12).millisecondsSinceEpoch);
    });

    test('a point within 5 km of one already queued is dropped', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      // ~1.1 km north.
      await CoveragePrefs.addPending(51.39, -2.36);
      expect((await CoveragePrefs.readPending()).length, 1);
    });

    test('a point beyond 5 km is queued', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      // ~11 km north.
      await CoveragePrefs.addPending(51.48, -2.36);
      expect((await CoveragePrefs.readPending()).length, 2);
    });

    test('queue caps at 200, evicting the oldest', () async {
      // 0.2 deg apart in longitude keeps every point > 5 km from the
      // last, so nothing is deduped away.
      for (var i = 0; i < 210; i++) {
        await CoveragePrefs.addPending(0, -100 + i * 0.2);
      }
      final pending = await CoveragePrefs.readPending();
      expect(pending.length, CoveragePrefs.pendingMax);
      // The first ten longitudes were evicted.
      expect(pending.first.lon, closeTo(-100 + 10 * 0.2, 1e-9));
      expect(pending.last.lon, closeTo(-100 + 209 * 0.2, 1e-9));
    });

    test('NaN and out-of-range coordinates are refused', () async {
      await CoveragePrefs.addPending(double.nan, 0);
      await CoveragePrefs.addPending(0, 181);
      await CoveragePrefs.addPending(-91, 0);
      expect(await CoveragePrefs.readPending(), isEmpty);
    });

    test('takePending returns and clears', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      final taken = await CoveragePrefs.takePending();
      expect(taken.length, 1);
      expect(await CoveragePrefs.readPending(), isEmpty);
      expect(await CoveragePrefs.pendingCount(), 0);
    });

    test('addPendingAll re-queues declined points with their timestamps',
        () async {
      final taken = [
        PendingPoint(lat: 51.38, lon: -2.36, tsMs: 111),
        PendingPoint(lat: 38.72, lon: -9.14, tsMs: 222),
      ];
      await CoveragePrefs.addPendingAll(taken);
      final pending = await CoveragePrefs.readPending();
      expect(pending.length, 2);
      expect(pending.map((p) => p.tsMs), [111, 222]);
    });

    test('malformed pending JSON reads as empty', () async {
      SharedPreferences.setMockInitialValues(
        {CoveragePrefs.pendingKey: '{"not":"a list"}'},
      );
      expect(await CoveragePrefs.readPending(), isEmpty);
    });

    test('clearPending empties the queue', () async {
      await CoveragePrefs.addPending(51.38, -2.36);
      await CoveragePrefs.clearPending();
      expect(await CoveragePrefs.readPending(), isEmpty);
    });
  });

  group('settings', () {
    test('defaults are enabled + Wi-Fi only', () async {
      final s = await CoveragePrefs.readSettings();
      expect(s.enabled, isTrue);
      expect(s.wifiOnly, isTrue);
    });

    test('round-trips both flags', () async {
      await CoveragePrefs.writeSettings(
        const CoverageSettings(enabled: false, wifiOnly: false),
      );
      final s = await CoveragePrefs.readSettings();
      expect(s.enabled, isFalse);
      expect(s.wifiOnly, isFalse);
    });

    test('malformed JSON falls back to the defaults', () {
      final s = CoveragePrefs.decodeSettings('¯\\_(ツ)_/¯');
      expect(s.enabled, isTrue);
      expect(s.wifiOnly, isTrue);
    });

    test('a partial object keeps the default for the missing flag', () {
      final s = CoveragePrefs.decodeSettings('{"enabled":false}');
      expect(s.enabled, isFalse);
      expect(s.wifiOnly, isTrue);
    });

    test('copyWith changes one flag at a time', () {
      const s = CoverageSettings();
      expect(s.copyWith(wifiOnly: false).enabled, isTrue);
      expect(s.copyWith(wifiOnly: false).wifiOnly, isFalse);
    });
  });

  group('server URL', () {
    test('round-trips and strips trailing slashes', () async {
      await CoveragePrefs.writeServerUrl('https://host:8443///');
      expect(await CoveragePrefs.readServerUrl(), 'https://host:8443');
    });

    test('an empty URL clears the setting', () async {
      await CoveragePrefs.writeServerUrl('https://host:8443');
      await CoveragePrefs.writeServerUrl('   ');
      expect(await CoveragePrefs.readServerUrl(), isNull);
    });

    test('unset reads as null', () async {
      expect(await CoveragePrefs.readServerUrl(), isNull);
    });
  });

  group('last fetch + notice', () {
    test('last fetch round-trips as UTC', () async {
      final when = DateTime.utc(2026, 8, 22, 9, 30);
      await CoveragePrefs.setLastFetch(when);
      expect(await CoveragePrefs.readLastFetch(), when);
    });

    test('unset last fetch is null', () async {
      expect(await CoveragePrefs.readLastFetch(), isNull);
    });

    test('notice round-trips and clears on null', () async {
      await CoveragePrefs.writeNotice('3 new places need 40 MB');
      expect(await CoveragePrefs.readNotice(), '3 new places need 40 MB');
      await CoveragePrefs.writeNotice(null);
      expect(await CoveragePrefs.readNotice(), isNull);
    });
  });

  group('token', () {
    test('maskToken shows only the ends', () {
      expect(CoveragePrefs.maskToken('abcdefghijkl'), 'abcd…ijkl');
      expect(CoveragePrefs.maskToken('short'), '****');
    });

    test('readToken returns null rather than throwing with no plugin',
        () async {
      // flutter_secure_storage has no platform side in a unit test; the
      // read must degrade to "not configured", not blow up the settings
      // screen or the fetch path.
      expect(await CoveragePrefs.readToken(), isNull);
    });
  });

  // Regression coverage for 0.17.10: `_editToken`/`_clearToken` in
  // `settings_screen.dart` used to await `writeToken`/`clearToken`
  // directly with no try/catch, so a thrown secure-store write (e.g. a
  // Keystore alias that fails to GENERATE) died as an unhandled Future
  // and the tile's subtitle silently stayed "Not set". `trySaveToken` /
  // `tryClearToken` are the pure functions the screen now calls instead.
  group('trySaveToken / tryClearToken (0.17.10)', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TrailSecureStore.channel, null);
    });

    test('trySaveToken returns null on a successful write', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              TrailSecureStore.channel, (call) async => null);
      expect(await CoveragePrefs.trySaveToken('abc123'), isNull);
    });

    test(
        'trySaveToken reports a Keystore write failure instead of throwing',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TrailSecureStore.channel, (call) async {
        throw PlatformException(
          code: 'KeyStoreException',
          message: 'UNKNOWN_ERROR (-1000)',
        );
      });
      final error = await CoveragePrefs.trySaveToken('abc123');
      expect(error, isNotNull);
      expect(error, contains('KeyStoreException'));
    });

    test('tryClearToken returns null on a successful delete', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              TrailSecureStore.channel, (call) async => null);
      expect(await CoveragePrefs.tryClearToken(), isNull);
    });

    test('tryClearToken reports a failure instead of throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TrailSecureStore.channel, (call) async {
        throw PlatformException(
          code: 'IllegalStateException',
          message: 'could not persist',
        );
      });
      final error = await CoveragePrefs.tryClearToken();
      expect(error, isNotNull);
      expect(error, contains('IllegalStateException'));
    });
  });

  group('trySaveServerUrl (0.17.10)', () {
    test('returns null and persists on success', () async {
      expect(
        await CoveragePrefs.trySaveServerUrl('https://host:8443'),
        isNull,
      );
      expect(await CoveragePrefs.readServerUrl(), 'https://host:8443');
    });
  });
}
