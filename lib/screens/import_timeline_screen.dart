import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../db/import_dao.dart';
import '../providers/backup_provider.dart';
import '../providers/import_provider.dart';
import '../providers/mbtiles_provider.dart';
import '../services/coverage/coverage_planner.dart';
import '../services/coverage/coverage_prefs.dart';
import '../services/coverage/coverage_service.dart';
import '../services/import/import_thinning.dart';
import '../services/import/timeline_import_service.dart';
import '../services/import/timeline_models.dart';
import '../services/tile_downloader.dart';
import '../widgets/help_button.dart';

/// Google Maps Timeline import (docs/TIMELINE_IMPORT.md, 0.16.0).
///
/// One screen, four states stacked as cards: how to get the file →
/// pick it → dry-run preview with a thinning preset → import with
/// progress + undo. A file Trail has already imported short-circuits to
/// an "already imported" card with the undo shortcut.
///
/// The heavy lifting is in [TimelineImportService]; this screen only
/// drives it and reports. Dark theme only (CLAUDE.md gotcha 4).
class ImportTimelineScreen extends ConsumerStatefulWidget {
  const ImportTimelineScreen({super.key});

  @override
  ConsumerState<ImportTimelineScreen> createState() =>
      _ImportTimelineScreenState();
}

class _ImportTimelineScreenState extends ConsumerState<ImportTimelineScreen> {
  static final _dateFmt = DateFormat('d MMM yyyy');

  TimelineImportService? _service;

  String? _path;
  String? _fileName;
  ImportPreset _preset = ImportPreset.normal;

  bool _previewing = false;
  ImportPreview? _preview;
  ImportRecord? _already;
  String? _error;

  bool _committing = false;
  ImportProgress? _progress;
  ImportCancelToken? _cancel;
  ImportResult? _result;

  bool _coverageBusy = false;
  String? _coverageNote;

  @override
  void dispose() {
    // The picker copies the SAF selection into the app cache
    // (docs/TIMELINE_IMPORT.md "Parsing") — a 200 MB Timeline.json is
    // not something to leave lying around.
    unawaited(FilePicker.clearTemporaryFiles());
    // Releases the parsing isolate; the service re-spawns on next use.
    _service?.dispose();
    super.dispose();
  }

  Future<TimelineImportService> _importService() async {
    final service = await ref.read(timelineImportServiceProvider.future);
    _service = service;
    return service;
  }

  // --- steps -------------------------------------------------------------

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;
    setState(() {
      _path = path;
      _fileName = picked.files.single.name;
      _preview = null;
      _already = null;
      _result = null;
      _error = null;
      _coverageNote = null;
    });
    await _runPreview();
  }

  /// Re-runs the dry run. Changing the preset re-parses the file — the
  /// thinning rules apply during the parse pass, and a re-read is
  /// cheaper than keeping every candidate of a 15-year export in RAM.
  Future<void> _runPreview() async {
    final path = _path;
    if (path == null || _previewing) return;
    setState(() {
      _previewing = true;
      _preview = null;
      _already = null;
      _error = null;
      _progress = null;
    });
    try {
      final service = await _importService();
      final preview = await service.preview(
        path,
        _preset,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _previewing = false;
        _progress = null;
      });
    } on AlreadyImportedException catch (e) {
      if (!mounted) return;
      setState(() {
        _already = e.record;
        _previewing = false;
        _progress = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _previewing = false;
        _progress = null;
      });
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (preview == null || _committing) return;
    final cancel = ImportCancelToken();
    setState(() {
      _committing = true;
      _cancel = cancel;
      _error = null;
      _progress = const ImportProgress(
        phase: ImportPhase.inserting,
        current: 0,
      );
    });
    try {
      final service = await _importService();
      final result = await service.commit(
        preview,
        cancelToken: cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      // Every read of the pings table is now stale (gotcha 29).
      invalidateAfterImport(ref);
      setState(() {
        _result = result;
        _committing = false;
        _cancel = null;
        _progress = null;
        _preview = result.ok ? null : _preview;
        _error = result.error;
      });
      if (result.ok && result.rows > 0) {
        await _offerCoverage(result);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _committing = false;
        _cancel = null;
        _progress = null;
      });
    }
  }

  Future<void> _undo(int importId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Undo this import?'),
        content: const Text(
          'Every ping this import added is deleted. Your own pings are '
          'untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Undo import'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final service = await _importService();
      final removed = await service.undo(importId);
      if (!mounted) return;
      invalidateAfterImport(ref);
      setState(() {
        _result = null;
        _already = null;
        _preview = null;
      });
      _snack('Removed $removed imported ping${removed == 1 ? '' : 's'}.');
      await _runPreview();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// Offers high-zoom map detail for the places the import just added
  /// (docs/TIMELINE_IMPORT.md §3 Phase C). Opt-in, one confirm dialog
  /// with the server's byte-exact dry-run size; skipped silently when no
  /// map-detail server is configured.
  Future<void> _offerCoverage(ImportResult result) async {
    if (result.sampledPoints.isEmpty) return;
    // No server configured = the feature is off for this user; say
    // nothing rather than reporting a failure they didn't ask for.
    final serverUrl = await CoveragePrefs.readServerUrl();
    if (serverUrl == null || serverUrl.isEmpty || !mounted) return;
    setState(() {
      _coverageBusy = true;
      _coverageNote = null;
    });
    try {
      final points = <GeoPoint>[
        for (final p in result.sampledPoints) GeoPoint(p.lat, p.lon),
      ];
      await CoverageService.instance.refreshExtents();
      final plan = await CoverageService.instance.planForPoints(points);
      if (!mounted) return;
      setState(() => _coverageBusy = false);
      if (plan.isEmpty) {
        setState(() => _coverageNote =
            'Every imported place is already covered in map detail.');
        return;
      }
      final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Download map detail?'),
              content: Text(
                'The import covers ${plan.boxes.length} place'
                '${plan.boxes.length == 1 ? '' : 's'} with no detailed '
                'tiles yet (${_formatMb(plan.totalBytes)}).',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Download'),
                ),
              ],
            ),
          ) ??
          false;
      if (!ok || !mounted) return;
      await _runCoverage(plan);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _coverageBusy = false;
        _coverageNote = 'Map detail unavailable: $e';
      });
    }
  }

  Future<void> _runCoverage(CoveragePlan plan) async {
    final cancelToken = TileDownloadCancelToken();
    final progress = ValueNotifier<String>('Starting…');
    setState(() => _coverageBusy = true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Downloading map detail'),
        content: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (_, text, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(text),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelToken.isCancelled = true;
              Navigator.pop(c);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ));
    final run = await CoverageService.instance.fetchPlan(
      plan,
      cancelToken: cancelToken,
      onProgress: (i, count, received, total) {
        progress.value = 'Area ${i + 1} of $count · ${_formatMb(received)}'
            '${total == null ? '' : ' / ${_formatMb(total)}'}';
      },
      onInstalled: () {
        if (mounted) invalidateTileProviders(ref);
      },
    );
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    progress.dispose();
    if (!mounted) return;
    setState(() {
      _coverageBusy = false;
      _coverageNote = run.cancelled
          ? 'Cancelled after ${run.downloaded} area(s).'
          : run.error != null
              ? 'Map detail failed: ${run.error}'
              : 'Installed ${run.downloaded} map-detail pack'
                  '${run.downloaded == 1 ? '' : 's'} '
                  '(${_formatMb(run.bytes)}).';
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // --- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final backupOn = ref.watch(backupEnabledProvider).valueOrNull ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Google Timeline'),
        actions: const [
          HelpButton(
            screenTitle: 'Import Google Timeline',
            sections: [
              HelpSection(
                icon: Icons.download_outlined,
                title: 'Getting the file',
                body:
                    'On Android: Settings → Location → Location services → '
                    'Timeline → Export Timeline data. Google saves a '
                    'Timeline.json to your device; pick it here.',
              ),
              HelpSection(
                icon: Icons.filter_alt_outlined,
                title: 'Thinning',
                body:
                    'Google records hundreds of points a day. Normal keeps '
                    'a point every 15 minutes or 250 m, Coarse every hour '
                    'or 1 km, Full keeps everything. Visits are always '
                    'kept, and points Trail already logged are skipped.',
              ),
              HelpSection(
                icon: Icons.undo,
                title: 'Undo',
                body:
                    'Every import is recorded, so it can be removed again '
                    'in one tap — here right after importing, or later '
                    'from Settings → History → Timeline imports.',
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          _introCard(backupOn),
          if (_already != null) _alreadyImportedCard(_already!),
          if (_path != null && _already == null) _presetCard(),
          if (_previewing) _busyCard('Reading ${_fileName ?? 'the file'}…'),
          if (_preview != null && !_committing) _previewCard(_preview!),
          if (_committing) _progressCard(),
          if (_result != null) _resultCard(_result!),
          if (_coverageBusy || _coverageNote != null) _coverageCard(),
          if (_error != null) _errorCard(_error!),
        ],
      ),
    );
  }

  Widget _introCard(bool backupOn) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Export your Timeline', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'On your phone: Settings → Location → Location services → '
              'Timeline → Export Timeline data. (Or Google Maps → Your '
              'Timeline → ⋮ → Location & privacy settings → Export.) '
              'Google writes a Timeline.json to this device — pick it '
              'below.',
            ),
            const SizedBox(height: 12),
            _note(
              Icons.lock_outline,
              'Imported places stay on the device: they are never sent to '
              'Wikimedia for photos, and they do not count towards stats, '
              'trips or the "last ping" card. They show on the map and in '
              'History.',
            ),
            if (backupOn) ...[
              const SizedBox(height: 8),
              _note(
                Icons.cloud_upload_outlined,
                'Cloud backup is on. A large import grows the encrypted '
                'database, and Android only auto-backs-up 25 MB per app — '
                'a big Timeline can push you over that quota.',
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _previewing || _committing ? null : _pickFile,
              icon: const Icon(Icons.folder_open),
              label: Text(
                _fileName == null
                    ? 'Choose Timeline.json'
                    : 'Choose another file',
              ),
            ),
            if (_fileName != null) ...[
              const SizedBox(height: 8),
              Text(_fileName!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _presetCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How much detail?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final preset in ImportPreset.values)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: _preset == preset,
                    onSelected: _previewing || _committing
                        ? null
                        : (_) {
                            if (_preset == preset) return;
                            setState(() => _preset = preset);
                            unawaited(_runPreview());
                          },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewCard(ImportPreview preview) {
    final theme = Theme.of(context);
    final projection = preview.projection;
    final counts = preview.counts;
    final skipped = counts.ignoredElements +
        counts.malformedElements +
        counts.rawRejectedAccuracy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preview', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${projection.kept} row${projection.kept == 1 ? '' : 's'} after '
              'thinning · ${projection.duplicates} duplicate'
              '${projection.duplicates == 1 ? '' : 's'} skipped',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Range ${_formatRange(projection)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Sections: ${counts.pathPoints} path · ${counts.visits} visits · '
              '${counts.activities} activities · ${counts.rawPositions} raw'
              '${skipped == 0 ? '' : ', $skipped skipped'}',
              style: theme.textTheme.bodySmall,
            ),
            if (projection.exceedsWarnThreshold) ...[
              const SizedBox(height: 12),
              _note(
                Icons.warning_amber_outlined,
                'That is over $kImportWarnRowThreshold rows. The map draws '
                'them fine, but the database grows and a cloud backup may '
                'not fit. Consider the Coarse preset.',
                color: Colors.amber,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: projection.kept == 0 ? null : _commit,
              icon: const Icon(Icons.download_done_outlined),
              label: Text('Import ${projection.kept} rows'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    final progress = _progress;
    final theme = Theme.of(context);
    final inserting = progress?.phase == ImportPhase.inserting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              inserting ? 'Importing…' : 'Preparing…',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 8),
            Text(
              inserting && progress != null
                  ? '${progress.current} of ${progress.total ?? 0} rows'
                  : 'Working…',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                _cancel?.isCancelled = true;
                _snack('Cancelling — nothing will be kept.');
              },
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(ImportResult result) {
    final theme = Theme.of(context);
    if (result.cancelled) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.block),
          title: const Text('Import cancelled'),
          subtitle: const Text('Nothing was added.'),
        ),
      );
    }
    if (!result.ok) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Import failed'),
          subtitle: Text(result.error ?? 'Unknown error'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Imported', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${result.rows} ping${result.rows == 1 ? '' : 's'} added'
                '${result.tsMinUtc == null ? '' : ' · '
                    '${_dateFmt.format(result.tsMinUtc!.toLocal())} – '
                    '${_dateFmt.format(result.tsMaxUtc!.toLocal())}'}'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: result.importId == null
                  ? null
                  : () => _undo(result.importId!),
              icon: const Icon(Icons.undo),
              label: const Text('Undo import'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _alreadyImportedCard(ImportRecord record) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Already imported on '
              '${_dateFmt.format(record.importedAtUtc.toLocal())}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'This exact file added ${record.rowCount} ping'
              '${record.rowCount == 1 ? '' : 's'}. Re-importing it would '
              'only duplicate work, so it is refused. Export a fresh '
              'Timeline for anything newer.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  record.id == null ? null : () => _undo(record.id!),
              icon: const Icon(Icons.undo),
              label: const Text('Undo that import'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverageCard() {
    return Card(
      child: ListTile(
        leading: _coverageBusy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.map_outlined),
        title: const Text('Map detail'),
        subtitle: Text(_coverageNote ?? 'Checking which places need tiles…'),
      ),
    );
  }

  Widget _busyCard(String label) {
    final progress = _progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress?.fraction),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String message) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: const Text('Import problem'),
        subtitle: Text(message),
      ),
    );
  }

  Widget _note(IconData icon, String text, {Color? color}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  String _formatRange(ImportProjection projection) {
    final min = projection.tsMinUtcMs;
    final max = projection.tsMaxUtcMs;
    if (min == null || max == null) return 'nothing to import';
    final from =
        DateTime.fromMillisecondsSinceEpoch(min, isUtc: true).toLocal();
    final to = DateTime.fromMillisecondsSinceEpoch(max, isUtc: true).toLocal();
    return '${_dateFmt.format(from)} – ${_dateFmt.format(to)}';
  }
}

/// Bottom sheet listing past imports with a per-row undo — Settings →
/// History → "Timeline imports".
Future<void> showTimelineImportsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _TimelineImportsSheet(),
  );
}

class _TimelineImportsSheet extends ConsumerWidget {
  const _TimelineImportsSheet();

  static final _dateFmt = DateFormat('d MMM yyyy HH:mm');

  Future<void> _undo(
    BuildContext context,
    WidgetRef ref,
    ImportRecord record,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Undo this import?'),
        content: Text(
          'Deletes the ${record.rowCount} ping'
          '${record.rowCount == 1 ? '' : 's'} this import added. Your own '
          'pings are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Undo import'),
          ),
        ],
      ),
    );
    if (confirmed != true || record.id == null) return;
    final service = await ref.read(timelineImportServiceProvider.future);
    final removed = await service.undo(record.id!);
    invalidateAfterImport(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed $removed imported ping'
            '${removed == 1 ? '' : 's'}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(importHistoryProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: history.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Could not read the import history'),
            subtitle: Text('$e'),
          ),
          data: (records) {
            if (records.isEmpty) {
              return const ListTile(
                leading: Icon(Icons.history_toggle_off),
                title: Text('No Timeline imports yet'),
                subtitle: Text(
                  'Settings → History → Import Google Timeline.',
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final record in records)
                  ListTile(
                    leading: const Icon(Icons.map_outlined),
                    title: Text('${record.rowCount} ping'
                        '${record.rowCount == 1 ? '' : 's'} · '
                        '${record.preset}'),
                    subtitle: Text(
                      '${record.fileName ?? 'Timeline.json'} · '
                      '${_dateFmt.format(record.importedAtUtc.toLocal())}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.undo),
                      tooltip: 'Undo import',
                      onPressed: () => _undo(context, ref, record),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _formatMb(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
