import 'dart:async';

import 'package:flutter/material.dart';

import '../services/photo_backfill_service.dart';

/// Bottom sheet that drives the photo-backfill walk. Opens from
/// Settings → Home → Auto-fetch photos → "Backfill older pings".
///
/// Designed for a single-shot user-tap operation: user taps Start,
/// progress bar climbs, photos appear on past pings in the gallery
/// sheet as each ping resolves. Cancel button stops the walk between
/// pings (mid-fetch HTTP requests complete; we don't try to abort
/// them, just drop the result).
class PhotoBackfillSheet extends StatefulWidget {
  const PhotoBackfillSheet({super.key});

  /// Showtime helper — handles the modal scaffolding so call sites
  /// stay one-liner.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const SafeArea(child: PhotoBackfillSheet()),
    );
  }

  @override
  State<PhotoBackfillSheet> createState() => _PhotoBackfillSheetState();
}

class _PhotoBackfillSheetState extends State<PhotoBackfillSheet> {
  PhotoBackfillProgress? _progress;
  StreamSubscription<PhotoBackfillProgress>? _sub;
  Completer<void>? _cancel;

  bool get _running =>
      _progress != null &&
      !_progress!.finished &&
      _cancel != null &&
      !_cancel!.isCompleted;

  void _start() => _consume(PhotoBackfillService().run(cancel: _cancel = Completer<void>()));

  void _reshuffle() => _consume(
        PhotoBackfillService().reshuffle(cancel: _cancel = Completer<void>()),
      );

  void _consume(Stream<PhotoBackfillProgress> stream) {
    setState(() => _progress = const PhotoBackfillProgress(
          processed: 0,
          total: 0,
          photosAdded: 0,
        ));
    _sub?.cancel();
    _sub = stream.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
  }

  void _stop() {
    if (_cancel != null && !_cancel!.isCompleted) {
      _cancel!.complete();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Backfill photos for older pings',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Walks every past ping with no Wikimedia photos yet and '
            'fetches up to 5 each. Throttled (~1/sec) so the API '
            'doesn\'t treat us like a scraper. Leaks each ping\'s '
            'lat/lon to Wikimedia — same as the auto-fetch toggle.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 10),
          // Cost callout — the Wikimedia API is free + keyless, so
          // there's no money spent. But a year of 4-hour pings is tens
          // of MB of JSON over the throttle window, which matters on
          // cellular. Image bytes are deferred — only fetched when the
          // gallery / slideshow renders them, not here.
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.wifi_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Free to run — Wikimedia's API has no per-call "
                    'cost. A year of 4-hour pings is roughly ~50 MB '
                    'of cellular data over ~40 minutes, so Wi-Fi is '
                    'kinder if you can.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (p == null) ...[
            FilledButton.icon(
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Start backfill'),
              onPressed: _start,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.shuffle),
              label: const Text('Re-shuffle (different photos)'),
              onPressed: _reshuffle,
            ),
            const SizedBox(height: 4),
            Text(
              'Re-shuffle drops every cached Wikimedia attachment and '
              'reassigns from the per-location cache with a new shuffle '
              'seed — fast (no new HTTP) and fully reversible by '
              're-shuffling again. Your own photos are untouched.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ] else ...[
            _ProgressBlock(progress: p),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _running ? _stop : null,
                    child: const Text('Stop'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: p.finished
                        ? () => Navigator.of(context).pop()
                        : null,
                    child: Text(p.finished ? 'Close' : 'Running…'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressBlock extends StatelessWidget {
  final PhotoBackfillProgress progress;
  const _ProgressBlock({required this.progress});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = progress;
    final pct = (p.fraction * 100).toStringAsFixed(0);
    final cacheNote = p.cellCacheHits > 0
        ? ' · ${p.cellCacheHits} from cache'
        : '';
    final statusLine = p.error != null
        ? 'Stopped: ${p.error}'
        : p.finished
            ? p.total == 0
                ? 'All pings already have photos.'
                : 'Done — added ${p.photosAdded} photo'
                    '${p.photosAdded == 1 ? '' : 's'} across '
                    '${p.processed} ping${p.processed == 1 ? '' : 's'}'
                    '$cacheNote.'
            : 'Processing ${p.processed} of ${p.total} pings · '
                'added ${p.photosAdded} so far$cacheNote';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: p.total == 0 ? null : p.fraction,
          minHeight: 6,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                statusLine,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (!p.finished) Text('$pct%',
                style: TextStyle(color: scheme.primary)),
          ],
        ),
      ],
    );
  }
}
