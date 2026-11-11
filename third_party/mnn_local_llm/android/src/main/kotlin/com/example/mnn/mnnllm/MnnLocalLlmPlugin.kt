package com.example.mnn.mnnllm

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Flutter plugin that routes method-channel calls to the MNN JNI bridge. */
class MnnLocalLlmPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var streamChannel: EventChannel
    private var native: MnnNative? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingTokens = StringBuilder()
    private var flushScheduled = false
    private val generating = AtomicBoolean(false)

    private fun getNative(): MnnNative {
        if (native == null) native = MnnNative()
        return native!!
    }

    private val flushRunnable = Runnable { flushTokens() }

    private fun enqueueToken(token: String) {
        synchronized(pendingTokens) {
            pendingTokens.append(token)
            if (!flushScheduled) {
                flushScheduled = true
                mainHandler.postDelayed(flushRunnable, FLUSH_INTERVAL_MS)
            }
        }
    }

    /** Must run on the main thread. */
    private fun flushTokens() {
        val chunk: String
        synchronized(pendingTokens) {
            chunk = pendingTokens.toString()
            pendingTokens.setLength(0)
            flushScheduled = false
        }
        if (chunk.isNotEmpty()) {
            eventSink?.success(mapOf("type" to "token", "text" to chunk))
        }
    }

    private fun statsMap(stats: LongArray): Map<String, Any> = mapOf(
        "promptTokens" to stats[0].toInt(),
        "decodeTokens" to stats[1].toInt(),
        "prefillUs" to stats[2],
        "decodeUs" to stats[3],
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "mnn_local_llm")
        channel.setMethodCallHandler(this)

        streamChannel = EventChannel(binding.binaryMessenger, "mnn_local_llm/stream")
        streamChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                mainHandler.removeCallbacks(flushRunnable)
                synchronized(pendingTokens) {
                    pendingTokens.setLength(0)
                    flushScheduled = false
                }
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "loadModel" -> {
                val modelDir = call.argument<String>("modelDir")
                if (modelDir == null) {
                    result.error("INVALID_ARGUMENT", "modelDir is required", null)
                    return
                }
                scope.launch {
                    try {
                        val loaded = getNative().loadModel(modelDir)
                        withContext(Dispatchers.Main) { result.success(loaded) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("LOAD_ERROR", e.message, null)
                        }
                    }
                }
            }

            "generate" -> {
                val prompt = call.argument<String>("prompt")
                if (prompt == null) {
                    result.error("INVALID_ARGUMENT", "prompt is required", null)
                    return
                }
                val temperature = (call.argument<Double>("temperature") ?: 0.4).toFloat()
                val topK = call.argument<Int>("topK") ?: 20
                val topP = (call.argument<Double>("topP") ?: 0.8).toFloat()
                val maxTokens = call.argument<Int>("maxTokens") ?: 768
                val repeatPenalty = (call.argument<Double>("repeatPenalty") ?: 1.1).toFloat()

                scope.launch {
                    try {
                        val text = getNative().generate(
                            prompt,
                            temperature,
                            topK,
                            topP,
                            maxTokens,
                            repeatPenalty,
                        )
                        val stats = getNative().getLastStats()
                        withContext(Dispatchers.Main) {
                            result.success(
                                mapOf(
                                    "text" to text,
                                    "stats" to statsMap(stats),
                                ),
                            )
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("GENERATE_ERROR", e.message, null)
                        }
                    }
                }
            }

            "startGenerate" -> {
                val prompt = call.argument<String>("prompt")
                if (prompt == null) {
                    result.error("INVALID_ARGUMENT", "prompt is required", null)
                    return
                }
                if (eventSink == null) {
                    result.error("NO_STREAM", "No stream listener", null)
                    return
                }
                if (!generating.compareAndSet(false, true)) {
                    result.error("BUSY", "A generation is already running", null)
                    return
                }

                val temperature = (call.argument<Double>("temperature") ?: 0.4).toFloat()
                val topK = call.argument<Int>("topK") ?: 20
                val topP = (call.argument<Double>("topP") ?: 0.8).toFloat()
                val maxTokens = call.argument<Int>("maxTokens") ?: 768
                val repeatPenalty = (call.argument<Double>("repeatPenalty") ?: 1.1).toFloat()

                result.success(true)
                scope.launch {
                    try {
                        val sink = MnnTokenSink { token -> enqueueToken(token) }
                        val cancelled = getNative().generateStream(
                            prompt,
                            temperature,
                            topK,
                            topP,
                            maxTokens,
                            repeatPenalty,
                            sink,
                        )
                        val stats = getNative().getLastStats()
                        withContext(Dispatchers.Main) {
                            mainHandler.removeCallbacks(flushRunnable)
                            flushTokens()
                            eventSink?.success(
                                mapOf(
                                    "type" to "done",
                                    "stats" to statsMap(stats),
                                    "cancelled" to cancelled,
                                ),
                            )
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            mainHandler.removeCallbacks(flushRunnable)
                            flushTokens()
                            eventSink?.success(
                                mapOf(
                                    "type" to "error",
                                    "message" to (e.message ?: "MNN stream error"),
                                ),
                            )
                        }
                    } finally {
                        generating.set(false)
                    }
                }
            }

            "cancelGenerate" -> {
                getNative().cancelGenerate()
                result.success(null)
            }

            "releaseModel" -> {
                native?.releaseModel()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        streamChannel.setStreamHandler(null)
        eventSink = null
        mainHandler.removeCallbacks(flushRunnable)
        scope.cancel()
    }

    private companion object {
        const val FLUSH_INTERVAL_MS = 40L
    }
}
