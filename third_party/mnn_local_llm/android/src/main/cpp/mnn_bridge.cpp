#include <android/log.h>
#include <jni.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>

#include "llm/llm.hpp"
#include "utf8.hpp"

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

jstring newStringFromUtf8(JNIEnv* env, const std::string& text) {
    const std::u16string utf16 = mnn_bridge::utf8ToUtf16(text);
    if (utf16.empty()) return env->NewStringUTF("");
    return env->NewString(
            reinterpret_cast<const jchar*>(utf16.data()),
            static_cast<jsize>(utf16.size()));
}

void releaseModelLocked() {
    if (g_llm) {
        g_llm.reset();
    }
}

struct RunResult {
    std::string text;
    bool cancelled = false;
};

RunResult runGeneration(
        JNIEnv* env,
        const std::string& prompt,
        jfloat temperature,
        jint topK,
        jfloat topP,
        jint maxTokens,
        jfloat repeatPenalty,
        jobject tokenSink,
        jmethodID onToken) {
    RunResult result;
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
        return result;
    }

    size_t lastLength = 0;
    std::string pendingUtf8;
    if (!g_cancel.load()) {
        while (!g_llm->stoped() && ctx->gen_seq_len < maxTokens) {
            if (g_cancel.load()) break;
            g_llm->generate(1);

            if (tokenSink == nullptr || onToken == nullptr) continue;
            std::string current;
            {
                std::lock_guard<std::mutex> ctxLock(ctx->mutex);
                current = ctx->generate_str;
            }
            if (current.size() <= lastLength) continue;

            pendingUtf8.append(current, lastLength, current.size() - lastLength);
            lastLength = current.size();

            const size_t complete = mnn_bridge::completeUtf8Length(pendingUtf8);
            if (complete == 0) continue;

            const std::string delta = pendingUtf8.substr(0, complete);
            pendingUtf8.erase(0, complete);
            jstring chunk = newStringFromUtf8(env, delta);
            if (chunk != nullptr) {
                env->CallVoidMethod(tokenSink, onToken, chunk);
                env->DeleteLocalRef(chunk);
            }
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                break;
            }
        }

        // Flush an incomplete tail as U+FFFD rather than dropping it silently.
        if (!pendingUtf8.empty() && tokenSink != nullptr && onToken != nullptr) {
            jstring chunk = newStringFromUtf8(env, pendingUtf8);
            if (chunk != nullptr) {
                env->CallVoidMethod(tokenSink, onToken, chunk);
                env->DeleteLocalRef(chunk);
            }
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
            }
        }
    }

    {
        std::lock_guard<std::mutex> ctxLock(ctx->mutex);
        result.text = ctx->generate_str;
    }
    result.cancelled = g_cancel.load();

    g_stats[0] = ctx->prompt_len;
    g_stats[1] = ctx->gen_seq_len;
    g_stats[2] = ctx->prefill_us;
    g_stats[3] = ctx->decode_us;

    LOGI("generate: prompt=%d decode=%d prefill=%.2fms decode=%.2fms chars=%zu%s",
         ctx->prompt_len,
         ctx->gen_seq_len,
         ctx->prefill_us / 1000.0,
         ctx->decode_us / 1000.0,
         result.text.size(),
         result.cancelled ? " (cancelled)" : "");
    return result;
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

    const RunResult result = runGeneration(
            env,
            prompt,
            temperature,
            topK,
            topP,
            maxTokens,
            repeatPenalty,
            nullptr,
            nullptr);
    return newStringFromUtf8(env, result.text);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_mnn_mnnllm_MnnNative_generateStream(
        JNIEnv* env,
        jobject /*thiz*/,
        jstring jPrompt,
        jfloat temperature,
        jint topK,
        jfloat topP,
        jint maxTokens,
        jfloat repeatPenalty,
        jobject tokenSink) {
    const std::string prompt = jstringToString(env, jPrompt);

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_llm) {
        LOGE("generateStream: model not loaded");
        return JNI_TRUE;
    }

    jclass sinkClass = env->GetObjectClass(tokenSink);
    if (sinkClass == nullptr) {
        LOGE("generateStream: missing token sink class");
        return JNI_TRUE;
    }
    jmethodID onToken =
            env->GetMethodID(sinkClass, "onToken", "(Ljava/lang/String;)V");
    if (onToken == nullptr) {
        LOGE("generateStream: missing onToken method");
        env->DeleteLocalRef(sinkClass);
        return JNI_TRUE;
    }

    const RunResult result = runGeneration(
            env,
            prompt,
            temperature,
            topK,
            topP,
            maxTokens,
            repeatPenalty,
            tokenSink,
            onToken);
    env->DeleteLocalRef(sinkClass);
    return result.cancelled ? JNI_TRUE : JNI_FALSE;
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
