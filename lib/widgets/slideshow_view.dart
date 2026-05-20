import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping.dart';
import '../models/ping_photo.dart';
import '../services/failed_photo_uris.dart';

/// Picture-mode playback. Slaved to the same `_sliderMax` cursor + the
/// same play/pause + speed-cycle controls the map view uses — toggling
/// the mode swaps the visible body without touching playback state.
///
/// Respects the active date filter: [visibleFixes] is whatever the
/// surrounding map widget already filtered (filter → slider → here).
/// If a ping in the window has no photos, we walk back to the nearest
/// earlier ping that does — that way the slideshow never blanks
/// mid-trail just because one mid-day fix had nothing nearby on
/// Wikimedia.
class SlideshowView extends ConsumerStatefulWidget {
  final List<Ping> visibleFixes;
  final DateTime sliderMax;

  /// Mirrors the map view's "no fixes" state so we never render
  /// "loading photos" on an empty trail.
  final bool hasAnyFixes;

  const SlideshowView({
    super.key,
    required this.visibleFixes,
    required this.sliderMax,
    required this.hasAnyFixes,
  });

  @override
  ConsumerState<SlideshowView> createState() => _SlideshowViewState();
}

class _SlideshowViewState extends ConsumerState<SlideshowView> {
  /// `ping.id → full list of photos`. Lazily built when the slideshow
  /// scrubs into a window; we keep the full list (not just first) so
  /// `pickPhotoForPing` can skip photos that have failed to load.
  final Map<int, List<PingPhoto>> _photoCache = {};
  bool _loadingAll = false;

  /// Pings + photo URLs we've already pushed into `precacheImage`. Used
  /// to avoid re-precaching the same URL on every slider tick.
  final Set<String> _precached = {};

  @override
  void initState() {
    super.initState();
    _prefetchVisibleWindow();
  }

  @override
  void didUpdateWidget(SlideshowView old) {
    super.didUpdateWidget(old);
    if (old.visibleFixes != widget.visibleFixes) {
      _photoCache.clear();
      _precached.clear();
      _prefetchVisibleWindow();
    }
  }

  Future<void> _prefetchVisibleWindow() async {
    if (_loadingAll) return;
    _loadingAll = true;
    try {
      final ids = widget.visibleFixes
          .map((p) => p.id)
          .whereType<int>()
          .toList(growable: false);
      if (ids.isEmpty) return;
      final db = await TrailDatabase.shared();
      final byPing = await PingPhotoDao(db).byPingIds(ids);
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          _photoCache[id] = byPing[id] ?? const <PingPhoto>[];
        }
      });
    } finally {
      _loadingAll = false;
    }
  }

  /// Walks the next [count] fixes after [from] and pushes their
  /// thumbnail URLs into Flutter's image cache so the slide renders
  /// instantly when the cursor reaches them. Cheap dedupe via
  /// `_precached`; only HTTP URLs get precached (file:// loads from
  /// disk fast enough that the warmup isn't worth the I/O).
  void _scheduleLookahead(Ping from) {
    final idx = widget.visibleFixes.indexOf(from);
    if (idx < 0) return;
    const lookahead = 5;
    final end = (idx + 1 + lookahead).clamp(0, widget.visibleFixes.length);
    for (var i = idx + 1; i < end; i++) {
      final p = widget.visibleFixes[i];
      final photo = pickPhotoForPing(p, widget.visibleFixes, _photoCache);
      if (photo == null) continue;
      final url = photo.thumbUri ?? photo.uri;
      if (!url.startsWith('http')) continue;
      if (_precached.contains(url)) continue;
      _precached.add(url);
      // Fire-and-forget — failures here will surface naturally when the
      // user reaches the frame; they're handled by `_onImageError`.
      precacheImage(
        CachedNetworkImageProvider(url),
        context,
        onError: (_, __) {
          FailedPhotoUris.register(url);
        },
      );
    }
  }

  void _onImageError(String url) {
    FailedPhotoUris.register(url);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hasAnyFixes || widget.visibleFixes.isEmpty) {
      return const _CenteredMessage(
        icon: Icons.image_outlined,
        text: 'No pings to show in slideshow mode.',
      );
    }
    final ping = pickSlideshowPing(widget.visibleFixes, widget.sliderMax);
    if (ping == null) {
      return const _CenteredMessage(
        icon: Icons.image_outlined,
        text: 'No fix yet at this point in the trail.',
      );
    }
    final photo = pickPhotoForPing(ping, widget.visibleFixes, _photoCache);
    if (photo == null) {
      return _CenteredMessage(
        icon: Icons.image_search_outlined,
        text: 'No photos for ${_fmtTime(ping.timestampUtc.toLocal())} — '
            'turn on auto-fetch or run the backfill from Settings.',
      );
    }
    // Prefetch a sliding window of upcoming frames. Scheduled in a
    // post-frame callback so the precacheImage calls don't fight the
    // current frame's layout work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleLookahead(ping);
    });
    return _SlidePage(
      photo: photo,
      ping: ping,
      onImageError: _onImageError,
    );
  }

  static String _fmtTime(DateTime t) => DateFormat('MMM d, HH:mm').format(t);
}

class _SlidePage extends StatelessWidget {
  final PingPhoto photo;
  final Ping ping;
  final ValueChanged<String> onImageError;
  const _SlidePage({
    required this.photo,
    required this.ping,
    required this.onImageError,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('MMM d, yyyy · HH:mm');
    final uri = photo.thumbUri ?? photo.uri;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: scheme.surface),
        _buildImage(uri, scheme),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmt.format(ping.timestampUtc.toLocal()),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (photo.attribution.isNotEmpty)
                        Text(
                          photo.attribution,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                if (photo.license.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      photo.license,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImage(String uri, ColorScheme scheme) {
    if (uri.startsWith('file://')) {
      return Image.asset(
        uri.replaceFirst('file://', ''),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) {
          // Local file failed (rare, but image_picker temp paths can
          // disappear if the OS cleans the temp dir). Register + show
          // an empty surface — the next slider tick will skip it.
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => onImageError(uri));
          return _placeholder(scheme);
        },
      );
    }
    if (uri.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: uri,
        fit: BoxFit.cover,
        // No spinner: at 0.25× a half-second of CircularProgressIndicator
        // on every frame is more visually jarring than a brief surface
        // flash while the next frame's prefetched bytes paint.
        placeholder: (_, __) => Container(color: scheme.surface),
        errorWidget: (_, __, ___) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => onImageError(uri));
          return _placeholder(scheme);
        },
      );
    }
    return _placeholder(scheme);
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined,
            size: 56, color: scheme.onSurfaceVariant),
      );
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String text;
  const _CenteredMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  )),
        ],
      ),
    );
  }
}

// ─── Pure helpers (exported for tests) ─────────────────────────────────

/// Returns the latest ping in [visibleFixes] at-or-before [sliderMax],
/// or null if every fix is after the slider. Mirrors the same logic
/// the map view's annotation pass uses to decide which fixes are
/// rendered — keeps the slideshow + map in lock-step under scrub.
Ping? pickSlideshowPing(List<Ping> visibleFixes, DateTime sliderMax) {
  if (visibleFixes.isEmpty) return null;
  Ping? best;
  for (final p in visibleFixes) {
    if (p.timestampUtc.isAfter(sliderMax)) break;
    best = p;
  }
  return best;
}

/// Resolves the photo to render for the current slideshow page.
///
/// Search order, all filtering out URIs in [FailedPhotoUris]:
///   1. The current ping's own photo list, in `ordinal` order.
///   2. Earlier pings in [visibleFixes], walked backward — the first
///      one that has a renderable photo wins.
///
/// This is why we store the full per-ping photo list in `_photoCache`
/// (vs the first-only approach in 0.13.3): when ping P has 5 photos
/// and photos[0]'s URL has failed, we want to fall back to photos[1]
/// before walking to an earlier ping.
PingPhoto? pickPhotoForPing(
  Ping current,
  List<Ping> visibleFixes,
  Map<int, List<PingPhoto>> photosByPing,
) {
  PingPhoto? firstGood(List<PingPhoto> list) {
    for (final p in list) {
      final uri = p.thumbUri ?? p.uri;
      if (!FailedPhotoUris.isFailed(uri) &&
          !FailedPhotoUris.isFailed(p.uri)) {
        return p;
      }
    }
    return null;
  }

  final idx = visibleFixes.indexOf(current);
  if (idx < 0) {
    if (current.id == null) return null;
    return firstGood(photosByPing[current.id!] ?? const <PingPhoto>[]);
  }
  for (var i = idx; i >= 0; i--) {
    final p = visibleFixes[i];
    final id = p.id;
    if (id == null) continue;
    final hit = firstGood(photosByPing[id] ?? const <PingPhoto>[]);
    if (hit != null) return hit;
  }
  return null;
}
