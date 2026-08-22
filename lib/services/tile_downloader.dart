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
  /// Streams [url] to `<docs>/tiles/<filename>` and reports progress in
  /// bytes via [onProgress]. Returns the installed region.
  ///
  /// When [filename] is null the name is taken from the response's
  /// `Content-Disposition` header, falling back to the last URL
  /// segment. That matters for the coverage-extract server (Phase C,
  /// `docs/TIMELINE_IMPORT.md` §3), whose download URL is a query
  /// endpoint (`/v1/extract?bbox=…`) with no usable last segment — the
  /// server is the only party that knows the planet date belonging in
  /// the file name, and the `coverage-` prefix is what makes
  /// `inferRoleFromFileName` tag the result as a coverage pack.
  ///
  /// [headers] are set on the request (the extract server needs
  /// `Authorization: Bearer …`); nothing from them is ever logged.
  static Future<TilesRegion> download({
    required Uri url,
    String? filename,
    Map<String, String>? headers,
    void Function(int received, int? total)? onProgress,
    TileDownloadCancelToken? cancelToken,
    HttpClient? httpClient,
  }) async {
    // Validate an explicitly-supplied name before opening a socket, so
    // a caller's typo still fails fast rather than after a 30 MB body.
    if (filename != null) _requireArchiveExtension(filename);
    final client = httpClient ?? HttpClient();
    client.userAgent = 'Trail/0.8 (mbtiles fetch)';
    File? tmp;
    try {
      final req = await client.getUrl(url);
      headers?.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // Drain so the socket is released rather than left half-read.
        try {
          await resp.drain<void>();
        } catch (_) {/* body already gone — nothing to release */}
        throw HttpException(
          'Download failed: HTTP ${resp.statusCode}',
          uri: url,
        );
      }
      final inferredName = filename ??
          filenameFromContentDisposition(
            resp.headers.value('content-disposition'),
          ) ??
          _inferFilename(url);
      _requireArchiveExtension(inferredName);
      final dest = await _destinationFile(inferredName);
      final partial = File('${dest.path}.partial');
      tmp = partial;
      final total = resp.contentLength == -1 ? null : resp.contentLength;
      final sink = partial.openWrite();
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
      await partial.rename(dest.path);
      final stat = await dest.stat();
      return TilesRegion(
        name: _stem(inferredName),
        path: dest.path,
        bytes: stat.size,
      );
    } catch (e) {
      // Clean up partial on any error so the user can retry without a
      // stale `.partial` lying around.
      final partial = tmp;
      if (partial != null && await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {/* swallow — best-effort cleanup */}
      }
      rethrow;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static void _requireArchiveExtension(String name) {
    final lower = name.toLowerCase();
    if (!lower.endsWith('.mbtiles') && !lower.endsWith('.pmtiles')) {
      throw ArgumentError(
        'Filename must end with .mbtiles or .pmtiles (got "$name")',
      );
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

/// Pulls the file name out of a `Content-Disposition` header, e.g.
/// `attachment; filename="coverage-lat+51.38_lon-002.36-z7-14-20260822.pmtiles"`.
/// Returns `null` when the header is absent or carries no usable name.
///
/// Any directory component is stripped — a hostile server must not be
/// able to steer the write outside `<docs>/tiles/`. Top-level and pure
/// so the parsing rules can be unit-tested without a socket.
String? filenameFromContentDisposition(String? header) {
  if (header == null || header.isEmpty) return null;
  String? value;
  // RFC 5987 `filename*=UTF-8''…` wins over the plain form when both
  // are present, which is what servers that emit both intend.
  final ext = RegExp(
    "filename\\*\\s*=\\s*[^']*'[^']*'([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (ext != null) {
    value = Uri.decodeComponent(ext.group(1)!.trim());
  } else {
    final plain = RegExp(
      r'filename\s*=\s*(?:"([^"]*)"|([^;]+))',
      caseSensitive: false,
    ).firstMatch(header);
    if (plain != null) {
      value = (plain.group(1) ?? plain.group(2) ?? '').trim();
    }
  }
  if (value == null) return null;
  // Strip any path the server tried to sneak in, both separators.
  final cleaned = value.split('/').last.split(r'\').last.trim();
  return cleaned.isEmpty ? null : cleaned;
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
