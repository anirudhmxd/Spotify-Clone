package com.example.rhythm

import com.ryanheise.audioservice.AudioServiceActivity
import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Retain the audio service's shared engine when the app leaves the foreground.
class MainActivity : AudioServiceActivity() {
    private var backupResult: MethodChannel.Result? = null
    private var backupJson: String? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rhythm/files").setMethodCallHandler { call, result ->
            if (call.method != "saveLibraryBackup") { result.notImplemented(); return@setMethodCallHandler }
            if (backupResult != null) { result.error("BUSY", "A file picker is already open.", null); return@setMethodCallHandler }
            val json = call.argument<String>("json")
            if (json == null) { result.error("INVALID", "No backup data.", null); return@setMethodCallHandler }
            backupResult = result
            backupJson = json
            try {
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, "rhythm-library.json")
                }, 6401)
            } catch (error: Exception) {
                backupResult = null; backupJson = null
                result.error("SAVE_FAILED", error.message, null)
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 6401) return
        val result = backupResult ?: return
        val json = backupJson ?: ""
        backupResult = null; backupJson = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result.success(false); return }
        try {
            val stream = contentResolver.openOutputStream(data.data!!)
                ?: throw java.io.IOException("Could not open the selected file.")
            stream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            result.success(true)
        } catch (error: Exception) { result.error("SAVE_FAILED", error.message, null) }
    }
    override fun onDestroy() {
        backupResult?.error("CANCELLED", "The file picker was closed.", null)
        backupResult = null; backupJson = null
        super.onDestroy()
    }
}
