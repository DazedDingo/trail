import 'package:flutter/widgets.dart';

import 'local_tile_server.dart';

/// Image-cache caps applied by `main()` (docs/PERF_PLAN.md §3 #5).
///
/// Flutter's defaults are 1 000 entries / 100 MB. 0.13.10 raised them to
/// 5 000 / 250 MB for slideshow scrubbing — which, stacked on MapLibre's
/// native tile cache and a 50 MB Dart-heap tile cache, made Trail the
/// top OOM-kill / background-eviction candidate on a mid-range phone.
///
/// 120 MB is sized against the slideshow's own numbers: every frame is
/// decoded at 320 px (`memCacheWidth` / `ResizeImage`), so the worst
/// case is a 2:3 portrait at 320 × 480 × 4 B ≈ 600 KB and a typical
/// 4:3 landscape ≈ 300 KB. The 0.13.10 eager warm-up (100 frames) plus
/// the 20-frame rolling lookahead is therefore ≤ 72 MB even if every
/// frame is portrait, and a full month of 4 h-cadence thumbnails
/// (~180) is 55 MB worst case — both fit with headroom, so 0.13.10's
/// "no gray re-loads when scrubbing backward" is preserved. 1 000
/// entries is the framework default and ~3× the warm-up.
const int kImageCacheMaxEntries = 1000;
const int kImageCacheMaxBytes = 120 * 1024 * 1024;

/// Worst-case decoded size of one 320 px slideshow frame (2:3 portrait,
/// RGBA). Exported so a test can pin "the cap still holds the warm-up".
const int kSlideshowFrameWorstCaseBytes = 320 * 480 * 4;

/// Applies [kImageCacheMaxEntries] / [kImageCacheMaxBytes] to the
/// process-wide [ImageCache]. Sync and cheap; runs before `runApp`.
void configureImageCache() {
  PaintingBinding.instance.imageCache
    ..maximumSize = kImageCacheMaxEntries
    ..maximumSizeBytes = kImageCacheMaxBytes;
}

/// Drops every in-process cache Trail can rebuild on demand:
///   - the tile server's Dart-heap tile LRU (misses fall through to
///     the MBTiles SQLite read — invisible to the user);
///   - the decoded-image cache, including the "live" references the
///     framework keeps for images currently painted, so a scrub that
///     moves away from them frees the bitmaps immediately.
///
/// Note that the framework already calls `imageCache.clear()` (and
/// `rootBundle.clear()`) from `PaintingBinding.handleMemoryPressure`
/// before observers run; the explicit call here is cheap and keeps
/// this function a complete, self-describing "release everything"
/// for direct callers.
void releaseMemoryCaches() {
  LocalTileServer.instance.clearTileCache();
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
}

/// Registered once by `main()`. Android delivers `onTrimMemory` as the
/// `memoryPressure` system message, which the bindings fan out to
/// [WidgetsBindingObserver.didHaveMemoryPressure].
class MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => releaseMemoryCaches();
}
