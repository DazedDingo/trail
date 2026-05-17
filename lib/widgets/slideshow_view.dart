import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../db/ping_photo_dao.dart';
import '../models/ping.dart';
import '../models/ping_photo.dart';

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
  /// `ping.id → first photo` cache. Built lazily as the slideshow
  /// scrubs into new pings — we don't pre-fetch every photo on entry
  /// because the trail might span months.
  final Map<int, PingPhoto?> _photoCache = {};
  bool _loadingAll = false;

  @override
  void initState() {
    super.initState();
    _prefetchVisibleWindow();
  }

  @override
  void didUpdateWidget(SlideshowView old) {
    super.didUpdateWidget(old);
    // visibleFixes changes on filter / data refresh; refresh the cache
    // so we don't render a stale "photo for an archived ping" frame.
    if (old.visibleFixes != widget.visibleFixes) {
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
          final list = byPing[id];
          _photoCache[id] = (list == null || list.isEmpty) ? null : list.first;
        }
      });
    } finally {
      _loadingAll = false;
    }
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
    return _SlidePage(photo: photo, ping: ping);
  }

  static String _fmtTime(DateTime t) =>
      DateFormat('MMM d, HH:mm').format(t);
}

class _SlidePage extends StatelessWidget {
  final PingPhoto photo;
  final Ping ping;
  const _SlidePage({required this.photo, required this.ping});

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
        errorBuilder: (_, __, ___) => _placeholder(scheme),
      );
    }
    if (uri.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: uri,
        fit: BoxFit.cover,
        placeholder: (_, __) =>
            const Center(child: CircularProgressIndicator()),
        errorWidget: (_, __, ___) => _placeholder(scheme),
      );
    }
    return _placeholder(scheme);
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined,
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
/// Prefers the picked ping's own photo; if it has none, walks back
/// through earlier visible pings looking for one — so the slideshow
/// never blanks out mid-trail just because one fix had no photo.
PingPhoto? pickPhotoForPing(
  Ping current,
  List<Ping> visibleFixes,
  Map<int, PingPhoto?> photoCache,
) {
  // Walk from current backwards through visibleFixes; return the first
  // ping we hit that has a cached photo.
  final idx = visibleFixes.indexOf(current);
  if (idx < 0) {
    final own = current.id == null ? null : photoCache[current.id!];
    return own;
  }
  for (var i = idx; i >= 0; i--) {
    final p = visibleFixes[i];
    final id = p.id;
    if (id == null) continue;
    final photo = photoCache[id];
    if (photo != null) return photo;
  }
  return null;
}
