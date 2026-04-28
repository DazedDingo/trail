import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/mbtiles_provider.dart';
import '../services/github_api.dart';
import '../services/mbtiles_service.dart';
import '../services/region_presets.dart';
import '../services/tile_catalog.dart';
import '../services/tile_downloader.dart';

/// Offline-map region library.
///
/// The logging pipeline is already fully offline; this screen makes the
/// history *viewer* offline too by letting the user sideload `.pmtiles`
/// files built from OpenStreetMap on a PC (see `docs/TILES.md`).
class RegionsScreen extends ConsumerWidget {
  const RegionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regions = ref.watch(installedRegionsProvider);
    final active = ref.watch(activeRegionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline map regions'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        actions: [
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
              ref.invalidate(activeRegionProvider);
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
        onPressed: () => _showAddSheet(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add region'),
      ),
      body: regions.when(
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
              return _RegionTile(region: r, isActive: isActive);
            },
          );
        },
      ),
    );
  }

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
                'Pick an .mbtiles you already have on the device',
              ),
              onTap: () => Navigator.pop(c, _AddSource.filePicker),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('From URL'),
              subtitle: const Text('Direct link to an .mbtiles file'),
              onTap: () => Navigator.pop(c, _AddSource.url),
            ),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Browse curated catalog'),
              subtitle: const Text('Pre-built regions, one tap to install'),
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
      ref.invalidate(installedRegionsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Region installed')),
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

class _Header extends StatelessWidget {
  final TilesRegion? activeRegion;
  const _Header({required this.activeRegion});

  @override
  Widget build(BuildContext context) {
    final text = activeRegion == null
        ? 'No active region — map viewer is empty until one is set.'
        : 'Active: ${activeRegion!.name} · viewer reads from this file.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              activeRegion == null ? Icons.map_outlined : Icons.storage,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _RegionTile extends ConsumerWidget {
  final TilesRegion region;
  final bool isActive;
  const _RegionTile({required this.region, required this.isActive});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        leading: Icon(
          isActive ? Icons.check_circle : Icons.map_outlined,
          color: isActive ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(region.name),
        subtitle: Text(_formatBytes(region.bytes)),
        trailing: PopupMenuButton<_RegionAction>(
          onSelected: (a) => _handle(context, ref, a),
          itemBuilder: (_) => [
            if (!isActive)
              const PopupMenuItem(
                value: _RegionAction.setActive,
                child: Text('Set as active'),
              ),
            if (isActive)
              const PopupMenuItem(
                value: _RegionAction.clearActive,
                child: Text('Clear active'),
              ),
            const PopupMenuItem(
              value: _RegionAction.delete,
              child: Text('Delete'),
            ),
          ],
        ),
        onTap: isActive
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
        ref.invalidate(activeRegionProvider);
        break;
      case _RegionAction.clearActive:
        await TilesService.clearActive();
        ref.invalidate(activeRegionProvider);
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
          ref.invalidate(installedRegionsProvider);
          ref.invalidate(activeRegionProvider);
        }
        break;
    }
  }
}

enum _RegionAction { setActive, clearActive, delete }

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
                          '${e.description}\n${_formatBytes(e.sizeBytes)}',
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
      filename: '${picked.id}.mbtiles',
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
                  TextFormField(
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
      ref.invalidate(installedRegionsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Installed ${region.name}'),
          action: SnackBarAction(
            label: 'Set active',
            onPressed: () async {
              await TilesService.setActive(region);
              ref.invalidate(activeRegionProvider);
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
