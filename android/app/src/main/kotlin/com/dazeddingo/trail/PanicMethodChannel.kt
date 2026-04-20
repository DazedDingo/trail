package com.dazeddingo.trail

import android.content.Context
import android.os.Build
import android.telephony.SmsManager
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
                "sendSms" -> {
                    // Silent panic-SMS send. Callers pass a recipient list
                    // (E.164 strings) and one body; we loop per-recipient
                    // because `sendTextMessage` is 1:1, and split long
                    // bodies into multipart to survive GSM 7-bit limits.
                    // Throwing here falls back to the user-taps-Send path
                    // on the Dart side — safer than losing the alert.
                    try {
                        val recipients =
                            call.argument<List<String>>("recipients").orEmpty()
                        val body = call.argument<String>("body").orEmpty()
                        if (recipients.isEmpty() || body.isEmpty()) {
                            result.error(
                                "PANIC_SMS_ARGS",
                                "recipients and body are required",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val sms = if (Build.VERSION.SDK_INT >=
                            Build.VERSION_CODES.S
                        ) {
                            context.getSystemService(SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            SmsManager.getDefault()
                        }
                        var sent = 0
                        for (phone in recipients) {
                            if (phone.isBlank()) continue
                            val parts = sms.divideMessage(body)
                            if (parts.size > 1) {
                                sms.sendMultipartTextMessage(
                                    phone, null, parts, null, null,
                                )
                            } else {
                                sms.sendTextMessage(
                                    phone, null, body, null, null,
                                )
                            }
                            sent += 1
                        }
                        result.success(sent)
                    } catch (t: Throwable) {
                        result.error("PANIC_SMS_FAILED", t.message, null)
                    }
                }
                "setContinuousDurationMinutes" -> {
                    // Mirrors the user's chosen duration into a native-readable
                    // SharedPreferences file so the Phase 3 tile + widget can
                    // start the FG service with the same duration the Settings
                    // screen shows — without re-implementing secure storage
                    // access in Kotlin.
                    try {
                        val mins = (call.argument<Int>("minutes") ?: 30)
                        PanicPrefs.setDurationMinutes(context, mins)
                        result.success(null)
                    } catch (t: Throwable) {
                        result.error("PANIC_PREF_FAILED", t.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
