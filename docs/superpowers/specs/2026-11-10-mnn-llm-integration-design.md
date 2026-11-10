# MNN 端侧 LLM 后端替换设计

- 日期：2026-11-10
- 状态：已评审（2026-11-10）
- 目标仓库：`/Users/fitz/REPO/mnn`
- 相关测量：`_sources/mnn-bench/RESULTS.md`

## 1. 背景

当前 Flutter Demo 使用 vendored `onenm_local_llm` 插件，通过 llama.cpp 加载
`MNN-Pocket-0.3B-Instruct-Q4_1.gguf`。同机实测（SM6435）llama.cpp decode 为
46.6 tok/s，而 MNN INT4 为 62–68 tok/s。下一步把 MNN 引擎接入 App，替换
llama.cpp，并保留现有 UI、ASR、打断和指标展示。

## 2. 目标

- 用 MNN runtime 加载 `MNN-Pocket-0.3B-MNN`（INT4 W4A16），完全离线运行。
- 保留现有单页聊天、流式 ASR、按住说话、打断、生成参数、设备指标。
- 模型支持 App 内从 ModelScope 下载，也支持 `adb` 推送。
- 指标行增加 MNN 的 decode tok/s。
- 删除 llama.cpp / GGUF 相关依赖和代码。

## 3. 非目标

- 不做逐 token 流式文本输出（当前 App 实际也是一次性返回）。
- 不保留 llama.cpp 双后端切换。
- 不支持 iOS、x86、armeabi-v7a。
- 不实现模型导出、量化或 MNN 模型转换流水线。

## 4. 已确认决策

| 决策 | 结论 |
| --- | --- |
| llama.cpp | 彻底移除 |
| 模型分发 | App 内 ModelScope 下载 + `tools/provision_device.sh` 推送 |
| 生成输出 | 对齐现状，不做流式 |
| 指标 | 增加 decode tok/s |
| 原生集成 | 预编译共享库 `libMNN.so` + JNI bridge |

## 5. 总体架构

```
lib/main.dart
  └─ MnnLlm（third_party/mnn_local_llm）
       └─ MethodChannel "mnn_local_llm"
            └─ Kotlin MnnLocalLlmPlugin
                 └─ JNI mnn_bridge.cpp
                      └─ libMNN.so（MNN runtime + llm engine）
```

ASR / VAD / 录音 / UI 布局不变：

```
sherpa_onnx（Dart FFI） → X-ASR INT8 + Silero VAD
```

## 6. 模型包与分发

### 6.1 文件清单

模型来源：<https://modelscope.cn/models/MNN/MNN-Pocket-0.3B-MNN>

| 文件 | 字节数 | 说明 |
| --- | ---: | --- |
| `config.json` | 502 | 模型结构配置 |
| `llm.mnn` | 953,112 | 计算图 |
| `llm.mnn.weight` | 171,481,330 | INT4 权重 |
| `llm_config.json` | 3,237 | LLM 运行配置与 chat template |
| `tokenizer.mtok` | 1,710,861 | tokenizer |

合计 174,259,042 字节，约 166.2 MiB。UI 文案使用「约 166 MB」。

### 6.2 本地目录

```
<appDocuments>/models/MNN-Pocket-0.3B-MNN/
  config.json
  llm.mnn
  llm.mnn.weight
  llm_config.json
  tokenizer.mtok
```

`MnnLlm.initialize()` 把模型目录路径传给原生层，而不是单个文件。

### 6.3 下载流程

- `MnnModel` 保存文件列表、每个文件的下载 URL 和期望字节数。
- 按文件顺序下载到 `<name>.part`，完成后校验大小并原子重命名为正式文件。
- 进度按「已接收总字节 / 模型总字节」汇总，沿用现有 UI 可解析的格式：
  - `Downloading MNN-Pocket 0.3B...\n45.2 / 166.2 MB (27.2%)`
  - 完成时 `Download complete`
- 保留现有重试策略：单文件最多 3 次自动重试，失败后通过 `onRetryRequired`
  让 App 弹窗；断网时等待用户重试。
- 只重下缺失或大小不合格的文件，不整包重下。

### 6.4 校验与恢复

- 小文件要求大小完全一致，权重文件允许 `>= 95%`。
- 启动时若目录缺失或不完整，进入下载流程。
- 原生加载失败时：删除整个模型目录，重新下载一次，再重试加载；仍失败则
  进入错误页并显示模型路径。

### 6.5 adb 推送

`tools/provision_device.sh` 改为：

- LLM：把 `_sources/MNN-Pocket-0.3B-MNN/` 下 5 个文件推到
  `app_flutter/models/MNN-Pocket-0.3B-MNN/`。
- ASR/VAD：保持现有逻辑不变。
- 仍要求 debug APK（依赖 `run-as`）。

## 7. Dart 插件 API

新建 `third_party/mnn_local_llm`，删除 `third_party/onenm_local_llm`。

### 7.1 类型

```dart
class MnnModelFile {
  final String name;
  final String url;
  final int bytes;
}

class MnnModel {
  final String id;
  final String name;
  final String dirName;
  final List<MnnModelFile> files;
  final int minRamGB;
  final int context;
  final MnnChatTemplate chatTemplate;

  int get totalBytes;
}

class MnnGenerationSettings {
  final double temperature; // 0.4
  final int topK;           // 20
  final double topP;        // 0.8
  final int maxTokens;      // 768
  final double repeatPenalty; // 1.1
}

class MnnGenerationResult {
  final String text;
  final int promptTokens;
  final int decodeTokens;
  final double prefillMs;
  final double decodeMs;

  double get decodeTokensPerSecond;
}
```

`MnnChatTemplate` 保留当前 ChatML 实现，避免把模板逻辑下沉到原生层。
`llm_config.json` 里的 jinja 模板不参与格式化（原生层设置 `use_template=false`）。

`MnnModel.context` 仅作为展示/未来历史裁剪的元数据；本次不强制 2048 上下文。
MNN 模型本身支持最长 32K，现有 App 的历史行为保持不变。

### 7.2 MnnLlm

```dart
class MnnLlm {
  final MnnModel model;
  final MnnGenerationSettings settings;
  final void Function(String status)? onProgress;
  final Future<bool> Function(String message)? onRetryRequired;

  MnnGenerationResult? lastResult;

  Future<void> initialize();
  Future<String> chat(String message, {String? systemPrompt});
  Future<String> generate(String rawPrompt);
  Future<void> cancelGenerate();
  void clearHistory();
  Future<void> dispose();
}
```

- `chat` 维护与当前实现相同的历史和 system prompt。
- `lastResult` 在每次生成后更新，供 UI 读取 tok/s。
- `cancelGenerate` 返回已生成的部分文本。

### 7.3 平台通道协议

MethodChannel：`mnn_local_llm`

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `loadModel` | `modelDir: String` | `Bool` |
| `generate` | `prompt, temperature, topK, topP, maxTokens, repeatPenalty` | `Map` |
| `cancelGenerate` | — | `null` |
| `releaseModel` | — | `null` |

`generate` 返回：

```json
{
  "text": "...",
  "stats": {
    "promptTokens": 55,
    "decodeTokens": 142,
    "prefillUs": 431420,
    "decodeUs": 3048604
  }
}
```

## 8. 原生层

### 8.1 产物与加载

放在 `third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/`：

| 文件 | 体积 |
| --- | ---: |
| `libMNN.so` | 4.0 MB（strip 后） |
| `libc++_shared.so` | 1.2 MB（NDK 28.2 strip 后） |
| `libmnn_bridge.so` | 约 100 KB（App 构建时编译） |

加载顺序：

```kotlin
System.loadLibrary("c++_shared")
System.loadLibrary("MNN")
System.loadLibrary("mnn_bridge")
```

`libMNN.so` 已包含 MNN runtime 和 LLM engine，无需再拆 `libllm.so`。

### 8.2 模型加载

```cpp
llm = Llm::createLLM(modelDir + "/config.json");
llm->set_config(R"({
  "thread_num": 4,
  "use_template": false,
  "max_new_tokens": 768
})");
llm->load();
llm->tuning(OP_ENCODER_NUMBER, {1, 5, 10, 20, 30, 50, 100});
```

- `thread_num=4`：spike 中 2/4 线程最优，6/8 线程明显负优化。
- `use_template=false`：prompt 已由 Dart 侧按 ChatML 格式化，避免重复套模板。
- `tuning` 在加载阶段执行一次；spike 实测约 333 ms，可接受。

### 8.3 生成与取消

每次生成前 `llm->reset()`，清空 KV 和历史，行为与当前 llama.cpp 实现一致。

```cpp
cancel_requested.store(false);
llm->set_config(sampling_json);
llm->reset();

std::ostringstream os;
llm->response(prompt, &os, nullptr, 0);   // 只做 prefill
auto ctx = llm->getContext();

while (!llm->stoped() && ctx->gen_seq_len < maxTokens) {
    if (cancel_requested.load()) break;
    llm->generate(1);
}

std::string text;
{
    std::lock_guard<std::mutex> lock(ctx->mutex);
    text = ctx->generate_str;
}
```

- 取消：`cancelGenerate()` 只设置 `std::atomic<bool>`，生成循环每个 token 检查一次。
- 返回部分文本，与当前「已停止」行为一致。
- 采样参数通过 `set_config` 写入：
  `temperature`、`topK`、`topP`、`repetition_penalty`、`max_new_tokens`。

### 8.4 统计

生成结束后从 `LlmContext` 读取：

- `prompt_len`
- `gen_seq_len`
- `prefill_us`
- `decode_us`

JNI 返回 `LongArray`：`[promptTokens, decodeTokens, prefillUs, decodeUs]`，
Kotlin 转成 Map。Dart 计算 `decodeTokensPerSecond = decodeTokens / decodeUs * 1e6`。

### 8.5 JNI 接口

Kotlin 包名：`com.example.mnn.mnnllm`

```kotlin
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
    external fun getLastStats(): LongArray
    external fun cancelGenerate()
    external fun releaseModel()
}
```

C++ 文件：`mnn_bridge.cpp`。

### 8.6 线程与生命周期

- Kotlin 在 `Dispatchers.IO` 执行加载和生成，MethodChannel 调用不阻塞主线程。
- 原生层用 `std::mutex` 保证同一时刻只有一个生成或加载操作。
- `releaseModel` 先设置取消标志，再获取锁并释放 `Llm`。
- App 的 `_busy` 仍然阻止并发发送；原生锁只作为最后一道保护。

## 9. UI 变更

- 模型描述：
  - 名称 `MNN-Pocket 0.3B`
  - 副标题 `端侧 · MNN INT4 · CPU`
  - 下载文案 `约 166 MB`
- 指标行：
  - 现在：`SM6435 · 7.2GB · 6.50s · 310 字`
  - 之后：`SM6435 · 7.2GB · 6.50s · 310 字 · 62 tok/s`
  - 无统计时省略 `tok/s` 段。
- 关于页、启动页、README 删除 llama.cpp / GGUF 描述，改为 MNN runtime。
- README 的「流式文本生成」改为真实描述：完整回复后一次上屏。
- 生成参数面板不变，参数仍传给 `MnnGenerationSettings`。

## 10. 构建与仓库

- 新增 `tools/build_mnn_android.sh`：
  - 固定 MNN commit：`b0239771b07b317a258fbc384683bbd540741406`
  - 浅克隆到 `_sources/MNN`
  - NDK 28.2，`arm64-v8a`，`c++_shared`
  - 关键宏：`MNN_BUILD_LLM=ON`、`MNN_LOW_MEMORY=ON`、
    `MNN_SUPPORT_TRANSFORMER_FUSE=ON`、`MNN_BUILD_SHARED_LIBS=ON`、
    `MNN_SEP_BUILD=OFF`、CPU-only
  - strip 后复制 `libMNN.so` 到插件 `jniLibs/`
  - 从 NDK sysroot 复制并 strip `libc++_shared.so`
- 仓库提交 `libMNN.so` 与 `libc++_shared.so` 两个预编译产物；bridge 在 App 构建时编译。
  使用者不需要本地 MNN 源码。
- `pubspec.yaml` 依赖改为 `mnn_local_llm`。
- 预计 APK：233 MB → 约 190 MB。

## 11. 删除项

- `third_party/onenm_local_llm/`（Dart、Kotlin、C++、jniLibs）
- llama.cpp / ggml / OpenMP 预编译库
- GGUF 模型描述、下载 URL、README 中的 llama.cpp 依赖说明
- 旧 `ChatTemplate`/`OneNmModel` 命名

## 12. 测试

### 12.1 Dart 单测

- `MnnModel.totalBytes` 与文件字节数一致。
- 单文件大小校验：小文件精确、权重允许 95%。
- 目录完整性判断：缺失、截断、全部齐全。
- 进度百分比计算：跨文件累计。

### 12.2 静态检查

```bash
flutter analyze
flutter test
```

### 12.3 真机验收

- 首次下载：删除模型目录，启动 App，确认下载进度、完成、加载成功。
- adb 推送：`tools/provision_device.sh` 后直接启动，不触发下载。
- 对话：同一条 Rust 斐波那契 prompt，输出正常。
- 打断：生成中点击停止，保留部分回答并显示「已停止」。
- 指标：显示 decode tok/s，数值在 55–70 tok/s（SM6435）。
- ASR：按住说话、松手发送、流式识别正常。
- 参数：修改 temperature/topK/topP/maxTokens 后重新加载生效。
- 负向：模型目录缺文件、权重截断、加载失败重试路径。
- 干净安装：卸载后重装，确认 `libc++_shared`/`libMNN` 加载无 `UnsatisfiedLinkError`。

### 12.4 回归

- ASR 流式、VAD、打断。
- 内置意图分类评测（`AUTO_EVAL`）。
- APK 中不再包含 `libllama.so`、`libggml*.so`、`libomp.so`。

## 13. 验收标准

- App 在真机上完全离线完成 LLM 推理，输出质量与 spike 一致。
- 同 prompt decode 速度不低于 55 tok/s（SM6435），目标 62–68 tok/s。
- 现有 ASR、打断、指标、参数面板全部可用。
- 指标行展示 tok/s。
- 仓库与 APK 中无 llama.cpp/GGUF 残留。
- `flutter analyze` 与 `flutter test` 通过。
- 已有 `libMNN.so` 可由 `tools/build_mnn_android.sh` 在固定 commit 上重建。

## 14. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| C++ STL 跨 `.so` 边界 | 统一 `c++_shared`，按 `c++_shared → MNN → bridge` 顺序加载；干净安装验证 |
| `use_template=false` 未生效导致双重模板 | 用固定 prompt 检查输出与 prompt token 数；必要时改用 `ChatMessages` API |
| `generate(1)` 循环比整段生成慢 | spike 已使用同一循环，实测 62–68 tok/s；不达标时再对比整段生成 |
| MNN 启动 tuning 增加等待 | 实测 333 ms；超过 2 s 则改为可配置/跳过 |
| ModelScope 下载不稳定 | 单文件重试 + 用户重试 + adb 推送兜底 |
| 共享库与 App ABI/NDK 不匹配 | 固定 NDK 28.2、arm64-v8a；构建脚本与 README 记录 |
| 低内存设备 OOM | spike 峰值 RSS 265 MB；保留加载失败提示 |

## 15. 许可

- MNN：Apache-2.0
- MNN-Pocket-0.3B：Apache-2.0
- X-ASR：Apache-2.0
- Silero VAD：MIT
- sherpa-onnx：Apache-2.0
- 删除的 llama.cpp / onenm_local_llm：MIT
