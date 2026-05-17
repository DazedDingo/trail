import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/stats/stats_service.dart';
import 'home_location_provider.dart';
import 'pings_provider.dart';

/// Detected trips for the household — pings that ran ≥6 h continuously
/// > 10 km from home. Most-recent-first.
///
/// Computed on every change to either input (pings or home location).
/// Cheap at household scale (a year of 4 h cadence = ~2 200 pings, the
/// O(n) pass runs in a millisecond). If the cost ever shows up in
/// profiling, swap to a memo keyed on ping count + home identity.
final tripsProvider = Provider<List<Trip>>((ref) {
  final pings = ref.watch(allPingsProvider).valueOrNull;
  final home = ref.watch(homeLocationProvider).valueOrNull;
  if (pings == null || home == null) return const [];
  return StatsService.detectTrips(pings, home);
});
