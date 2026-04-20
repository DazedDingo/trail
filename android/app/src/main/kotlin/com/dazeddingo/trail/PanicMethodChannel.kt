package com.dazeddingo.trail

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the `com.dazeddingo.trail/panic` MethodChannel to
 * [PanicForegroundService].
 *
 * Flutter side (see `lib/services/panic/panic_service.dart`):
 *   - `startContinuous({durationMinutes: Int})` → start the service.
 *   - `stopContinuous()` → stop the service.
 *
 * We catch *any* throw and return it as a PlatformException so a broken
 * native path can't crash the UI isolate mid-panic — the Dart side falls
 * back to a one-shot ping when the channel reports failure.
 */
object PanicMethodChannel {
    private const val CHANNEL = "com.dazeddingo.trail/panic"

    fun register(engine: FlutterEngine, context: Context) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startContinuous" -> {
                    try {
                        val mins = (call.argument<Int>("durationMinutes") ?: 30)
                            .coerceIn(1, 120)
                        PanicForegroundService.start(context, mins)
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("PANIC_START_FAILED", t.message, null)
                    }
                }
                "stopContinuous" -> {
                    try {
                        PanicForegroundService.stop(context)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("PANIC_STOP_FAILED", t.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
