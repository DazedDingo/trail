package com.dazeddingo.trail

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Continuous-panic foreground service.
 *
 * Owns two things the Flutter side can't:
 *   1. A visible, user-dismissable "Panic active" notification (Android
 *      requires foreground services to post their own).
 *   2. A wake-capable timer that ticks every ~90s for up to the configured
 *      duration, even with the screen off and the app process swapped out.
 *
 * Each tick enqueues a one-off WorkManager task that re-enters the Flutter
 * isolate via [BackgroundWorker] and runs `_handlePanic` in
 * `workmanager_scheduler.dart` — same DB-write path that scheduled pings
 * use. That keeps SQLCipher access off the native side and avoids dragging
 * the sqlcipher-android dep into the Kotlin layer.
 *
 * Started via [PanicMethodChannel] (from Flutter) or a direct Intent
 * (from the Phase 3 quick-settings tile / home-screen widget).
 *
 * Safety invariants:
 *   - Self-stops after `durationMinutes` even if Flutter dies.
 *   - [stopFromFlutter] and the notification "Stop" action both route to
 *     the same stop path — no chance of a session lingering.
 *   - `foregroundServiceType=location` declared so Android 14+ lets the
 *     process keep GPS active while foregrounded. Runtime permission
 *     (`FOREGROUND_SERVICE_LOCATION`) already declared in manifest and
 *     granted implicitly with `ACCESS_BACKGROUND_LOCATION`.
 */
class PanicForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var tickRunnable: Runnable? = null
    private var stopRunnable: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopSelfCleanly()
            return START_NOT_STICKY
        }

        val durationMinutes = intent?.getIntExtra(EXTRA_DURATION_MINUTES, 30)
            ?.coerceIn(1, 120) ?: 30

        startForegroundSafely(durationMinutes)
        schedulePingLoop()
        scheduleAutoStop(durationMinutes)
        // Fire an immediate ping so the user sees a row land in the history
        // as soon as they hit panic — don't wait the full tick interval.
        enqueuePanicTick()
        return START_REDELIVER_INTENT
    }

    private fun startForegroundSafely(durationMinutes: Int) {
        ensureChannel()
        val stopIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, PanicForegroundService::class.java)
                .setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?.let {
                PendingIntent.getActivity(
                    this,
                    0,
                    it,
                    PendingIntent.FLAG_IMMUTABLE,
                )
            }
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Panic active")
            .setContentText("Pinging every ~90s for ~${durationMinutes} min.")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .apply {
                if (contentIntent != null) setContentIntent(contentIntent)
            }
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                stopIntent,
            )
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Panic (continuous)",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Persistent notification while continuous-panic is active."
                setShowBadge(false)
            },
        )
    }

    private fun schedulePingLoop() {
        tickRunnable?.let { handler.removeCallbacks(it) }
        val r = object : Runnable {
            override fun run() {
                enqueuePanicTick()
                handler.postDelayed(this, TICK_INTERVAL_MS)
            }
        }
        tickRunnable = r
        handler.postDelayed(r, TICK_INTERVAL_MS)
    }

    private fun scheduleAutoStop(durationMinutes: Int) {
        stopRunnable?.let { handler.removeCallbacks(it) }
        val r = Runnable { stopSelfCleanly() }
        stopRunnable = r
        handler.postDelayed(r, durationMinutes * 60L * 1000L)
    }

    private fun enqueuePanicTick() {
        try {
            val inputData = Data.Builder()
                .putString(DART_TASK_KEY, PANIC_TASK_NAME)
                .build()
            val request = OneTimeWorkRequestBuilder<BackgroundWorker>()
                .setInputData(inputData)
                .addTag(TAG_PANIC)
                .build()
            // APPEND so a burst of ticks all land as separate rows — we
            // want every attempted fix recorded, not collapsed.
            WorkManager.getInstance(this).enqueueUniqueWork(
                "trail_panic_tick_${System.currentTimeMillis()}",
                ExistingWorkPolicy.APPEND,
                request,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to enqueue panic tick: ${t.message}")
        }
    }

    private fun stopSelfCleanly() {
        tickRunnable?.let { handler.removeCallbacks(it) }
        stopRunnable?.let { handler.removeCallbacks(it) }
        tickRunnable = null
        stopRunnable = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        tickRunnable?.let { handler.removeCallbacks(it) }
        stopRunnable?.let { handler.removeCallbacks(it) }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "PanicFG"
        const val ACTION_START = "com.dazeddingo.trail.PANIC_START"
        const val ACTION_STOP = "com.dazeddingo.trail.PANIC_STOP"
        const val EXTRA_DURATION_MINUTES = "duration_minutes"
        private const val CHANNEL_ID = "trail_panic_continuous"
        private const val NOTIFICATION_ID = 42_002

        // 90s matches PLAN.md's "1–2 min cadence" and leaves GPS enough
        // cold-acquisition budget between fixes to keep accuracy useful.
        private const val TICK_INTERVAL_MS = 90L * 1000L

        // Matches PanicService.panicTaskName on the Dart side.
        private const val PANIC_TASK_NAME = "trail_panic_ping"
        private const val TAG_PANIC = "trail:panic"
        // Stable contract with the workmanager plugin (same key BootReceiver uses).
        private const val DART_TASK_KEY = "dev.fluttercommunity.workmanager.DART_TASK"

        fun start(context: Context, durationMinutes: Int) {
            val intent = Intent(context, PanicForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_DURATION_MINUTES, durationMinutes)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, PanicForegroundService::class.java)
                .setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
