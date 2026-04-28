import 'dart:convert';
import 'dart:io';

/// Curated MBTiles regions the user can install with one tap.
///
/// The catalog JSON lives at [_catalogUrl] (currently
/// `docs/tilesets.json` in this repo, served via raw.githubusercontent
/// so we can update it independently of app releases). Schema:
///
/// ```json
/// {
///   "version": 1,
///   "regions": [
///     {
///       "id": "uk-z13",
///       "name": "Great Britain (z13)",
///       "description": "All of GB at zoom 13...",
///       "url": "https://github.com/.../releases/download/.../gb-z13.mbtiles",
///       "sizeBytes": 573161472
///     }
///   ]
/// }
/// ```
class TileCatalog {
  static const _catalogUrl =
      'https://raw.githubusercontent.com/DazedDingo/trail/main/'
      'docs/tilesets.json';

  /// Fetches the curated catalog. Returns an empty list when the URL
  /// is unreachable or the JSON is malformed — the regions screen
  /// renders that as "No regions in the catalog yet" rather than an
  /// error card, since either case is functionally the same to the
  /// user.
  static Future<List<TilesetEntry>> fetch({HttpClient? httpClient}) async {
    final client = httpClient ?? HttpClient();
    client.userAgent = 'Trail/0.8 (catalog fetch)';
    try {
      final req = await client
          .getUrl(Uri.parse(_catalogUrl))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return const [];
      final body =
          await resp.transform(utf8.decoder).join().timeout(
                const Duration(seconds: 10),
              );
      final root = jsonDecode(body);
      if (root is! Map<String, dynamic>) return const [];
      final regions = root['regions'];
      if (regions is! List) return const [];
      return regions
          .whereType<Map<String, dynamic>>()
          .map(TilesetEntry._fromJson)
          .whereType<TilesetEntry>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

class TilesetEntry {
  final String id;
  final String name;
  final String description;
  final Uri url;
  final int sizeBytes;

  const TilesetEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
    required this.sizeBytes,
  });

  static TilesetEntry? _fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    final description = j['description'];
    final urlStr = j['url'];
    final sizeBytes = j['sizeBytes'];
    if (id is! String ||
        name is! String ||
        description is! String ||
        urlStr is! String) {
      return null;
    }
    final url = Uri.tryParse(urlStr);
    if (url == null) return null;
    return TilesetEntry(
      id: id,
      name: name,
      description: description,
      url: url,
      sizeBytes: sizeBytes is int ? sizeBytes : 0,
    );
  }
}
