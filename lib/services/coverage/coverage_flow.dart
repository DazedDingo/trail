import 'dart:async';

import 'package:flutter/material.dart';

import '../tile_downloader.dart';
import 'coverage_planner.dart';
import 'coverage_prefs.dart';
import 'coverage_service.dart';

/// The user-facing half of Phase C (docs/TIMELINE_IMPORT.md §3): plan →
/// "Download map detail?" → progress dialog with cancel → note.
///
/// It exists because there are now three entry points into the same
/// eight steps — the offer right after a Timeline import, the per-import
/// "Map detail…" action in the imports sheet (the only way to cover an
/// import older than the Settings button's 365-day window), and the
/// Settings "Fetch map detail for my pins now" button. Two hand-copied
/// versions of a hundred lines of dialog code is how the wording, the
/// cancel semantics and the `notConfigured` handling drift apart.
///
/// Everything is returned rather than shown: the caller decides between
/// a SnackBar, a card note or nothing at all. Nothing here throws.
enum CoverageFlowStatus {
  /// Caller passed no coordinates (nothing to plan).
  noPoints,

  /// No map-detail server URL in prefs — the feature is unconfigured,
  /// NOT broken. Recoverable: the caller shows [CoverageFlowResult.message]
  /// with a route into Settings.
  noServer,

  /// Every place already sits inside an installed detailed archive.
  alreadyCovered,

  /// The user dismissed the confirm dialog (or the screen went away
  /// before it could be shown). Nothing downloaded.
  declined,

  /// The user cancelled mid-download; whatever landed is kept.
  cancelled,

  /// Planning or downloading failed (server unreachable, auth, I/O).
  failed,

  /// At least one coverage pack was written to `<docs>/tiles/`.
  installed,
}

/// Outcome of [runCoverageFlow] plus a message ready to show verbatim.
class CoverageFlowResult {
  const CoverageFlowResult(
    this.status,
    this.message, {
    this.downloaded = 0,
    this.bytes = 0,
    this.attemptedDownload = false,
  });

  final CoverageFlowStatus status;

  /// Human-readable, already pluralised. Empty for [CoverageFlowStatus.noPoints].
  final String message;

  /// Archives actually installed.
  final int downloaded;

  /// Bytes written.
  final int bytes;

  /// True once the user confirmed the download — i.e. the pending queue
  /// / Settings notice this run was answering can be considered handled.
  final bool attemptedDownload;

  bool get installedAny => downloaded > 0;
}

/// The "you never set a server up" note for an import-driven run, with
/// the exact recovery path spelled out. [places] is how many sampled
/// coordinates the run had to offer.
String coverageServerNotSetNote(int places) =>
    'Map detail server not set — $places place${places == 1 ? '' : 's'} '
    'from this import could get detail. Set it up in Settings → Map '
    'detail server, then use Timeline imports → Map detail.';

/// Plans coverage for [points], asks the user, downloads with progress.
///
/// [onInstalled] fires once, at the end, when at least one archive
/// landed — pass `invalidateTileProviders`, which restarts the loopback
/// on a new port with the new archive set (CLAUDE.md gotcha 31).
Future<CoverageFlowResult> runCoverageFlow(
  BuildContext context, {
  required List<GeoPoint> points,
  required String serverMissingNote,
  required VoidCallback onInstalled,
  String alreadyCoveredNote =
      'Every place is already covered in map detail.',
  String declinedNote = 'Map detail not downloaded.',
  CoverageService? service,
}) async {
  if (points.isEmpty) {
    return const CoverageFlowResult(CoverageFlowStatus.noPoints, '');
  }
  final svc = service ?? CoverageService.instance;

  // Unconfigured is a first-class outcome, not a failure to report as
  // one: silently returning here is exactly the bug this replaces.
  final url = await CoveragePrefs.readServerUrl();
  if (url == null || url.isEmpty) {
    return CoverageFlowResult(CoverageFlowStatus.noServer, serverMissingNote);
  }

  final CoveragePlan plan;
  try {
    await svc.refreshExtents();
    plan = await svc.planForPoints(points);
  } catch (e) {
    return CoverageFlowResult(
      CoverageFlowStatus.failed,
      'Map detail unavailable: $e',
    );
  }
  if (plan.isEmpty) {
    return CoverageFlowResult(
      CoverageFlowStatus.alreadyCovered,
      alreadyCoveredNote,
    );
  }
  if (!context.mounted) {
    return CoverageFlowResult(CoverageFlowStatus.declined, declinedNote);
  }

  final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Download map detail?'),
          content: Text(
            '${plan.boxes.length} area'
            '${plan.boxes.length == 1 ? '' : 's'} · '
            '${formatCoverageMb(plan.totalBytes)} · planet '
            '${plan.planetDate ?? 'unknown'}',
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
  if (!confirmed || !context.mounted) {
    return CoverageFlowResult(CoverageFlowStatus.declined, declinedNote);
  }

  final cancelToken = TileDownloadCancelToken();
  final progress = ValueNotifier<String>('Starting…');
  // Pushed as a route we HOLD, rather than via `showDialog`: the flow
  // has to be able to take the dialog down again, and a caller that is
  // itself inside a modal sheet must not have that sheet popped by
  // mistake. Holding the route also survives a fetch that finishes
  // before the dialog's first build (fast server, everything cached) —
  // `showDialog` + "pop the context the builder gave me" would strand
  // the dialog on screen forever in that race.
  final navigator = Navigator.of(context);
  final progressRoute = DialogRoute<void>(
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
            Navigator.of(c).pop();
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  unawaited(navigator.push(progressRoute));

  final run = await svc.fetchPlan(
    plan,
    cancelToken: cancelToken,
    onProgress: (i, count, received, total) {
      progress.value = 'Area ${i + 1} of $count · '
          '${formatCoverageMb(received)}'
          '${total == null ? '' : ' / ${formatCoverageMb(total)}'}';
    },
    onInstalled: onInstalled,
  );
  if (navigator.mounted && progressRoute.isActive) {
    navigator.removeRoute(progressRoute);
  }
  // Deliberately NOT disposing `progress`: a popped route keeps
  // rebuilding through its exit transition (and `fetchPlan` can emit one
  // last tick after a cancel), and a `ValueListenableBuilder`
  // re-subscribing to a disposed notifier throws. A notifier nobody
  // listens to is collected like any other object.

  if (run.cancelled) {
    return CoverageFlowResult(
      CoverageFlowStatus.cancelled,
      'Cancelled after ${run.downloaded} area'
      '${run.downloaded == 1 ? '' : 's'}.',
      downloaded: run.downloaded,
      bytes: run.bytes,
      attemptedDownload: true,
    );
  }
  if (run.notConfigured) {
    return CoverageFlowResult(
      CoverageFlowStatus.noServer,
      serverMissingNote,
      attemptedDownload: true,
    );
  }
  if (run.error != null) {
    return CoverageFlowResult(
      CoverageFlowStatus.failed,
      'Map detail failed: ${run.error}',
      downloaded: run.downloaded,
      bytes: run.bytes,
      attemptedDownload: true,
    );
  }
  return CoverageFlowResult(
    CoverageFlowStatus.installed,
    'Installed ${run.downloaded} map-detail pack'
    '${run.downloaded == 1 ? '' : 's'} '
    '(${formatCoverageMb(run.bytes)}).',
    downloaded: run.downloaded,
    bytes: run.bytes,
    attemptedDownload: true,
  );
}

/// Shared MB formatter for every coverage-facing string.
String formatCoverageMb(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
