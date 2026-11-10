# MNN LLM Backend Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the llama.cpp/GGUF backend with MNN runtime + the MNN-Pocket INT4 model, keeping the existing chat UI, ASR, interrupt, and settings.

**Architecture:** A new Flutter plugin `third_party/mnn_local_llm` exposes `MnnLlm`, which manages a 5-file model directory and talks over MethodChannel `mnn_local_llm` to a Kotlin plugin. The Kotlin plugin calls a JNI bridge linked against a prebuilt `libMNN.so` (MNN runtime + LLM engine). Model download and adb provisioning both target one model directory. Generation returns the full text plus token/timing stats for the UI.

**Tech Stack:** Flutter/Dart, Kotlin, JNI/C++, CMake, MNN `b0239771b07b317a258fbc384683bbd540741406`, MNN-Pocket-0.3B-MNN INT4, Android NDK 28.2.13676358, sherpa_onnx ASR.

**Spec:** `docs/superpowers/specs/2026-11-10-mnn-llm-integration-design.md`

## Global Constraints

- Android arm64-v8a only; minSdk 21; no iOS/x86/armeabi-v7a.
- MNN commit exactly `b0239771b07b317a258fbc384683bbd540741406`.
- NDK exactly 28.2.13676358; C++ runtime `c++_shared`.
- MNN build flags: `MNN_BUILD_LLM=ON`, `MNN_LOW_MEMORY=ON`, `MNN_SUPPORT_TRANSFORMER_FUSE=ON`, `MNN_BUILD_SHARED_LIBS=ON`, `MNN_SEP_BUILD=OFF`, CPU-only.
- Model directory name `MNN-Pocket-0.3B-MNN`; total bytes `174259042`.
- Model files and exact sizes: `config.json` 502, `llm.mnn` 953112, `llm.mnn.weight` 171481330, `llm_config.json` 3237, `tokenizer.mtok` 1710861.
- ModelScope base URL: `https://modelscope.cn/models/MNN/MNN-Pocket-0.3B-MNN/resolve/master/`.
- Native config: `thread_num=4`, `use_template=false`, default `max_new_tokens=768`.
- Sampling defaults: temperature 0.4, topK 20, topP 0.8, maxTokens 768, repeatPenalty 1.1.
- MethodChannel name `mnn_local_llm`; Kotlin package `com.example.mnn.mnnllm`; plugin class `MnnLocalLlmPlugin`.
- No token streaming; no llama.cpp fallback; no GGUF references after Task 9.
- Keep ASR, VAD, recording, interrupt, and general UI behavior unchanged.

## Review Focus

- A model directory missing one file or holding a truncated weight: only the bad file is re-downloaded, and the app never loads a partial model.
- Clean install on a device with no pre-extracted libs: `libc++_shared.so → libMNN.so → libmnn_bridge.so` load without `UnsatisfiedLinkError`.
- Prompt already formatted with ChatML while native `use_template=false`: no double template, and the reply is coherent.
- Cancel during generation, then immediately send again or release the model: partial text returns, no deadlock, next generation succeeds.
- Network drops mid-file: `.part` is never treated as valid, retry resumes from a clean file, and the UI still parses the progress percentage.

---

### Task 1: Vendor MNN artifacts and build script

**Files:**
- Create: `tools/build_mnn_android.sh`
- Create: `third_party/mnn_local_llm/android/src/main/cpp/mnn/include/MNN/` (copied headers)
- Create: `third_party/mnn_local_llm/android/src/main/cpp/mnn/include/llm/` (copied headers)
- Create: `third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/libMNN.so`
- Create: `third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/libc++_shared.so`

**Interfaces:**
- Produces: prebuilt native libraries and headers consumed by Task 5's CMake build.

- [ ] **Step 1: Write `tools/build_mnn_android.sh`**

Script requirements:
- `set -euo pipefail`; resolve repo root from `BASH_SOURCE`.
- `MNN_COMMIT="b0239771b07b317a258fbc384683bbd540741406"`.
- `NDK="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"`; fail with a clear message if it is missing.
- Detect the LLVM host directory (`darwin-x86_64` on macOS, `linux-x86_64` on Linux) for `llvm-strip`.
- Clone `https://github.com/alibaba/MNN.git` shallow to `_sources/MNN` when absent, then checkout the pinned commit.
- Build directory `_sources/mnn-build-android-shared`.
- Configure with the exact flags from Global Constraints and `-DMNN_LLM_BUILD_DEMO=OFF`, `-DMNN_BUILD_OPENCV=OFF`, `-DMNN_BUILD_DIFFUSION=OFF`, `-DMNN_BUILD_BENCHMARK=OFF`, `-DMNN_BUILD_TEST=OFF`, `-DMNN_BUILD_TOOLS=OFF`, `-DMNN_BUILD_FOR_ANDROID_COMMAND=true`, `-DMNN_USE_LOGCAT=OFF`, `-DMNN_USE_SSE=OFF`.
- Build target `MNN` with `-j` equal to `sysctl -n hw.ncpu` on macOS, fallback `nproc`.
- `llvm-strip --strip-unneeded` the built `libMNN.so` and the NDK `sysroot/usr/lib/aarch64-linux-android/libc++_shared.so`.
- Copy both to `third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/`.
- Copy `_sources/MNN/include/MNN` and `_sources/MNN/transformers/llm/engine/include/llm` into `third_party/mnn_local_llm/android/src/main/cpp/mnn/include/`.

- [ ] **Step 2: Run the script**

Run: `chmod +x tools/build_mnn_android.sh && tools/build_mnn_android.sh`
Expected: exits 0, prints the two `.so` destinations.

- [ ] **Step 3: Verify artifacts**

Run:
```bash
file third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/libMNN.so
$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf -d \
  third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/libMNN.so | grep NEEDED
```
Expected: `ELF 64-bit LSB shared object, ARM aarch64`; NEEDED includes `libc++_shared.so`, `liblog.so`, `libm.so`, `libandroid.so`, `libc.so`.

- [ ] **Step 4: Commit**

```bash
git add tools/build_mnn_android.sh third_party/mnn_local_llm
git commit -m "feat(mnn): vendor MNN runtime and Android build script"
```

---

### Task 2: Plugin package and model types

**Files:**
- Create: `third_party/mnn_local_llm/pubspec.yaml`
- Create: `third_party/mnn_local_llm/analysis_options.yaml`
- Create: `third_party/mnn_local_llm/lib/models.dart`
- Create: `third_party/mnn_local_llm/lib/mnn_local_llm.dart`
- Create: `third_party/mnn_local_llm/test/models_test.dart`

**Interfaces:**
- Produces: `MnnModelFile`, `MnnModel`, `MnnChatTemplate`, `MnnGenerationSettings`, `MnnGenerationResult`.
- Produces: `MnnModelFile.bytes`, `MnnModel.totalBytes`, `MnnGenerationSettings.toMap()`, `MnnGenerationResult.fromChannel(String, Map<dynamic, dynamic>)`, `MnnGenerationResult.decodeTokensPerSecond`.

- [ ] **Step 1: Write `test/models_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mnn_local_llm/mnn_local_llm.dart';

const _model = MnnModel(
  id: 'test',
  name: 'Test',
  dirName: 'test-model',
  files: [
    MnnModelFile(name: 'a.json', url: 'http://x/a.json', bytes: 100),
    MnnModelFile(name: 'w.weight', url: 'http://x/w.weight', bytes: 1000),
  ],
  minRamGB: 1,
  context: 2048,
  chatTemplate: MnnChatTemplate(
    system: '<|im_start|>system\n{text}<|im_end|>\n',
    user: '<|im_start|>user\n{text}<|im_end|>\n',
    assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
  ),
);

void main() {
  test('totalBytes sums all files', () {
    expect(_model.totalBytes, 1100);
  });

  test('chat template renders system, user, assistant prefix', () {
    final prompt = _model.chatTemplate.format(
      systemPrompt: 'sys',
      messages: [(role: 'user', text: 'hi')],
    );
    expect(prompt, '<|im_start|>system\nsys<|im_end|>\n'
        '<|im_start|>user\nhi<|im_end|>\n'
        '<|im_start|>assistant\n');
  });

  test('settings map contains channel keys', () {
    const s = MnnGenerationSettings();
    expect(s.toMap(), {
      'temperature': 0.4,
      'topK': 20,
      'topP': 0.8,
      'maxTokens': 768,
      'repeatPenalty': 1.1,
    });
  });

  test('result parses stats and computes tok/s', () {
    final r = MnnGenerationResult.fromChannel('ok', {
      'promptTokens': 55,
      'decodeTokens': 100,
      'prefillUs': 500000,
      'decodeUs': 2000000,
    });
    expect(r.text, 'ok');
    expect(r.promptTokens, 55);
    expect(r.decodeTokens, 100);
    expect(r.prefillMs, 500.0);
    expect(r.decodeMs, 2000.0);
    expect(r.decodeTokensPerSecond, 50.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd third_party/mnn_local_llm && flutter test test/models_test.dart`
Expected: FAIL because the package/files do not exist.

- [ ] **Step 3: Implement the package and types**

`pubspec.yaml`:
- name `mnn_local_llm`, version `0.1.0`, SDK `^3.5.3`, Flutter `>=3.3.0`.
- dependencies: `flutter`, `plugin_platform_interface: ^2.0.2`, `path_provider: ^2.1.2`, `http: ^1.2.0`.
- dev: `flutter_test`, `flutter_lints: ^4.0.0`.
- Android plugin: `package: com.example.mnn.mnnllm`, `pluginClass: MnnLocalLlmPlugin`.

`models.dart`:
- `MnnModelFile` with `const` ctor and final `name/url/bytes`.
- `MnnModel` with `const` ctor and `int get totalBytes`.
- `MnnChatTemplate` copied from the old ChatTemplate behavior: `format({String? systemPrompt, required List<({String role, String text})> messages})`, writes system + each message + `assistant.split('{text}').first`.
- `MnnGenerationSettings` defaults 0.4 / 20 / 0.8 / 768 / 1.1 and `toMap()`.
- `MnnGenerationResult` with `fromChannel(String text, Map<dynamic, dynamic> stats)` reading `promptTokens`, `decodeTokens`, `prefillUs`, `decodeUs`; `prefillMs`, `decodeMs`, `prefillTokensPerSecond`, `decodeTokensPerSecond`.

`mnn_local_llm.dart` exports `models.dart`; later tasks add exports.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd third_party/mnn_local_llm && flutter test test/models_test.dart`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add third_party/mnn_local_llm
git commit -m "feat(mnn): add plugin model types and chat template"
```

---

### Task 3: Model store and download

**Files:**
- Create: `third_party/mnn_local_llm/lib/model_store.dart`
- Create: `third_party/mnn_local_llm/test/model_store_test.dart`
- Modify: `third_party/mnn_local_llm/lib/mnn_local_llm.dart`

**Interfaces:**
- Produces: `bool isModelFileValid(MnnModelFile file, int actualBytes)`.
- Produces: `double modelProgress(int receivedBytes, int totalBytes)`.
- Produces: `String modelDownloadStatus(MnnModel model, int receivedBytes, int totalBytes)`.
- Produces: `Future<bool> isModelComplete(Directory dir, MnnModel model)`.
- Produces: `MnnModelStore({required MnnModel model, required Directory modelDir, required void Function(String) onProgress, required Future<bool> Function(String) onRetryRequired, http.Client Function()? clientFactory, Duration retryDelay})` with `Future<void> ensureModel()` and `Future<List<MnnModelFile>> missingFiles()`.

- [ ] **Step 1: Write `test/model_store_test.dart`**

Use `package:http/testing.dart` and `package:http/http.dart` with a tiny model:

```dart
const _fileA = MnnModelFile(name: 'a.json', url: 'http://test/a.json', bytes: 4);
const _fileW = MnnModelFile(name: 'w.weight', url: 'http://test/w.weight', bytes: 8);
const _model = MnnModel(
  id: 'test', name: 'Test', dirName: 'test-model',
  files: [_fileA, _fileW], minRamGB: 1, context: 2048,
  chatTemplate: MnnChatTemplate(system: '{text}', user: '{text}', assistant: '{text}'),
);
```

Tests:
1. `isModelFileValid` accepts exact small file; rejects 3/4 bytes. Accepts weight at 95% (`7` of 8? 8*0.95=7.6 → floor 7); rejects 6.
2. `modelProgress(50, 100) == 0.5`; `modelDownloadStatus` contains `50.0 / 100.0`? Use MB values: call with 1048576/2 in a 2×1 MiB model and assert `(50.0%)`.
3. `isModelComplete` with temp dir: write files of exact sizes → true; truncate weight to 6 bytes → false.
4. `ensureModel` downloads both missing files through `MockClient`, writes correct bytes, and the last progress message is `Download complete`.
5. Truncated weight: pre-create `a.json` valid and `w.weight` 6 bytes; `ensureModel` re-requests only `w.weight` (count URLs) and ends complete.
6. Retry: `MockClient` fails the first request with HTTP 500 then succeeds; use `retryDelay: Duration.zero`; `ensureModel` completes.
7. Offline: `MockClient` throws `SocketException`; `onRetryRequired` returns false; `ensureModel` throws; `.part` file does not exist.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd third_party/mnn_local_llm && flutter test test/model_store_test.dart`
Expected: FAIL because `model_store.dart` does not exist.

- [ ] **Step 3: Implement `model_store.dart`**

- `isModelFileValid`: weight threshold `(file.bytes * 0.95).floor()`, others exact; compare `actualBytes >= min`.
- `isModelComplete`: each file exists and is valid.
- `missingFiles`: returns files that do not exist or are invalid.
- `ensureModel`:
  - If complete: report `Model found (${(totalBytes / 1048576).toStringAsFixed(1)} MB)` and return.
  - For each missing file: `baseBytes = totalBytes - sum(missing.bytes)` plus bytes completed earlier in this run.
  - Download to `File('${modelDir.path}/${file.name}.part')`; on HTTP 200 stream chunks, update `onProgress(modelDownloadStatus(...))`; validate final size; rename `.part` to the final name.
  - Close every `http.Client` in a `finally` block.
  - 3 attempts per file with `retryDelay`; after exhaustion or `SocketException`, call `onRetryRequired`; if it returns true restart attempts, else rethrow. Delete `.part` on every failure.
  - Report `Download complete` once all files are valid.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd third_party/mnn_local_llm && flutter test test/model_store_test.dart`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add third_party/mnn_local_llm
git commit -m "feat(mnn): add resumable multi-file model store"
```

---

### Task 4: Platform channel and `MnnLlm`

**Files:**
- Create: `third_party/mnn_local_llm/lib/mnn_local_llm_platform_interface.dart`
- Create: `third_party/mnn_local_llm/lib/mnn_local_llm_method_channel.dart`
- Create: `third_party/mnn_local_llm/lib/mnn_llm.dart`
- Create: `third_party/mnn_local_llm/test/mnn_llm_test.dart`
- Modify: `third_party/mnn_local_llm/lib/mnn_local_llm.dart`

**Interfaces:**
- Produces: `MnnLocalLlmPlatform` with `Future<bool?> loadModel(String modelDir)`, `Future<Map<String, dynamic>?> generate(String prompt, Map<String, dynamic> settings)`, `Future<void> cancelGenerate()`, `Future<void> releaseModel()`.
- Produces: `MnnLlm({required MnnModel model, MnnGenerationSettings settings, void Function(String)? onProgress, Future<bool> Function(String)? onRetryRequired, Directory? modelRoot, http.Client Function()? clientFactory})`.
- Produces: `MnnGenerationResult? lastResult`, `Future<void> initialize()`, `Future<String> chat(String, {String? systemPrompt})`, `Future<String> generate(String)`, `Future<void> cancelGenerate()`, `void clearHistory()`, `Future<void> dispose()`.

- [ ] **Step 1: Write `test/mnn_llm_test.dart`**

```dart
class _FakePlatform extends MnnLocalLlmPlatform {
  String? loadedDir;
  String? lastPrompt;
  Map<String, dynamic>? lastSettings;
  bool cancelled = false;
  bool released = false;

  @override
  Future<bool?> loadModel(String dir) async {
    loadedDir = dir;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> generate(
      String prompt, Map<String, dynamic> settings) async {
    lastPrompt = prompt;
    lastSettings = settings;
    return {
      'text': 'hello',
      'stats': {
        'promptTokens': 10,
        'decodeTokens': 20,
        'prefillUs': 100000,
        'decodeUs': 400000,
      },
    };
  }

  @override
  Future<void> cancelGenerate() async => cancelled = true;

  @override
  Future<void> releaseModel() async => released = true;
}
```

Tests:
1. `initialize` loads the model directory and reports `Ready`.
2. `chat('hi', systemPrompt: 'sys')` sends the exact ChatML prompt and sets `lastResult!.decodeTokensPerSecond == 50`.
3. `chat` appends assistant history: a second `chat('again')` prompt contains both `hi` and `hello`.
4. `cancelGenerate` and `dispose` delegate to the platform.
5. `generate` throws `Exception` when the platform returns null.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd third_party/mnn_local_llm && flutter test test/mnn_llm_test.dart`
Expected: FAIL because the classes do not exist.

- [ ] **Step 3: Implement the platform interface and method channel**

- `MnnLocalLlmPlatform` extends `PlatformInterface` with the static token pattern copied from the old plugin; default instance `MethodChannelMnnLocalLlm`.
- Method channel `mnn_local_llm`; `loadModel` sends `{'modelDir': modelDir}`; `generate` sends `{'prompt': prompt, ...settings}`; parses the returned `Map` via `Map<String, dynamic>.from`.

- [ ] **Step 4: Implement `MnnLlm`**

- `initialize`: `modelDir = '${(modelRoot ?? await getApplicationDocumentsDirectory()).path}/${model.dirName}'`; create recursively; `MnnModelStore.ensureModel()`; `platform.loadModel(modelDir)`; if false delete the dir, download again, retry load once; throw on second failure; report `Ready`.
- `chat`: same history/template behavior as the old `OneNm.chat`; `_systemPrompt` persists.
- `generate`: call platform; null/empty result throws `Exception('MNN generation failed')`; build `lastResult` with `MnnGenerationResult.fromChannel(text, stats)`; return text.
- `dispose`: `releaseModel`, clear ready.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd third_party/mnn_local_llm && flutter test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add third_party/mnn_local_llm
git commit -m "feat(mnn): add Dart API and method channel client"
```

---

### Task 5: Kotlin plugin and JNI bridge

**Files:**
- Create: `third_party/mnn_local_llm/android/settings.gradle`
- Create: `third_party/mnn_local_llm/android/build.gradle`
- Create: `third_party/mnn_local_llm/android/src/main/AndroidManifest.xml`
- Create: `third_party/mnn_local_llm/android/src/main/kotlin/com/example/mnn/mnnllm/MnnNative.kt`
- Create: `third_party/mnn_local_llm/android/src/main/kotlin/com/example/mnn/mnnllm/MnnLocalLlmPlugin.kt`
- Create: `third_party/mnn_local_llm/android/src/main/cpp/CMakeLists.txt`
- Create: `third_party/mnn_local_llm/android/src/main/cpp/mnn_bridge.cpp`
- Modify: `pubspec.yaml` (add `mnn_local_llm` path dependency; keep the old dependency until Task 9)

**Interfaces:**
- Consumes: `libMNN.so`, `libc++_shared.so`, headers from Task 1.
- Produces: MethodChannel handlers for `loadModel`, `generate`, `cancelGenerate`, `releaseModel`.
- Produces: `generate` result `{text: String, stats: {promptTokens, decodeTokens, prefillUs, decodeUs}}`.

- [ ] **Step 1: Add the Gradle/CMake scaffolding**

- `settings.gradle`: `rootProject.name = 'mnn_local_llm'`.
- `build.gradle`: Android library, namespace `com.example.mnn.mnnllm`, compileSdk 34, minSdk 21, `abiFilters "arm64-v8a"`, CMake path `src/main/cpp/CMakeLists.txt`, Kotlin coroutines dependency `1.7.3`, Java/Kotlin target 1.8.
- `AndroidManifest.xml`: package only; no storage permission, no `extractNativeLibs` override.
- `CMakeLists.txt`: C++17; `add_library(mnn_bridge SHARED mnn_bridge.cpp)`; include `${CMAKE_CURRENT_SOURCE_DIR}/mnn/include`; import `libMNN.so` with `IMPORTED_NO_SONAME TRUE`; link `MNN` and `log`.

- [ ] **Step 2: Implement `mnn_bridge.cpp`**

JNI functions for `com.example.mnn.mnnllm.MnnNative`:
- `loadModel(modelDir)`:
  - `std::lock_guard` on a static mutex; reset existing model.
  - `g_llm.reset(Llm::createLLM(modelDir + "/config.json"))`; null → false.
  - `set_config` with `{"thread_num":4,"use_template":false,"max_new_tokens":768}`.
  - `load()`; on false reset and return false.
  - `tuning(OP_ENCODER_NUMBER, {1, 5, 10, 20, 30, 50, 100})`.
- `generate(prompt, temperature, topK, topP, maxTokens, repeatPenalty)`:
  - Lock mutex; `g_cancel = false`; `set_config` sampling JSON; `reset()`.
  - `std::ostringstream os; g_llm->response(prompt, &os, nullptr, 0);`
  - After prefill, `if (!g_cancel) { while (!g_llm->stoped() && ctx->gen_seq_len < maxTokens) { if (g_cancel) break; g_llm->generate(1); } }`
  - Copy `ctx->generate_str` under `ctx->mutex`; store `prompt_len`, `gen_seq_len`, `prefill_us`, `decode_us` in a static `jlong[4]`; return `NewStringUTF`.
  - On null model return an empty string.
- `getLastStats()`: return a new `jlongArray` of length 4.
- `cancelGenerate()`: `g_cancel = true`.
- `releaseModel()`: set cancel, lock, `g_llm.reset()`.
- Use `__android_log_print(ANDROID_LOG_INFO, "mnn_bridge", ...)` for load/generate summaries.

- [ ] **Step 3: Implement Kotlin**

- `MnnNative` companion loads `c++_shared`, `MNN`, `mnn_bridge` in that order; declares the five external methods.
- `MnnLocalLlmPlugin`: `MethodChannel("mnn_local_llm")`; `CoroutineScope(Dispatchers.IO + SupervisorJob())`.
  - `loadModel`: read `modelDir`, call native on IO, return Boolean.
  - `generate`: read `prompt` and numeric args with defaults `0.7/40/0.9/128/1.1`; call native; read `getLastStats()`; return `mapOf("text" to text, "stats" to mapOf(...))`.
  - `cancelGenerate`, `releaseModel`: call native directly and `success(null)`.
  - Unknown methods → `notImplemented()`.

- [ ] **Step 4: Build and verify packaging**

Run: `flutter pub get && flutter build apk --debug`
Expected: build succeeds.

Run:
```bash
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep -E 'libMNN|libmnn_bridge|libc\+\+_shared'
```
Expected: all three `.so` files under `lib/arm64-v8a/`.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock third_party/mnn_local_llm
git commit -m "feat(mnn): add Android JNI bridge and native plugin"
```

---

### Task 6: Provisioning script for MNN model directory

**Files:**
- Modify: `tools/provision_device.sh`
- Modify: `README.md` (only the provisioning paths in this task)

**Interfaces:**
- Consumes: `_sources/MNN-Pocket-0.3B-MNN/` with the five files.
- Produces: device path `app_flutter/models/MNN-Pocket-0.3B-MNN/`.

- [ ] **Step 1: Update the script**

- Replace the single `LLM` variable with an array of the five files under `_sources/MNN-Pocket-0.3B-MNN/`.
- Required file check iterates over all five.
- Create `app_flutter/models/MNN-Pocket-0.3B-MNN`; push each file to `/data/local/tmp/`, then `run-as cp` into the model directory; clean temp files.
- Keep ASR/VAD logic unchanged.
- Update header comments and the final `ls` to show the model directory.

- [ ] **Step 2: Verify on the connected device**

Run: `tools/provision_device.sh --serial 300c0ed8`
Expected: five `pushing ...` lines; final `run-as ls` shows the five files in `app_flutter/models/MNN-Pocket-0.3B-MNN`.

- [ ] **Step 3: Commit**

```bash
git add tools/provision_device.sh README.md
git commit -m "feat(mnn): provision MNN model directory to device"
```

---

### Task 7: App integration and first end-to-end run

**Files:**
- Create: `lib/model_config.dart`
- Modify: `lib/main.dart` (types, model path, bootstrap, init, chat, settings)
- Modify: `pubspec.yaml` / `pubspec.lock` (remove old dependency only after Task 9; keep both during this task)

**Interfaces:**
- Consumes: `MnnLlm`, `MnnModel`, `MnnGenerationSettings`, `isModelComplete` from Tasks 2–4.
- Produces: working chat path on MNN; `_ai.lastResult` available for Task 8.

- [ ] **Step 1: Create `lib/model_config.dart`**

```dart
import 'package:mnn_local_llm/mnn_local_llm.dart';

const String systemPrompt = '你是 MNN-Pocket，一个完全运行在手机本地的 AI 助手。回答简洁、准确，优先使用用户的语言。';

const MnnModel pocketModel = MnnModel(
  id: 'mnn-pocket-0.3b',
  name: 'MNN-Pocket 0.3B',
  dirName: 'MNN-Pocket-0.3B-MNN',
  files: [
    MnnModelFile(name: 'config.json', url: '.../config.json', bytes: 502),
    MnnModelFile(name: 'llm.mnn', url: '.../llm.mnn', bytes: 953112),
    MnnModelFile(name: 'llm.mnn.weight', url: '.../llm.mnn.weight', bytes: 171481330),
    MnnModelFile(name: 'llm_config.json', url: '.../llm_config.json', bytes: 3237),
    MnnModelFile(name: 'tokenizer.mtok', url: '.../tokenizer.mtok', bytes: 1710861),
  ],
  minRamGB: 1,
  context: 2048,
  chatTemplate: MnnChatTemplate(
    system: '<|im_start|>system\n{text}<|im_end|>\n',
    user: '<|im_start|>user\n{text}<|im_end|>\n',
    assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
    systemDefault: systemPrompt,
  ),
);

const MnnGenerationSettings defaultSettings = MnnGenerationSettings();
```

Use the ModelScope base URL for all five URLs.

- [ ] **Step 2: Modify `lib/main.dart`**

- Import `package:mnn_local_llm/mnn_local_llm.dart` and `model_config.dart`; remove `package:onenm_local_llm/...`.
- Delete the old `_systemPrompt`, `_pocketModel`, `_defaultSettings` definitions; use `systemPrompt`, `pocketModel`, `defaultSettings`.
- `OneNm? _ai` → `MnnLlm? _ai`; `GenerationSettings` → `MnnGenerationSettings` in state and `_applySettings`.
- `_status` initial text → `首次使用需要下载模型（约 166 MB）`.
- `_expectedModelPath` → return `'${dir.path}/models/${pocketModel.dirName}'`.
- `_bootstrap`: replace the single-file size check with `await isModelComplete(Directory(path), pocketModel)`.
- `_initModel`: construct `MnnLlm(model: pocketModel, settings: _settings, onProgress: _onProgress, onRetryRequired: _onRetry)`.
- Replace all `_systemPrompt` references with `systemPrompt`.
- Replace remaining `_pocketModel.fileName` / `_defaultSettings` references; the about/status copy is updated in Task 8.

- [ ] **Step 3: Build and install**

Run:
```bash
flutter pub get
flutter build apk --debug
adb -s 300c0ed8 install -r -t build/app/outputs/flutter-apk/app-debug.apk
```
Expected: build/install succeed.

- [ ] **Step 4: End-to-end smoke on device**

Run: `flutter run --dart-define=AUTO_SMOKE=true` (or build with the define and launch).
Expected:
- Logcat `1nm_bridge` equivalent tag `mnn_bridge` shows load success and a generate summary.
- The reply is coherent, not double-templated (no repeated `<|im_start|>` in the output).
- No `UnsatisfiedLinkError`.
- App shows the assistant reply.

- [ ] **Step 5: Cancel and re-send on device**

Send a prompt with a long answer, tap stop while generating, then immediately send
another prompt. Expected: the first reply keeps its partial text with `已停止`; the
second generation completes; logcat shows no deadlock or `USER_CANCEL` stuck state.
Also confirm the native prompt-token count is in the normal range (for the intro
prompt, roughly 40–80 tokens, not doubled by a second template).

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/model_config.dart pubspec.yaml pubspec.lock
git commit -m "feat(mnn): switch app chat to MNN backend"
```

---

### Task 8: Metrics line with tok/s

**Files:**
- Create: `lib/meta_format.dart`
- Create: `test/meta_format_test.dart`
- Modify: `lib/main.dart` (meta construction, about/status copy)

**Interfaces:**
- Produces: `String formatMetaLine({String? device, required double seconds, required int chars, MnnGenerationResult? result, bool stopped = false})`.
- Produces: `String formatSettingsLine(MnnGenerationSettings settings)`.

- [ ] **Step 1: Write `test/meta_format_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mnn/meta_format.dart';
import 'package:mnn_local_llm/mnn_local_llm.dart';

void main() {
  test('meta without stats omits tok/s', () {
    expect(
      formatMetaLine(device: 'SM6435 · 7.2GB', seconds: 6.5, chars: 310),
      'SM6435 · 7.2GB · 6.50s · 310 字',
    );
  });

  test('meta with stats appends rounded tok/s', () {
    final r = MnnGenerationResult.fromChannel('x', {
      'promptTokens': 55,
      'decodeTokens': 100,
      'prefillUs': 500000,
      'decodeUs': 2000000,
    });
    expect(
      formatMetaLine(device: 'SM6435', seconds: 6.5, chars: 310, result: r),
      'SM6435 · 6.50s · 310 字 · 50 tok/s',
    );
  });

  test('stopped suffix is preserved', () {
    expect(
      formatMetaLine(seconds: 1.0, chars: 5, stopped: true),
      '1.00s · 5 字 · 已停止',
    );
  });

  test('settings line matches current UI format', () {
    expect(
      formatSettingsLine(const MnnGenerationSettings()),
      'T=0.40 · top_p=0.80 · top_k=20 · max=768 · repeat=1.10',
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/meta_format_test.dart`
Expected: FAIL because `lib/meta_format.dart` does not exist.

- [ ] **Step 3: Implement `lib/meta_format.dart`**

- `formatMetaLine` joins non-empty parts: device, `${seconds.toStringAsFixed(2)}s`, `$chars 字`, `tok/s` only when `result != null && result.decodeTokens > 0 && result.decodeMs > 0`, `已停止`.
- `formatSettingsLine` produces the exact existing string with two decimals for temperature/topP/repeat and integer topK/max.

- [ ] **Step 4: Modify `lib/main.dart`**

- In `_send`, after `ai.chat`, use `formatMetaLine(device: ..., seconds: ..., chars: clean.length, result: ai.lastResult, stopped: _stopRequested)` and `formatSettingsLine(gen)`.
- Update about dialog: `量化：MNN INT4 (W4A16)`, `文件：约 166 MB`, `运行时：MNN (CPU, 4 线程)`.
- Update header subtitle to `端侧 · MNN INT4 · CPU`.
- Update welcome/onboarding copy from 183MB/GGUF/llama.cpp to 166MB/MNN.
- Update `_buildSetup` text and the stats chip text.

- [ ] **Step 5: Run tests and analyze**

Run: `flutter test && flutter analyze`
Expected: all tests pass, no analyzer errors.

- [ ] **Step 6: Device verification**

Run the app, send the Rust Fibonacci prompt, confirm the meta line shows `· NN tok/s` in the 55–70 range and the settings line is unchanged. Then cancel a generation and confirm `· 已停止` still appears.

- [ ] **Step 7: Commit**

```bash
git add lib/meta_format.dart lib/main.dart test/meta_format_test.dart
git commit -m "feat(mnn): show decode tok/s in message metrics"
```

---

### Task 9: Remove llama.cpp backend and update docs

**Files:**
- Delete: `third_party/onenm_local_llm/`
- Modify: `pubspec.yaml` / `pubspec.lock` (remove `onenm_local_llm`)
- Modify: `README.md` (full rewrite of architecture, model, metrics, build, limitations)
- Modify: `lib/main.dart` (remove any lingering GGUF/llama copy)
- Modify: `.gitignore` if needed (no new entries expected)

**Interfaces:**
- Produces: a repository with no llama.cpp/GGUF references; APK without llama/ggml/omp libs.

- [ ] **Step 1: Delete the old plugin and dependency**

```bash
git rm -r third_party/onenm_local_llm
```
Remove the `onenm_local_llm` path dependency from `pubspec.yaml`; run `flutter pub get`.

- [ ] **Step 2: Update README**

Replace:
- Title/intro: MNN-Pocket INT4, 166MB, MNN runtime.
- Architecture diagram: `lib/main.dart → mnn_local_llm → MethodChannel → Kotlin → JNI → libMNN.so`.
- Directory structure: `third_party/mnn_local_llm/`, `lib/model_config.dart`, `lib/meta_format.dart`, `tools/build_mnn_android.sh`.
- Model setup: five files, `_sources/MNN-Pocket-0.3B-MNN/`, ModelScope URL, provisioning path.
- Parameters: MNN INT4, thread 4, context behavior, sampling.
- Metrics: add `tok/s` explanation.
- APK size: ~190MB; remove llama.cpp claims.
- Known limitations: no streaming (state the truth), arm64 only, no llama.cpp fallback.
- Licensing: MNN Apache-2.0; remove llama.cpp/onenm lines.

- [ ] **Step 3: Search for leftovers**

Run:
```bash
grep -RniE 'llama|gguf|onenm|libggml|libomp|Q4_1|183 ?MB' \
  --exclude-dir=build --exclude-dir=_sources --exclude-dir=.git --exclude-dir=docs \
  --exclude='pubspec.lock' .
```
Expected: no matches. Historical mentions under `docs/superpowers/` are allowed.

- [ ] **Step 4: Build and verify APK contents**

Run:
```bash
flutter clean
flutter pub get
flutter build apk --debug
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep -E 'libllama|libggml|libomp|libMNN|libc\+\+_shared'
```
Expected: only `libMNN.so` and `libc++_shared.so` (plus unrelated app libs); no llama/ggml/omp.

- [ ] **Step 5: Run analyze and tests**

Run: `flutter analyze && flutter test`
Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove llama.cpp backend and update MNN docs"
```

---

### Task 10: Final on-device verification

**Files:**
- No source changes expected; fix regressions in place if found.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Clean build and install**

```bash
flutter clean
flutter pub get
flutter build apk --debug
adb -s 300c0ed8 install -r -t build/app/outputs/flutter-apk/app-debug.apk
```

- [ ] **Step 2: Provision and cold start**

```bash
tools/provision_device.sh --serial 300c0ed8
adb -s 300c0ed8 logcat -c
adb -s 300c0ed8 shell am force-stop com.example.mnn
adb -s 300c0ed8 shell am start -n com.example.mnn/.MainActivity
```
Expected: no `UnsatisfiedLinkError`; model loads; home screen shows 166MB MNN copy.

- [ ] **Step 3: Functional checks**

- Send `用 Rust 写一个斐波那契函数，带注释`; verify coherent output, no double ChatML markers.
- While generating, tap stop; verify partial reply + `已停止`; send another prompt successfully.
- Switch to voice mode, hold to talk, release; verify ASR text is sent and answered.
- Open settings, change temperature/max tokens, apply; verify new values appear in the settings line.
- Run `AUTO_EVAL=true` and confirm the eval screen completes.

- [ ] **Step 4: Performance check**

Use the same prompt and record the meta line. Expected decode `55–70 tok/s` on SM6435; compare with `_sources/mnn-bench/RESULTS.md` (62–68 tok/s). If it is below 55, capture `mnn_bridge` timing logs and investigate thread count/tuning before accepting.

- [ ] **Step 5: Download path check**

- Stop app, `adb shell run-as com.example.mnn rm -rf app_flutter/models/MNN-Pocket-0.3B-MNN`.
- Launch app; tap download; verify aggregate progress and completion; then send a message.
- If network is unavailable, verify the retry dialog and no partial file load.

- [ ] **Step 6: Commit any fixes and report**

```bash
git status --short
git add -A
git commit -m "fix(mnn): final device verification fixes"
```
Only commit if there are changes. Report the measured tok/s, APK size, and any remaining limitations.
