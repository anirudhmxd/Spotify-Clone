"""Compile actual plugin Kotlin against API fakes, then test local install/cancel paths.
Not an Android APK or device test. Requires Java 17+ and Kotlin compiler jars.
Usage: python3 tool/test_android_latency.py --java /path/to/java --compiler /path/to/jars
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1]
PLUGIN = APP / 'third_party/ytdlp_flutter/android/src/main'
SOURCES = {
'Context.kt': r'''
package android.content
import java.io.File
class AssetManager(val root: File) { fun open(name: String) = File(root, name).inputStream() }
class Preferences {
 val values = mutableMapOf<String,String>()
 fun getString(key: String, default: String?) = values[key] ?: default
 fun edit() = this
 fun putString(key: String, value: String): Preferences { values[key] = value; return this }
 fun apply() {}
}
class Context(val root: File, assetsRoot: File) {
 companion object { const val MODE_PRIVATE = 0 }
 val noBackupFilesDir = File(root,"backup").apply { mkdirs() }
 val cacheDir = File(root,"cache").apply { mkdirs() }
 val assets = AssetManager(assetsRoot)
 private val prefs = Preferences()
 fun getSharedPreferences(name: String, mode: Int) = prefs
}
''',
'Os.kt': r'''
package android.os
object SystemClock { @Volatile var offset = 0L; fun elapsedRealtime() = System.nanoTime()/1000000 + offset }
class Looper { companion object { fun getMainLooper() = Looper() } }
class Handler(looper: Looper) { fun post(work: () -> Unit) = work() }
''',
'Log.kt': r'''
package android.util
object Log { fun i(tag: String, message: String) = 0; fun w(tag: String, message: String, error: Throwable) = 0 }
''',
'Flutter.kt': r'''
package io.flutter.embedding.engine.plugins
import android.content.Context
interface FlutterPlugin {
 class FlutterPluginBinding(val applicationContext: Context, val binaryMessenger: Any = Any())
 fun onAttachedToEngine(binding: FlutterPluginBinding)
 fun onDetachedFromEngine(binding: FlutterPluginBinding)
}
''',
'Channels.kt': r'''
package io.flutter.plugin.common
class MethodCall(val method: String, val args: Map<String,Any> = emptyMap()) {
 @Suppress("UNCHECKED_CAST") fun <T> argument(key: String): T? = args[key] as T?
}
class MethodChannel(messenger: Any, name: String) {
 interface Result { fun success(value: Any?); fun error(code: String, message: String?, details: Any?); fun notImplemented() }
 interface MethodCallHandler { fun onMethodCall(call: MethodCall, result: Result) }
 fun setMethodCallHandler(handler: MethodCallHandler?) {}
}
class EventChannel(messenger: Any, name: String) {
 interface EventSink { fun success(value: Any?) }
 interface StreamHandler { fun onListen(arguments: Any?, events: EventSink?); fun onCancel(arguments: Any?) }
 fun setStreamHandler(handler: StreamHandler?) {}
}
''',
'FFmpeg.kt': r'''
package com.yausername.ffmpeg
import android.content.Context
object FFmpeg { fun getInstance() = this; fun init(context: Context) {} }
''',
'YoutubeDL.kt': r'''
package com.yausername.youtubedl_android
import android.content.Context
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
class YoutubeDLRequest(val url: String) {
 val options = mutableMapOf<String,String?>()
 fun addOption(key: String, value: String? = null) { options[key] = value }
}
class Response(val out: String)
object YoutubeDL {
 class CanceledException : Exception()
 enum class UpdateStatus { DONE, ALREADY_UP_TO_DATE }
 enum class UpdateChannel { STABLE }
 var updateCalls = 0
 var lookupEntered = CountDownLatch(1)
 val processes = ConcurrentHashMap<String,CountDownLatch>()
 fun getInstance() = this
 fun init(context: Context) {}
 fun version(context: Context): String? = null
 fun updateYoutubeDL(context: Context, channel: UpdateChannel): UpdateStatus { updateCalls++; return UpdateStatus.DONE }
 fun destroyProcessById(id: String): Boolean { val p = processes[id] ?: return false; p.countDown(); return true }
 fun execute(request: YoutubeDLRequest, processId: String? = null, callback: ((Float,Long,String)->Unit)? = null): Response {
   check(request.options.containsKey("--cache-dir"))
   if (request.options.containsKey("--get-url")) {
     lookupEntered.countDown()
     Thread.sleep(300) // cancellation must also work before process registration
     val signal = CountDownLatch(1)
     processes[processId!!] = signal
     try { signal.await(); throw CanceledException() } finally { processes.remove(processId) }
   }
   return Response("")
 }
}
''',
'Fixture.kt': r'''
package se.cstate.ytdlp_flutter
import android.content.Context
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

class Result : MethodChannel.Result {
 val done = CountDownLatch(1)
 var code: String? = null
 var value: Any? = null
 override fun success(value: Any?) { this.value = value; done.countDown() }
 override fun error(code: String, message: String?, details: Any?) { this.code = code; done.countDown() }
 override fun notImplemented() { error("UNIMPLEMENTED",null,null) }
 fun await() { check(done.await(3, TimeUnit.SECONDS)) { "Native operation did not finish" } }
}
fun main(args: Array<String>) {
 try {
  val root = File(args[0]); val assets = File(args[1])
  val context = Context(File(root,"normal"), assets)
  check(BundledExtractor.install(context, null) == BundledExtractor.VERSION)
  val binary = File(context.noBackupFilesDir,"youtubedl-android/yt-dlp/yt-dlp")
  check(binary.readBytes().contentEquals(File(assets,"rhythm-yt-dlp").readBytes()))
  binary.writeText("newer runtime update")
  check(BundledExtractor.install(context,"2026.11.01") == "2026.11.01")
  check(binary.readText() == "newer runtime update")

  val newer = Context(File(root,"newer"), File(root,"missing-assets"))
  val newerBinary = File(newer.noBackupFilesDir,"youtubedl-android/yt-dlp/yt-dlp")
  newerBinary.parentFile.mkdirs(); newerBinary.writeText("newer")
  check(BundledExtractor.install(newer,"2026.11.01") == "2026.11.01")
  check(newerBinary.readText() == "newer")

  val badAssets = File(root,"bad-assets").apply { mkdirs() }
  File(badAssets,"rhythm-yt-dlp").writeText("corrupt")
  val bad = Context(File(root,"bad"), badAssets)
  val old = File(bad.noBackupFilesDir,"youtubedl-android/yt-dlp/yt-dlp")
  old.parentFile.mkdirs(); old.writeText("old preserved")
  check(runCatching { BundledExtractor.install(bad,null) }.isFailure)
  check(old.readText() == "old preserved")
  check(!File(old.parentFile,"yt-dlp.bundled.tmp").exists())
  println("Bundled extractor: checksum, installation, preservation and cleanup passed")

  val plugin = YtdlpFlutterPlugin()
  plugin.onAttachedToEngine(FlutterPlugin.FlutterPluginBinding(Context(File(root,"plugin"),assets)))
  val init = Result(); plugin.onMethodCall(MethodCall("init"), init); init.await(); check(init.code == null)
  for (deadline in listOf(false,true)) {
    YoutubeDL.lookupEntered = CountDownLatch(1)
    val id = if (deadline) "deadline" else "cancel"
    val lookup = Result()
    plugin.onMethodCall(MethodCall("resolveAudio",mapOf("url" to "https://example.test", "taskId" to id)),lookup)
    check(YoutubeDL.lookupEntered.await(2,TimeUnit.SECONDS))
    if (deadline) SystemClock.offset += 9000 else {
      val cancel = Result(); plugin.onMethodCall(MethodCall("cancel",mapOf("taskId" to id)),cancel)
      cancel.await(); check(cancel.value == true)
    }
    lookup.await(); check(lookup.code == "CANCELLED")
    check(YoutubeDL.processes.isEmpty())
  }
  check(YoutubeDL.updateCalls == 0)
  println("Native lookups: pre-registration cancellation and deadline termination passed; no update/retry")
  exitProcess(0)
 } catch (error: Throwable) { error.printStackTrace(); exitProcess(1) }
}
''',
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--java', required=True)
    parser.add_argument('--compiler', type=Path, required=True)
    args = parser.parse_args()
    jars = list(args.compiler.glob('*.jar'))
    cp = ':'.join(str(jar) for jar in jars)
    with tempfile.TemporaryDirectory(prefix='rhythm-native-fixture-') as tmp:
        directory = Path(tmp)
        files = []
        for name, source in SOURCES.items():
            path = directory / name
            path.write_text(source)
            files.append(str(path))
        files.extend(str(path) for path in (PLUGIN / 'kotlin').rglob('*.kt'))
        classes = directory / 'classes'
        subprocess.run([args.java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
            '-no-stdlib', '-no-reflect', '-nowarn', '-jvm-target', '17', '-classpath', cp,
            '-d', str(classes), *files], check=True)
        subprocess.run([args.java, '-cp', f'{classes}:{cp}', 'se.cstate.ytdlp_flutter.FixtureKt',
            str(directory / 'state'), str(PLUGIN / 'assets')], check=True, timeout=15)

if __name__ == '__main__':
    main()
