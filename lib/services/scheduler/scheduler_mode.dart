import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduler_policy.dart';
import 'workmanager_scheduler.dart';

/// How the user's chosen cadence is driven.
///
/// - [workmanager]: periodic WorkManager job (default). Battery-aware:
///   doubles the interval below 20%, skips entirely below 5%. System-
///   batched with other wakeups so battery cost is minimal; punctuality
///   is "within a window" (Doze can stretch long cadences further on
///   idle devices).
/// - [exact]: `AlarmManager.setExactAndAllowWhileIdle` per ping.
///   Fires at the scheduled time ± a small window even under Doze, at
///   the cost of more frequent standalone wakeups. Not battery-aware —
///   holds the user's chosen cadence regardless of battery level.
enum SchedulerMode {
  workmanager('workmanager'),
  exact('exact');

  final String wire;
  const SchedulerMode(this.wire);

  static SchedulerMode fromWire(String? s) => switch (s) {
        'exact' => SchedulerMode.exact,
        _ => SchedulerMode.workmanager,
      };
}

/// One entry in the rolling last-20 scheduler event log.
///
/// The native side writes these (via [SchedulerEventsLog] in Kotlin)
/// whenever an exact alarm is scheduled / fires / fails, when the mode
/// changes, etc. The Flutter UI reads them through
/// [ExactAlarmBridge.recentEvents] and renders them on the Settings
/// screen so the user can verify "yes, the 4h alarm actually fired at
/// 02:07" instead of staring at the black box of WorkManager.
class SchedulerEvent {
  final DateTime timestamp;
  final String kind;
  final String? note;

  const SchedulerEvent({
    required this.timestamp,
    required this.kind,
    this.note,
  });

  factory SchedulerEvent.fromJson(Map<String, dynamic> j) => SchedulerEvent(
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (j['tsMs'] as num).toInt(),
        ),
        kind: j['kind'] as String? ?? 'unknown',
        note: j['note'] as String?,
      );
}

/// Flutter-side wrapper for the native scheduler MethodChannel.
///
/// The channel is registered in `SchedulerMethodChannel.kt` on every
/// [MainActivity] launch. Calls are safe to invoke from the UI isolate
/// only — the background WorkManager dispatcher isolate doesn't have
/// this channel wired, by design. Scheduling changes belong in the UI
/// path where the user is actively toggling settings.
class ExactAlarmBridge {
  static const _channel = MethodChannel('com.dazeddingo.trail/scheduler');

  /// API 31+ permission state. Returns `true` on API < 31 (the
  /// permission didn't exist, manifest entry covers it there).
  static Future<bool> canScheduleExactAlarms() async {
    final v = await _channel.invokeMethod<bool>('canScheduleExactAlarms');
    return v ?? false;
  }

  /// Deep-links to the per-app exact-alarm permission page on API 31+.
  /// No-op on older OS versions.
  static Future<void> openExactAlarmSettings() async {
    await _channel.invokeMethod<void>('openExactAlarmSettings');
  }

  /// Schedules the first exact alarm (+4h). Returns `false` if the
  /// permission is denied — caller should prompt the user via
  /// [openExactAlarmSettings] first.
  static Future<bool> enableExactAlarms() async {
    final v = await _channel.invokeMethod<bool>('enableExactAlarms');
    return v ?? false;
  }

  static Future<void> disableExactAlarms() async {
    await _channel.invokeMethod<void>('disableExactAlarms');
  }

  /// Returns the last 20 scheduler events, newest-first.
  static Future<List<SchedulerEvent>> recentEvents() async {
    final s = await _channel.invokeMethod<String>('recentEvents');
    if (s == null || s.isEmpty) return const [];
    final decoded = jsonDecode(s);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((m) => SchedulerEvent.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// Mirrors the current mode into a native-readable SharedPreferences
  /// file so [BootReceiver] can re-arm the exact alarm after a reboot
  /// without waiting for the user to open the app.
  static Future<void> recordModeChanged(SchedulerMode mode) async {
    await _channel.invokeMethod<void>('recordModeChanged', {
      'mode': mode.wire,
    });
  }

  /// Mirrors the user's chosen cadence into native SharedPreferences so
  /// [ExactAlarmScheduler] (re-armed by [BootReceiver] without the UI
  /// ever running) uses the same cadence the Settings screen shows.
  static Future<void> recordCadenceChanged(PingCadence cadence) async {
    await _channel.invokeMethod<void>('recordCadenceChanged', {
      'minutes': cadence.minutes,
    });
  }
}

/// Persists the user's scheduling-mode choice in [SharedPreferences] on
/// the Flutter side. Mirrored to a native prefs file via
/// [ExactAlarmBridge.recordModeChanged] so [BootReceiver] can re-arm
/// after reboot.
class SchedulerModeStore {
  static const _key = 'trail_scheduler_mode_v1';

  static Future<SchedulerMode> get() async {
    final prefs = await SharedPreferences.getInstance();
    return SchedulerMode.fromWire(prefs.getString(_key));
  }

  static Future<void> set(SchedulerMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.wire);
    await ExactAlarmBridge.recordModeChanged(mode);
  }
}

/// Persists the user's chosen ping cadence (default 4h; pickable
/// 30min/1h/2h/4h via Settings → Scheduling → Cadence). Same
/// SharedPreferences file as everything else — the background
/// WorkManager isolate reads from this same key on every fire
/// (SharedPreferences is cross-isolate-safe, see CLAUDE.md gotcha #11).
/// Native mirror goes via [ExactAlarmBridge.recordCadenceChanged].
class CadenceStore {
  static const _key = 'trail_scheduler_cadence_v1';

  static Future<PingCadence> get() async {
    final prefs = await SharedPreferences.getInstance();
    return PingCadence.fromWire(prefs.getString(_key));
  }

  static Future<void> set(PingCadence cadence) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, cadence.wire);
    await ExactAlarmBridge.recordCadenceChanged(cadence);
  }
}

/// Persists the user's opt-in for motion-aware skipping. When on, the
/// periodic worker checks the most-recent two pings; if they're
/// within `stationaryThresholdMeters` of each other AND the latest
/// is younger than `confirmAfter`, the worker logs a `no_fix` row
/// with the "motion-aware skip" note and skips the GPS warm-up
/// entirely. After `confirmAfter` worth of consecutive skips the
/// next call falls through to a real fix so a slow drift can't go
/// undetected. Off by default — preserves the legacy every-tick-is
/// -real behaviour for users who'd rather have full data over
/// battery savings.
class MotionAwareStore {
  static const _key = 'trail_motion_aware_v1';

  /// Distance threshold (m) below which two consecutive pings count
  /// as "stationary". 50 m comfortably covers GPS jitter at typical
  /// outdoor accuracy and indoor cell-only fixes.
  static const double stationaryThresholdMeters = 50;

  /// How long we'll keep skipping GPS while stationary before forcing
  /// a real fix to confirm.
  static const Duration confirmAfter = Duration(hours: 2);

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

/// High-level mode switch. Call this from the Settings toggle.
///
/// WorkManager mode: cancels any pending exact alarm, then re-enqueues
/// the periodic WorkManager job. Exact mode: cancels the periodic
/// WorkManager job, then schedules the first exact alarm. Exact mode
/// requires the [SCHEDULE_EXACT_ALARM] permission on API 31+; the
/// caller should check [ExactAlarmBridge.canScheduleExactAlarms]
/// before invoking [switchTo] with [SchedulerMode.exact] and prompt
/// via [ExactAlarmBridge.openExactAlarmSettings] if denied.
///
/// Returns `true` on success. Returns `false` only when switching to
/// exact mode without the permission granted — everything else either
/// succeeds or throws.
Future<bool> switchSchedulerMode(SchedulerMode mode) async {
  switch (mode) {
    case SchedulerMode.workmanager:
      await ExactAlarmBridge.disableExactAlarms();
      await WorkmanagerScheduler.enqueuePeriodic();
      await SchedulerModeStore.set(SchedulerMode.workmanager);
      return true;
    case SchedulerMode.exact:
      final ok = await ExactAlarmBridge.enableExactAlarms();
      if (!ok) return false;
      await WorkmanagerScheduler.cancelAll();
      await SchedulerModeStore.set(SchedulerMode.exact);
      return true;
  }
}
