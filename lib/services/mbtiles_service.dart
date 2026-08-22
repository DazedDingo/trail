import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What an installed archive is *for*.
///
/// The loopback tile server serves an ordered stack of archives
/// (detailed first), so a file's role decides both whether it is served
/// at all and where it sits in that stack:
///
///   * [coverage] — high-zoom extracts around places actually visited.
///     Always served, in front of everything else.
///   * [region] — a conventional sideloaded country/park pack. Only the
///     ONE the user marked active is served.
///   * [overview] — the coarse world pack (z0–6). Always served, last,
///     so it only answers where nothing more detailed exists.
///
/// [wire] is persisted in SharedPreferences and must stay stable;
/// [label] is what the regions screen shows.
enum TileRole {
  region('region', 'Region'),
  coverage('coverage', 'Coverage'),
  overview('overview', 'World overview');

  const TileRole(this.wire, this.label);

  /// Stable persisted discriminator.
  final String wire;

  /// Human-readable chip text.
  final String label;
}

/// Parses a persisted [TileRole.wire] value. Returns `null` — rather
/// than defaulting to [TileRole.region] — for an absent or unknown
/// value so callers can tell "never tagged" (infer from the name) from
/// "explicitly tagged as a region" (leave alone).
TileRole? tileRoleFromWire(String? wire) {
  for (final role in TileRole.values) {
    if (role.wire == wire) return role;
  }
  return null;
}

/// Guesses a role from an archive's file name. Pure.
///
/// Applied once, at install time, to whatever the user (or the VPS
/// extract job) named the file — `world-overview.pmtiles` →
/// [TileRole.overview], `coverage-bath.pmtiles` → [TileRole.coverage],
/// anything else → [TileRole.region]. `overview` is checked first so a
/// hypothetical `coverage-overview.pmtiles` reads as the overview.
/// The user can always override it from the regions screen.
TileRole inferRoleFromFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('overview')) return TileRole.overview;
  if (lower.contains('coverage')) return TileRole.coverage;
  return TileRole.region;
}

/// Orders the archives the loopback server should serve, **highest
/// priority first** — the server answers each tile from the first
/// archive that holds it:
///
///   1. every [TileRole.coverage] pack, sorted by name;
///   2. the active [TileRole.region], if any;
///   3. every [TileRole.overview] pack, sorted by name.
///
/// Region files that are not the active one are excluded entirely.
/// Pure so the ordering can be unit-tested without prefs or a disk.
List<TilesRegion> orderServedArchives(
  List<TilesRegion> installed,
  TilesRegion? active,
) {
  int byName(TilesRegion a, TilesRegion b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  final ordered = <TilesRegion>[
    ...installed.where((r) => r.role == TileRole.coverage).toList()
      ..sort(byName),
  ];
  if (active != null) {
    // Prefer the installed entry — it carries the role tag; `active`
    // may be a synthetic entry (the diagnostic sentinel) that isn't on
    // disk at all.
    var entry = active;
    for (final r in installed) {
      if (r.path == active.path) {
        entry = r;
        break;
      }
    }
    if (entry.role == TileRole.region &&
        !ordered.any((r) => r.path == entry.path)) {
      ordered.add(entry);
    }
  }
  ordered.addAll(
    installed.where((r) => r.role == TileRole.overview).toList()..sort(byName),
  );
  return ordered;
}

/// A single installed tile archive (`.mbtiles` or `.pmtiles`).
///
/// `name` is the filename without extension — we don't read the archive
/// metadata `name` field because user-picked filenames (e.g.
/// "gb-z13.pmtiles", "lake-district.pmtiles") are more meaningful than
/// the generator's default ("OpenMapTiles").
class TilesRegion {
  final String name;
  final String path;
  final int bytes;

  /// How this archive participates in the served stack. Defaults to
  /// [TileRole.region] so every pre-roles call site keeps its old
  /// meaning.
  final TileRole role;

  const TilesRegion({
    required this.name,
    required this.path,
    required this.bytes,
    this.role = TileRole.region,
  });

  /// Same archive, different role tag.
  TilesRegion withRole(TileRole role) =>
      TilesRegion(name: name, path: path, bytes: bytes, role: role);
}

/// Manages the on-device tile-archive library.
///
/// Storage layout:
///   `<appDocumentsDir>/tiles/<region>.pmtiles`
///
/// The active-region filename is kept in [SharedPreferences] under
/// [_activeKey] rather than in the encrypted DB — basemap choice is a
/// UX preference, not sensitive data, and we want it readable from any
/// isolate without plumbing. Role tags live next to it in [_rolesKey].
///
/// **File sizes:** UK-wide vector PMTiles from `planetiler` typically
/// run 300 MB at z12, 600–700 MB at z13, 1.5 GB at z14. Hiking-region
/// extracts (Lake District etc.) are 50–150 MB at z14. A world overview
/// at z0–6 is ~45 MB and a town coverage extract ~2 MB
/// (`docs/TIMELINE_IMPORT.md` §3). [install] copies the picked file into
/// the app dir because Android's SAF URIs can go stale (user deletes,
/// moves to SD, etc.); copying once makes offline use reliable across
/// reboots and SAF permission expiry.
class TilesService {
  static const _activeKey = 'trail_active_tiles_v1';

  /// `{fileName: TileRole.wire}`. Keyed by file name rather than the
  /// absolute path so a role survives the app documents dir moving.
  static const _rolesKey = 'trail_tiles_roles_v1';
  static const _dirName = 'tiles';
  static const _extensions = ['.mbtiles', '.pmtiles'];

  /// Lists every supported tile-archive file currently installed, with
  /// its role attached. We accept `.mbtiles` and `.pmtiles`. Returns
  /// `[]` if the directory doesn't exist yet (fresh install).
  ///
  /// Files with no stored role (sideloaded by the downloader, or
  /// dropped in out-of-band) are tagged by [inferRoleFromFileName] on
  /// the fly — read-only, so nothing is written behind the user's back.
  static Future<List<TilesRegion>> listInstalled() async {
    final dir = await _ensureDir();
    if (!await dir.exists()) return const [];
    final prefs = await SharedPreferences.getInstance();
    final roles = _decodeRoles(prefs);
    final entries = await dir.list().toList();
    final regions = <TilesRegion>[];
    for (final e in entries) {
      if (e is! File) continue;
      final lower = e.path.toLowerCase();
      if (!_extensions.any(lower.endsWith)) continue;
      final stat = await e.stat();
      regions.add(TilesRegion(
        name: _nameFromPath(e.path),
        path: e.path,
        bytes: stat.size,
        role: _roleFor(roles, e.path),
      ));
    }
    regions.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return regions;
  }

  /// The ordered archive list the loopback server should serve —
  /// coverage packs, then the active region, then world overviews.
  /// See [orderServedArchives] for the rules.
  static Future<List<TilesRegion>> servedArchives() async {
    final installed = await listInstalled();
    final active = await getActive();
    return orderServedArchives(installed, active);
  }

  /// Copies [sourcePath] into the tiles dir. Returns the installed
  /// region. Overwrites any existing region with the same filename —
  /// this is the user's explicit action via the picker, so "latest
  /// install wins" matches expectations.
  ///
  /// A role is inferred from the file name and persisted, but only when
  /// that file name has no role yet: re-installing a file the user has
  /// re-tagged by hand must not undo the tag.
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
    final prefs = await SharedPreferences.getInstance();
    final roles = _decodeRoles(prefs);
    var role = roles[filename];
    if (role == null) {
      role = inferRoleFromFileName(filename);
      roles[filename] = role;
      await _writeRoles(prefs, roles);
    }
    return TilesRegion(
      name: _nameFromPath(dest.path),
      path: dest.path,
      bytes: stat.size,
      role: role,
    );
  }

  /// Retags [region]. Tagging the *active* region as anything other
  /// than [TileRole.region] also clears the active preference — a
  /// coverage/overview pack is served unconditionally, so "active"
  /// would be a second, contradictory switch on the same file.
  static Future<void> setRole(TilesRegion region, TileRole role) async {
    final prefs = await SharedPreferences.getInstance();
    final roles = _decodeRoles(prefs);
    roles[_filenameOnly(region.path)] = role;
    await _writeRoles(prefs, roles);
    if (role != TileRole.region &&
        prefs.getString(_activeKey) == region.path) {
      await clearActive();
    }
  }

  /// Deletes a region from disk, dropping its role tag. If it was the
  /// active region, clears the active preference so the viewer falls
  /// back to the empty state instead of pointing at a missing file.
  static Future<void> delete(TilesRegion region) async {
    final f = File(region.path);
    if (await f.exists()) await f.delete();
    final active = await getActive();
    if (active?.path == region.path) {
      await clearActive();
    }
    final prefs = await SharedPreferences.getInstance();
    final roles = _decodeRoles(prefs);
    if (roles.remove(_filenameOnly(region.path)) != null) {
      await _writeRoles(prefs, roles);
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

  /// Returns the currently active region, or `null` if none is set, the
  /// file on disk is gone, or the file has since been retagged as a
  /// coverage/overview pack. We reconcile rather than trust the pref so
  /// a user who deletes the file from outside the app — or retags it
  /// through some other path — still gets a clean fallback.
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
    final role = _roleFor(_decodeRoles(prefs), path);
    if (role != TileRole.region) {
      await prefs.remove(_activeKey);
      return null;
    }
    final stat = await f.stat();
    return TilesRegion(
      name: _nameFromPath(path),
      path: path,
      bytes: stat.size,
      role: role,
    );
  }

  /// The stored role for [path], or the name-inferred one when the file
  /// has never been tagged.
  static TileRole _roleFor(Map<String, TileRole> roles, String path) {
    final file = _filenameOnly(path);
    return roles[file] ?? inferRoleFromFileName(file);
  }

  /// Reads [_rolesKey]. Malformed JSON (or an entry with an unknown
  /// wire value) reads as "not tagged" rather than throwing — garbage
  /// in prefs must not blank the regions screen (same rule as
  /// `WorkerRunLog`, CLAUDE.md gotcha 11).
  static Map<String, TileRole> _decodeRoles(SharedPreferences prefs) {
    final raw = prefs.getString(_rolesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, TileRole>{};
      decoded.forEach((key, value) {
        final role = tileRoleFromWire(value is String ? value : null);
        if (role != null) out['$key'] = role;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeRoles(
    SharedPreferences prefs,
    Map<String, TileRole> roles,
  ) async {
    await prefs.setString(
      _rolesKey,
      jsonEncode(roles.map((file, role) => MapEntry(file, role.wire))),
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
