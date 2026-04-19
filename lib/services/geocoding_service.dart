import 'package:geocoding/geocoding.dart';

/// Thin, testable wrapper around `geocoding.placemarkFromCoordinates`.
///
/// Reverse geocoding on Android uses the system Geocoder, which may or may
/// not succeed depending on whether the OEM has cached geocoder data and
/// the current network state. Trail is offline-first, so every call path
/// has to treat a missing result as normal — never as an error.
///
/// The service returns a short human-readable label ("Cambridge, MA" /
/// "Inverness, Scotland") rather than the full Placemark, so callers don't
/// have to care which subfield was populated. `null` means "no label
/// available right now" — render the raw coordinates only.
class GeocodingService {
  /// Injection seam for tests. Default calls the real platform geocoder.
  final Future<List<Placemark>> Function(double lat, double lon) _lookup;

  GeocodingService({
    Future<List<Placemark>> Function(double lat, double lon)? lookup,
  }) : _lookup = lookup ?? placemarkFromCoordinates;

  /// Returns a short "Locality, Region" label for ([lat], [lon]), or `null`
  /// if the system geocoder has nothing useful (no cache, no network, or
  /// the coordinates fall in an unnamed area).
  Future<String?> reverseLookup(double lat, double lon) async {
    try {
      final marks = await _lookup(lat, lon);
      if (marks.isEmpty) return null;
      return _format(marks.first);
    } catch (_) {
      // Platform geocoder throws on "no internet + no cache" — treat as
      // "no label available" rather than propagating.
      return null;
    }
  }

  /// Picks the most location-specific pair of fields available. Prefers
  /// `locality + administrativeArea` (city + state/region); falls back
  /// through subAdministrativeArea and country so remote coordinates still
  /// get *some* label rather than nothing.
  static String? _format(Placemark p) {
    final primary = _firstNonBlank([p.locality, p.subLocality, p.subAdministrativeArea]);
    final region = _firstNonBlank([p.administrativeArea, p.country]);
    if (primary != null && region != null && primary != region) {
      return '$primary, $region';
    }
    return primary ?? region;
  }

  static String? _firstNonBlank(List<String?> candidates) {
    for (final c in candidates) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }
}
