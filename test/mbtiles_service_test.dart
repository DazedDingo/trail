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
  });
}
