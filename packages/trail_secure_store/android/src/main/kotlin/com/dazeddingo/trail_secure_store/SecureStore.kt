package com.dazeddingo.trail_secure_store

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Trail's own secret store (`trail/secure_store`).
 *
 * ## Why this exists
 *
 * Until 0.17.9 every Trail secret lived in `flutter_secure_storage`. On
 * 2026-08-23 that plugin stopped working on a real device: Android
 * Keystore refused its RSA-OAEP unwrap (`KeyStoreException
 * UNKNOWN_ERROR -1000`) persistently, and its `createRSAKeysIfNeeded`
 * regenerates the RSA pair the moment the Keystore reports the alias
 * missing — which orphans every entry it ever wrote. The SQLCipher key
 * for the user's whole location log was behind that.
 *
 * This store drops the wrapping layer entirely: a single AES-256-GCM key
 * lives in AndroidKeyStore and encrypts the values directly. It is the
 * same primitive [KeyEscrowStore] has been running on that same device
 * without trouble since 0.17.7.
 *
 * ## Format
 *
 * `base64(iv12 ‖ ciphertext‖tag)` in the dedicated prefs file [PREFS],
 * under the **plain key name** (no prefix, no namespace — nothing else
 * writes this file, so there is nothing to disambiguate from, and a
 * prefix is one more thing that can drift and orphan a user).
 *
 * ## Crypto
 *
 * AES-256-GCM under the AndroidKeyStore alias [ALIAS]:
 * `PURPOSE_ENCRYPT | PURPOSE_DECRYPT`, `BLOCK_MODE_GCM`,
 * `ENCRYPTION_PADDING_NONE`, `setUserAuthenticationRequired(false)` (the
 * WorkManager isolate and the pre-unlock startup path both need it
 * without a prompt) and `setRandomizedEncryptionRequired(true)`.
 *
 * No StrongBox: `setIsStrongBoxBacked(true)` throws
 * `StrongBoxUnavailableException` on most devices and would need a
 * fallback path.
 *
 * The IV is the provider's, not ours: `setRandomizedEncryptionRequired`
 * makes AndroidKeyStore *reject* a caller-supplied `GCMParameterSpec` on
 * encrypt, and `Cipher.getIV()` after `init` is a fresh 12-byte nonce per
 * call — which is the property that flag exists to guarantee.
 *
 * ## What it will and will not do
 *
 * * **Generate** the AES key on [write] when the alias does not exist.
 *   On a fresh store there is nothing to lose; on a store whose alias
 *   Android has dropped, the existing entries are *already* unreadable
 *   and refusing to write would only add "and now nothing can be saved
 *   either" to the user's day. Generation never deletes anything.
 * * **Never regenerate** it because a decrypt failed, and never wipe an
 *   entry it could not read. A bad GCM tag comes back as an error for
 *   THAT key ([read]), which is exactly when the Dart side wants to
 *   report rather than clean up. [readAll] skips such entries instead,
 *   so one corrupt blob cannot blank the whole store.
 * * **Never** touch the alias on [deleteAll] — the key is not the data.
 *
 * ## Backup
 *
 * `backup_rules.xml` / `data_extraction_rules.xml` list only
 * `<include domain="file" path="."/>`, so sharedprefs are already
 * excluded implicitly. The blob would be useless off-device anyway: the
 * AES key never leaves the Keystore.
 */
internal object SecureStore {
    const val CHANNEL = "trail/secure_store"

    private const val ALIAS = "com.dazeddingo.trail.secure_store.v1"

    /** Dedicated prefs file — deliberately not shared with any plugin. */
    private const val PREFS = "trail_secure_store"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128
    private const val IV_BYTES = 12
    private const val B64 = Base64.NO_WRAP

    fun read(context: Context, key: String): String? {
        val blob = prefs(context).getString(key, null) ?: return null
        val raw = Base64.decode(blob, B64)
        if (raw.size <= IV_BYTES) {
            throw IllegalStateException("secure store entry '$key' is truncated")
        }
        val secretKey = existingSecretKey()
            ?: throw IllegalStateException(
                "secure store entry '$key' exists but its Keystore alias is gone",
            )
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey,
            GCMParameterSpec(TAG_BITS, raw, 0, IV_BYTES),
        )
        val plaintext = cipher.doFinal(raw, IV_BYTES, raw.size - IV_BYTES)
        return String(plaintext, Charsets.UTF_8)
    }

    fun write(context: Context, key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, orCreateSecretKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = ByteArray(iv.size + ciphertext.size)
        System.arraycopy(iv, 0, blob, 0, iv.size)
        System.arraycopy(ciphertext, 0, blob, iv.size, ciphertext.size)
        // `commit`, not `apply`: we are already off the platform thread and
        // the Dart caller's `await` should mean the bytes are on disk.
        val ok = prefs(context)
            .edit()
            .putString(key, Base64.encodeToString(blob, B64))
            .commit()
        if (!ok) throw IllegalStateException("could not persist '$key'")
    }

    fun delete(context: Context, key: String) {
        prefs(context).edit().remove(key).commit()
    }

    fun containsKey(context: Context, key: String): Boolean =
        prefs(context).contains(key)

    fun readAll(context: Context): Map<String, String> {
        val out = HashMap<String, String>()
        for (key in prefs(context).all.keys) {
            val value = try {
                read(context, key)
            } catch (t: Throwable) {
                // One unreadable blob must not fail the other five.
                null
            }
            if (value != null) out[key] = value
        }
        return out
    }

    fun deleteAll(context: Context) {
        prefs(context).edit().clear().commit()
    }

    fun status(context: Context): Map<String, Any?> = mapOf(
        "aliasExists" to keystore().containsAlias(ALIAS),
        "entryCount" to prefs(context).all.size,
    )

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

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
}
