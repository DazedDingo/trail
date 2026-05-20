import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping.dart';
import '../models/ping_photo.dart';
import '../services/failed_photo_uris.dart';
import '../services/online_photo_service.dart';

/// Tighter than the Wikimedia thumb-URL default (320 today, 512 for
/// pre-0.13.4 cached rows) means every frame stays under ~80 KB and
/// decodes in single-digit ms even on a Pixel 5.
const int _kSlideshowThumbWidth = 320;

/// Number of upcoming frames to push into the image cache eagerly.
/// 20 is the sweet spot for 16× playback on a 4 h cadence: at the
/// fastest speed the slider advances ~one frame per 22 ms, so we need
/// a healthy buffer of decoded bytes to stay ahead of paint. Bigger
/// values would warm the cache further but Wikimedia's CDN serializes
/// HTTP/2 streams to the same host, so beyond ~20 in-flight there's
/// no further gain.
const int _kPrefetchLookahead = 20;

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

  /// True once `_prefetchVisibleWindow` has finished its single DB
  /// read. Used to disambiguate "still loading" from "no photos here".
  bool _cacheLoaded = false;
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
      _cacheLoaded = false;
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
      if (ids.isEmpty) {
        if (mounted) setState(() => _cacheLoaded = true);
        return;
      }
      final db = await TrailDatabase.shared();
      final byPing = await PingPhotoDao(db).byPingIds(ids);
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          _photoCache[id] = byPing[id] ?? const <PingPhoto>[];
        }
        _cacheLoaded = true;
      });
      // Eagerly warm the first chunk so the very first slideshow frame
      // doesn't pay the network round-trip — that's the slowest
      // perceived frame for the user (everything else benefits from
      // the rolling lookahead).
      _warmFirstFrames();
    } finally {
      _loadingAll = false;
    }
  }

  void _warmFirstFrames() {
    final cap = widget.visibleFixes.length < _kPrefetchLookahead
        ? widget.visibleFixes.length
        : _kPrefetchLookahead;
    for (var i = 0; i < cap; i++) {
      _precacheForPing(widget.visibleFixes[i]);
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
    final end = (idx + 1 + _kPrefetchLookahead)
        .clamp(0, widget.visibleFixes.length);
    for (var i = idx + 1; i < end; i++) {
      _precacheForPing(widget.visibleFixes[i]);
    }
  }

  void _precacheForPing(Ping p) {
    final photo = pickPhotoForPing(p, widget.visibleFixes, _photoCache);
    if (photo == null) return;
    final url = renderableUriFor(photo);
    if (!url.startsWith('http')) return;
    if (_precached.contains(url)) return;
    _precached.add(url);
    // **Pre-decode at the render target width.** The slideshow renders
    // via `CachedNetworkImage(memCacheWidth: 320)`, which internally
    // resizes during decode and stores in the image cache under a
    // `(url, 320)` key. If we precache a *plain* `CachedNetworkImageProvider`,
    // the bytes land on disk but the cache entry is keyed on the full-
    // size decode — so the actual slideshow render gets a cache miss
    // on the 320-wide key and re-decodes from disk on every frame. At
    // 1× playback that re-decode hit is what makes the frame stutter.
    //
    // Wrapping in `ResizeImage` here matches the render's decode key,
    // so the precache fills the same bucket the render reads from —
    // a true zero-work paint when the cursor reaches that frame.
    final provider = ResizeImage(
      CachedNetworkImageProvider(url),
      width: _kSlideshowThumbWidth,
    );
    precacheImage(
      provider,
      context,
      onError: (_, __) {
        FailedPhotoUris.register(url);
        if (mounted) setState(() {});
      },
    );
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
    if (!_cacheLoaded) {
      return const _CenteredMessage(
        icon: Icons.hourglass_top_outlined,
        text: 'Loading photos…',
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
      return _emptyState(ping);
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

  Widget _emptyState(Ping ping) {
    // Disambiguate the "no usable photo" branches so the message tells
    // the truth: a "run the backfill" hint after backfill has already
    // run is misleading.
    final ts = _fmtTime(ping.timestampUtc.toLocal());
    final reason = classifyEmptyState(widget.visibleFixes, _photoCache);
    switch (reason) {
      case EmptySlideshowReason.allFailed:
        return _CenteredMessage(
          icon: Icons.broken_image_outlined,
          text: 'Photos for $ts exist but failed to load.\n'
              'Settings → Retry broken photos to re-attempt them.',
        );
      case EmptySlideshowReason.noPhotosFetched:
        return _CenteredMessage(
          icon: Icons.image_search_outlined,
          text: 'No photos for $ts — turn on auto-fetch or run the '
              'backfill from Settings.',
        );
    }
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
    final uri = renderableUriFor(photo);
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
        // memCacheWidth resizes during decode so a 320 px image isn't
        // held in RAM at its full size. Reduces image cache pressure
        // when the slideshow scrubs through dozens of frames quickly.
        memCacheWidth: _kSlideshowThumbWidth,
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

  /// Surface-only placeholder for the one-frame moment between an
  /// image failing to load and the next slider tick swapping to a
  /// different photo. The user used to see a big "box with mountains"
  /// icon here for every transient failure; that flashing icon
  /// dominated the slideshow at faster playback speeds even though
  /// the picker is already skipping the failed URL on the very next
  /// frame. Clean surface flash is invisible at 1× and above.
  Widget _placeholder(ColorScheme scheme) =>
      Container(color: scheme.surface);
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

/// Returns the URL the slideshow should hand to its image widget for
/// [photo]. Prefers the thumbnail; rewrites pre-0.13.4 wider thumbs
/// down to the slideshow's target width via [shrinkWikimediaThumbUrl]
/// so existing cached rows don't keep paying for 512 px bytes.
String renderableUriFor(PingPhoto photo) {
  final base = photo.thumbUri ?? photo.uri;
  return shrinkWikimediaThumbUrl(base, targetWidth: _kSlideshowThumbWidth);
}

/// Why the slideshow has nothing to show. Distinguishes "we tried, the
/// URLs all 404'd" from "there's nothing to show because the user
/// hasn't run the backfill or auto-fetch was off" — those are very
/// different actions and the message used to lump them together as a
/// misleading "run the backfill" prompt.
enum EmptySlideshowReason {
  /// At least one ping in the window has photo rows but every one of
  /// them lives in the failed-URL denylist. Solution: clear the
  /// denylist from Settings.
  allFailed,

  /// No ping in the window has any photo rows at all. Solution: run
  /// the backfill or turn on auto-fetch.
  noPhotosFetched,
}

EmptySlideshowReason classifyEmptyState(
  List<Ping> visibleFixes,
  Map<int, List<PingPhoto>> photosByPing,
) {
  for (final p in visibleFixes) {
    if (p.id == null) continue;
    final list = photosByPing[p.id!] ?? const <PingPhoto>[];
    if (list.isNotEmpty) return EmptySlideshowReason.allFailed;
  }
  return EmptySlideshowReason.noPhotosFetched;
}
