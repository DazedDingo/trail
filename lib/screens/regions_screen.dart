import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/mbtiles_provider.dart';
import '../services/mbtiles_service.dart';

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
          onPressed: () => context.go('/settings'),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _installRegion(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Install'),
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

  Future<void> _installRegion(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.pmtiles')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a .pmtiles file')),
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
            'Tap Install and pick a .pmtiles file. See docs/TILES.md '
            'for building one on your PC.',
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
