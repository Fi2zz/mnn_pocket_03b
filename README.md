# MNN-Pocket 0.3B · Android 端侧推理 Demo

在 Android 手机上**完全离线**运行 [MNN-Pocket-0.3B](https://modelscope.cn/models/MNN/MNN-Pocket-0.3B)（INT4 W4A16，约 166 MB），并用 **X-ASR-zh-en + Silero VAD** 做流式语音输入。

LLM 后端是 **MNN runtime**：`libMNN.so` 同时包含 MNN 引擎和 LLM engine，通过 JNI 直接加载 `llm.mnn` / `llm.mnn.weight`。同一台 SM6435 上实测 decode 约 **63–67 tok/s**，比之前的 llama.cpp + Q4_1 GGUF 构建快约 1.4 倍。

---

## 功能

- **纯本地推理**：模型、语音、对话数据都不出设备，无 API Key、无网络请求
- **流式语音输入**：按住说话，松手自动发送；INT8 量化 ASR，边说边出字
- **流式文本生成**：token 分批上屏，末尾显示光标；生成中可随时打断
- **可打断**：生成中右下角按钮变为停止，点击后保留已生成的部分回答
- **设备感知指标**：每条回答下方显示 SoC、内存、耗时、字数、decode tok/s，以及完整生成参数
- **单页聊天**：没有底部 Tab，只有对话；输入框支持“文本 / 按住说话”两种模式
- **参数可调**：温度、Top-P、Top-K、最大生成长度，修改后重新加载模型生效
- **完全离线部署**：模型通过 App 下载或 adb 推送，适合内网/无网设备

## 界面

```
┌─────────────────────────────────┐
│ MNN-Pocket 0.3B            ⓘ ⚙ 🗑 │
│ 端侧 · MNN INT4 · CPU            │
├─────────────────────────────────┤
│  MNN-Pocket                     │
│  你好，我是 MNN-Pocket 0.3B…     │
│  本地模型 · 零网络请求           │
│                                 │
│              用 Rust 写一个斐波那契 │
│                                 │
│  MNN-Pocket                     │
│  /// 斐波那契数列…               │
│  SM6435 · 7.2GB · 2.83s · 322 字 │
│  · 64 tok/s                     │
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
- 生成中先显示「正在本地推理…」，第一个 token 到达后逐字上屏，末尾显示 `▍`；完成后切换为 Markdown 渲染

## 技术架构

```
┌──────────────────────────────────────────────┐
│                  Flutter UI                  │
│                  lib/main.dart               │
├───────────────────────┬──────────────────────┤
│   mnn_local_llm       │     sherpa_onnx      │
│ MethodChannel +       │     Dart FFI         │
│ EventChannel          │        ↓             │
│        ↓              │   X-ASR INT8 + VAD   │
│   Kotlin Plugin       │   16 kHz 流式解码     │
│        ↓ JNI          │                      │
│   libMNN.so           │                      │
│   (MNN + LLM engine)  │                      │
└───────────────────────┴──────────────────────┘
```

- LLM：`third_party/mnn_local_llm`，JNI bridge 链接预编译 `libMNN.so`
- 流式输出：`startGenerate` 启动生成，EventChannel 推送 token；Kotlin 每 40 ms 批量 flush，Dart 侧逐字追加
- **取消生成**：`std::atomic<bool>` + 逐 token `generate(1)` 循环，命中后返回已生成文本
- 采样：`temperature`、`topK`、`topP`、`repetition_penalty` 通过 MNN `set_config` 写入
- ASR：sherpa-onnx 的 `OnlineRecognizer`（Zipformer2 transducer，`greedy_search`）
- VAD：Silero VAD，用于判断说话起止和端点
- 录音：`record` 包，16 kHz 单声道 PCM

## 目录结构

```
.
├── lib/
│   ├── main.dart                      # UI、ASR 流程、打断、指标展示
│   ├── model_config.dart              # MNN 模型 5 文件描述与默认参数
│   └── meta_format.dart               # 指标行格式化
├── android/
│   └── app/src/main/kotlin/com/example/mnn/
│       └── MainActivity.kt            # device_info MethodChannel
├── third_party/mnn_local_llm/         # vendored MNN Flutter 插件
│   ├── lib/                           # Dart API（MnnLlm / MnnModel / 下载）
│   └── android/src/main/
│       ├── cpp/mnn_bridge.cpp         # JNI + 生成循环 + 取消 + 统计
│       ├── cpp/mnn/include/           # MNN / llm 头文件
│       └── jniLibs/arm64-v8a/         # libMNN.so / libc++_shared.so
├── tools/
│   ├── build_mnn_android.sh           # 固定 commit 重建 libMNN.so
│   └── provision_device.sh            # 一键推送模型到设备
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
| 构建 | Android SDK + NDK 28.2 + CMake（由 Flutter 管理） |
| 工具 | `adb` 在 PATH 中 |
| 模型 | 约 166 MB LLM + 约 162 MB ASR/VAD |

> x86 / x86_64 模拟器不支持：`libMNN.so` 只提供 `arm64-v8a`。

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

首次启动时如果模型不完整，引导页会出现「下载并加载模型」，点击后从 ModelScope 拉取约 166 MB。

## 模型与参数

### LLM

| 项目 | 值 |
| --- | --- |
| 模型 | MNN-Pocket-0.3B-Instruct |
| 参数量 | 302 M |
| 量化 | MNN INT4（W4A16，group 64） |
| 文件大小 | 166.2 MiB（5 个文件） |
| 运行时 | MNN runtime（CPU，`thread_num=4`） |
| 上下文 | 模型最长 32K；Demo 未做历史裁剪 |
| 默认采样 | T=0.40, top_p=0.80, top_k=20, repeat=1.10 |
| 最大生成 | 768 tokens |

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
SM6435 · 7.2GB · 2.83s · 322 字 · 64 tok/s
T=0.40 · top_p=0.80 · top_k=20 · max=768 · repeat=1.10
```

- `SM6435`：SoC 型号（`Build.SOC_MODEL`，低版本回退到 `Build.HARDWARE`）
- `7.2GB`：总内存（`ActivityManager.MemoryInfo.totalMem`）
- `2.83s`：从提交 prompt 到生成结束的墙钟时间，包含 prefill 和生成
- `322 字`：清理模板标记后的字符数，**不是 token 数**
- `64 tok/s`：MNN 原生 `decode_us` 统计的 decode 阶段速度，不含 prefill 和采样
- 第二行：本次请求实际使用的采样参数

> 报告里的 251 tok/s 是骁龙 8 Gen 5 的 MNN 数据；本 Demo 的 63–67 tok/s 是 SM6435 实测。跨设备不能直接对比。

## 生成参数

右上角 ⚙ 打开「生成参数」：

- 温度（temperature）
- Top-P
- Top-K
- 最大生成长度

修改后会重新加载模型并应用。参数也会实时显示在每条回答下方，方便做对照实验。

## 重建 MNN 原生库

仓库已包含 `libMNN.so` 与 `libc++_shared.so`，普通构建不需要 MNN 源码。要重新生成：

```bash
tools/build_mnn_android.sh
```

脚本会：

- 浅克隆 MNN 到 `_sources/MNN`，切到固定 commit `b0239771b07b317a258fbc384683bbd540741406`
- 用 NDK 28.2 交叉编译 `arm64-v8a`、`c++_shared`
- 关键宏：`MNN_BUILD_LLM=ON`、`MNN_LOW_MEMORY=ON`、`MNN_SUPPORT_TRANSFORMER_FUSE=ON`、`MNN_BUILD_SHARED_LIBS=ON`、`MNN_SEP_BUILD=OFF`、CPU-only
- strip 后复制到 `third_party/mnn_local_llm/android/src/main/jniLibs/arm64-v8a/`
- 同步 `MNN` 与 `llm` 头文件

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
| 23124RN87C | MT6835 | 3.5 GB | 15 | llama.cpp 版本通过；MNN 版本待测 |
| 2607DRA18C | SM6435 | 7.2 GB | 16 | MNN + ASR + 打断 + 指标均通过，decode 63–67 tok/s |

同一 prompt 的生成耗时在不同设备上会明显不同；请以设备自己的指标行为准。

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

**为什么生成时没有逐字上屏**

当前版本不做逐 token 流式输出：MNN 生成完成后整段回答一次上屏。ASR 侧仍然是流式识别。

**APK 为什么这么大**

Debug APK 约 157 MB，包含 Flutter debug 产物、sherpa-onnx 和 MNN 原生库；模型不打进 APK，由启动下载或 adb 推送。

## 已知限制

- 仅 Android arm64-v8a，不支持模拟器和 x86
- 无对话持久化，杀进程后历史丢失
- ASR 只有中英文，且依赖外部模型文件
- 不保留 llama.cpp 后端，无法在 App 内切换引擎

## 相关文档

- [MNN-Pocket-0.3B 深度解读报告（Markdown）](MNN-Pocket-0.3B-深度解读报告.md)
- [MNN-Pocket-0.3B 深度解读报告（PDF）](MNN-Pocket-0.3B-深度解读报告.pdf)
- [DeepSeek-V4-Pro-Qwen3.5-9B-heretic 调查报告](DeepSeek-V4-Pro-Qwen3.5-9B-heretic-调查报告.md)
- [MNN-Pocket 模型合集](https://modelscope.cn/collections/MNN/MNN-Pocket-03B)
- [X-ASR 项目](https://github.com/Gilgamesh-J/X-ASR)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- [MNN](https://github.com/alibaba/MNN)

## 许可与致谢

本项目代码用于技术验证。依赖组件遵循各自许可证：

- MNN — Apache-2.0
- MNN-Pocket-0.3B — Apache-2.0
- X-ASR — Apache-2.0
- Silero VAD — MIT
- sherpa-onnx — Apache-2.0
