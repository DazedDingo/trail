import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';
import '../services/geocoding_service.dart';

/// All four providers share one `Database` handle (see [TrailDatabase.shared]).
/// Opening four SQLCipher connections in parallel on the home-screen build
/// raced Keystore key derivation + schema create on first install, which
/// surfaced as a generic "database exception" in 0.1.3.

/// Loads the N most recent pings. Re-runs on invalidation — call
/// `ref.invalidate(recentPingsProvider)` after an export or a manual
/// ping-now action.
final recentPingsProvider = FutureProvider<List<Ping>>((ref) async {
  final db = await TrailDatabase.shared();
  return PingDao(db).recent();
});

/// Full chronological (oldest-first) history — EVERY row, including the
/// coordinate-less `no_fix` / boot markers. Its consumers are the ones
/// that need gaps to be visible: stats (`topPlacesProvider`, daily and
/// hourly counts), trip detection (`tripsProvider`), the Trips screen.
///
/// The map does NOT read this. Since 0.14.1 it goes through
/// [pingsByRangeProvider], which is a *different* query (fixes only, a
/// partial-index walk — see `PingDao.fixesByDateRange`), so the two
/// reads are not a duplicate of one another and nothing is gained by
/// deriving one from the other: the map would either decode no_fix
/// rows it never draws, or stats would lose the gaps they exist to show.
/// Kept non-autoDispose on purpose — one copy, shared by three derived
/// providers, invalidated only on writes.
final allPingsProvider = FutureProvider<List<Ping>>((ref) async {
  final db = await TrailDatabase.shared();
  return PingDao(db).all();
});

/// UTC instants for the SQL `BETWEEN` of a map date filter. The picker
/// hands back local-day boundaries; `end` is widened to the last
/// millisecond of its day so a single-day filter catches the whole day.
/// Both bounds are inclusive (that is `BETWEEN`'s contract). Pure, so
/// `pings_provider_test.dart` can pin the boundary without a DB.
///
/// Note this is NOT the export dialog's rule (`exportRangeUtcBounds`,
/// `[start, nextMidnight)`): the map's presets can carry a time-of-day
/// in `end`, and widening by `1 day − 1 ms` from *that* instant is the
/// behaviour the map has always had. Don't unify them blindly.
({DateTime startUtc, DateTime endUtc}) mapRangeUtcBounds(DateTimeRange range) {
  return (
    startUtc: range.start.toUtc(),
    endUtc: range.end
        .add(const Duration(days: 1) - const Duration(milliseconds: 1))
        .toUtc(),
  );
}

/// The map's pin data: fixes only (rows with a usable lat/lon),
/// oldest-first, clipped at the SQL layer to the user's date filter —
/// `null` means every fix ever. Backed by `PingDao.fixesByDateRange`,
/// which walks the v4 partial index; no_fix/boot rows never reach Dart.
///
/// `autoDispose`: a member lives exactly as long as something watches
/// it. `FullMapPanel` watches the active range continuously from
/// `build`, so that member is retained by the watch itself; the moment
/// the user picks another range the old member loses its listener and
/// is released after the frame. There is deliberately NO unconditional
/// `ref.keepAlive()` — that would pin every range ever selected for the
/// life of the session, which is the 0.13 leak this replaces. It is
/// safe against the in-flight upload: the panel copies the resolved list
/// into its own `_snap` before building GeoJSON, so disposal of the
/// provider never pulls data out from under an upload.
///
/// Invalidate the whole family (`ref.invalidate(pingsByRangeProvider)`)
/// after any write to `pings` — delete, archive, manual ping.
final pingsByRangeProvider = FutureProvider.autoDispose
    .family<List<Ping>, DateTimeRange?>((ref, range) async {
  final db = await TrailDatabase.shared();
  final dao = PingDao(db);
  if (range == null) return dao.fixesByDateRange();
  final b = mapRangeUtcBounds(range);
  return dao.fixesByDateRange(startUtc: b.startUtc, endUtc: b.endUtc);
});

/// Last successful fix (null-coord rows excluded). Feeds the home-screen
/// "last successful ping" card.
final lastSuccessfulPingProvider = FutureProvider<Ping?>((ref) async {
  final db = await TrailDatabase.shared();
  return PingDao(db).latestSuccessful();
});

/// Heartbeat health: red if `now - lastPingTs > 5h` (PLAN.md: 5h buffer on
/// the 4h cadence). Independent of success — any recent attempt counts,
/// since a `no_fix` row still proves the worker ran.
final heartbeatHealthyProvider = FutureProvider<bool>((ref) async {
  final db = await TrailDatabase.shared();
  final latest = await PingDao(db).latest();
  if (latest == null) return false;
  final age = DateTime.now().toUtc().difference(latest.timestampUtc);
  return age < const Duration(hours: 5);
});

/// Total ping count (all sources). Shown on home screen for confidence.
final pingCountProvider = FutureProvider<int>((ref) async {
  final db = await TrailDatabase.shared();
  return PingDao(db).count();
});

/// Singleton so callers can inject a fake in tests.
final geocodingServiceProvider = Provider<GeocodingService>(
  (ref) => GeocodingService(),
);

/// Reverse-geocoded label for ([lat], [lon]) — "Cambridge, MA" or similar.
/// Returns `null` when the system geocoder has nothing (no cache, no net).
/// Keyed by a rounded string so small GPS jitter doesn't blow out the cache
/// on every re-fetch.
final approxLocationProvider =
    FutureProvider.family<String?, ({double lat, double lon})>(
  (ref, coords) async {
    final svc = ref.watch(geocodingServiceProvider);
    return svc.reverseLookup(coords.lat, coords.lon);
  },
);
