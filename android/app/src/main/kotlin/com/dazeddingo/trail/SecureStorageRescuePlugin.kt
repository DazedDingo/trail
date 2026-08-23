package com.dazeddingo.trail

import android.content.Context
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/**
 * Last-resort reader/rebuilder for `flutter_secure_storage`'s own store
 * (`trail/secure_storage_rescue`).
 *
 * ## The incident this exists for (2026-08-23)
 *
 * On one device `flutter_secure_storage` 11 fails at *every* init with
 * `InvalidKeyException: Failed to unwrap key` ←
 * `IllegalBlockSizeException` ← `KeyStoreException UNKNOWN_ERROR (-1000)
 * at KeystoreOperation::finish`, persistently across reboots. The
 * plugin's own unwrap is
 * `Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround")`
 * in `UNWRAP_MODE` with `OAEPParameterSpec("SHA-256", "MGF1",
 * MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)` against the
 * Keystore alias `<pkg>.FlutterSecureStoragePluginKeyOAEP`. Every
 * `read`/`write` therefore throws and the whole store — including the
 * SQLCipher key for the user's encrypted log — is unreachable through
 * the library.
 *
 * The bytes are still on disk. This plugin goes at them directly:
 *
 * * [rescue] — **read-only**. Re-tries the RSA unwrap through provider /
 *   mode / MGF1-digest combinations the library never tries, and on the
 *   first 32-byte answer decrypts every value in the store with it. It
 *   never writes and never deletes; a total failure is a `false` plus the
 *   per-attempt exception names, which is a bug report.
 * * [setAside] — the only mutating call. **Copies** the store's XML files
 *   aside as `<name>.broken-<yyyyMMdd-HHmm>.xml` (nothing is deleted),
 *   empties the live ones, and drops the plugin's Keystore aliases so its
 *   `createRSAKeysIfNeeded` mints a working pair on the next init.
 * * [status] — what is on disk right now, for Diagnostics.
 *
 * ## Store layout (`flutter_secure_storage` 11, config suffix empty)
 *
 * SharedPreferences file [PREFS] (`shared_prefs/FlutterSecureStorage.xml`):
 *
 * * [WRAPPED_KEY_PREF] → base64 of the RSA-OAEP-wrapped 256-bit AES key.
 * * [VALUE_PREFIX]`<ourKey>` → base64 of `iv(12) ‖ AES-GCM ciphertext+tag(16)`
 *   over the UTF-8 value.
 * * the algorithm markers live in a sibling
 *   `FlutterSecureStorageConfiguration*.xml`, which is why [setAside]
 *   takes those too — leaving a marker behind that names an algorithm the
 *   fresh key was not created with is exactly the
 *   "Migration failed after algorithm change" trap.
 *
 * ## Ordering contract (the dangerous part)
 *
 * [setAside] destroys the ability to ever unwrap the old AES key. The
 * Dart side (`lib/services/passphrase_recovery_service.dart`) must
 * therefore have (a) a DB key that was verified by actually opening the
 * log and escrowed via `KeyEscrowPlugin`, and (b) a completed [rescue]
 * call whose values are held in memory, before it calls this. Nothing in
 * here enforces that — it cannot — so do not add a second call site
 * without re-reading that flow.
 */
object SecureStorageRescuePlugin {
    private const val CHANNEL = "trail/secure_storage_rescue"

    /** `flutter_secure_storage`'s prefs file when no namespace is set. */
    private const val PREFS = "FlutterSecureStorage"

    /** Its algorithm-marker sibling(s): `FlutterSecureStorageConfiguration*`. */
    private const val CONFIG_PREFS_PREFIX = "FlutterSecureStorageConfiguration"

    /** Pref key holding the wrapped AES key (base64 of the plugin's own literal). */
    private const val WRAPPED_KEY_PREF =
        "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"

    /** Every stored secret is `<prefix><our key>`. */
    private const val VALUE_PREFIX =
        "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"

    /**
     * Both plugin aliases start with this; the OAEP one is the suffixed
     * variant. [setAside] deletes by prefix so a legacy PKCS1 alias left
     * over from an older release goes with it.
     */
    private const val ALIAS_PREFIX = ".FlutterSecureStoragePluginKey"
    private const val OAEP_ALIAS_SUFFIX = ".FlutterSecureStoragePluginKeyOAEP"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val AES_KEY_BYTES = 32
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    /** Infix of the kept-forever copies, also the [status] filter. */
    private const val BROKEN_MARKER = ".broken-"

    /**
     * Written + committed immediately before a file is copied aside, to
     * flush any `apply()` the plugin left queued. It rides along into the
     * `.broken-` copy (forensic only) and is gone from the live store a
     * line later, when the whole map is cleared.
     */
    private const val FLUSH_KEY = "trail_rescue_flush_at"

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "rescue" -> result.success(rescue(app))
                    "setAside" -> result.success(setAside(app))
                    "status" -> result.success(status(app))
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                // Same contract as KeyEscrowPlugin: the exception's simple
                // name is the payload the Dart side reports.
                result.error(t.javaClass.simpleName, t.message, null)
            }
        }
    }

    /** One labelled way to get the AES key back out of the wrapped blob. */
    private class Attempt(val name: String, val run: (ByteArray) -> ByteArray?)

    /**
     * READ-ONLY. `{ok, method, values, attempts}` — or `{ok: false,
     * attempts}` when no combination produced 32 bytes.
     *
     * The attempt list is ordered cheapest-and-likeliest first and every
     * step is recorded as `<attempt> → <ExceptionClass>` so a total
     * failure still tells the developer which layer said no.
     */
    private fun rescue(context: Context): Map<String, Any?> {
        val attempts = ArrayList<String>()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wrapped = prefs.getString(WRAPPED_KEY_PREF, null)
        if (wrapped == null) {
            attempts.add("wrapped AES key → absent from $PREFS")
            return mapOf("ok" to false, "attempts" to attempts)
        }
        val wrappedBytes = try {
            Base64.decode(wrapped, Base64.DEFAULT)
        } catch (t: Throwable) {
            attempts.add("base64(wrapped AES key) → ${t.javaClass.simpleName}")
            return mapOf("ok" to false, "attempts" to attempts)
        }

        var aesKey: ByteArray? = null
        var method: String? = null
        for (attempt in unwrapAttempts(context)) {
            try {
                val bytes = attempt.run(wrappedBytes)
                if (bytes == null || bytes.size != AES_KEY_BYTES) {
                    attempts.add(
                        "${attempt.name} → " +
                            if (bytes == null) "null" else "${bytes.size} bytes",
                    )
                    continue
                }
                attempts.add("${attempt.name} → ok")
                aesKey = bytes
                method = attempt.name
                break
            } catch (t: Throwable) {
                attempts.add("${attempt.name} → ${t.javaClass.simpleName}")
            }
        }
        if (aesKey == null) return mapOf("ok" to false, "attempts" to attempts)

        val values = HashMap<String, String>()
        for ((prefKey, raw) in prefs.all) {
            if (!prefKey.startsWith(VALUE_PREFIX) || raw !is String) continue
            val ourKey = prefKey.substring(VALUE_PREFIX.length)
            try {
                values[ourKey] = decryptValue(aesKey, raw)
            } catch (t: Throwable) {
                attempts.add("value $ourKey → ${t.javaClass.simpleName}")
            }
        }
        return mapOf(
            "ok" to true,
            "method" to method,
            "values" to values,
            "attempts" to attempts,
        )
    }

    /**
     * The combinations, in order. (1)–(3) are plain `DECRYPT_MODE`
     * `doFinal`s — RSA-OAEP unwrap and decrypt are the same operation, and
     * the library's failure is inside `Cipher.unwrap` on the
     * `AndroidKeyStoreBCWorkaround` provider, so going through the default
     * provider in decrypt mode is a genuinely different code path.
     * (4)–(5) repeat it in `UNWRAP_MODE` in case a device only implements
     * that one. (6) covers an install whose key predates the OAEP alias.
     *
     * No provider is named anywhere: letting the platform resolve
     * `AndroidKeyStoreRSACipherSpi` is the entire point.
     */
    private fun unwrapAttempts(context: Context): List<Attempt> {
        val oaep = context.packageName + OAEP_ALIAS_SUFFIX
        val legacy = context.packageName + ALIAS_PREFIX
        val mgf1Sha1 = OAEPParameterSpec(
            "SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT,
        )
        val mgf1Sha256 = OAEPParameterSpec(
            "SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT,
        )
        return listOf(
            Attempt("decrypt OAEP SHA-256/MGF1-SHA1") {
                rsa(oaep, "RSA/ECB/OAEPPadding", mgf1Sha1, Cipher.DECRYPT_MODE, it)
            },
            Attempt("decrypt OAEP SHA-256/MGF1-SHA256") {
                rsa(oaep, "RSA/ECB/OAEPPadding", mgf1Sha256, Cipher.DECRYPT_MODE, it)
            },
            Attempt("decrypt OAEPWithSHA-256AndMGF1Padding") {
                rsa(
                    oaep,
                    "RSA/ECB/OAEPWithSHA-256AndMGF1Padding",
                    null,
                    Cipher.DECRYPT_MODE,
                    it,
                )
            },
            Attempt("unwrap OAEP SHA-256/MGF1-SHA1") {
                rsa(oaep, "RSA/ECB/OAEPPadding", mgf1Sha1, Cipher.UNWRAP_MODE, it)
            },
            Attempt("unwrap OAEP SHA-256/MGF1-SHA256") {
                rsa(oaep, "RSA/ECB/OAEPPadding", mgf1Sha256, Cipher.UNWRAP_MODE, it)
            },
            Attempt("decrypt PKCS1 (legacy alias)") {
                rsa(legacy, "RSA/ECB/PKCS1Padding", null, Cipher.DECRYPT_MODE, it)
            },
        )
    }

    private fun rsa(
        alias: String,
        transformation: String,
        spec: OAEPParameterSpec?,
        mode: Int,
        input: ByteArray,
    ): ByteArray? {
        val key = privateKey(alias)
            ?: throw IllegalStateException("no Keystore private key for $alias")
        val cipher = Cipher.getInstance(transformation)
        if (spec == null) cipher.init(mode, key) else cipher.init(mode, key, spec)
        return if (mode == Cipher.UNWRAP_MODE) {
            (cipher.unwrap(input, "AES", Cipher.SECRET_KEY) as SecretKey).encoded
        } else {
            cipher.doFinal(input)
        }
    }

    /** `iv(12) ‖ ciphertext+tag`, exactly what the library writes. */
    private fun decryptValue(aesKey: ByteArray, encoded: String): String {
        val raw = Base64.decode(encoded, Base64.DEFAULT)
        if (raw.size <= IV_BYTES) {
            throw IllegalStateException("value shorter than an IV")
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(aesKey, "AES"),
            GCMParameterSpec(TAG_BITS, raw, 0, IV_BYTES),
        )
        return String(
            cipher.doFinal(raw, IV_BYTES, raw.size - IV_BYTES),
            Charsets.UTF_8,
        )
    }

    /**
     * The only mutating call. Nothing is deleted from `shared_prefs`: the
     * XML is **copied** to `<name>.broken-<stamp>.xml` and the live file
     * is then emptied.
     *
     * Why empty rather than delete the file: Android caches one
     * `SharedPreferencesImpl` per name for the life of the process, and a
     * cached instance keeps serving (and re-writing) its old map long
     * after the file is gone — the plugin would carry on reading a store
     * we thought we had removed. `getSharedPreferences(name).edit()
     * .clear().commit()` empties the cache and the disk together, which
     * is the state the plugin treats as "first run".
     *
     * The Keystore aliases go too, so `createRSAKeysIfNeeded` mints a
     * fresh, working pair on the next init. That is what makes the old
     * wrapped AES key unrecoverable forever — see the ordering contract on
     * the class doc.
     */
    private fun setAside(context: Context): Map<String, Any?> {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
        val dir = File(context.filesDir.parentFile, "shared_prefs")
        val names = LinkedHashSet<String>()
        names.add(PREFS)
        if (dir.isDirectory) {
            dir.listFiles()?.forEach { f ->
                val n = f.name
                if (n.startsWith(CONFIG_PREFS_PREFIX) &&
                    n.endsWith(".xml") &&
                    !n.contains(BROKEN_MARKER)
                ) {
                    names.add(n.removeSuffix(".xml"))
                }
            }
        }

        val moved = ArrayList<String>()
        for (name in names) {
            val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            val src = File(dir, "$name.xml")
            if (src.exists()) {
                // Synchronous write first: it flushes anything the plugin
                // left queued with apply(), so the copy is the whole map.
                prefs.edit().putLong(FLUSH_KEY, System.currentTimeMillis()).commit()
                val dst = File(dir, "$name$BROKEN_MARKER$stamp.xml")
                src.copyTo(dst, overwrite = true)
                moved.add(dst.name)
            }
            prefs.edit().clear().commit()
        }

        val deleted = ArrayList<String>()
        val aliasPrefix = context.packageName + ALIAS_PREFIX
        val ks = keystore()
        for (alias in ks.aliases().toList()) {
            if (alias.startsWith(aliasPrefix)) {
                ks.deleteEntry(alias)
                deleted.add(alias)
            }
        }
        return mapOf(
            "stamp" to stamp,
            "movedFiles" to moved,
            "deletedAliases" to deleted,
        )
    }

    private fun status(context: Context): Map<String, Any?> {
        val dir = File(context.filesDir.parentFile, "shared_prefs")
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val broken = (dir.listFiles() ?: emptyArray())
            .map { it.name }
            .filter { it.startsWith(PREFS) && it.contains(BROKEN_MARKER) }
            .sorted()
        return mapOf(
            "storeFileExists" to File(dir, "$PREFS.xml").exists(),
            "wrappedKeyPresent" to (prefs.getString(WRAPPED_KEY_PREF, null) != null),
            "aliasExists" to
                keystore().containsAlias(context.packageName + OAEP_ALIAS_SUFFIX),
            "brokenCopies" to broken,
        )
    }

    private fun keystore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun privateKey(alias: String): PrivateKey? =
        (keystore().getEntry(alias, null) as? KeyStore.PrivateKeyEntry)?.privateKey
}
