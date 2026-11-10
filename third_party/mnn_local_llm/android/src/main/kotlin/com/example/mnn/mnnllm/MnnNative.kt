package com.example.mnn.mnnllm

/**
 * JNI bridge to libMNN.so. All methods are implemented in mnn_bridge.cpp.
 *
 * libMNN.so already contains the MNN runtime and the LLM engine. The C++
 * runtime is shared across the plugin and libMNN.so, so c++_shared must be
 * loaded first.
 */
class MnnNative {
    external fun loadModel(modelDir: String): Boolean

    external fun generate(
        prompt: String,
        temperature: Float,
        topK: Int,
        topP: Float,
        maxTokens: Int,
        repeatPenalty: Float,
    ): String

    /** Returns [promptTokens, decodeTokens, prefillUs, decodeUs]. */
    external fun getLastStats(): LongArray

    external fun cancelGenerate()

    external fun releaseModel()

    companion object {
        init {
            System.loadLibrary("c++_shared")
            System.loadLibrary("MNN")
            System.loadLibrary("mnn_bridge")
        }
    }
}
