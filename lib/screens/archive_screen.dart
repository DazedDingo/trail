import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/pings_provider.dart';
import '../services/archive/archive_service.dart';

/// Archive flow — export-then-delete rows older than a user-picked
/// cutoff.
///
/// Exists because the PLAN.md retention policy is "keep forever" but
/// the user might want to prune old data after they've exported it
/// out. Per the plan: "provide a manual 'archive older than X' flow
/// that exports to GPX/CSV then deletes from DB. No auto-prune."
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});

  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  late DateTime _cutoff;
  ArchiveFormat _format = ArchiveFormat.gpxAndCsv;
  ArchivePreview? _preview;
  bool _loadingPreview = false;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Default: everything older than 1 year ago. A conservative default
    // so the user can't accidentally nuke recent history by spamming
    // "Archive".
    final now = DateTime.now().toUtc();
    _cutoff = DateTime.utc(now.year - 1, now.month, now.day);
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loadingPreview = true;
      _error = null;
    });
    try {
      final p = await ArchiveService.preview(_cutoff);
      if (!mounted) return;
      setState(() {
        _preview = p;
        _loadingPreview = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingPreview = false;
      });
    }
  }

  Future<void> _pickCutoff() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _cutoff.toLocal(),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      _cutoff = DateTime.utc(picked.year, picked.month, picked.day);
    });
    await _loadPreview();
  }

  Future<void> _runArchive() async {
    if (_preview == null || _preview!.count == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Archive now?'),
        content: Text(
          'This exports ${_preview!.count} pings older than '
          '${_cutoff.toLocal().toIso8601String().split("T").first} to '
          'a file, then PERMANENTLY deletes them from the app.\n\n'
          'Make sure the export opens cleanly in a reader of your '
          'choice before you delete the last copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Archive + delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result = await ArchiveService.archive(
        cutoffUtc: _cutoff,
        format: _format,
      );
      // Invalidate ping-derived providers so the home screen / map /
      // recent history re-query the now-smaller table.
      ref
        ..invalidate(recentPingsProvider)
        ..invalidate(allPingsProvider)
        ..invalidate(lastSuccessfulPingProvider);
      if (!mounted) return;
      await Share.shareXFiles(
        result.exportedFiles.map(XFile.new).toList(),
        subject: 'Trail archive (before '
            '${_cutoff.toLocal().toIso8601String().split("T").first})',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Archived ${result.deletedCount} pings. Export shared.',
          ),
        ),
      );
      await _loadPreview();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Archive older pings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What this does',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Exports every ping older than the cutoff to GPX '
                    'and/or CSV, shares the file, then deletes the '
                    'rows from the app. Your export is the ONLY copy '
                    'after this — save it somewhere durable before '
                    'confirming.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('Cutoff'),
              subtitle: Text(
                'Archive everything before '
                '${_cutoff.toLocal().toIso8601String().split("T").first} '
                '(UTC).',
              ),
              trailing: TextButton(
                onPressed: _pickCutoff,
                child: const Text('Change'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: RadioGroup<ArchiveFormat>(
                groupValue: _format,
                onChanged: (v) {
                  if (v != null) setState(() => _format = v);
                },
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text('Export format'),
                    ),
                    RadioListTile<ArchiveFormat>(
                      title: Text('GPX + CSV (default)'),
                      subtitle: Text(
                        'GPX for map readers, CSV for the raw columns.',
                      ),
                      value: ArchiveFormat.gpxAndCsv,
                    ),
                    RadioListTile<ArchiveFormat>(
                      title: Text('GPX only'),
                      value: ArchiveFormat.gpxOnly,
                    ),
                    RadioListTile<ArchiveFormat>(
                      title: Text('CSV only'),
                      value: ArchiveFormat.csvOnly,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _loadingPreview
                  ? const Center(child: CircularProgressIndicator())
                  : preview == null
                      ? const Text('Loading preview…')
                      : _PreviewBody(preview: preview),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          FilledButton.icon(
            onPressed: _running ||
                    preview == null ||
                    preview.count == 0
                ? null
                : _runArchive,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.archive),
            label: Text(
              preview == null || preview.count == 0
                  ? 'Nothing to archive'
                  : 'Archive ${preview.count} pings + delete from app',
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  final ArchivePreview preview;
  const _PreviewBody({required this.preview});

  @override
  Widget build(BuildContext context) {
    if (preview.count == 0) {
      return const Text(
        'No pings older than this cutoff — nothing to archive.',
      );
    }
    String fmt(DateTime t) => t.toLocal().toIso8601String().split('.').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text('${preview.count} pings will be archived.'),
        if (preview.earliest != null && preview.latest != null) ...[
          const SizedBox(height: 6),
          Text('Earliest: ${fmt(preview.earliest!)} (local)'),
          Text('Latest:   ${fmt(preview.latest!)} (local)'),
        ],
      ],
    );
  }
}
