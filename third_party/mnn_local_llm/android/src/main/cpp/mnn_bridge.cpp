#include <android/log.h>
#include <jni.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>

#include "llm/llm.hpp"

using MNN::Transformer::Llm;
using MNN::Transformer::LlmContext;
using MNN::Transformer::OP_ENCODER_NUMBER;

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "mnn_bridge", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "mnn_bridge", __VA_ARGS__)

namespace {
std::unique_ptr<Llm> g_llm;
std::mutex g_mutex;
std::atomic<bool> g_cancel{false};
jlong g_stats[4] = {0, 0, 0, 0};  // promptTokens, decodeTokens, prefillUs, decodeUs

std::string jstringToString(JNIEnv* env, jstring value) {
    if (value == nullptr) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

void releaseModelLocked() {
    if (g_llm) {
        g_llm.reset();
    }
}
}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_mnn_mnnllm_MnnNative_loadModel(JNIEnv* env, jobject /*thiz*/, jstring jModelDir) {
    const std::string modelDir = jstringToString(env, jModelDir);
    if (modelDir.empty()) {
        LOGE("loadModel: empty model directory");
        return JNI_FALSE;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    releaseModelLocked();

    const std::string configPath = modelDir + "/config.json";
    g_llm.reset(Llm::createLLM(configPath));
    if (!g_llm) {
        LOGE("loadModel: createLLM failed for %s", configPath.c_str());
        return JNI_FALSE;
    }

    g_llm->set_config(R"({"thread_num":4,"use_template":false,"max_new_tokens":768})");
    if (!g_llm->load()) {
        LOGE("loadModel: llm->load() failed for %s", modelDir.c_str());
        g_llm.reset();
        return JNI_FALSE;
    }

    g_llm->tuning(OP_ENCODER_NUMBER, {1, 5, 10, 20, 30, 50, 100});
    g_stats[0] = g_stats[1] = g_stats[2] = g_stats[3] = 0;
    LOGI("loadModel: loaded %s", modelDir.c_str());
    return JNI_TRUE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_mnn_mnnllm_MnnNative_generate(
        JNIEnv* env,
        jobject /*thiz*/,
        jstring jPrompt,
        jfloat temperature,
        jint topK,
        jfloat topP,
        jint maxTokens,
        jfloat repeatPenalty) {
    const std::string prompt = jstringToString(env, jPrompt);

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_llm) {
        LOGE("generate: model not loaded");
        return env->NewStringUTF("");
    }

    g_cancel.store(false);
    g_llm->reset();

    char config[256];
    std::snprintf(
            config,
            sizeof(config),
            R"({"temperature":%.2f,"topK":%d,"topP":%.2f,"max_new_tokens":%d,"repetition_penalty":%.2f})",
            temperature,
            topK,
            topP,
            maxTokens,
            repeatPenalty);
    g_llm->set_config(config);

    std::ostringstream os;
    g_llm->response(prompt, &os, nullptr, 0);

    const LlmContext* ctx = g_llm->getContext();
    if (ctx == nullptr) {
        LOGE("generate: missing context");
        return env->NewStringUTF("");
    }

    if (!g_cancel.load()) {
        while (!g_llm->stoped() && ctx->gen_seq_len < maxTokens) {
            if (g_cancel.load()) break;
            g_llm->generate(1);
        }
    }

    std::string text;
    {
        std::lock_guard<std::mutex> ctxLock(ctx->mutex);
        text = ctx->generate_str;
    }

    g_stats[0] = ctx->prompt_len;
    g_stats[1] = ctx->gen_seq_len;
    g_stats[2] = ctx->prefill_us;
    g_stats[3] = ctx->decode_us;

    LOGI("generate: prompt=%d decode=%d prefill=%.2fms decode=%.2fms chars=%zu%s",
         ctx->prompt_len,
         ctx->gen_seq_len,
         ctx->prefill_us / 1000.0,
         ctx->decode_us / 1000.0,
         text.size(),
         g_cancel.load() ? " (cancelled)" : "");

    return env->NewStringUTF(text.c_str());
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_example_mnn_mnnllm_MnnNative_getLastStats(JNIEnv* env, jobject /*thiz*/) {
    jlongArray result = env->NewLongArray(4);
    if (result != nullptr) {
        env->SetLongArrayRegion(result, 0, 4, g_stats);
    }
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_mnn_mnnllm_MnnNative_cancelGenerate(JNIEnv* /*env*/, jobject /*thiz*/) {
    g_cancel.store(true);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_mnn_mnnllm_MnnNative_releaseModel(JNIEnv* /*env*/, jobject /*thiz*/) {
    g_cancel.store(true);
    std::lock_guard<std::mutex> lock(g_mutex);
    releaseModelLocked();
    LOGI("releaseModel: released");
}
