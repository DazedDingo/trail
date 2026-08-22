import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/mbtiles_provider.dart';
import '../providers/tile_server_provider.dart';
import '../services/github_api.dart';
import '../services/local_tile_server.dart';
import '../services/mbtiles_service.dart';
import '../services/region_presets.dart';
import '../services/tile_catalog.dart';
import '../services/tiles/tile_schema.dart';
import '../services/tile_downloader.dart';
import '../widgets/help_button.dart';
import 'bbox_picker_screen.dart';

/// Offline-map archive library.
///
/// The logging pipeline is already fully offline; this screen makes the
/// history *viewer* offline too by letting the user sideload `.pmtiles`
/// / `.mbtiles` archives built from OpenStreetMap on a PC (see
/// `docs/TILES.md`), and tag each one with the role it plays in the
/// served stack (`TileRole`).
class RegionsScreen extends ConsumerStatefulWidget {
  const RegionsScreen({super.key});

  @override
  ConsumerState<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends ConsumerState<RegionsScreen> {
  /// Memoised [LocalTileServer.probe] calls, keyed by archive path.
  ///
  /// A probe opens the archive, reads its metadata and closes it again —
  /// cheap, but not free, and `ListView` rebuilds a row on every scroll
  /// frame. Caching the *future* (not the value) also collapses the
  /// duplicate calls a rebuild-during-probe would otherwise make.
  /// Dropped for a path when that archive is deleted or re-installed.
  final Map<String, Future<ServedArchiveSummary>> _probes = {};

  Future<ServedArchiveSummary> _probe(String path) =>
      _probes.putIfAbsent(path, () => LocalTileServer.probe(path));

  void _forgetProbe(String path) => _probes.remove(path);

  @override
  Widget build(BuildContext context) {
    final regions = ref.watch(installedRegionsProvider);
    final active = ref.watch(activeRegionProvider);
    final tileServer = ref.watch(tileServerProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline map regions'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        actions: [
          const HelpButton(
            screenTitle: 'Offline map regions',
            sections: [
              HelpSection(
                icon: Icons.cloud_download_outlined,
                title: 'What\'s an archive?',
                body:
                    'A `.pmtiles` or `.mbtiles` file with vector map data '
                    'for an area (e.g. UK, Lake District, Cairngorms). '
                    'Trail is fully offline — with nothing installed, the '
                    'maps go blank. Archives live under the app\'s '
                    'documents folder so they survive uninstall-restore.',
              ),
              HelpSection(
                icon: Icons.layers_outlined,
                title: 'Roles',
                body:
                    'Every archive is a region, a coverage pack or the '
                    'world overview. Coverage packs and the overview are '
                    'always shown; one region can be active alongside '
                    'them. Tiles are served detailed-first, and zooms no '
                    'archive holds are drawn from the nearest coarser '
                    'tile. A file name containing "coverage" or '
                    '"overview" is tagged for you — change it any time '
                    'from the row menu → Role.',
              ),
              HelpSection(
                icon: Icons.add_circle_outline,
                title: 'Add an archive',
                body:
                    'Tap "Add region" for four sources: pick a `.pmtiles` '
                    'or `.mbtiles` file from your device, paste a download '
                    'URL, browse the curated catalog (built from '
                    'raw.githubusercontent), or build one on demand from a '
                    'bbox or national-park preset (needs a GitHub PAT for '
                    'the workflow_dispatch).',
              ),
              HelpSection(
                icon: Icons.check_circle_outline,
                title: 'Set active',
                body:
                    'Only one region is active at a time — tap a region '
                    'row to set it. Coverage packs and the world overview '
                    'need no activating. The map rebuilds on the next '
                    'visit.',
              ),
            ],
          ),
          // Diagnostic only — flips the active region to a synthetic
          // "remote demo" entry so the next map render uses the
          // Protomaps public PMTiles instead of the local file. Lets us
          // test whether the renderer works at all separately from
          // local-PMTiles support.
          IconButton(
            tooltip: 'Run map renderer diagnostic',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () async {
              await TilesService.setActive(const TilesRegion(
                name: 'Remote demo (diagnostic)',
                path: TilesService.diagnosticRemoteSentinel,
                bytes: 0,
              ));
              invalidateTileProviders(ref);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text(
                    'Diagnostic mode on — remote demo PMTiles active',
                  )),
                );
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await widget._showAddSheet(context, ref);
          // A new file (or an overwrite of an existing name) invalidates
          // whatever the cached probes said about the library.
          _probes.clear();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add region'),
      ),
      body: Column(
        children: [
          // Only one style can be live at a time, so a library holding
          // both schemas draws fully in one of them and mostly-blank in
          // the other. Say which, rather than leaving the user to guess
          // why half their archives look empty.
          if (tileServer != null && tileServer.mixedSchemas)
            _MixedSchemaNote(chosen: tileServer.schema),
          Expanded(
            child: regions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err')),
              data: (list) {
                if (list.isEmpty) return const _EmptyState();
                final activeRegion = active.valueOrNull;
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    if (i == 0) return _Header(activeRegion: activeRegion);
                    final r = list[i - 1];
                    final isActive = activeRegion?.path == r.path;
                    return _RegionTile(
                      region: r,
                      isActive: isActive,
                      probe: _probe,
                      onFileChanged: _forgetProbe,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The file-picker install flow. On the widget rather than the state
/// because it touches no state — same reason the URL / catalog / build
/// variants sit in `_RegionsScreenAddFlows` further down.
extension _RegionsScreenInstall on RegionsScreen {
  Future<void> _showAddSheet(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_AddSource>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('From file'),
              subtitle: const Text(
                'Pick a .pmtiles or .mbtiles you already have on the device',
              ),
              onTap: () => Navigator.pop(c, _AddSource.filePicker),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('From URL'),
              subtitle: const Text(
                'Direct link to a .pmtiles or .mbtiles file',
              ),
              onTap: () => Navigator.pop(c, _AddSource.url),
            ),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Browse curated catalog'),
              subtitle: const Text('Pre-built archives, one tap to install'),
              onTap: () => Navigator.pop(c, _AddSource.catalog),
            ),
            ListTile(
              leading: const Icon(Icons.build_outlined),
              title: const Text('Build a region (GitHub Actions)'),
              subtitle: const Text(
                'Pick a bbox + zoom, GitHub Actions builds an MBTiles, '
                'lands in the catalog ~10–20 min later. Needs a GitHub '
                'token in Settings.',
              ),
              isThreeLine: true,
              onTap: () => Navigator.pop(c, _AddSource.build),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case _AddSource.filePicker:
        await _installRegion(context, ref);
      case _AddSource.url:
        await _downloadFromUrl(context, ref);
      case _AddSource.catalog:
        await _browseCatalog(context, ref);
      case _AddSource.build:
        await _requestBuild(context, ref);
      case null:
        break;
    }
  }

  Future<void> _installRegion(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final lower = path.toLowerCase();
    if (!lower.endsWith('.pmtiles') && !lower.endsWith('.mbtiles')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a .mbtiles or .pmtiles file')),
        );
      }
      return;
    }
    try {
      await TilesService.install(path);
      invalidateTileProviders(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archive installed')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Install failed: $e')),
        );
      }
    }
  }
}

/// One-line warning that the served library mixes tile schemas.
class _MixedSchemaNote extends StatelessWidget {
  final TileSchema chosen;
  const _MixedSchemaNote({required this.chosen});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined,
              size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Archives of two map schemas are installed — only '
              '${chosen.label} ones draw fully.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.amber,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final TilesRegion? activeRegion;
  const _Header({required this.activeRegion});

  @override
  Widget build(BuildContext context) {
    final text = activeRegion == null
        ? 'No active region.'
        : 'Active region: ${activeRegion!.name}.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              activeRegion == null ? Icons.map_outlined : Icons.storage,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text),
                  const SizedBox(height: 6),
                  Text(
                    'Coverage packs and the world overview are always '
                    'shown; one region can be active. Tiles are served '
                    'detailed-first, and zooms no archive holds are drawn '
                    'from the nearest coarser tile.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionTile extends ConsumerWidget {
  final TilesRegion region;
  final bool isActive;

  /// Memoised metadata read, owned by `_RegionsScreenState`.
  final Future<ServedArchiveSummary> Function(String path) probe;

  /// Called when the file behind [region] is deleted or retagged, so the
  /// screen can drop its cached probe.
  final void Function(String path) onFileChanged;

  const _RegionTile({
    required this.region,
    required this.isActive,
    required this.probe,
    required this.onFileChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isRegionRole = region.role == TileRole.region;
    return Card(
      child: ListTile(
        isThreeLine: true,
        leading: Icon(
          switch (region.role) {
            TileRole.coverage => Icons.layers_outlined,
            TileRole.overview => Icons.public,
            TileRole.region =>
              isActive ? Icons.check_circle : Icons.map_outlined,
          },
          color: isActive && isRegionRole ? scheme.primary : null,
        ),
        title: Row(
          children: [
            Flexible(child: Text(region.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            _RoleChip(role: region.role, active: isActive && isRegionRole),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatBytes(region.bytes)),
            // Zoom range + format, read from the archive itself. Lazy:
            // one probe per file, cached by the screen.
            FutureBuilder<ServedArchiveSummary>(
              future: probe(region.path),
              builder: (context, snap) {
                final String detail;
                if (snap.hasError) {
                  detail = 'Unreadable archive';
                } else if (!snap.hasData) {
                  detail = 'Reading…';
                } else {
                  final s = snap.data!;
                  detail = 'z${s.minZoom}–${s.maxZoom}'
                      '${s.format == null ? '' : ' · ${s.format}'}'
                      '${s.schema == TileSchema.unknown ? '' : ' · ${s.schema.label}'}';
                }
                return Text(
                  detail,
                  style: Theme.of(context).textTheme.bodySmall,
                );
              },
            ),
          ],
        ),
        trailing: PopupMenuButton<_RegionAction>(
          onSelected: (a) => _handle(context, ref, a),
          itemBuilder: (_) => [
            if (isRegionRole && !isActive)
              const PopupMenuItem(
                value: _RegionAction.setActive,
                child: Text('Set as active'),
              ),
            if (isRegionRole && isActive)
              const PopupMenuItem(
                value: _RegionAction.clearActive,
                child: Text('Clear active'),
              ),
            const PopupMenuItem(
              value: _RegionAction.changeRole,
              child: Text('Role…'),
            ),
            const PopupMenuItem(
              value: _RegionAction.delete,
              child: Text('Delete'),
            ),
          ],
        ),
        onTap: !isRegionRole || isActive
            ? null
            : () => _handle(context, ref, _RegionAction.setActive),
      ),
    );
  }

  Future<void> _handle(
    BuildContext context,
    WidgetRef ref,
    _RegionAction action,
  ) async {
    switch (action) {
      case _RegionAction.setActive:
        await TilesService.setActive(region);
        invalidateTileProviders(ref);
        break;
      case _RegionAction.clearActive:
        await TilesService.clearActive();
        invalidateTileProviders(ref);
        break;
      case _RegionAction.changeRole:
        final picked = await showDialog<TileRole>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Role for ${region.name}'),
            content: SingleChildScrollView(
              child: RadioGroup<TileRole>(
                groupValue: region.role,
                onChanged: (v) => Navigator.pop(c, v),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<TileRole>(
                      title: Text('Region'),
                      subtitle: Text(
                        'A normal pack. Served only while it is the '
                        'active region.',
                      ),
                      value: TileRole.region,
                    ),
                    RadioListTile<TileRole>(
                      title: Text('Coverage'),
                      subtitle: Text(
                        'Detailed extract around places visited. Always '
                        'served, ahead of the region.',
                      ),
                      value: TileRole.coverage,
                    ),
                    RadioListTile<TileRole>(
                      title: Text('World overview'),
                      subtitle: Text(
                        'Coarse whole-world pack. Always served, last.',
                      ),
                      value: TileRole.overview,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
        if (picked == null || picked == region.role) break;
        await TilesService.setRole(region, picked);
        onFileChanged(region.path);
        invalidateTileProviders(ref);
        break;
      case _RegionAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Delete ${region.name}?'),
            content: Text(
              'Frees ${_formatBytes(region.bytes)}. You can re-install later.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await TilesService.delete(region);
          onFileChanged(region.path);
          invalidateTileProviders(ref);
        }
        break;
    }
  }
}

/// Role badge next to an archive's name. The active region additionally
/// reads "Region · active" — role and active are different axes and the
/// row has to show both without a second icon.
class _RoleChip extends StatelessWidget {
  final TileRole role;
  final bool active;
  const _RoleChip({required this.role, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight = active || role != TileRole.region;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        active ? '${role.label} · active' : role.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: highlight
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

enum _RegionAction { setActive, clearActive, changeRole, delete }

enum _AddSource { filePicker, url, catalog, build }

/// Discriminator returned by the build-picker bottom sheet — either a
/// preset (one-tap → confirm → dispatch) or "custom area" (open the
/// bbox form). A nullable `preset` avoids needing a sealed class for
/// just two cases.
class _BuildPickerResult {
  final RegionPreset? preset;
  const _BuildPickerResult.preset(RegionPreset this.preset);
  const _BuildPickerResult.custom() : preset = null;
}

/// Add this method on `RegionsScreen` via extension below — keeps the
/// main class file readable; the URL / catalog flows are noticeably
/// longer than the file-picker one.
extension _RegionsScreenAddFlows on RegionsScreen {
  Future<void> _downloadFromUrl(BuildContext context, WidgetRef ref) async {
    final urlController = TextEditingController();
    final filenameController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Download from URL'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: urlController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Direct URL to an .mbtiles file',
                  hintText: 'https://…/region.mbtiles',
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'Required';
                  final uri = Uri.tryParse(t);
                  if (uri == null || !uri.hasScheme) return 'Invalid URL';
                  if (uri.scheme != 'http' && uri.scheme != 'https') {
                    return 'Use http(s):// only';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: filenameController,
                decoration: const InputDecoration(
                  labelText: 'Save as (optional)',
                  hintText: 'region.mbtiles',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(c, true);
              }
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (go != true) return;
    if (!context.mounted) return;
    await _runDownload(
      context: context,
      ref: ref,
      url: Uri.parse(urlController.text.trim()),
      filename: filenameController.text.trim().isEmpty
          ? null
          : filenameController.text.trim(),
    );
  }

  Future<void> _browseCatalog(BuildContext context, WidgetRef ref) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Loading catalog…'),
          ],
        ),
      ),
    );
    final entries = await TileCatalog.fetch();
    if (!context.mounted) return;
    Navigator.pop(context); // dismiss loading dialog
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<TilesetEntry>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: entries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No regions in the catalog yet — check back later or '
                    'use "From URL" to install one you found yourself.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.map_outlined),
                        title: Text(e.name),
                        subtitle: Text(
                          '${e.description}\n'
                          '${_formatBytes(e.sizeBytes)} · '
                          '${e.schema.label}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        onTap: () => Navigator.pop(c, e),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
    if (picked == null) return;
    if (!context.mounted) return;
    await _runDownload(
      context: context,
      ref: ref,
      url: picked.url,
      filename: picked.filename,
    );
  }

  /// Preset-picker primary flow. Renders UK national parks and AONBs
  /// as a tappable list — one tap and the build kicks off. Power users
  /// can tap "Custom area" at the bottom for the bbox form.
  Future<void> _requestBuild(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_BuildPickerResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) {
        final mq = MediaQuery.of(c);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: mq.size.height * 0.8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding:
                      EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Build a region',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Pick a national park / AONB and GitHub Actions '
                        'will build the offline map (~10–20 min). It '
                        'lands in the catalog when ready.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: kUkRegionPresets.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      if (i == kUkRegionPresets.length) {
                        return ListTile(
                          leading:
                              const Icon(Icons.edit_location_outlined),
                          title: const Text('Custom area…'),
                          subtitle: const Text(
                            'Type your own bounding box',
                          ),
                          onTap: () => Navigator.pop(
                            c,
                            const _BuildPickerResult.custom(),
                          ),
                        );
                      }
                      final r = kUkRegionPresets[i];
                      return ListTile(
                        leading: const Icon(Icons.terrain_outlined),
                        title: Text(r.name),
                        subtitle: Text(
                          '${r.region} · ${r.sizeLabel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(
                          c,
                          _BuildPickerResult.preset(r),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    if (!context.mounted) return;
    if (choice.preset != null) {
      await _confirmAndBuildPreset(context, choice.preset!);
    } else {
      await _customBuildForm(context, ref);
    }
  }

  Future<void> _confirmAndBuildPreset(
    BuildContext context,
    RegionPreset r,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Build ${r.name}?'),
        content: Text(
          '${r.region}\n\n'
          'Approx ${r.approxSizeMb} MB at zoom ${r.defaultZoom}. '
          'Build runs on GitHub Actions and takes ~10–20 minutes; you '
          "don't need to keep the app open. The new region will appear "
          'under "Browse curated catalog" once ready.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Start build'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await _dispatchBuild(
      context: context,
      name: r.id,
      bbox: r.bbox,
      maxzoom: r.defaultZoom.toString(),
      area: r.area,
      description: '${r.name} · ${r.region}',
      displayName: r.name,
    );
  }

  /// The advanced-user form — shown only behind "Custom area".
  /// Same fields as before but laid out as a single dialog with help
  /// text and a link out to bboxfinder.com.
  Future<void> _customBuildForm(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    final bboxController = TextEditingController();
    final descController = TextEditingController();
    String maxzoom = '13';
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Custom region'),
        content: StatefulBuilder(
          builder: (c, setLocal) => SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Use bboxfinder.com to draw an area on a map and '
                      'copy the four numbers — paste them below.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Short name',
                      hintText: 'e.g. cambridge-walks',
                      helperText: 'Lower-case, no spaces',
                    ),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return 'Required';
                      if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(t)) {
                        return 'Lowercase letters, digits, . _ -';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: bboxController,
                          decoration: const InputDecoration(
                            labelText: 'Bounding box',
                            hintText: '-3.5,54.3,-2.7,54.8',
                            helperText: 'minLon,minLat,maxLon,maxLat',
                          ),
                          validator: (v) {
                            final t = v?.trim() ?? '';
                            final parts = t.split(',');
                            if (parts.length != 4) {
                              return 'Need 4 comma-separated numbers';
                            }
                            for (final p in parts) {
                              if (double.tryParse(p.trim()) == null) {
                                return 'Each part must be a number';
                              }
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: IconButton.filledTonal(
                          tooltip: 'Pick on a map',
                          icon: const Icon(Icons.map_outlined),
                          onPressed: () async {
                            final picked = await BboxPickerScreen.pick(c);
                            if (picked != null) {
                              bboxController.text = picked;
                              formKey.currentState?.validate();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descController,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: maxzoom,
                    decoration: const InputDecoration(
                      labelText: 'Detail level',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: '11',
                        child: Text('11 — region overview'),
                      ),
                      DropdownMenuItem(
                        value: '12',
                        child: Text('12 — major roads'),
                      ),
                      DropdownMenuItem(
                        value: '13',
                        child: Text('13 — streets + tracks (recommended)'),
                      ),
                      DropdownMenuItem(
                        value: '14',
                        child: Text('14 — every footpath (largest file)'),
                      ),
                    ],
                    onChanged: (v) =>
                        setLocal(() => maxzoom = v ?? '13'),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(c, true);
              }
            },
            child: const Text('Start build'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final name = nameController.text.trim();
    await _dispatchBuild(
      context: context,
      name: name,
      bbox: bboxController.text.trim(),
      maxzoom: maxzoom,
      area: 'great-britain',
      description: descController.text.trim(),
      displayName: name,
    );
  }

  Future<void> _dispatchBuild({
    required BuildContext context,
    required String name,
    required String bbox,
    required String maxzoom,
    required String area,
    required String description,
    required String displayName,
  }) async {
    try {
      await GithubApi.dispatchRegionBuild(
        name: name,
        bbox: bbox,
        maxzoom: maxzoom,
        area: area,
        description: description,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Build started for $displayName. Check the catalog '
            'in ~10–20 min.',
          ),
        ),
      );
    } on GithubAuthMissingError {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No GitHub token. Settings → GitHub token to set one up.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Build dispatch failed: $e')),
      );
    }
  }

  Future<void> _runDownload({
    required BuildContext context,
    required WidgetRef ref,
    required Uri url,
    required String? filename,
  }) async {
    final cancel = TileDownloadCancelToken();
    final progress = ValueNotifier<({int received, int? total})>(
      (received: 0, total: null),
    );
    bool dismissed = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Downloading'),
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (_, p, __) {
            final pct = p.total == null || p.total == 0
                ? null
                : (p.received / p.total!).clamp(0.0, 1.0).toDouble();
            final txt = p.total == null
                ? '${_formatBytes(p.received)} downloaded'
                : '${_formatBytes(p.received)} / '
                    '${_formatBytes(p.total!)}';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: pct),
                const SizedBox(height: 12),
                Text(txt, textAlign: TextAlign.center),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancel.isCancelled = true;
              Navigator.pop(c);
              dismissed = true;
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    try {
      final region = await TileDownloader.download(
        url: url,
        filename: filename,
        cancelToken: cancel,
        onProgress: (received, total) {
          progress.value = (received: received, total: total);
        },
      );
      if (!context.mounted) return;
      if (!dismissed) Navigator.pop(context); // close progress dialog
      invalidateTileProviders(ref);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Installed ${region.name}'),
          action: SnackBarAction(
            label: 'Set active',
            onPressed: () async {
              await TilesService.setActive(region);
              invalidateTileProviders(ref);
            },
          ),
        ),
      );
    } on TileDownloadCancelled {
      // user-initiated, no UI
    } catch (e) {
      if (!context.mounted) return;
      if (!dismissed) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    } finally {
      progress.dispose();
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'No regions installed',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Install and pick a .mbtiles or .pmtiles file. See '
            'docs/TILES.md for building one on your PC.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text(
            'The map viewer is offline-only — without a region installed '
            'the map screen shows an empty state.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
