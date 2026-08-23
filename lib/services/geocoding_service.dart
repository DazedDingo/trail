import 'dart:async';
import 'dart:collection';

import 'package:geocoding/geocoding.dart';

import 'bounded_map.dart';
import 'lru_cache.dart';

/// Cache / provider-family key for a reverse-geocode lookup: latitude and
/// longitude rounded to 4 decimal places (~11 m at the equator) and held
/// as exact integers, so two pings whose GPS jitter differs by a few
/// metres compare EQUAL (record equality is field-wise; with raw doubles
/// every ping was its own key and its own platform call). Build one with
/// [geocodeKey]; read the coordinate back with the extension getters.
typedef GeocodeKey = ({int lat4, int lon4});

/// Rounds to the 4-dp grid. `round()` is half-away-from-zero, so the
/// grid is symmetric about zero — `geocodeKey(x, -x)` is always
/// `(k, -k)` — and there is no bias toward one hemisphere.
GeocodeKey geocodeKey(double lat, double lon) =>
    (lat4: (lat * 1e4).round(), lon4: (lon * 1e4).round());

extension GeocodeKeyCoords on GeocodeKey {
  /// Grid-centre latitude (what the provider hands to the geocoder).
  double get lat => lat4 / 1e4;

  /// Grid-centre longitude.
  double get lon => lon4 / 1e4;
}

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
///
/// Caching (0.14.1, PERF_PLAN §3 #2): results are memoised in a bounded
/// LRU keyed on [GeocodeKey], so a list that re-mounts (Home ↔ History ↔
/// Stats) or a second ping at the same spot is a memory hit, not another
/// platform round-trip. Only non-null labels are cached — a `null` is
/// usually "offline right now" and should be retried later. Concurrent
/// lookups for the same key share one in-flight future.
///
/// Concurrency (0.17.5): every platform call goes through one FIFO
/// limiter, so at most [defaultMaxConcurrent] are in flight no matter
/// how many callers are asking. The Places screen watches one label per
/// place at once (300 rows = 300 asks); firing those at the OEM
/// geocoder together produced "Service not Available" storms, and a cap
/// inside `reverseLookupAll` alone couldn't see them. The limiter is
/// per instance, which is app-wide in practice: `geocodingServiceProvider`
/// hands every screen the same service. Cache hits and in-flight
/// dedupe never take a slot — they cost no platform call.
class GeocodingService {
  /// Default LRU size. 512 labels × ~40 bytes is nothing; a household's
  /// distinct 11 m cells over a year is a few hundred.
  static const defaultCacheCapacity = 512;

  /// Upper bound on simultaneous platform calls, both from
  /// [reverseLookupAll] and across every other caller of one service.
  /// Firing 30 at once (the old Top Places burst) produced "Service not
  /// Available" storms on some OEM geocoders; four hides the per-call
  /// latency without tripping them.
  static const defaultMaxConcurrent = 4;

  /// Injection seam for tests. Default calls the real platform geocoder.
  final Future<List<Placemark>> Function(double lat, double lon) _lookup;

  final LruCache<GeocodeKey, String> _cache;
  final _inFlight = <GeocodeKey, Future<String?>>{};

  /// Platform calls allowed in flight at once — see [_withSlot].
  final int _maxConcurrent;

  /// Callers holding a slot right now.
  int _active = 0;

  /// Callers waiting for one, oldest first.
  final _waiting = Queue<Completer<void>>();

  GeocodingService({
    Future<List<Placemark>> Function(double lat, double lon)? lookup,
    int cacheCapacity = defaultCacheCapacity,
    int maxConcurrent = defaultMaxConcurrent,
  })  : _lookup = lookup ?? placemarkFromCoordinates,
        _maxConcurrent = maxConcurrent,
        _cache = LruCache(cacheCapacity),
        assert(maxConcurrent > 0, 'maxConcurrent must be > 0');

  /// Number of labels currently memoised. Diagnostics / tests.
  int get cachedLabels => _cache.length;

  /// Platform calls in flight right now. Diagnostics / tests.
  int get activeLookups => _active;

  /// Callers queued behind the limiter right now. Diagnostics / tests.
  int get queuedLookups => _waiting.length;

  /// Returns a short "Locality, Region" label for ([lat], [lon]), or `null`
  /// if the system geocoder has nothing useful (no cache, no network, or
  /// the coordinates fall in an unnamed area).
  Future<String?> reverseLookup(double lat, double lon) {
    final key = geocodeKey(lat, lon);
    final hit = _cache.get(key);
    if (hit != null) return Future.value(hit);
    return _inFlight[key] ??= _lookupAndCache(key, lat, lon);
  }

  Future<String?> _lookupAndCache(GeocodeKey key, double lat, double lon) async {
    try {
      final marks = await _withSlot(() => _lookup(lat, lon));
      final label = marks.isEmpty ? null : _format(marks.first);
      if (label != null) _cache.put(key, label);
      return label;
    } catch (_) {
      // Platform geocoder throws on "no internet + no cache" — treat as
      // "no label available" rather than propagating.
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// [reverseLookup] over many coordinates. Results are in [coords]
  /// order; each is `null` on the same terms as [reverseLookup].
  ///
  /// The in-flight cap is the service-wide limiter's, which this shares
  /// with every other caller — [maxConcurrent] only lets one batch ask
  /// for something TIGHTER than that (it can never widen it).
  Future<List<String?>> reverseLookupAll(
    List<({double lat, double lon})> coords, {
    int maxConcurrent = defaultMaxConcurrent,
  }) =>
      mapBounded(
        coords,
        (c) => reverseLookup(c.lat, c.lon),
        maxConcurrent: maxConcurrent,
      );

  /// Runs [task] holding one of the [_maxConcurrent] slots, queueing
  /// FIFO when they are all taken.
  ///
  /// A finished task HANDS its slot to the next waiter instead of
  /// releasing it and re-counting: dropping [_active] first would let a
  /// caller arriving in that gap take the same slot the woken waiter
  /// already owns, and the cap would drift up by one per handover.
  Future<T> _withSlot<T>(Future<T> Function() task) async {
    if (_active >= _maxConcurrent) {
      final gate = Completer<void>();
      _waiting.add(gate);
      await gate.future; // resumes owning a slot
    } else {
      _active++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
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
