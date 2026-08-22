import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../db/import_dao.dart';
import '../db/ping_dao.dart';
import '../providers/backup_provider.dart';
import '../providers/import_provider.dart';
import '../providers/mbtiles_provider.dart';
import '../services/coverage/coverage_flow.dart';
import '../services/coverage/coverage_planner.dart';
import '../services/import/import_thinning.dart';
import '../services/import/timeline_import_service.dart';
import '../services/import/timeline_models.dart';
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

  /// The note on the card is "you never set a server up" — render the
  /// route out of it.
  bool _coverageNeedsServer = false;

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
      _coverageNeedsServer = false;
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
  /// with the server's byte-exact dry-run size.
  ///
  /// A missing server URL used to return here silently, so a user who
  /// had never set one up saw NOTHING after importing years of Timeline
  /// data — and, with the import older than the Settings button's
  /// 365-day window, had no way to ask for it later either. It is now an
  /// explicit note with a route into Settings, and the imports sheet
  /// carries a per-import "Map detail" action for the second half.
  Future<void> _offerCoverage(ImportResult result) async {
    if (result.sampledPoints.isEmpty) return;
    setState(() {
      _coverageBusy = true;
      _coverageNote = null;
      _coverageNeedsServer = false;
    });
    final points = <GeoPoint>[
      for (final p in result.sampledPoints) GeoPoint(p.lat, p.lon),
    ];
    final flow = await runCoverageFlow(
      context,
      points: points,
      serverMissingNote: coverageServerNotSetNote(points.length),
      alreadyCoveredNote:
          'Every imported place is already covered in map detail.',
      declinedNote: 'Not downloaded. You can fetch it later from Settings '
          '→ History → Timeline imports → Map detail.',
      onInstalled: () {
        if (mounted) invalidateTileProviders(ref);
      },
    );
    if (!mounted) return;
    setState(() {
      _coverageBusy = false;
      _coverageNeedsServer = flow.status == CoverageFlowStatus.noServer;
      _coverageNote = flow.message;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: _coverageBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.map_outlined),
            title: const Text('Map detail'),
            subtitle:
                Text(_coverageNote ?? 'Checking which places need tiles…'),
          ),
          if (_coverageNeedsServer)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/settings'),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open Settings'),
                ),
              ),
            ),
        ],
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

class _TimelineImportsSheet extends ConsumerStatefulWidget {
  const _TimelineImportsSheet();

  @override
  ConsumerState<_TimelineImportsSheet> createState() =>
      _TimelineImportsSheetState();
}

class _TimelineImportsSheetState extends ConsumerState<_TimelineImportsSheet> {
  static final _dateFmt = DateFormat('d MMM yyyy HH:mm');

  /// `imports.id` of the row currently planning/downloading map detail —
  /// one at a time, and the row shows a spinner while it works.
  int? _busyId;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _undo(ImportRecord record) async {
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
    if (!mounted) return;
    invalidateAfterImport(ref);
    _snack('Removed $removed imported ping${removed == 1 ? '' : 's'}.');
  }

  /// Per-import recovery for the map-detail offer: re-plans coverage for
  /// the places THIS import added, whenever the user wants.
  ///
  /// The Settings button ("Fetch map detail for my pins now") only looks
  /// at the last 365 days, so a Timeline export of 2015–2019 was
  /// unreachable from there — and if no server was configured at import
  /// time, the offer never appeared at all. This is the way back.
  Future<void> _mapDetail(ImportRecord record) async {
    final id = record.id;
    if (id == null || _busyId != null) return;
    setState(() => _busyId = id);
    try {
      final db = await TrailDatabase.shared();
      final dao = PingDao(db);
      if (await dao.countByImportId(id) == 0) {
        _snack('That import has no pings left.');
        return;
      }
      final fixes = await dao.fixesByImportId(id);
      final points = <GeoPoint>[
        for (final f in fixes) GeoPoint(f.lat, f.lon),
      ];
      if (points.isEmpty) {
        _snack('That import has no coordinates to cover.');
        return;
      }
      if (!mounted) return;
      final flow = await runCoverageFlow(
        context,
        points: points,
        serverMissingNote: coverageServerNotSetNote(points.length),
        alreadyCoveredNote:
            'Every place in that import is already covered in map detail.',
        declinedNote: '',
        onInstalled: () {
          if (mounted) invalidateTileProviders(ref);
        },
      );
      if (!mounted) return;
      if (flow.status == CoverageFlowStatus.noServer) {
        await _serverMissingDialog(flow.message);
      } else if (flow.message.isNotEmpty) {
        _snack(flow.message);
      }
    } catch (e) {
      _snack('Map detail failed: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _serverMissingDialog(String note) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Map detail'),
        content: Text(note),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (open != true || !mounted) return;
    // Grab the router BEFORE popping: reading an inherited widget off a
    // context that is on its way out is how this crashes.
    final router = GoRouter.of(context);
    Navigator.of(context).pop(); // close the sheet first
    router.push('/settings');
  }

  @override
  Widget build(BuildContext context) {
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
                    trailing: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_busyId == record.id)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          IconButton(
                            icon: const Icon(
                              Icons.download_for_offline_outlined,
                            ),
                            tooltip: 'Map detail…',
                            onPressed: _busyId != null
                                ? null
                                : () => _mapDetail(record),
                          ),
                        IconButton(
                          icon: const Icon(Icons.undo),
                          tooltip: 'Undo import',
                          onPressed:
                              _busyId != null ? null : () => _undo(record),
                        ),
                      ],
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
