package com.dazeddingo.trail

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Trail-owned escrow for the SQLCipher DB key (`trail/key_escrow`).
 *
 * ## Why this exists
 *
 * Until 0.17.6 the key lived in exactly one place: `flutter_secure_storage`.
 * One plugin's cipher was therefore a single point of failure for the
 * user's entire encrypted log — the 0.17.5 incident (a secure-storage read
 * that threw/hung after the 10 → 11 upgrade) made that concrete. This is a
 * second, independent copy under our own control: our own Keystore alias,
 * our own SharedPreferences file, our own format. No third-party migration
 * can silently invalidate it, because nothing but this file writes it.
 *
 * ## Format
 *
 * `base64(iv) + ':' + base64(ciphertext) + ':' + 'v1'` in the DEDICATED
 * prefs file [PREFS] (never the plugin's own file — a store that another
 * library owns is the thing we are hedging against) under [KEY_BLOB], plus
 * [KEY_STORED_AT] (epoch ms) and [KEY_SHA256].
 *
 * The SHA-256 of the *plaintext* key is deliberate: the DB open path needs
 * to answer "is the escrowed copy already this key?" on every open, and a
 * fingerprint compare costs one prefs read where a decrypt costs a
 * Keystore round trip. It leaks nothing a 256-bit random key cares about.
 *
 * ## Crypto
 *
 * AES-256-GCM under the AndroidKeyStore alias [ALIAS]:
 * `PURPOSE_ENCRYPT | PURPOSE_DECRYPT`, `BLOCK_MODE_GCM`,
 * `ENCRYPTION_PADDING_NONE`, `setUserAuthenticationRequired(false)` (the
 * background WorkManager isolate and the pre-unlock startup path both need
 * it without a prompt) and `setRandomizedEncryptionRequired(true)`.
 *
 * No StrongBox: `setIsStrongBoxBacked(true)` throws
 * `StrongBoxUnavailableException` on the majority of devices and would
 * need a fallback path, i.e. it does not cost nothing. TEE-backed AES is
 * the same threat model for an at-rest blob.
 *
 * The IV is the one the provider generates, not one we pass in:
 * `setRandomizedEncryptionRequired(true)` makes AndroidKeyStore *reject* a
 * caller-supplied `GCMParameterSpec` on encrypt. `Cipher.getIV()` after
 * `init` is a fresh 12-byte nonce per call, which is the property the
 * randomized-encryption flag exists to guarantee.
 *
 * ## Backup
 *
 * `backup_rules.xml` / `data_extraction_rules.xml` list only
 * `<include domain="file" path="."/>`, so every sharedpref is already
 * implicitly excluded and an explicit `<exclude domain="sharedpref">`
 * would be a `FullBackupContent` lint error (both files say so in their
 * own comments). Nothing added there. The blob would be useless off-device
 * anyway — the wrapping key never leaves the Keystore.
 *
 * ## Threading
 *
 * Handlers run synchronously on the platform thread. Every operation is a
 * prefs read plus one AES-GCM block over ~43 bytes — sub-millisecond, and
 * none of it can ever wait on the user (that is what
 * `setUserAuthenticationRequired(false)` buys).
 *
 * ## Errors
 *
 * Any throw becomes `result.error(<exception class simple name>, message,
 * null)`. Nothing is ever deleted on a failed [load]: an `AEADBadTagException`
 * or `KeyPermanentlyInvalidatedException` is exactly when the Dart side
 * wants to *report*, not to clean up. Only the explicit `clear` call
 * removes anything.
 */
object KeyEscrowPlugin {
    private const val CHANNEL = "trail/key_escrow"
    private const val ALIAS = "com.dazeddingo.trail.db_key_escrow.v1"

    /** Dedicated prefs file — deliberately not shared with any plugin. */
    private const val PREFS = "trail_key_escrow"
    private const val KEY_BLOB = "db_key"
    private const val KEY_STORED_AT = "stored_at"
    private const val KEY_SHA256 = "key_sha256"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128
    private const val FORMAT_VERSION = "v1"
    private const val B64 = Base64.NO_WRAP

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "store" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                            ?: throw IllegalArgumentException("bytes is required")
                        store(app, bytes)
                        result.success(null)
                    }
                    "load" -> result.success(load(app))
                    "clear" -> {
                        clear(app)
                        result.success(null)
                    }
                    "status" -> result.success(status(app))
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                // The class name is the payload: the Dart side branches on
                // "the blob is corrupt" vs "the alias was invalidated" vs
                // "this isolate has no handler at all".
                result.error(t.javaClass.simpleName, t.message, null)
            }
        }
    }

    /**
     * Idempotent: storing the same bytes twice leaves the blob and
     * [KEY_STORED_AT] untouched, so "present since" keeps meaning the
     * first time this key was escrowed rather than the last app open.
     */
    private fun store(context: Context, bytes: ByteArray) {
        if (bytes.isEmpty()) {
            throw IllegalArgumentException("refusing to escrow an empty key")
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val digest = sha256Hex(bytes)
        if (prefs.getString(KEY_BLOB, null) != null &&
            prefs.getString(KEY_SHA256, null) == digest
        ) {
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, orCreateSecretKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(bytes)
        val blob = buildString {
            append(Base64.encodeToString(iv, B64))
            append(':')
            append(Base64.encodeToString(ciphertext, B64))
            append(':')
            append(FORMAT_VERSION)
        }
        prefs.edit()
            .putString(KEY_BLOB, blob)
            .putString(KEY_SHA256, digest)
            .putLong(KEY_STORED_AT, System.currentTimeMillis())
            .apply()
    }

    /** `null` when nothing is stored or the alias is gone; throws otherwise. */
    private fun load(context: Context): ByteArray? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val blob = prefs.getString(KEY_BLOB, null) ?: return null
        val key = existingSecretKey() ?: return null
        val parts = blob.split(':')
        if (parts.size != 3 || parts[2] != FORMAT_VERSION) {
            throw IllegalStateException("unrecognised escrow blob format")
        }
        val iv = Base64.decode(parts[0], B64)
        val ciphertext = Base64.decode(parts[1], B64)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    /** The only path that deletes anything. Blob first, then the alias. */
    private fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_BLOB)
            .remove(KEY_SHA256)
            .remove(KEY_STORED_AT)
            .apply()
        val ks = keystore()
        if (ks.containsAlias(ALIAS)) ks.deleteEntry(ALIAS)
    }

    private fun status(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val blob = prefs.getString(KEY_BLOB, null)
        val storedAt = prefs.getLong(KEY_STORED_AT, 0L)
        return mapOf(
            "present" to (blob != null),
            "storedAt" to if (storedAt > 0L) storedAt else null,
            "aliasExists" to keystore().containsAlias(ALIAS),
            "keySha256" to prefs.getString(KEY_SHA256, null),
        )
    }

    private fun keystore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun existingSecretKey(): SecretKey? =
        (keystore().getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun orCreateSecretKey(): SecretKey = existingSecretKey() ?: run {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        generator.generateKey()
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
}
