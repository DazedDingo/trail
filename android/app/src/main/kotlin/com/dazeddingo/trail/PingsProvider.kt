package com.dazeddingo.trail

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.UriMatcher
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import net.zetetic.database.sqlcipher.SQLiteDatabase

/**
 * Read-only export of Trail's GPS fixes for Weekend Picker.
 *
 * Guarded by the signature permission `READ_PINGS`, so only an app signed with
 * the same key as Trail can query it.
 *
 *  - `content://com.dazeddingo.trail.pings/fixes?since=<ms>&afterId=<id>&limit=<n>&includeImported=<0|1>`
 *    -> `_id, ts_utc, lat, lon, accuracy, source`, rows with lat/lon only,
 *    never `no_fix`, ordered (ts_utc, id) ascending, keyset-paged.
 *  - `content://com.dazeddingo.trail.pings/status`
 *    -> one row `state` (ok|locked|no_db|error), `message`, `latest_ts`.
 *
 * Strictly read-only: the DB passphrase is only ever *decrypted* here (the
 * copy of the read path of `SecureStore` in trail_secure_store); no Keystore
 * key is ever generated and nothing is written to prefs or the DB. A missing
 * or undecryptable key reports `locked`. Nothing here may crash Trail, so
 * every failure becomes an `error` status or an empty cursor.
 */
class PingsProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        // selection / sortOrder / projection are deliberately ignored.
        val ctx = context ?: return emptyFixes()
        return try {
            when (matcher.match(uri)) {
                CODE_FIXES -> queryFixes(ctx, uri)
                CODE_STATUS -> queryStatus(ctx)
                else -> null
            }
        } catch (t: Throwable) {
            when (matcher.match(uri)) {
                CODE_STATUS -> statusCursor("error", t.javaClass.simpleName + ": " + (t.message ?: ""), null)
                else -> emptyFixes()
            }
        }
    }

    private sealed class Opened {
        class Ok(val db: SQLiteDatabase) : Opened()
        class Fail(val state: String, val message: String) : Opened()
    }

    private fun open(ctx: Context): Opened {
        val file = File(ctx.getDir("flutter", Context.MODE_PRIVATE), DB_NAME)
        if (!file.exists()) return Opened.Fail("no_db", "trail.db not found")
        val pass = try {
            readPassphrase(ctx)
        } catch (t: Throwable) {
            return Opened.Fail("locked", "passphrase unreadable: " + t.javaClass.simpleName)
        } ?: return Opened.Fail("locked", "no passphrase stored")
        return try {
            ensureLib()
            Opened.Ok(
                SQLiteDatabase.openDatabase(
                    file.path, pass, null, SQLiteDatabase.OPEN_READWRITE, null, null,
                ),
            )
        } catch (t: Throwable) {
            Opened.Fail("error", "open failed: " + t.javaClass.simpleName + ": " + (t.message ?: ""))
        }
    }

    private fun queryStatus(ctx: Context): Cursor {
        val o = open(ctx)
        if (o is Opened.Fail) return statusCursor(o.state, o.message, null)
        val db = (o as Opened.Ok).db
        try {
            var latest: Long? = null
            db.rawQuery(
                "SELECT MAX(ts_utc) FROM pings WHERE lat IS NOT NULL AND lon IS NOT NULL " +
                    "AND source != 'no_fix'",
                arrayOf<String>(),
            ).use { c -> if (c.moveToFirst() && !c.isNull(0)) latest = c.getLong(0) }
            return statusCursor("ok", "", latest)
        } catch (t: Throwable) {
            return statusCursor("error", t.javaClass.simpleName + ": " + (t.message ?: ""), null)
        } finally {
            try { db.close() } catch (_: Throwable) {}
        }
    }

    private fun queryFixes(ctx: Context, uri: Uri): Cursor {
        val since = uri.getQueryParameter("since")?.toLongOrNull() ?: 0L
        val afterId = uri.getQueryParameter("afterId")?.toLongOrNull() ?: 0L
        val limit = (uri.getQueryParameter("limit")?.toIntOrNull() ?: DEFAULT_LIMIT)
            .coerceIn(1, MAX_LIMIT)
        val includeImported = uri.getQueryParameter("includeImported") == "1"

        val out = emptyFixes()
        val o = open(ctx)
        if (o is Opened.Fail) return out
        val db = (o as Opened.Ok).db
        try {
            val sql = StringBuilder(
                "SELECT id, ts_utc, lat, lon, accuracy, source FROM pings " +
                    "WHERE lat IS NOT NULL AND lon IS NOT NULL AND source != 'no_fix' " +
                    "AND (ts_utc > ? OR (ts_utc = ? AND id > ?)) ",
            )
            if (!includeImported) sql.append("AND source != 'import' ")
            sql.append("ORDER BY ts_utc ASC, id ASC LIMIT ?")
            val args = arrayOf(
                since.toString(), since.toString(), afterId.toString(), limit.toString(),
            )
            db.rawQuery(sql.toString(), args).use { c ->
                while (c.moveToNext()) {
                    out.addRow(
                        arrayOf<Any?>(
                            c.getLong(0),
                            c.getLong(1),
                            c.getDouble(2),
                            c.getDouble(3),
                            if (c.isNull(4)) null else c.getDouble(4),
                            c.getString(5),
                        ),
                    )
                }
            }
            return out
        } catch (t: Throwable) {
            return emptyFixes()
        } finally {
            try { db.close() } catch (_: Throwable) {}
        }
    }

    private fun emptyFixes() = MatrixCursor(FIX_COLUMNS)

    private fun statusCursor(state: String, message: String, latest: Long?): Cursor =
        MatrixCursor(STATUS_COLUMNS).apply { addRow(arrayOf<Any?>(state, message, latest)) }

    // --- Read-only passphrase decrypt (mirrors SecureStore.read) ---------

    private fun readPassphrase(ctx: Context): String? {
        val blob = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PASSPHRASE_KEY, null) ?: return null
        val raw = Base64.decode(blob, Base64.NO_WRAP)
        if (raw.size <= IV_BYTES) throw IllegalStateException("truncated")
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        // Never generate: an absent alias just means locked.
        val key = (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey as SecretKey?
            ?: throw IllegalStateException("keystore alias missing")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, raw, 0, IV_BYTES))
        return String(cipher.doFinal(raw, IV_BYTES, raw.size - IV_BYTES), Charsets.UTF_8)
    }

    // --- Read-only provider surface -------------------------------------

    override fun getType(uri: Uri): String? = when (matcher.match(uri)) {
        CODE_FIXES -> "vnd.android.cursor.dir/vnd.com.dazeddingo.trail.fix"
        CODE_STATUS -> "vnd.android.cursor.item/vnd.com.dazeddingo.trail.status"
        else -> null
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("read-only provider")

    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("read-only provider")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("read-only provider")

    companion object {
        private const val AUTHORITY = "com.dazeddingo.trail.pings"
        private const val CODE_FIXES = 1
        private const val CODE_STATUS = 2
        private const val DB_NAME = "trail.db"
        private const val PREFS = "trail_secure_store"
        private const val PASSPHRASE_KEY = "trail_db_passphrase_v1"
        private const val ALIAS = "com.dazeddingo.trail.secure_store.v1"
        private const val TAG_BITS = 128
        private const val IV_BYTES = 12
        private const val DEFAULT_LIMIT = 5000
        private const val MAX_LIMIT = 20000
        private val FIX_COLUMNS = arrayOf("_id", "ts_utc", "lat", "lon", "accuracy", "source")
        private val STATUS_COLUMNS = arrayOf("state", "message", "latest_ts")

        private val matcher = UriMatcher(UriMatcher.NO_MATCH).apply {
            addURI(AUTHORITY, "fixes", CODE_FIXES)
            addURI(AUTHORITY, "status", CODE_STATUS)
        }

        @Volatile private var libLoaded = false

        @Synchronized
        private fun ensureLib() {
            if (!libLoaded) {
                System.loadLibrary("sqlcipher")
                libLoaded = true
            }
        }
    }
}
