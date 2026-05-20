import 'dart:convert';

import 'package:http/http.dart' as http;

/// One photo discovered near a ping. Lat/lon match the source (not the
/// ping) — the gallery UI uses the distance to mark "this photo was
/// taken N m from your pin" so users understand the source's accuracy.
class FetchedOnlinePhoto {
  final String uri;
  final String? thumbUri;
  final String attribution;
  final String license;
  final double distanceMeters;

  const FetchedOnlinePhoto({
    required this.uri,
    this.thumbUri,
    required this.attribution,
    required this.license,
    required this.distanceMeters,
  });
}

/// Wikimedia Commons GeoSearch → ImageInfo lookup for the auto-photo
/// feature (#6, schema v2). Free, no API key, CC-BY-SA 4.0 photos.
///
/// Two-hop API:
///   1. `list=geosearch&gsnamespace=6` returns the titles of geotagged
///      File: pages within radius of (lat, lon).
///   2. `prop=imageinfo&iiprop=url|extmetadata&titles=…` returns the
///      resolvable image URL + attribution + license per title.
///
/// Privacy note: this leaks the caller's (lat, lon) to Wikimedia. Per
/// the Settings toggle the user opts into this — we never call this
/// service without a positive `autoPhotosEnabled` check upstream.
class OnlinePhotoService {
  /// Base endpoint — overridable for tests (the unit tests inject a
  /// `MockClient` that responds with canned JSON, so the test never
  /// hits the real Wikimedia infra).
  final Uri endpoint;
  final http.Client client;
  final Duration timeout;

  OnlinePhotoService({
    Uri? endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  })  : endpoint =
            endpoint ?? Uri.parse('https://commons.wikimedia.org/w/api.php'),
        client = client ?? http.Client();

  /// Returns up to [limit] geotagged photos within [radiusMeters] of
  /// `(lat, lon)`. Empty list on any failure path (network drop, parse
  /// error, no results) — caller treats absence as "no photos this time".
  Future<List<FetchedOnlinePhoto>> fetchNearby({
    required double lat,
    required double lon,
    int radiusMeters = 500,
    int limit = 5,
  }) async {
    if (limit <= 0) return const [];
    try {
      final titles = await _geoSearch(lat, lon, radiusMeters, limit);
      if (titles.isEmpty) return const [];
      return await _resolveImageInfo(titles);
    } catch (_) {
      return const [];
    }
  }

  Future<List<GeoSearchHit>> _geoSearch(
    double lat,
    double lon,
    int radius,
    int limit,
  ) async {
    final uri = endpoint.replace(queryParameters: {
      'action': 'query',
      'list': 'geosearch',
      'gsnamespace': '6', // File: namespace
      'gsradius': radius.clamp(10, 10000).toString(),
      'gscoord': '$lat|$lon',
      'gslimit': limit.clamp(1, 50).toString(),
      'format': 'json',
      'origin': '*',
    });
    final res = await client.get(uri).timeout(timeout);
    if (res.statusCode != 200) return const [];
    return parseGeoSearch(res.body);
  }

  Future<List<FetchedOnlinePhoto>> _resolveImageInfo(
    List<GeoSearchHit> hits,
  ) async {
    final titles = hits.map((h) => h.title).join('|');
    final uri = endpoint.replace(queryParameters: {
      'action': 'query',
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata',
      'iiurlwidth': '512',
      'titles': titles,
      'format': 'json',
      'origin': '*',
    });
    final res = await client.get(uri).timeout(timeout);
    if (res.statusCode != 200) return const [];
    final byTitle = parseImageInfoByTitle(res.body);
    final out = <FetchedOnlinePhoto>[];
    for (final hit in hits) {
      final info = byTitle[hit.title];
      if (info == null) continue;
      out.add(FetchedOnlinePhoto(
        uri: info.url,
        thumbUri: info.thumbUrl,
        attribution: info.attribution,
        license: info.license,
        distanceMeters: hit.distanceMeters,
      ));
    }
    return out;
  }
}

// ─── Pure parsers (exported for unit testing without network) ────────

/// One GeoSearch hit — intermediate shape between the two API hops.
/// Exposed (rather than file-private) so the pure parser can be hit
/// from unit tests; production callers ignore this and consume
/// [FetchedOnlinePhoto] after imageinfo resolution.
class GeoSearchHit {
  final String title;
  final double distanceMeters;
  const GeoSearchHit({required this.title, required this.distanceMeters});
}

/// Image file extensions Flutter's `Image.network` can decode out of
/// the box. Whitelist applied at parse time so non-image File:
/// entries — OGG audio, PDFs, MP4 video, TIFF, SVG (which Flutter
/// can't render natively) — never reach the DB. The 0.13.0 release
/// was missing this guard; lots of pins ended up with broken-image
/// placeholders because GeoSearch returns every File: namespace
/// entry within radius, not just photos.
///
/// SVG is excluded deliberately even though Wikimedia generates raster
/// thumbnails for SVG sources — we'd need `flutter_svg` to render the
/// originals if `thumburl` were ever absent, and the simpler "match
/// the URL's extension" rule is honest about what we can render.
const _kImageSuffixes = {'.jpg', '.jpeg', '.png', '.gif', '.webp'};

/// True when [uriOrTitle]'s lowercase trailing dot-suffix matches one
/// of [_kImageSuffixes]. Tolerant: empty strings, missing dots, and
/// query-string trailers all return false. Exported for the DAO's
/// read-time tombstone filter (see `PingPhotoDao.byPingId`).
bool isLikelyImage(String uriOrTitle) {
  final cleaned = uriOrTitle.split('?').first.split('#').first.toLowerCase();
  final dot = cleaned.lastIndexOf('.');
  if (dot < 0) return false;
  final suffix = cleaned.substring(dot);
  return _kImageSuffixes.contains(suffix);
}

/// Parses the GeoSearch JSON envelope. Tolerant — missing fields,
/// non-File: titles, and non-image media (audio/video/PDF/SVG) drop
/// out silently.
List<GeoSearchHit> parseGeoSearch(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (json is! Map) return const [];
  final query = json['query'];
  if (query is! Map) return const [];
  final list = query['geosearch'];
  if (list is! List) return const [];
  final out = <GeoSearchHit>[];
  for (final row in list) {
    if (row is! Map) continue;
    final title = row['title'];
    if (title is! String || !title.startsWith('File:')) continue;
    if (!isLikelyImage(title)) continue; // drop OGG/PDF/MP4/etc.
    final dist = (row['dist'] is num)
        ? (row['dist'] as num).toDouble()
        : 0.0;
    out.add(GeoSearchHit(title: title, distanceMeters: dist));
  }
  return out;
}

/// One imageinfo result — full url + thumbnail + attribution + license.
class ImageInfoEntry {
  final String url;
  final String? thumbUrl;
  final String attribution;
  final String license;
  const ImageInfoEntry({
    required this.url,
    this.thumbUrl,
    required this.attribution,
    required this.license,
  });
}

/// Parses the imageinfo JSON envelope into a map keyed by full title
/// (`"File:Foo.jpg"`). Tolerant — pages without imageinfo or extmetadata
/// drop out silently.
Map<String, ImageInfoEntry> parseImageInfoByTitle(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return const {};
  }
  if (json is! Map) return const {};
  final query = json['query'];
  if (query is! Map) return const {};
  final pages = query['pages'];
  if (pages is! Map) return const {};
  final out = <String, ImageInfoEntry>{};
  for (final entry in pages.values) {
    if (entry is! Map) continue;
    final title = entry['title'];
    if (title is! String) continue;
    final infoList = entry['imageinfo'];
    if (infoList is! List || infoList.isEmpty) continue;
    final info = infoList.first;
    if (info is! Map) continue;
    final url = info['url'];
    if (url is! String || url.isEmpty) continue;
    // Defense-in-depth — `parseGeoSearch` already dropped non-image
    // titles, but a future caller that wires `prop=imageinfo` against
    // a different title source (search, transclusions, etc.) would
    // bypass that. Re-check on the URL itself; if the thumbnail is a
    // raster we accept the row even if the source extension isn't on
    // the whitelist (Wikimedia rasters SVGs into PNG thumbs).
    final thumbUrl = info['thumburl'];
    final thumbIsImage = thumbUrl is String &&
        thumbUrl.isNotEmpty &&
        isLikelyImage(thumbUrl);
    if (!isLikelyImage(url) && !thumbIsImage) continue;
    final ext = info['extmetadata'];
    String attribution = '';
    String license = '';
    if (ext is Map) {
      final artist = ext['Artist'];
      if (artist is Map && artist['value'] is String) {
        attribution = _stripHtml(artist['value'] as String);
      }
      final licenseShort = ext['LicenseShortName'];
      if (licenseShort is Map && licenseShort['value'] is String) {
        license = licenseShort['value'] as String;
      }
    }
    out[title] = ImageInfoEntry(
      url: url,
      thumbUrl: thumbUrl is String && thumbUrl.isNotEmpty ? thumbUrl : null,
      attribution: attribution,
      license: license,
    );
  }
  return out;
}

/// Bare-bones HTML stripper for the `Artist` extmetadata field. The
/// API returns wikitext-rendered HTML like
/// `<a href="..." title="...">Jane Doe</a>` — we want just the visible
/// text for a chip caption. A regex is sufficient here; we never render
/// untrusted HTML, and the surface is decorative not authoritative.
String _stripHtml(String html) {
  final noTags = html.replaceAll(RegExp(r'<[^>]*>'), '');
  // Collapse whitespace + decode the two HTML entities that show up
  // in practice (`&amp;` from band names, `&quot;` from titles).
  return noTags
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
