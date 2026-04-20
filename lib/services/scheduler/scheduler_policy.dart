import '../../models/ping.dart';

/// User-selectable cadence for scheduled pings.
///
/// The app default is [hour4] (original PLAN.md spec). Tighter cadences
/// are opt-in via `Settings → Scheduling → Cadence` — each step below
/// 4h roughly doubles the per-day GPS-fix count and battery cost, so
/// the picker is presented with a battery-tradeoff warning.
///
/// 15 min is the absolute floor WorkManager will accept for a periodic
/// task; we stop at 30 min to keep the exact-alarm battery budget from
/// dominating the device. If you ever want to add a 15 min option,
/// remember WorkManager doesn't guarantee the period — Doze + OEM
/// throttling routinely stretch it to 30+ min anyway on restrictive
/// devices, so the "precision" benefit only lands in exact-alarm mode.
enum PingCadence {
  min30(Duration(minutes: 30), '30 min'),
  hour1(Duration(hours: 1), '1 h'),
  hour2(Duration(hours: 2), '2 h'),
  hour4(Duration(hours: 4), '4 h');

  final Duration value;
  final String label;
  const PingCadence(this.value, this.label);

  String get wire => name;
  int get minutes => value.inMinutes;

  static PingCadence fromWire(String? s) {
    for (final c in PingCadence.values) {
      if (c.name == s) return c;
    }
    return PingCadence.hour4;
  }
}

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

  /// Fallback cadence when the user hasn't touched the cadence picker
  /// or we're running in a context that can't read prefs (e.g. tests).
  /// Matches [PingCadence.hour4].
  static const defaultCadence = Duration(hours: 4);
  static const retryDelay = Duration(minutes: 5);

  /// Marker written into a Ping's `note` field when we skip a fix for low
  /// battery. Also used by [shouldRetry] to suppress retrying the skip.
  static const skipNote = 'skipped_low_battery';

  // --- WorkManager constraint invariants --------------------------------
  //
  // All four flags below MUST stay false. WorkManager otherwise silently
  // defers the job exactly when the user most wants the log — e.g.
  // `requiresBatteryNotLow: true` would stop the worker on a long hike with
  // a draining battery, which is the whole situation the app exists for.
  // Our own SchedulerPolicy is the only thing allowed to throttle.

  static const requiresBatteryNotLow = false;
  static const requiresCharging = false;
  static const requiresDeviceIdle = false;
  static const requiresStorageNotLow = false;
  // Scheduled pings log offline first; we never need a network to run.
  static const requiresNetwork = false;

  /// True if we should skip the fix and just log a marker row. `null` and
  /// zero readings are treated as "unknown" and do NOT trigger a skip.
  static bool shouldSkipForLowBattery(int? batteryPct) {
    if (batteryPct == null) return false;
    return batteryPct > 0 && batteryPct < skipBatteryThreshold;
  }

  /// Next periodic cadence to enqueue after this run, derived from the
  /// user's chosen [base] cadence. Below 20% battery we double the
  /// interval to stretch remaining charge; above that, we keep the
  /// user's choice. `null` battery is treated as "unknown" and falls
  /// through to [base] — we'd rather over-ping than silently halve the
  /// rate on a missing sensor reading.
  static Duration nextCadence(int? batteryPct, {Duration? base}) {
    final effectiveBase = base ?? defaultCadence;
    if (batteryPct == null) return effectiveBase;
    if (batteryPct > 0 && batteryPct < lowBatteryThreshold) {
      return effectiveBase * 2;
    }
    return effectiveBase;
  }

  /// Whether to enqueue a 5-minute one-shot retry after [snapshot].
  /// Only no-fix rows trigger a retry, and the low-battery skip marker is
  /// explicitly excluded — retrying it would just re-skip.
  static bool shouldRetry(Ping snapshot) {
    return snapshot.source == PingSource.noFix && snapshot.note != skipNote;
  }
}
