package se.cstate.ytdlp_flutter

import android.content.Context
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android backend: wraps youtubedl-android (bundled Python + runtime-updatable
 * yt-dlp + FFmpeg). All engine calls run on a thread pool; results and
 * progress events are posted back on the main thread.
 */
class YtdlpFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context

    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressSink: EventChannel.EventSink? = null

    @Volatile
    private var initialized = false

    @Volatile
    private var lastUpdateStatus: String = "not-attempted"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ytdlp_flutter")
        channel.setMethodCallHandler(this)
        progressChannel = EventChannel(binding.binaryMessenger, "ytdlp_flutter/progress")
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
    }

    @Volatile private var diagnostics = false
    private fun diagnostic(stage: String, detail: String) {
        if (!diagnostics) return
        val safe = detail.replace(Regex("https?://[^\\s<>\"']+"), "<url>")
            .replace('\n', ' ').replace('\r', ' ').take(1000)
        Log.i("RhythmAudio", "[AUDIO-NATIVE t=${SystemClock.elapsedRealtime()}ms] $stage $safe")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        call.argument<Boolean>("diagnostics")?.let { diagnostics = it }
        when (call.method) {
            "init" -> runAsync(result) {
                ensureInit()
                null
            }
            "resolveAudio" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("BAD_ARGS", "url is required", null)
                runAsync(result) {
                    ensureInit()
                    val request = YoutubeDLRequest(url).apply {
                        addOption("--no-playlist")
                        addOption("--skip-download")
                        addOption("--get-url")
                        addOption("-f", "bestaudio[ext=m4a][protocol=https]/bestaudio[ext=m4a][protocol=http]")
                        addOption("--socket-timeout", "5")
                        addOption("--retries", "1")
                        addOption("--extractor-retries", "1")
                    }
                    withExtractorRefresh { YoutubeDL.getInstance().execute(request) }.out.lines()
                        .map { it.trim() }
                        .firstOrNull { it.startsWith("https://") || it.startsWith("http://") }
                        ?: throw RuntimeException("No compatible audio stream is available")
                }
            }
            "getVideoInfo" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("BAD_ARGS", "url is required", null)
                runAsync(result) {
                    ensureInit()
                    val request = YoutubeDLRequest(url).apply {
                        addOption("--dump-single-json")
                        addOption("--no-playlist")
                    }
                    withExtractorRefresh { YoutubeDL.getInstance().execute(request) }.out.trim()
                }
            }
            "downloadAudio" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("BAD_ARGS", "url is required", null)
                val outputDir = call.argument<String>("outputDir")
                    ?: return result.error("BAD_ARGS", "outputDir is required", null)
                val taskId = call.argument<String>("taskId")
                    ?: return result.error("BAD_ARGS", "taskId is required", null)
                val format = call.argument<String>("format") ?: "bestaudio/best"
                val audioFormat = call.argument<String>("audioFormat")
                runAsync(result) {
                    ensureInit()
                    downloadAudio(url, outputDir, taskId, format, audioFormat)
                }
            }
            "cancel" -> {
                val taskId = call.argument<String>("taskId")
                    ?: return result.error("BAD_ARGS", "taskId is required", null)
                result.success(YoutubeDL.getInstance().destroyProcessById(taskId))
            }
            "update" -> runAsync(result) {
                ensureInit()
                val status = YoutubeDL.getInstance()
                    .updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                status?.name ?: "unknown"
            }
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun ensureInit() {
        if (initialized) return
        val started = SystemClock.elapsedRealtime()
        diagnostic("engine.start", "")
        YoutubeDL.getInstance().init(context)
        diagnostic("engine.ready", "ms=${SystemClock.elapsedRealtime() - started}")
        initialized = true
    }

    @Volatile
    private var refreshAttempted = false

    // A successful stream never waits for a network update. Refresh the
    // extractor only on an extraction failure, once per process, then retry.
    @Synchronized
    private fun refreshAfterFailure(): Boolean {
        if (refreshAttempted) return false
        refreshAttempted = true
        diagnostic("extractor.update.start", "")
        return try {
            val status = YoutubeDL.getInstance()
                .updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
            lastUpdateStatus = status?.name ?: "unknown"
            diagnostic("extractor.update.complete", lastUpdateStatus)
            true
        } catch (e: Exception) {
            lastUpdateStatus = "failed: ${e.message}"
            Log.w("ytdlp_flutter", "Extractor refresh failed", e)
            false
        }
    }

    private fun <T> withExtractorRefresh(block: () -> T): T {
        try {
            return block()
        } catch (e: YoutubeDL.CanceledException) {
            throw e
        } catch (e: Exception) {
            diagnostic("extractor.failed", e.message ?: e.javaClass.simpleName)
            if (!refreshAfterFailure()) throw e
            diagnostic("extractor.retry", "after update")
            return block()
        }
    }

    /// Version + update status, appended to every error so failures on
    /// user devices are self-describing.
    private fun engineInfo(): String {
        val version = try {
            YoutubeDL.getInstance().version(context) ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
        return "yt-dlp=$version, update=$lastUpdateStatus"
    }

    private fun downloadAudio(
        url: String,
        outputDir: String,
        taskId: String,
        format: String,
        audioFormat: String?,
    ): String {
        File(outputDir).mkdirs()
        val request = YoutubeDLRequest(url).apply {
            addOption("--no-playlist")
            addOption("--concurrent-fragments", "4")
            addOption("--http-chunk-size", "1M")
            addOption("--socket-timeout", "10")
            addOption("--retries", "3")
            addOption("--fragment-retries", "3")
            addOption("--abort-on-unavailable-fragments")
            addOption("-f", format)
            if (audioFormat != null) {
                FFmpeg.getInstance().init(context)
                addOption("-x")
                addOption("--audio-format", audioFormat)
            }
            addOption("-o", "$outputDir/%(id)s.%(ext)s")
            addOption("--no-simulate")
            if (diagnostics) {
                addOption("--no-quiet")
                addOption("--progress")
                addOption("--newline")
            }
            addOption("--print", "after_move:filepath")
        }
        val started = SystemClock.elapsedRealtime()
        var lastProgressLog = 0L
        diagnostic("download.start", "track=$taskId ${engineInfo()}")
        val response = withExtractorRefresh {
            YoutubeDL.getInstance().execute(request, taskId) { progress, eta, line ->
                val now = SystemClock.elapsedRealtime()
                if (!line.startsWith("[download]") || now - lastProgressLog >= 2000 || line.contains("retry", ignoreCase = true) || line.contains("error", ignoreCase = true)) {
                    lastProgressLog = now
                    diagnostic("download.output", "track=$taskId ms=${now - started} $line")
                }
                mainHandler.post {
                    progressSink?.success(
                        mapOf(
                            "taskId" to taskId,
                            "progress" to progress,
                            "etaSeconds" to eta,
                        )
                    )
                }
            }
        }
        diagnostic("download.complete", "track=$taskId ms=${SystemClock.elapsedRealtime() - started}")
        // '--print after_move:filepath'  emits the finished file on stdout;
        // scan from the end past any progress noise.
        val path = response.out.lines()
            .map { it.trim() }
            .lastOrNull { it.startsWith("/") && File(it).exists() }
            ?: throw RuntimeException("yt-dlp finished but printed no file path")
        return path
    }

    private fun runAsync(result: Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                mainHandler.post { result.error("CANCELLED", "cancelled", null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "YTDLP_ERROR",
                        e.message ?: e.javaClass.simpleName,
                        engineInfo(),
                    )
                }
            }
        }
    }
}
