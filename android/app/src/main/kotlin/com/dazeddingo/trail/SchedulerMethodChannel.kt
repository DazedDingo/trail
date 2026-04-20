package com.dazeddingo.trail

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the `com.dazeddingo.trail/scheduler` MethodChannel to
 * [ExactAlarmScheduler] + [SchedulerEventsLog].
 *
 * Methods:
 *   - `canScheduleExactAlarms()` → Bool
 *   - `openExactAlarmSettings()` → null (deep-links to the per-app
 *     exact-alarm permission page on API 31+; no-op on older OS)
 *   - `enableExactAlarms()` → Bool — schedules the first exact alarm
 *     in +4h. Returns false if the permission is denied (caller should
 *     prompt via `openExactAlarmSettings` first).
 *   - `disableExactAlarms()` → null — cancels any pending alarm.
 *   - `recentEvents()` → String (JSON array) — last 20 scheduler
 *     events, newest-first. Dart decodes via `jsonDecode`.
 *   - `recordModeChanged({mode: String})` → null — UI records when
 *     the user flips between WorkManager / exact-alarm so the events
 *     timeline stays coherent.
 *   - `recordCadenceChanged({minutes: Int})` → null — mirrors the
 *     user's chosen base cadence so [ExactAlarmScheduler] reads the
 *     same value from native prefs after reboot or upgrade, before
 *     the Flutter UI has run.
 */
object SchedulerMethodChannel {
    private const val CHANNEL = "com.dazeddingo.trail/scheduler"

    fun register(engine: FlutterEngine, context: Context) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "canScheduleExactAlarms" -> {
                    result.success(ExactAlarmScheduler.canScheduleExactAlarms(context))
                }
                "openExactAlarmSettings" -> {
                    try {
                        openSettings(context)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("EXACT_SETTINGS_FAILED", t.message, null)
                    }
                }
                "enableExactAlarms" -> {
                    try {
                        val ok = ExactAlarmScheduler.scheduleNext(context)
                        result.success(ok)
                    } catch (t: Throwable) {
                        result.error("EXACT_ENABLE_FAILED", t.message, null)
                    }
                }
                "disableExactAlarms" -> {
                    try {
                        ExactAlarmScheduler.cancel(context)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("EXACT_DISABLE_FAILED", t.message, null)
                    }
                }
                "recentEvents" -> {
                    result.success(SchedulerEventsLog.readJson(context))
                }
                "recordModeChanged" -> {
                    val mode = call.argument<String>("mode") ?: "unknown"
                    // Mirror the chosen mode so BootReceiver can decide
                    // whether to re-arm the exact alarm after reboot
                    // without needing the UI isolate.
                    SchedulerPrefs.setMode(context, mode)
                    SchedulerEventsLog.record(
                        context,
                        SchedulerEventsLog.EventKind.MODE_CHANGED,
                        note = mode,
                    )
                    result.success(null)
                }
                "recordCadenceChanged" -> {
                    val minutes = call.argument<Int>("minutes")
                        ?: SchedulerPrefs.DEFAULT_CADENCE_MIN
                    SchedulerPrefs.setCadenceMinutes(context, minutes)
                    SchedulerEventsLog.record(
                        context,
                        SchedulerEventsLog.EventKind.MODE_CHANGED,
                        note = "cadence=${minutes}min",
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openSettings(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        } else {
            // Nothing to grant on < API 31 — SCHEDULE_EXACT_ALARM is
            // implicitly granted via the manifest entry.
        }
    }
}
