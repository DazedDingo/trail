package com.dazeddingo.trail

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

/**
 * Native exact-alarm scheduler — the opt-in alternative to WorkManager's
 * periodic job. Uses [AlarmManager.setExactAndAllowWhileIdle] so the alarm
 * fires within a small window of its scheduled time even in Doze.
 *
 * **Tradeoff vs. WorkManager:** exact alarms are more battery-costly (the
 * system can't batch them with other wakeups) but honour the 4h cadence
 * under Doze. We document this in the Settings UI.
 *
 * **Self-rescheduling:** [AlarmManager] doesn't offer a true periodic
 * exact mode (repeating exact alarms were never Doze-compatible). So we
 * schedule a one-shot, and [ExactAlarmReceiver] re-schedules the next
 * one after each fire. The initial schedule is fired from the MethodChannel
 * when the user enables exact-alarm mode or toggles the periodic cadence.
 *
 * **Cadence:** user-configurable via [SchedulerPrefs.getCadenceMinutes]
 * (default 4 hours; picker ships 30min / 1h / 2h / 4h). The battery-
 * aware low-battery cadence bump (double below 20%, skip below 5%)
 * only applies to WorkManager mode — exact alarms hold the user's
 * chosen cadence regardless of battery level by design.
 *
 * **Permission model:** [SCHEDULE_EXACT_ALARM] is a special permission on
 * API 31+. `canScheduleExactAlarms()` returns false until the user grants
 * it via the per-app system settings page (we deep-link there from the
 * Settings screen). [USE_EXACT_ALARM] on API 33+ is auto-granted for
 * categories like "user-facing alarm / clock / calendar" — Trail is in
 * that category (safety-critical, periodic user-visible log).
 */
object ExactAlarmScheduler {
    const val ACTION_SCHEDULED_PING = "com.dazeddingo.trail.EXACT_SCHEDULED_PING"
    const val REQUEST_CODE = 42_100

    /**
     * Resolves the current cadence from [SchedulerPrefs] to milliseconds.
     * Separate helper so callers (receiver, boot, tests) don't each
     * repeat the `minutes → ms` arithmetic.
     */
    fun currentCadenceMs(context: Context): Long {
        return SchedulerPrefs.getCadenceMinutes(context).toLong() * 60L * 1000L
    }

    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    /**
     * Schedules the next exact alarm. If [delayMs] is null, reads the
     * user's chosen cadence from [SchedulerPrefs]. Silently skips (and
     * records a denied event) when [SCHEDULE_EXACT_ALARM] hasn't been
     * granted — we don't want to throw from the receiver, which is
     * called from a background broadcast and would kill the whole
     * dispatch.
     */
    fun scheduleNext(context: Context, delayMs: Long? = null): Boolean {
        val effective = delayMs ?: currentCadenceMs(context)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        if (!canScheduleExactAlarms(context)) {
            SchedulerEventsLog.record(
                context,
                SchedulerEventsLog.EventKind.EXACT_PERMISSION_DENIED,
                note = "canScheduleExactAlarms=false",
            )
            return false
        }

        // `buildPendingIntent` returns `PendingIntent?` only to support the
        // cancel path (which passes `FLAG_NO_CREATE`). Without that flag,
        // `PendingIntent.getBroadcast` never returns null — enforce that
        // invariant here so the signature of `setExactAndAllowWhileIdle`
        // (non-null) type-checks.
        val pi = buildPendingIntent(context)!!
        val triggerAt = SystemClock.elapsedRealtime() + effective
        am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
        SchedulerEventsLog.record(
            context,
            SchedulerEventsLog.EventKind.EXACT_SCHEDULED,
            note = "+${effective / 60_000} min",
        )
        return true
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = buildPendingIntent(context, flagsOverride = PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        if (pi != null) {
            am.cancel(pi)
            pi.cancel()
        }
        SchedulerEventsLog.record(context, SchedulerEventsLog.EventKind.EXACT_CANCELLED)
    }

    private fun buildPendingIntent(
        context: Context,
        flagsOverride: Int? = null,
    ): PendingIntent? {
        val intent = Intent(context, ExactAlarmReceiver::class.java).apply {
            action = ACTION_SCHEDULED_PING
            // Scope the broadcast to our package — AlarmManager.setExact
            // requires an explicit target on API 26+ anyway, but the
            // package-qualified form is belt-and-braces.
            setPackage(context.packageName)
        }
        val flags = flagsOverride
            ?: (PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
