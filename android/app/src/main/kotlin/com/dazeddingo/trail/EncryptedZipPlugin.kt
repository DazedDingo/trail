package com.dazeddingo.trail

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.CompressionMethod
import net.lingala.zip4j.model.enums.EncryptionMethod
import java.io.File

/**
 * Bridges Dart → zip4j so the export dialog can produce a standard
 * AES-256 encrypted zip without bundling a custom format.
 *
 * Why native and not a Dart-only zipper: there is no maintained pure
 * Dart implementation of WinZip's AES extension (the convention 7-Zip
 * / macOS Archive Utility / Linux `7z` all read), and rolling our own
 * loses the "open with any unzip tool" property that motivated the
 * switch from `TRLENC01`.
 */
object EncryptedZipPlugin {
    private const val CHANNEL = "com.dazeddingo.trail/encrypted_zip"

    fun register(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "createZip" -> {
                    val inputs = call.argument<List<String>>("inputs")
                    val output = call.argument<String>("output")
                    val passphrase = call.argument<String>("passphrase")
                    if (inputs.isNullOrEmpty() || output.isNullOrEmpty() ||
                        passphrase.isNullOrEmpty()) {
                        result.error(
                            "BAD_ARGS",
                            "inputs / output / passphrase all required",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    try {
                        createEncryptedZip(inputs, output, passphrase)
                        result.success(output)
                    } catch (t: Throwable) {
                        result.error("ZIP_FAILED", t.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createEncryptedZip(
        inputs: List<String>,
        output: String,
        passphrase: String,
    ) {
        val outFile = File(output)
        if (outFile.exists()) outFile.delete()
        val zip = ZipFile(outFile, passphrase.toCharArray())
        val params = ZipParameters().apply {
            isEncryptFiles = true
            encryptionMethod = EncryptionMethod.AES
            aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
            compressionMethod = CompressionMethod.DEFLATE
        }
        for (path in inputs) {
            zip.addFile(File(path), params)
        }
    }
}
