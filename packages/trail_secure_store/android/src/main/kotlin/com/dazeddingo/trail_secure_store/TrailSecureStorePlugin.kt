package com.dazeddingo.trail_secure_store

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts both of Trail's Keystore channels: [SecureStore.CHANNEL]
 * (`trail/secure_store`) and [KeyEscrowStore.CHANNEL]
 * (`trail/key_escrow`).
 *
 * ## Why a plugin and not a `MainActivity` registration
 *
 * That is the entire point of this package. `MainActivity` only
 * configures the UI engine, so the escrow channel did not exist in
 * WorkManager's background engine and a scheduled tick that could not
 * read the DB key had to skip (`key_unavailable`). Flutter's
 * `FlutterEngine(Context)` constructor calls
 * `GeneratedPluginRegister.registerGeneratedPlugins(this)` — and
 * `workmanager_android`'s `BackgroundWorker` uses exactly that
 * constructor — so a real `FlutterPlugin` listed in the app's pubspec is
 * registered in **every** engine the app ever creates.
 *
 * ## Threading
 *
 * Keystore work is short (one AES-GCM block over tens of bytes) but it is
 * still a TEE round trip, and the DB-key read happens on the startup
 * critical path. Everything runs on one [HandlerThread]; results are
 * posted back to the main looper because `MethodChannel.Result` is
 * `@UiThread`. One thread, not a pool: the operations are serialised
 * anyway by the single prefs file, and ordering between a write and the
 * read that follows it must be preserved.
 *
 * ## Errors
 *
 * Any throw becomes `result.error(<exception class simple name>, message,
 * null)`. The class name is the payload — the Dart side branches on "the
 * blob is corrupt" vs "the alias was invalidated" vs "this engine has no
 * handler at all".
 */
class TrailSecureStorePlugin : FlutterPlugin {
    private var storeChannel: MethodChannel? = null
    private var escrowChannel: MethodChannel? = null
    private var worker: HandlerThread? = null
    private var background: Handler? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val thread = HandlerThread("trail-secure-store").apply { start() }
        worker = thread
        background = Handler(thread.looper)

        storeChannel = MethodChannel(binding.binaryMessenger, SecureStore.CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    dispatch(result) { handleStore(context, call) }
                }
            }
        escrowChannel =
            MethodChannel(binding.binaryMessenger, KeyEscrowStore.CHANNEL)
                .also { channel ->
                    channel.setMethodCallHandler { call, result ->
                        dispatch(result) { handleEscrow(context, call) }
                    }
                }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        storeChannel?.setMethodCallHandler(null)
        escrowChannel?.setMethodCallHandler(null)
        storeChannel = null
        escrowChannel = null
        background = null
        // `quitSafely`, so an in-flight write finishes before the thread
        // goes away. A half-written secret is worse than a slow teardown.
        worker?.quitSafely()
        worker = null
    }

    /** Sentinel for "this channel has no such method". */
    private object NotImplemented

    private fun dispatch(result: MethodChannel.Result, work: () -> Any?) {
        val handler = background
        if (handler == null) {
            result.error(
                "IllegalStateException",
                "trail_secure_store is detached from its engine",
                null,
            )
            return
        }
        handler.post {
            try {
                val value = work()
                main.post {
                    if (value === NotImplemented) {
                        result.notImplemented()
                    } else {
                        result.success(value)
                    }
                }
            } catch (t: Throwable) {
                main.post { result.error(t.javaClass.simpleName, t.message, null) }
            }
        }
    }

    private fun handleStore(context: Context, call: MethodCall): Any? =
        when (call.method) {
            "read" -> SecureStore.read(context, requiredKey(call))
            "write" -> {
                val value = call.argument<String>("value")
                    ?: throw IllegalArgumentException("value is required")
                SecureStore.write(context, requiredKey(call), value)
                null
            }
            "delete" -> {
                SecureStore.delete(context, requiredKey(call))
                null
            }
            "containsKey" -> SecureStore.containsKey(context, requiredKey(call))
            "readAll" -> SecureStore.readAll(context)
            "deleteAll" -> {
                SecureStore.deleteAll(context)
                null
            }
            "status" -> SecureStore.status(context)
            else -> NotImplemented
        }

    private fun handleEscrow(context: Context, call: MethodCall): Any? =
        when (call.method) {
            "store" -> {
                val bytes = call.argument<ByteArray>("bytes")
                    ?: throw IllegalArgumentException("bytes is required")
                KeyEscrowStore.store(context, bytes)
                null
            }
            "load" -> KeyEscrowStore.load(context)
            "clear" -> {
                KeyEscrowStore.clear(context)
                null
            }
            "status" -> KeyEscrowStore.status(context)
            else -> NotImplemented
        }

    private fun requiredKey(call: MethodCall): String =
        call.argument<String>("key")
            ?: throw IllegalArgumentException("key is required")
}
