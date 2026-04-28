import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mbtiles_service.dart';

/// Streams an `.mbtiles` file from `url` into the app's tiles dir,
/// reporting progress and returning the resulting [TilesRegion] when
/// the download completes. Used by the Regions screen's
/// "Download from URL" action and the curated-catalog browser.
///
/// Cancellation: callers can pass [cancelToken]; flipping
/// `cancelToken.isCancelled = true` will close the underlying socket
/// at the next chunk and the future completes with a
/// [TileDownloadCancelled].
class TileDownloader {
  /// Streams [url] to `<docs>/tiles/<filename>` (filename inferred
  /// from the URL when [filename] is null) and reports progress in
  /// bytes via [onProgress]. Returns the installed region.
  static Future<TilesRegion> download({
    required Uri url,
    String? filename,
    void Function(int received, int? total)? onProgress,
    TileDownloadCancelToken? cancelToken,
    HttpClient? httpClient,
  }) async {
    final client = httpClient ?? HttpClient();
    client.userAgent = 'Trail/0.8 (mbtiles fetch)';
    final inferredName = filename ?? _inferFilename(url);
    final lower = inferredName.toLowerCase();
    if (!lower.endsWith('.mbtiles') && !lower.endsWith('.pmtiles')) {
      throw ArgumentError(
        'Filename must end with .mbtiles or .pmtiles (got "$inferredName")',
      );
    }
    final dest = await _destinationFile(inferredName);
    final tmp = File('${dest.path}.partial');
    try {
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException(
          'Download failed: HTTP ${resp.statusCode}',
          uri: url,
        );
      }
      final total = resp.contentLength == -1 ? null : resp.contentLength;
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          if (cancelToken?.isCancelled ?? false) {
            throw const TileDownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // Atomic rename so a half-written file never gets picked up by
      // listInstalled if the user kills the app mid-download.
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
      final stat = await dest.stat();
      return TilesRegion(
        name: _stem(inferredName),
        path: dest.path,
        bytes: stat.size,
      );
    } catch (e) {
      // Clean up partial on any error so the user can retry without a
      // stale `.partial` lying around.
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {/* swallow — best-effort cleanup */}
      }
      rethrow;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static Future<File> _destinationFile(String filename) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'tiles'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, filename));
  }

  static String _inferFilename(Uri url) {
    final segments = url.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return 'region.mbtiles';
    final last = segments.last;
    if (last.endsWith('.mbtiles') || last.endsWith('.pmtiles')) return last;
    return '$last.mbtiles';
  }

  static String _stem(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? filename : filename.substring(0, dot);
  }
}

/// Caller-flippable flag to abort an in-flight download.
class TileDownloadCancelToken {
  bool isCancelled = false;
}

class TileDownloadCancelled implements Exception {
  const TileDownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}
