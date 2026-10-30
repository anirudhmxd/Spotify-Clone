package se.cstate.ytdlp_flutter

import android.content.Context
import java.io.File
import java.security.MessageDigest

/** Ships a known extractor with the app instead of updating during a song. */
internal object BundledExtractor {
    const val VERSION = "2026.10.26"
    const val SHA256 = "e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3"

    fun install(context: Context, updatedVersion: String?): String {
        val prefs = context.getSharedPreferences("rhythm_extractor", Context.MODE_PRIVATE)
        val previous = prefs.getString("bundled_version", null)
        val target = File(context.noBackupFilesDir, "youtubedl-android/yt-dlp/yt-dlp")
        if (target.isFile && target.length() > 0 && previous == VERSION) {
            return if (updatedVersion != null && updatedVersion >= VERSION) updatedVersion else VERSION
        }
        // Preserve a more recent runtime update when this app is upgraded.
        val installed = updatedVersion ?: previous
        if (target.isFile && installed != null &&
            Regex("\\d{4}\\.\\d{2}\\.\\d{2}").find(installed)?.value.orEmpty() >= VERSION) {
            prefs.edit().putString("bundled_version", VERSION).apply()
            return installed
        }
        target.parentFile!!.mkdirs()
        val temporary = File(target.parentFile, "yt-dlp.bundled.tmp")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            context.assets.open("rhythm-yt-dlp").use { source ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            check(actual == SHA256) { "Bundled extractor checksum mismatch" }
            check(temporary.renameTo(target)) { "Could not install bundled extractor" }
            prefs.edit().putString("bundled_version", VERSION).apply()
            return VERSION
        } finally {
            temporary.delete()
        }
    }
}
