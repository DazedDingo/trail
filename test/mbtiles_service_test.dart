import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trail/services/mbtiles_service.dart';

/// Fake path_provider that points `getApplicationDocumentsDirectory()`
/// at a temp dir so [TilesService] can create its `tiles/` subdir
/// without touching the real app docs directory.
class _TempDocsPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String root;
  _TempDocsPathProvider(this.root);

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempRoot = await Directory.systemTemp.createTemp('tiles_svc_test_');
    PathProviderPlatform.instance = _TempDocsPathProvider(tempRoot.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// Writes a fake `.pmtiles` file (just arbitrary bytes) and returns
  /// its path. Size coming back from `listInstalled` uses the file's
  /// real byte count, which is what [makeFake] writes.
  Future<String> makeFake(String name, {int size = 64}) async {
    final f = File('${tempRoot.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(List<int>.filled(size, 0));
    return f.path;
  }

  group('TilesService.listInstalled', () {
    test('returns empty list on a fresh install (no installed regions)',
        () async {
      final regions = await TilesService.listInstalled();
      expect(regions, isEmpty);
    });

    test('skips non-pmtiles files in the regions directory', () async {
      final source = await makeFake('uk.pmtiles', size: 128);
      await TilesService.install(source);
      // Drop a stray non-pmtiles file into the regions dir — listInstalled
      // should ignore it rather than reporting it as a broken region.
      final stray = File(
        '${tempRoot.path}${Platform.pathSeparator}tiles'
        '${Platform.pathSeparator}readme.txt',
      );
      await stray.writeAsString('hello');

      final regions = await TilesService.listInstalled();
      expect(regions, hasLength(1));
      expect(regions.first.name, 'uk');
    });

    test('sorts regions alphabetically (case-insensitive)', () async {
      await TilesService.install(await makeFake('Zulu.pmtiles'));
      await TilesService.install(await makeFake('alpha.pmtiles'));
      await TilesService.install(await makeFake('Mike.pmtiles'));

      final regions = await TilesService.listInstalled();
      expect(regions.map((r) => r.name).toList(), ['alpha', 'Mike', 'Zulu']);
    });
  });

  group('TilesService.install', () {
    test('copies the source file into the app dir and reports size',
        () async {
      final source = await makeFake('uk.pmtiles', size: 256);
      final region = await TilesService.install(source);

      expect(region.name, 'uk');
      expect(region.bytes, 256);
      expect(await File(region.path).exists(), isTrue);
      // The install path must NOT be the original — install() copies so
      // the source can be deleted/moved without breaking the viewer.
      expect(region.path, isNot(source));
    });

    test('throws when the source file does not exist', () async {
      expect(
        () => TilesService.install(
          '${tempRoot.path}${Platform.pathSeparator}does_not_exist.pmtiles',
        ),
        throwsStateError,
      );
    });

    test('overwrites an existing region with the same name', () async {
      await TilesService.install(await makeFake('uk.pmtiles', size: 100));
      final second = await TilesService.install(
        await makeFake('uk.pmtiles', size: 300),
      );
      expect(second.bytes, 300);

      final regions = await TilesService.listInstalled();
      expect(regions, hasLength(1));
      expect(regions.first.bytes, 300);
    });
  });

  group('TilesService active region', () {
    test('getActive returns null when nothing is set', () async {
      expect(await TilesService.getActive(), isNull);
    });

    test('setActive / getActive round-trip', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setActive(region);

      final active = await TilesService.getActive();
      expect(active, isNotNull);
      expect(active!.path, region.path);
      expect(active.name, 'uk');
    });

    test('clearActive reverts getActive to null', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setActive(region);
      await TilesService.clearActive();
      expect(await TilesService.getActive(), isNull);
    });

    test(
        'getActive auto-clears stale pref when the file is gone '
        '(user deleted from outside the app)', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setActive(region);
      // Simulate out-of-band file deletion.
      await File(region.path).delete();

      expect(await TilesService.getActive(), isNull);
      // And the pref should have been cleared, so a second call returns
      // null just as quickly without hitting the filesystem check again.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('trail_active_tiles_v1'), isNull);
    });
  });

  group('TilesService.delete', () {
    test('removes the file from disk', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.delete(region);
      expect(await File(region.path).exists(), isFalse);
    });

    test('clears the active pref when deleting the active region',
        () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setActive(region);
      await TilesService.delete(region);
      expect(await TilesService.getActive(), isNull);
    });

    test('leaves the active pref alone when deleting a non-active region',
        () async {
      final r1 = await TilesService.install(await makeFake('uk.pmtiles'));
      final r2 = await TilesService.install(await makeFake('de.pmtiles'));
      await TilesService.setActive(r1);
      await TilesService.delete(r2);

      final active = await TilesService.getActive();
      expect(active, isNotNull);
      expect(active!.path, r1.path);
    });

    test('is a no-op when the file has already vanished', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await File(region.path).delete();
      // Should not throw.
      await TilesService.delete(region);
    });

    test('drops the stored role entry', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setRole(region, TileRole.coverage);
      await TilesService.delete(region);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('trail_tiles_roles_v1'), isNot(contains('uk')));
      // Re-installing the same filename therefore infers afresh rather
      // than inheriting the role of a file the user threw away.
      final again = await TilesService.install(await makeFake('uk.pmtiles'));
      expect(again.role, TileRole.region);
    });
  });

  group('inferRoleFromFileName', () {
    test('names containing "overview" are the world overview', () {
      expect(inferRoleFromFileName('world-overview.pmtiles'),
          TileRole.overview);
      expect(inferRoleFromFileName('WORLD_OVERVIEW.MBTILES'),
          TileRole.overview);
    });

    test('names containing "coverage" are coverage packs', () {
      expect(inferRoleFromFileName('coverage-bath.pmtiles'),
          TileRole.coverage);
      expect(inferRoleFromFileName('Bath.Coverage.mbtiles'),
          TileRole.coverage);
    });

    test('overview wins over coverage when both appear', () {
      expect(inferRoleFromFileName('coverage-overview.pmtiles'),
          TileRole.overview);
    });

    test('anything else is a plain region', () {
      expect(inferRoleFromFileName('gb-z13.pmtiles'), TileRole.region);
      expect(inferRoleFromFileName(''), TileRole.region);
    });
  });

  group('orderServedArchives', () {
    TilesRegion make(String name, TileRole role) => TilesRegion(
          name: name,
          path: '/tiles/$name.pmtiles',
          bytes: 1,
          role: role,
        );

    test('coverage (by name) → active region → overview (by name)', () {
      final zCover = make('zebra-coverage', TileRole.coverage);
      final aCover = make('alpha-coverage', TileRole.coverage);
      final active = make('gb', TileRole.region);
      final zOver = make('zeta-overview', TileRole.overview);
      final aOver = make('alpha-overview', TileRole.overview);

      final ordered = orderServedArchives(
        [zOver, active, zCover, aOver, aCover],
        active,
      );

      expect(
        ordered.map((r) => r.name).toList(),
        ['alpha-coverage', 'zebra-coverage', 'gb', 'alpha-overview',
            'zeta-overview'],
      );
    });

    test('region files that are not active are excluded', () {
      final active = make('gb', TileRole.region);
      final other = make('de', TileRole.region);
      final ordered = orderServedArchives([other, active], active);
      expect(ordered.map((r) => r.name).toList(), ['gb']);
    });

    test('no active region still serves coverage + overview', () {
      final cover = make('bath-coverage', TileRole.coverage);
      final over = make('world-overview', TileRole.overview);
      final region = make('gb', TileRole.region);
      final ordered = orderServedArchives([region, cover, over], null);
      expect(
        ordered.map((r) => r.name).toList(),
        ['bath-coverage', 'world-overview'],
      );
    });

    test('an active file tagged coverage is not added twice', () {
      // Belt-and-braces: `getActive` reconciles this away, but the pure
      // helper must not emit the same path in two slots if it ever sees
      // a stale pairing.
      final cover = make('bath-coverage', TileRole.coverage);
      final ordered = orderServedArchives([cover], cover);
      expect(ordered.map((r) => r.path).toList(), [cover.path]);
    });

    test('a synthetic active entry not on disk is still served', () {
      // The diagnostic sentinel has no installed counterpart.
      const sentinel = TilesRegion(
        name: 'Remote demo (diagnostic)',
        path: TilesService.diagnosticRemoteSentinel,
        bytes: 0,
      );
      final ordered = orderServedArchives(const [], sentinel);
      expect(ordered.single.path, TilesService.diagnosticRemoteSentinel);
    });

    test('empty in, empty out', () {
      expect(orderServedArchives(const [], null), isEmpty);
    });
  });

  group('TilesService roles', () {
    test('install infers a role from the file name and persists it',
        () async {
      final overview =
          await TilesService.install(await makeFake('world-overview.pmtiles'));
      expect(overview.role, TileRole.overview);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('trail_tiles_roles_v1'),
        contains('"world-overview.pmtiles":"overview"'),
      );
    });

    test('setRole round-trips through prefs into listInstalled', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      expect(region.role, TileRole.region);

      await TilesService.setRole(region, TileRole.coverage);

      final listed = await TilesService.listInstalled();
      expect(listed.single.role, TileRole.coverage);
    });

    test('re-installing a hand-tagged file keeps the user tag', () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setRole(region, TileRole.overview);

      final again = await TilesService.install(await makeFake('uk.pmtiles'));
      expect(again.role, TileRole.overview);
    });

    test('an untagged file on disk is listed with its inferred role',
        () async {
      // TileDownloader writes straight into the tiles dir without going
      // through install(), so the read path has to infer too.
      final dir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}tiles',
      );
      await dir.create(recursive: true);
      await File('${dir.path}${Platform.pathSeparator}bath-coverage.mbtiles')
          .writeAsBytes(const [0]);

      final listed = await TilesService.listInstalled();
      expect(listed.single.role, TileRole.coverage);
      // Inference on read does NOT write anything back.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('trail_tiles_roles_v1'), isNull);
    });

    test('malformed role JSON reads as "no roles" rather than throwing',
        () async {
      SharedPreferences.setMockInitialValues(
        {'trail_tiles_roles_v1': 'not json at all'},
      );
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      expect(region.role, TileRole.region);
      expect((await TilesService.listInstalled()).single.role, TileRole.region);
    });

    test('retagging the active region away from region clears active',
        () async {
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setActive(region);
      expect(await TilesService.getActive(), isNotNull);

      await TilesService.setRole(region, TileRole.coverage);

      expect(await TilesService.getActive(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('trail_active_tiles_v1'), isNull);
    });

    test('retagging a non-active region leaves the active one alone',
        () async {
      final gb = await TilesService.install(await makeFake('uk.pmtiles'));
      final de = await TilesService.install(await makeFake('de.pmtiles'));
      await TilesService.setActive(gb);

      await TilesService.setRole(de, TileRole.coverage);

      expect((await TilesService.getActive())?.path, gb.path);
    });

    test('getActive ignores a file whose role is no longer region',
        () async {
      // The pref is written directly here so the reconcile-on-read path
      // is what clears it, not setRole's own guard.
      final region = await TilesService.install(await makeFake('uk.pmtiles'));
      await TilesService.setRole(region, TileRole.overview);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('trail_active_tiles_v1', region.path);

      expect(await TilesService.getActive(), isNull);
      expect(prefs.getString('trail_active_tiles_v1'), isNull);
    });
  });

  group('TilesService.servedArchives', () {
    test('is empty on a fresh install', () async {
      expect(await TilesService.servedArchives(), isEmpty);
    });

    test('serves coverage + overview with no active region', () async {
      await TilesService.install(await makeFake('bath-coverage.mbtiles'));
      await TilesService.install(await makeFake('world-overview.mbtiles'));
      await TilesService.install(await makeFake('gb.mbtiles'));

      final served = await TilesService.servedArchives();
      expect(
        served.map((r) => r.name).toList(),
        ['bath-coverage', 'world-overview'],
      );
    });

    test('slots the active region between coverage and overview', () async {
      await TilesService.install(await makeFake('bath-coverage.mbtiles'));
      await TilesService.install(await makeFake('world-overview.mbtiles'));
      final gb = await TilesService.install(await makeFake('gb.mbtiles'));
      await TilesService.setActive(gb);

      final served = await TilesService.servedArchives();
      expect(
        served.map((r) => r.name).toList(),
        ['bath-coverage', 'gb', 'world-overview'],
      );
      expect(served.map((r) => r.role).toList(), [
        TileRole.coverage,
        TileRole.region,
        TileRole.overview,
      ]);
    });
  });
}
