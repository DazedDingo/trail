import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../db/ping_dao.dart';
import '../models/ping.dart';

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
