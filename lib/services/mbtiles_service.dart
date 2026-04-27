import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single installed `.pmtiles` region.
///
/// `name` is the filename without extension — we don't read the PMTiles
/// metadata `name` field because user-picked filenames (e.g.
/// "gb-z13.pmtiles", "lake-district.pmtiles") are more meaningful than
/// the generator's default ("OpenMapTiles").
class TilesRegion {
  final String name;
  final String path;
  final int bytes;

  const TilesRegion({
    required this.name,
    required this.path,
    required this.bytes,
  });
}

/// Manages the on-device PMTiles library.
///
/// Storage layout:
///   `<appDocumentsDir>/tiles/<region>.pmtiles`
///
/// The active-region filename is kept in [SharedPreferences] under
/// [_activeKey] rather than in the encrypted DB — basemap choice is a
/// UX preference, not sensitive data, and we want it readable from any
/// isolate without plumbing.
///
/// **File sizes:** UK-wide vector PMTiles from `planetiler` typically
/// run 300 MB at z12, 600–700 MB at z13, 1.5 GB at z14. Hiking-region
/// extracts (Lake District etc.) are 50–150 MB at z14. [install] copies
/// the picked file into the app dir because Android's SAF URIs can go
/// stale (user deletes, moves to SD, etc.); copying once makes offline
/// use reliable across reboots and SAF permission expiry.
class TilesService {
  static const _activeKey = 'trail_active_tiles_v1';
  static const _dirName = 'tiles';
  static const _extension = '.pmtiles';

  /// Lists every `.pmtiles` file currently installed. Returns `[]` if
  /// the directory doesn't exist yet (fresh install).
  static Future<List<TilesRegion>> listInstalled() async {
    final dir = await _ensureDir();
    if (!await dir.exists()) return const [];
    final entries = await dir.list().toList();
    final regions = <TilesRegion>[];
    for (final e in entries) {
      if (e is! File) continue;
      if (!e.path.toLowerCase().endsWith(_extension)) continue;
      final stat = await e.stat();
      regions.add(TilesRegion(
        name: _nameFromPath(e.path),
        path: e.path,
        bytes: stat.size,
      ));
    }
    regions.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return regions;
  }

  /// Copies [sourcePath] into the tiles dir. Returns the installed
  /// region. Overwrites any existing region with the same filename —
  /// this is the user's explicit action via the picker, so "latest
  /// install wins" matches expectations.
  static Future<TilesRegion> install(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw StateError('Picked file does not exist: $sourcePath');
    }
    final dir = await _ensureDir();
    final filename = _filenameOnly(sourcePath);
    final dest = File('${dir.path}${Platform.pathSeparator}$filename');
    await src.copy(dest.path);
    final stat = await dest.stat();
    return TilesRegion(
      name: _nameFromPath(dest.path),
      path: dest.path,
      bytes: stat.size,
    );
  }

  /// Deletes a region from disk. If it was the active region, clears
  /// the active preference so the viewer falls back to the empty state
  /// instead of pointing at a missing file.
  static Future<void> delete(TilesRegion region) async {
    final f = File(region.path);
    if (await f.exists()) await f.delete();
    final active = await getActive();
    if (active?.path == region.path) {
      await clearActive();
    }
  }

  static Future<void> setActive(TilesRegion region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, region.path);
  }

  static Future<void> clearActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
  }

  /// Sentinel "path" used by the regions screen's diagnostic-mode
  /// button to flip the renderer to a remote demo PMTiles URL.
  /// `getActive` short-circuits the file-existence check for this value
  /// so the synthetic region survives across app restarts.
  static const diagnosticRemoteSentinel = '__remote_demo__';

  /// Returns the currently active region, or `null` if none is set or
  /// the file on disk is gone. We check existence rather than trusting
  /// the pref so a user who deletes the file from outside the app still
  /// gets a clean fallback to the empty state.
  static Future<TilesRegion?> getActive() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_activeKey);
    if (path == null) return null;
    if (path == diagnosticRemoteSentinel) {
      return const TilesRegion(
        name: 'Remote demo (diagnostic)',
        path: diagnosticRemoteSentinel,
        bytes: 0,
      );
    }
    final f = File(path);
    if (!await f.exists()) {
      await prefs.remove(_activeKey);
      return null;
    }
    final stat = await f.stat();
    return TilesRegion(
      name: _nameFromPath(path),
      path: path,
      bytes: stat.size,
    );
  }

  static Future<Directory> _ensureDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _nameFromPath(String path) {
    final file = _filenameOnly(path);
    final idx = file.lastIndexOf('.');
    return idx <= 0 ? file : file.substring(0, idx);
  }

  static String _filenameOnly(String path) {
    final sep = path.contains(Platform.pathSeparator)
        ? Platform.pathSeparator
        : '/';
    final idx = path.lastIndexOf(sep);
    return idx < 0 ? path : path.substring(idx + 1);
  }
}
