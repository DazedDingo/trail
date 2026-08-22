import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/stats/stats_service.dart';
import 'pings_provider.dart';

/// One row in the deduped Top Places leaderboard.
class RankedPlace {
  final double lat;
  final double lon;
  final int count;

  /// Reverse-geocoded label (e.g. "Bristol, England"); `null` when
  /// the system geocoder has nothing — render the raw coords in that
  /// case.
  final String? label;

  const RankedPlace({
    required this.lat,
    required this.lon,
    required this.count,
    this.label,
  });
}

/// Top 10 places by visit count, **deduplicated by reverse-geocoded
/// label**. The raw bucketing in [StatsService.topPlaces] groups on a
/// 1 km grid which is finer than the geocoder's locality resolution,
/// so a city like Bristol or Cambridge typically spans 5–15 buckets
/// that all reverse-geocode to the same string. This provider:
///
///   1. Over-fetches 30 raw buckets (so the post-dedupe list still
///      has enough rows to fill 10 leaderboard slots).
///   2. Reverse-geocodes them with at most 4 platform calls in flight.
///   3. Merges buckets sharing a label — sums counts, keeps the
///      centroid of the largest contributing bucket so the "open
///      this place on the map" affordance still lands somewhere
///      sensible inside the city.
///   4. Buckets with no label (no-internet + no cached geocoder) are
///      kept unmerged — coords are unique enough not to look
///      duplicated to the user.
///
/// Re-evaluated whenever [allPingsProvider] invalidates, which is
/// rare (manual ping-now / panic / archive / pin delete). The geocoder
/// calls are the slow step; with 30 buckets they typically resolve in a
/// few hundred ms total, and a re-evaluation is almost entirely hits on
/// `GeocodingService`'s LRU.
final topPlacesProvider = FutureProvider<List<RankedPlace>>((ref) async {
  const fetchSize = 30;
  const displaySize = 10;

  final pings = await ref.watch(allPingsProvider.future);
  final raw = StatsService.topPlaces(pings, limit: fetchSize);
  if (raw.isEmpty) return const [];

  final geo = ref.watch(geocodingServiceProvider);

  // Geocode in parallel but BOUNDED — the system geocoder is per-call
  // latency bound, so resolving 30 sequentially would stall the stats
  // screen on first paint, yet firing all 30 at once produced "Service
  // not Available" bursts on some OEM geocoders (PERF_PLAN §3 #2). Four
  // in flight hides the latency without tripping them.
  final labels = await geo.reverseLookupAll(
    [for (final b in raw) (lat: b.lat, lon: b.lon)],
  );

  final byLabel = <String, RankedPlace>{};
  final unlabeled = <RankedPlace>[];

  for (var i = 0; i < raw.length; i++) {
    final b = raw[i];
    final label = labels[i];
    final ranked = RankedPlace(
      lat: b.lat,
      lon: b.lon,
      count: b.count,
      label: label,
    );
    if (label == null) {
      unlabeled.add(ranked);
      continue;
    }
    final existing = byLabel[label];
    if (existing == null) {
      byLabel[label] = ranked;
    } else {
      // Centroid of the larger contributor wins (it's where the bulk
      // of the visits actually happened); counts sum.
      final winner = existing.count >= ranked.count ? existing : ranked;
      byLabel[label] = RankedPlace(
        lat: winner.lat,
        lon: winner.lon,
        count: existing.count + ranked.count,
        label: label,
      );
    }
  }

  final all = [...byLabel.values, ...unlabeled]
    ..sort((a, b) => b.count.compareTo(a.count));
  return all.take(displaySize).toList(growable: false);
});
