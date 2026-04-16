import '../../models/ping.dart';

/// Pure, dependency-free decision logic for the WorkManager scheduler.
///
/// Extracted from the handler so we can exhaustively test the battery /
/// retry thresholds without spinning up workmanager or sqflite. The handler
/// calls these from inside a background isolate — none of the logic here
/// may touch plugins or async resources.
///
/// Invariants (PLAN.md "Hard rules"):
///   - <5% battery → skip the fix entirely (log a marker, no silent gap).
///   - <20% battery → next periodic cadence is 8h, not 4h.
///   - Battery 0 is treated as "unknown", not "dead" — some devices report
///     0 when the battery API is unavailable. Skipping on that would mean
///     silently losing pings on those devices.
///   - A no-fix row triggers a one-shot 5-minute retry UNLESS it was the
///     low-battery skip marker (retrying a skip would just re-skip).
class SchedulerPolicy {
  static const skipBatteryThreshold = 5;
  static const lowBatteryThreshold = 20;

  static const defaultCadence = Duration(hours: 4);
  static const lowBatteryCadence = Duration(hours: 8);
  static const retryDelay = Duration(minutes: 5);

  /// Marker written into a Ping's `note` field when we skip a fix for low
  /// battery. Also used by [shouldRetry] to suppress retrying the skip.
  static const skipNote = 'skipped_low_battery';

  /// True if we should skip the fix and just log a marker row. `null` and
  /// zero readings are treated as "unknown" and do NOT trigger a skip.
  static bool shouldSkipForLowBattery(int? batteryPct) {
    if (batteryPct == null) return false;
    return batteryPct > 0 && batteryPct < skipBatteryThreshold;
  }

  /// Next periodic cadence to enqueue after this run. `null` falls back to
  /// the default — we'd rather over-ping than silently drop to 8h because
  /// of a missing sensor reading.
  static Duration nextCadence(int? batteryPct) {
    if (batteryPct == null) return defaultCadence;
    if (batteryPct > 0 && batteryPct < lowBatteryThreshold) {
      return lowBatteryCadence;
    }
    return defaultCadence;
  }

  /// Whether to enqueue a 5-minute one-shot retry after [snapshot].
  /// Only no-fix rows trigger a retry, and the low-battery skip marker is
  /// explicitly excluded — retrying it would just re-skip.
  static bool shouldRetry(Ping snapshot) {
    return snapshot.source == PingSource.noFix && snapshot.note != skipNote;
  }
}
