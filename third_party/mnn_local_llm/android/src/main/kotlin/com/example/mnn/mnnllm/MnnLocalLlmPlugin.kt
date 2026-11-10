package com.example.mnn.mnnllm

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Flutter plugin that routes method-channel calls to the MNN JNI bridge. */
class MnnLocalLlmPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var native: MnnNative? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private fun getNative(): MnnNative {
        if (native == null) native = MnnNative()
        return native!!
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "mnn_local_llm")
        channel.setMethodCallHandler(this)
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
                val temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat()
                val topK = call.argument<Int>("topK") ?: 40
                val topP = (call.argument<Double>("topP") ?: 0.9).toFloat()
                val maxTokens = call.argument<Int>("maxTokens") ?: 128
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
                                    "stats" to mapOf(
                                        "promptTokens" to stats[0].toInt(),
                                        "decodeTokens" to stats[1].toInt(),
                                        "prefillUs" to stats[2],
                                        "decodeUs" to stats[3],
                                    ),
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
        scope.cancel()
    }
}
