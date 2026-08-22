import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trail/services/local_tile_server.dart';
import 'package:trail/services/memory_pressure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image cache caps (PERF_PLAN §3 #5)', () {
    test('120 MB / 1 000 entries', () {
      expect(kImageCacheMaxBytes, 120 * 1024 * 1024);
      expect(kImageCacheMaxEntries, 1000);
    });

    test('cap still holds the 0.13.10 slideshow warm-up with headroom', () {
      // 100 eager frames (`_kEagerWarmFrames`) + 20 rolling lookahead
      // (`_kPrefetchLookahead`), every one a worst-case portrait decode.
      const warmUpAndLookahead = 100 + 20;
      expect(
        kImageCacheMaxBytes,
        greaterThanOrEqualTo(
          warmUpAndLookahead * kSlideshowFrameWorstCaseBytes,
        ),
      );
      // …and a full month of 4 h-cadence thumbnails.
      const monthOfPings = 31 * 6;
      expect(
        kImageCacheMaxBytes,
        greaterThanOrEqualTo(monthOfPings * kSlideshowFrameWorstCaseBytes),
      );
      expect(kImageCacheMaxEntries, greaterThanOrEqualTo(monthOfPings));
    });

    test('configureImageCache applies the caps', () {
      configureImageCache();
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.maximumSize, kImageCacheMaxEntries);
      expect(cache.maximumSizeBytes, kImageCacheMaxBytes);
    });
  });

  group('memory pressure', () {
    ImageStreamCompleter pendingImage() =>
        OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

    test('releaseMemoryCaches drops the tile cache + image cache', () {
      final server = LocalTileServer.instance;
      server.tileCache.put('14/1/1', List<int>.filled(512, 1));
      final cache = PaintingBinding.instance.imageCache;
      cache.putIfAbsent(Object(), pendingImage);
      expect(server.tileCache.bytes, 512);
      expect(cache.pendingImageCount, 1);

      releaseMemoryCaches();

      expect(server.tileCache.bytes, 0);
      expect(cache.pendingImageCount, 0);
      expect(cache.currentSize, 0);
      expect(cache.liveImageCount, 0);
    });

    testWidgets(
        'the platform memoryPressure message reaches MemoryPressureObserver',
        (tester) async {
      final observer = MemoryPressureObserver();
      tester.binding.addObserver(observer);
      addTearDown(() => tester.binding.removeObserver(observer));
      final server = LocalTileServer.instance;
      server.tileCache.put('14/2/2', List<int>.filled(256, 1));
      expect(server.tileCache.bytes, 256);

      // Same wire format Android's `onTrimMemory` hook sends.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.system.name,
        SystemChannels.system.codec.encodeMessage(<String, dynamic>{
          'type': 'memoryPressure',
        }),
        (_) {},
      );

      expect(server.tileCache.bytes, 0);
    });
  });
}
