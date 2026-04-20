package com.dazeddingo.trail

import android.content.Context

/**
 * Small native-readable mirror of the user's scheduling-mode choice.
 *
 * Written from Flutter via [SchedulerMethodChannel.recordModeChanged]
 * whenever the toggle flips, and read from [BootReceiver] so the
 * device can re-arm the exact alarm after a reboot without waiting for
 * the user to open the app.
 *
 * Stored separately from [PanicPrefs] even though both are tiny — we
 * want a bug in one to not blow away the other, and the mirror is
 * written from different code paths on different cadences.
 */
object SchedulerPrefs {
    private const val FILE = "trail_scheduler_prefs"
    private const val KEY_MODE = "mode"
    private const val KEY_CADENCE_MIN = "cadence_min"
    const val MODE_WORKMANAGER = "workmanager"
    const val MODE_EXACT = "exact"

    // Default matches [PingCadence.hour4] on the Dart side — the
    // original PLAN.md spec. Keep this in sync with
    // SchedulerPolicy.defaultCadence; the ExactAlarmScheduler falls
    // back to this only when the Flutter UI has never mirrored a
    // cadence yet (fresh install, pre-upgrade).
    const val DEFAULT_CADENCE_MIN = 240

    fun setMode(context: Context, mode: String) {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_MODE, mode).apply()
    }

    fun getMode(context: Context): String {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return prefs.getString(KEY_MODE, MODE_WORKMANAGER) ?: MODE_WORKMANAGER
    }

    fun isExactMode(context: Context): Boolean = getMode(context) == MODE_EXACT

    fun setCadenceMinutes(context: Context, minutes: Int) {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        prefs.edit().putInt(KEY_CADENCE_MIN, minutes).apply()
    }

    fun getCadenceMinutes(context: Context): Int {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_CADENCE_MIN, DEFAULT_CADENCE_MIN)
    }
}
