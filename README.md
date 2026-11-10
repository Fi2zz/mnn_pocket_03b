# MNN-Pocket 0.3B · Android 端侧推理 Demo

在 Android 手机上**完全离线**运行 [MNN-Pocket-0.3B](https://modelscope.cn/models/MNN/MNN-Pocket-0.3B)（Q4_1 GGUF，183 MB），并用 **X-ASR-zh-en + Silero VAD** 做流式语音输入。

这个 Demo 用 **llama.cpp** 加载 GGUF，目的是验证模型效果和端侧交互，不是 MNN 引擎的性能复现。报告里 MNN 的 251 tok/s 是 MNN runtime 的数字，和本项目的 llama.cpp 构建不能直接对比。

---

## 功能

- **纯本地推理**：模型、语音、对话数据都不出设备，无 API Key、无网络请求
- **流式语音输入**：按住说话，松手自动发送；INT8 量化 ASR，边说边出字
- **流式文本生成**：token 逐个上屏，Markdown 实时渲染
- **可打断**：生成中右下角按钮变为停止，点击后保留已生成的部分回答
- **设备感知指标**：每条回答下方显示 SoC、内存、耗时、字数，以及完整生成参数
- **单页聊天**：没有底部 Tab，只有对话；输入框支持“文本 / 按住说话”两种模式
- **参数可调**：温度、Top-P、Top-K、最大生成长度，修改后重新加载模型生效
- **完全离线部署**：模型通过 adb 推送，适合内网/无网设备

## 界面

```
┌─────────────────────────────────┐
│ MNN-Pocket 0.3B            ⓘ ⚙ 🗑 │
│ 端侧 · GGUF Q4_1 · llama.cpp     │
├─────────────────────────────────┤
│  MNN-Pocket                     │
│  你好，我是 MNN-Pocket 0.3B…     │
│  本地模型 · 零网络请求           │
│                                 │
│              用 Rust 写一个斐波那契 │
│                                 │
│  MNN-Pocket                     │
│  /// 斐波那契数列…               │
│  SM6435 · 7.2GB · 6.50s · 310 字 │
│  T=0.40 · top_p=0.80 · top_k=20 │
│  · max=768 · repeat=1.10        │
├─────────────────────────────────┤
│ 发消息或按住说话             🎙  │
└─────────────────────────────────┘
```

- 文本框模式：占位符「发消息或按住说话」，键盘回车发送
- 语音模式：显示「按住说话」，按住开始流式识别，松手自动发送
- 右下角按钮：文本模式时是麦克风，语音模式时是键盘；生成中变成红色停止按钮
- 右上角：关于、生成参数、清空对话

## 技术架构

```
┌──────────────────────────────────────────────┐
│                  Flutter UI                  │
│                  lib/main.dart               │
├───────────────────────┬──────────────────────┤
│   onenm_local_llm     │     sherpa_onnx      │
│   Dart → MethodChannel│     Dart FFI         │
│        ↓              │        ↓             │
│   Kotlin Plugin       │   X-ASR INT8 + VAD   │
│        ↓ JNI          │   16 kHz 流式解码     │
│   llama.cpp (C++)     │                      │
│   libllama.so         │                      │
│   libggml*.so         │                      │
└───────────────────────┴──────────────────────┘
```

- LLM：vendored [`onenm_local_llm`](third_party/onenm_local_llm)，内部集成了 llama.cpp 预编译库（arm64-v8a）
- 取消生成：`std::atomic<bool>` 标志位，生成循环每个 token 检查一次，命中后返回已生成文本
- ASR：sherpa-onnx 的 `OnlineRecognizer`（Zipformer2 transducer，`greedy_search`）
- VAD：Silero VAD，用于判断说话起止和端点
- 录音：`record` 包，16 kHz 单声道 PCM

## 目录结构

```
.
├── lib/main.dart                      # 全部 UI、ASR 流程、指标展示
├── android/
│   └── app/src/main/kotlin/com/example/mnn/
│       └── MainActivity.kt            # device_info MethodChannel
├── third_party/onenm_local_llm/       # vendored llama.cpp Flutter 插件
│   ├── lib/                           # Dart API
│   └── android/src/main/
│       ├── cpp/onenm_bridge.cpp       # JNI + 生成循环 + 取消
│       └── jniLibs/arm64-v8a/         # libllama.so / libggml*.so
├── tools/provision_device.sh          # 一键推送模型到设备
├── _sources/                          # 模型与本地资料（gitignored）
├── MNN-Pocket-0.3B-深度解读报告.md
├── MNN-Pocket-0.3B-深度解读报告.pdf
├── DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.md
└── DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.pdf
```

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Flutter | 3.47+（stable） |
| Android | arm64-v8a 真机，Android 5.0+（minSdk 21） |
| 构建 | Android SDK + NDK + CMake（由 Flutter 管理） |
| 工具 | `adb` 在 PATH 中 |
| 模型 | 约 183 MB LLM + 约 162 MB ASR/VAD |

> x86 / x86_64 模拟器不支持：插件里的 llama.cpp 预编译库只有 `arm64-v8a`。

## 快速开始

### 1. 克隆与依赖

```bash
git clone <this-repo> mnn
cd mnn
flutter pub get
```

### 2. 准备模型

LLM（必须，5 个文件）：

```text
_sources/MNN-Pocket-0.3B-MNN/config.json
_sources/MNN-Pocket-0.3B-MNN/llm.mnn
_sources/MNN-Pocket-0.3B-MNN/llm.mnn.weight            166.2 MiB
_sources/MNN-Pocket-0.3B-MNN/llm_config.json
_sources/MNN-Pocket-0.3B-MNN/tokenizer.mtok
```

来源：<https://modelscope.cn/models/MNN/MNN-Pocket-0.3B-MNN>

ASR + VAD（语音输入需要）：

```text
_sources/xasr/encoder-480ms.int8.onnx              148 MB
_sources/xasr/decoder-480ms.int8.onnx               10 MB
_sources/xasr/joiner-480ms.int8.onnx               2.4 MB
_sources/xasr/tokens.txt                            57 KB
_sources/asr/silero_vad.onnx                       629 KB
```

- X-ASR-zh-en：<https://huggingface.co/GilgameshWind/X-ASR-zh-en>（或 [ModelScope](https://modelscope.cn/models/Gilgamesh-J/X-ASR-zh-en)），取 480 ms 的 sherpa-onnx 导出 INT8 模型
- Silero VAD：<https://github.com/snakers4/silero-vad>，取 `silero_vad.onnx`

> 也可以用未量化的 `encoder-480ms.onnx` / `decoder-480ms.onnx` / `joiner-480ms.onnx`（约 615 MB），App 会自动优先使用 INT8，找不到时回退 FP32。

### 3. 构建并安装

```bash
flutter build apk --debug
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
```

### 4. 推送模型

```bash
# 默认设备
tools/provision_device.sh

# 指定设备，并在推送前安装最新 debug APK
tools/provision_device.sh --serial 300c0ed8 --install

# 查看全部参数
tools/provision_device.sh --help
```

脚本会推送到：

| 文件 | 设备路径 |
| --- | --- |
| LLM（5 个文件） | `/data/user/0/com.example.mnn/app_flutter/models/MNN-Pocket-0.3B-MNN/` |
| ASR / VAD / tokens | `/data/user/0/com.example.mnn/files/asr/` |

> 必须使用 **debug APK**，脚本依赖 `run-as` 写入应用私有目录。Release 包无法用这个方式配置。

### 5. 运行

```bash
adb shell am start -n com.example.mnn/.MainActivity
# 或
flutter run
```

首次启动时如果 LLM 不存在，引导页会出现「下载并加载模型」，点击后从 ModelScope 拉取 183 MB。

## 模型与参数

### LLM

| 项目 | 值 |
| --- | --- |
| 模型 | MNN-Pocket-0.3B-Instruct |
| 参数量 | 302 M |
| 量化 | Q4_1 GGUF |
| 文件大小 | 183 MB |
| 上下文 | 2048（vendored bridge 中已 patch） |
| 默认采样 | T=0.40, top_p=0.80, top_k=20, repeat=1.10 |
| 最大生成 | 768 tokens |

`maxTokens` 从早期版本的 128 提高到 768，避免长回答被截断；上下文同时从默认值 patch 到 2048。

### ASR

| 项目 | 值 |
| --- | --- |
| 模型 | X-ASR-zh-en，480 ms 流式 |
| 结构 | Zipformer2 transducer |
| 解码 | `greedy_search` |
| 采样率 / 特征 | 16 kHz / 80-dim |
| 线程 | 4 |
| 量化 | INT8（encoder 148 MB + decoder 10 MB + joiner 2.4 MB） |
| 语言 | 中文 / 英文 |

### VAD

| 参数 | 值 |
| --- | --- |
| threshold | 0.5 |
| minSilenceDuration | 0.8 s |
| minSpeechDuration | 0.3 s |
| maxSpeechDuration | 20 s |
| windowSize | 512 |
| 尾部补零 | 1.0 s（确保最后一字被解码） |

第一次切换到语音模式时会懒加载 ASR，约 1–2 秒；之后常驻内存。

## 指标行说明

每条 assistant 回答下方有两行：

```text
SM6435 · 7.2GB · 6.50s · 310 字
T=0.40 · top_p=0.80 · top_k=20 · max=768 · repeat=1.10
```

- `SM6435`：SoC 型号（`Build.SOC_MODEL`，低版本回退到 `Build.HARDWARE`）
- `7.2GB`：总内存（`ActivityManager.MemoryInfo.totalMem`）
- `6.50s`：从提交 prompt 到生成结束的墙钟时间，包含 prompt decode 和生成
- `310 字`：清理模板标记后的字符数，**不是 token 数**
- 第二行：本次请求实际使用的采样参数

> 要对比原报告时，请使用同一段 prompt，并注意：本 Demo 是 llama.cpp + GGUF，报告是 MNN runtime；`字` 和 `tok/s` 也不是同一口径。

## 生成参数

右上角 ⚙ 打开「生成参数」：

- 温度（temperature）
- Top-P
- Top-K
- 最大生成长度

修改后会重新加载模型并应用。参数也会实时显示在每条回答下方，方便做对照实验。

## 隐藏诊断能力

以下开关只在编译期生效，默认关闭：

```bash
# 启动后自动跑一条 smoke test
flutter run --dart-define=AUTO_SMOKE=true

# 跑内置意图分类评测（25 条）
flutter run --dart-define=AUTO_EVAL=true

# 用文件而不是麦克风跑流式 ASR 自测
flutter run --dart-define=AUTO_STREAM=true
```

## 已验证设备

| 设备 | SoC | 内存 | Android | 状态 |
| --- | --- | --- | --- | --- |
| 23124RN87C | MT6835 | 3.5 GB | 15 | LLM + ASR + 打断均通过 |
| 2607DRA18C | SM6435 | 7.2 GB | 16 | LLM + 指标行通过；ASR 已部署 |

同一 prompt（310 字）的生成耗时在不同设备上会明显不同；请以设备自己的指标行为准。

## 常见问题

**提示「ASR 模型未安装」**

ASR 不会在 App 内下载。把模型放进 `_sources/` 后执行：

```bash
tools/provision_device.sh
```

**`run-as failed: com.example.mnn is not debuggable`**

当前安装的是 release 包。脚本只能配置 debug 包：

```bash
flutter build apk --debug
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
```

**第一次按住说话没反应**

ASR 正在懒加载，等待 1–2 秒；屏幕上方会显示「正在加载 ASR 模型…」。

**回答被截断**

检查右上角 ⚙ 里的最大生成长度是否为 768；如果仍然不够，可以调大，但会更慢、更占内存。

**APK 为什么这么大**

Debug APK 约 233 MB，包含 Flutter debug 产物和 llama.cpp 原生库；模型不打进 APK，由启动下载或 adb 推送。

## 已知限制

- 仅 Android arm64-v8a，不支持模拟器和 x86
- LLM 上下文固定 2048，超长对话会被截断
- 无对话持久化，杀进程后历史丢失
- ASR 只有中英文，且依赖外部模型文件
- 本 Demo 不包含 MNN runtime 集成，不能复现报告的 MNN 性能
- `flutter_markdown` 已停止维护，但当前功能正常

## 相关文档

- [MNN-Pocket-0.3B 深度解读报告（Markdown）](MNN-Pocket-0.3B-深度解读报告.md)
- [MNN-Pocket-0.3B 深度解读报告（PDF）](MNN-Pocket-0.3B-深度解读报告.pdf)
- [DeepSeek-V4-Pro-Qwen3.5-9B-heretic 调查报告](DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.md)
- [MNN-Pocket 模型合集](https://modelscope.cn/collections/MNN/MNN-Pocket-03B)
- [X-ASR 项目](https://github.com/Gilgamesh-J/X-ASR)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)

## 许可与致谢

本项目代码用于技术验证。依赖组件遵循各自许可证：

- llama.cpp — MIT
- `onenm_local_llm` — MIT
- X-ASR — Apache-2.0
- Silero VAD — MIT
- MNN-Pocket-0.3B — Apache-2.0
- sherpa-onnx — Apache-2.0
