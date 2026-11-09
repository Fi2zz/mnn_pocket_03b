<div class="cover">
<div class="cover-kicker">MODEL DUE DILIGENCE · 2026-11-09</div>
<h1 class="cover-title">DeepSeek-V4-Pro-Qwen3.5-9B<br><span>UNCENSORED-heretic</span></h1>
<p class="cover-sub">模型调查报告：谱系、架构、去审查方法、基准复核与部署评估</p>
<div class="cover-rule"></div>
<table class="cover-facts">
<tr><td>模型仓库</td><td>xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic</td></tr>
<tr><td>固定版本</td><td><code>e4bfa83c72896cbb4990c909967d6f27bb97bac4</code></td></tr>
<tr><td>参数规模</td><td>9.65B（文本主干 8.95B + 视觉 0.46B + MTP 0.24B）</td></tr>
<tr><td>权重体积</td><td>19.33 GB（BF16）</td></tr>
<tr><td>许可</td><td>Apache-2.0（权重）</td></tr>
<tr><td>调查方式</td><td>API 元数据、仓库文件、Safetensors/GGUF 头部解析、讨论区与上游项目交叉核对</td></tr>
</table>
<p class="cover-note">本报告基于 2026-11-09 的公开快照。模型卡与仓库可能继续更新，引用前请重新核对 commit。报告不构成法律意见，也不构成对“去审查”用途的推荐。</p>
</div>

<div class="pagebreak"></div>

## 目录

1. 执行摘要
2. 调查方法、证据等级与边界
3. 模型身份与仓库概况
4. 谱系：从 Qwen3.5 到 DeepSeek 蒸馏，再到 Heretic
5. 技术架构拆解
6. 去审查方法：Heretic 2.0 与 ARA
7. 仓库、权重与文件一致性核查
8. 基准测试复核
9. 推理效率分析
10. 部署评估
11. 风险、合规与伦理
12. 适用与不适用场景
13. 结论与行动建议
14. 附录

### 报告速览

| 指标 | 数值 | 含义 |
|:--|--:|:--|
| 总参数 | 9.653 B | 文本 8.954B + 视觉 0.456B + MTP 0.243B |
| BF16 权重 | 19.33 GB | 单卡 24 GB 起 |
| 去审查改写层 | 16 / 32 | 第 9–24 层 |
| 作者报告拒答 | 3 / 100 | 原模型 100 / 100 |
| 作者报告 KL | 0.0422 | 校准语料未公开 |
| MMLU-Pro 平均 | 90.53% | 3 子集 × 500 题，自报 |
| Q4_K_M 体积 | 5.63 GB | 社区量化，当前有 MTP 缺陷 |

> **阅读建议：** 时间有限时，先读第 1 章（结论）、第 8 章（基准复核）、第 11 章（风险）与第 13 章（行动清单）。第 5–7 章适合需要部署或二次开发的读者。



<div class="pagebreak"></div>

# 1. 执行摘要

## 1.1 一句话结论

这是一个**二次派生**的 9B 级多模态推理模型：底座是 Qwen3.5-9B，中间经过 Jackrong 用 DeepSeek-V4-Pro 生成的约 25 万条数学/STEM 数据做蒸馏与 GSPO 强化学习，最后由 xtools-at 用 Heretic 2.0 的 Arbitrary-Rank Ablation（ARA）移除拒答行为。它不是 DeepSeek 官方模型，也不是从零训练的新模型，而是一次“强底座 + 领域蒸馏 + 行为定向修改”的组合实验。

## 1.2 关键发现

| 发现 | 证据等级 |
|:--|:--:|
| **F1**　真实规模为 **9.653B 参数**（文本主干 8.954B、视觉塔 0.456B、MTP 头 0.243B），BF16 权重 **19.33 GB**；“9B”是产品档位命名。 | A |
| **F2**　去审查只修改语言解码器第 **9–24 层**（32 层中的 16 层）的模块矩阵，不重训、不改词表、不改视觉塔、不改 MTP 头。 | A/B |
| **F3**　作者报告拒答率从 **100/100 降到 3/100**，KL 散度 **0.0422**。该指标来自 Heretic 的关键词拒答打分器，不等于安全评测。 | B |
| **F4**　数学/STEM 基准均为**作者自报**：MMLU-Pro 只取 Math/Physics/Chemistry 各 500 题；相对 Qwen3.5-9B 的 **+0.93 分在统计上不显著**（标准误约 0.77，z≈1.2）。 | A/C |
| **F5**　模型卡把 Qwen3.5-9B 基线测到 **89.60**，而 Qwen 官方 MMLU-Pro 为 **82.5**，相差 7.1 分，说明评测协议明显不同；因此跨模型排名不可直接采信。 | A/C |
| **F6**　最可信的差异点是**推理 token 更省**：每正确答中位 token 676，对比 Qwen3.5-9B 的 3,214；每百万 token 正确数 316.8 对 202.5。 | B |
| **F7**　仓库在 2026-11-08 修复了 MTP 权重缺失；但社区 GGUF（近 30 天合计约 28.1 万次下载）仍是 10-31 的旧转换。独立解析 Q4_K_M 证实：`block_count=33`、`nextn_predict_layers=1`，但只有 `blk.0–31`、没有任何 `nextn/eh_proj` 张量，llama.cpp 会在加载时断言失败。 | A |
| **F8**　许可链干净：Qwen3.5-9B 与 Jackrong 底座为 Apache-2.0，教师 DeepSeek-V4-Pro 为 MIT，本仓库声明 Apache-2.0。但“去审查”属性使其不适合无护栏的公众部署。 | A |
| **F9**　缺少 `reproduce/` 清单、评测脚本、原始日志与置信区间；模型卡 38 KB，但大部分是底座模型的营销 HTML，没有本模型的用法示例。 | A |

> **总评：技术上有意思，证据上不够硬，工程上有明显交付瑕疵。** 适合作为消融/去审查研究与受控实验对象；不建议直接作为生产依赖，尤其不建议用于面向公众的消费级应用或受监管建议场景。

## 1.3 分项评级

| 维度 | 评级 | 理由 |
|:--|:--:|:--|
| 架构先进性 | A− | Qwen3.5 的混合线性注意力 + 全注意力、原生多模态、MTP，属于 2026 年主流先进结构 |
| 文档完整性 | C | 关键信息散落在底座营销页；缺用法、评测配置、复现清单与限制说明 |
| 基准可信度 | C+ | 数字具体但样本小、协议不统一、无置信区间、无原始日志 |
| 去审查效果 | B | 拒答率下降明显，但指标单一、提示集仅 100 条、无人工复核 |
| 工程可用性 | C+ | Safetensors 已修复；社区 GGUF 仍坏；`pipeline_tag` 与多模态事实不一致 |
| 可复现性 | D | 只有 ARA 超参数和版本号，没有可复现 manifest，无法字节级复现 |
| 许可清晰度 | A− | 许可链兼容；但缺 NOTICE/归属文件，去审查用途仍受平台与地方法规约束 |
| 社区热度 | A− | 879 likes、7,088 次仓库下载；量化版合计约 29 万次下载，实际使用入口是 GGUF |



# 2. 调查方法、证据等级与边界

## 2.1 调查对象与时间

- 对象：`xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic`
- 固定 commit：`e4bfa83c72896cbb4990c909967d6f27bb97bac4`（2026-11-08 03:48 UTC）
- 快照日期：2026-11-09
- 关联对象：底座 `Jackrong/DeepSeek-V4-Pro-Qwen3.5-9B`、基座 `Qwen/Qwen3.5-9B`、教师 `deepseek-ai/DeepSeek-V4-Pro`、工具 `p-e-w/heretic`、社区量化仓库 `mradermacher/*-GGUF`

## 2.2 使用的一手材料

| 材料 | 用途 |
|:--|:--|
| Hugging Face Model API | 下载量、点赞、创建/更新时间、tags、文件清单、commit 历史 |
| 仓库原始文件 | `README.md`、`config.json`、`generation_config.json`、`tokenizer_config.json`、`model.safetensors.index.json` |
| Safetensors 头部 | 远程 Range 读取 5 个权重文件的张量名、dtype、shape，精确统计参数量 |
| GGUF 头部 | 远程 Range 读取 Q4_K_M 前 16 MB，解析 metadata 与 427 个张量名，独立验证 MTP 缺陷 |
| Hugging Face Discussions API | 上游仓库与 mradermacher 量化仓库的故障报告、作者回应、修复时间线 |
| GitHub API | Heretic 仓库星标、许可、发布版本、ARA 设计文档（PR #211） |
| 上游模型卡 | Qwen3.5-9B、DeepSeek-V4-Pro、Jackrong 蒸馏版的架构、许可、基准与训练说明 |

## 2.3 证据等级

| 等级 | 含义 |
|:--:|:--|
| A | 本次调查直接读取或解析得到的事实（API、文件头、配置、张量清单） |
| B | 作者/维护者在模型卡、README 或讨论区中的自述，尚未独立复现 |
| C | 基于公开信息的推断、统计复核或交叉比对，存在不确定性 |

## 2.4 边界与未做之事

1. **没有跑全量推理。** 权重 19.33 GB，本机为 Apple M5 / 16 GB 内存，不具备 BF16 运行条件；社区 Q4_K_M 又存在加载缺陷。报告中的能力结论均来自作者自报与静态核查，不是本次实测。
2. **没有独立重跑基准。** 没有作者的评测脚本、提示模板、随机种子与原始输出，无法复现 MMLU-Pro/GSM8K 数字。
3. **没有做安全红队。** 报告只评估“去审查”的方法与声明，不测试具体有害请求的合规性，也不提供绕过安全机制的提示。
4. **没有做法律审查。** 许可与合规部分是基于公开许可文本的技术性提示，正式商用请咨询法务。
5. **数据是快照。** 作者在 11-07 至 11-08 连续修改仓库；本报告以 `e4bfa83` 为准，早于该 commit 的量化文件不能视为同一模型。



# 3. 模型身份与仓库概况

## 3.1 身份卡

| 字段 | 值 |
|:--|:--|
| 仓库 ID | `xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic` |
| 作者 | `xtools-at`（显示名 Colonel Panic） |
| 作者画像 | 65 个模型、308 关注者、340 likes；方向为开放权重、本地模型、蒸馏/融合、abliteration/decensoring、嵌入式 AI |
| 创建时间 | 2026-10-30 10:21 UTC |
| 最后修改 | 2026-11-08 03:48 UTC |
| 固定 commit | `e4bfa83c72896cbb4990c909967d6f27bb97bac4` |
| 任务标签 | `text-generation`（但 tags 同时含 `image-text-to-text`） |
| 库 | `transformers` |
| 架构 | `Qwen3_5ForConditionalGeneration` |
| 基座 | `Jackrong/DeepSeek-V4-Pro-Qwen3.5-9B`（finetune 关系） |
| 许可 | Apache-2.0 |
| 语言声明 | en / zh / ko / ja / es / ru |
| 近 30 天下载 | 7,088 |
| 点赞 | 879 |
| 权重精度 | BF16 |
| 上下文 | 262,144 tokens（底座宣称可扩展至约 1.01M） |
| 模态 | 文本 + 图像 + 视频 token（视觉塔保留） |

## 3.2 命名拆解

`DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic` 这个名字包含四层信息，但容易误导：

- **DeepSeek-V4-Pro**：指教师模型，不是本模型的架构。教师是 1.6T 总参数 / 49B 激活的 MoE，MIT 许可。
- **Qwen3.5-9B**：真正的底座架构与初始化权重来源，Apache-2.0。
- **UNCENSORED / decensored / abliterated**：表示用消融方法削弱拒答行为，不是重新做安全对齐。
- **heretic**：指使用的工具链 Heretic，不是模型系列名。

因此，把它称为“DeepSeek 模型”是不准确的；更准确的描述是“**Qwen3.5-9B 的 DeepSeek 蒸馏版，再去拒答**”。

## 3.3 作者与维护状态

`xtools-at` 不是 DeepSeek、Qwen 或 Jackrong 的官方账号，而是一个活跃的个人模型改造者。其仓库列表中有大量 `*-UNCENSORED-heretic` 模型，覆盖 Qwen3.5、Ministral、SmolLM3 等，说明这是一条持续的“去审查流水线”，而不是单次偶发发布。

维护状态方面：

- 10-30 发布，11-07 收到 MTP/GGUF 故障报告，11-08 连续提交修复；
- 作者回应积极，但修复方式是“从母模型补回 MTP 张量”，并未重新生成量化；
- 截至 11-09，上游 Safetensors 已一致，社区 GGUF 仍旧，存在“仓库已修、下游仍坏”的错位。



# 4. 谱系：从 Qwen3.5 到 DeepSeek 蒸馏，再到 Heretic

## 4.1 三代谱系

```text
Qwen/Qwen3.5-9B                   2026-02-27   Apache-2.0
   │  原生多模态、混合线性注意力、262K 上下文、MTP
   ▼
Jackrong/DeepSeek-V4-Pro-Qwen3.5-9B   2026-07-19   Apache-2.0
   │  ~250K 数学/STEM 样本 SFT + GSPO 轻量 RL
   │  教师：DeepSeek-V4-Pro（1.6T 总参 / 49B 激活，MIT）
   ▼
xtools-at/...-UNCENSORED-heretic     2026-10-30   Apache-2.0
   │  Heretic v2.0.0.dev0，ARA 消融第 9–24 层
   ▼
社区量化（GGUF / NVFP4 / MLX）        2026-10-31 起
```

## 4.2 教师模型：DeepSeek-V4-Pro

| 项目 | 数据 |
|:--|:--|
| 总参数 | 1.6T |
| 激活参数 | 49B |
| 结构 | MoE，61 层，384 路由专家，每 token 激活 6 个 |
| 上下文 | 1,048,576 tokens |
| 许可 | MIT |
| 官方定位 | 百万 token 级高效推理 |

教师规模是学生的约 170 倍（按总参数）或 5 倍（按激活参数）。用这样的教师生成 25 万条数学/STEM 轨迹，再蒸馏到 9B，是 2026 年常见的“强教师—小学生”路线。

需要指出：模型卡反复出现的“**Max Effect mode**”在 DeepSeek-V4-Pro 官方模型卡中找不到定义。它更可能是数据生成时使用的推理强度/采样配置，而不是官方模型变体。报告将其视为“作者自述的数据生成设置”，不做能力承诺。

## 4.3 中间层：Jackrong 的蒸馏版

Jackrong 版本的关键信息：

- 约 **250,000** 条数学与 STEM 样本，强调结构化推导、领域分解、最终答案构造；
- 训练路径为 **纯 SFT → 轻量 GSPO 强化学习**；
- **没有加入代码数据**，但作者观察到编程/工具调用有轻微迁移提升；
- 作者明确说明这是“交叉迁移”，不是代码专精；
- 由于训练时 DeepSeek 已发布更强的 0731/0813 版本，代码/agent 数据尚未纳入，后续会迭代。

这意味着本模型的“编程能力提升”没有专门的代码监督支撑，不能当作代码模型使用。

## 4.4 工具层：Heretic

| 项目 | 数据 |
|:--|:--|
| 仓库 | `p-e-w/heretic` |
| 定位 | 免训练语言模型行为修改（去审查、去 slop、降谄媚等） |
| 许可 | AGPL-3.0 |
| 星标 | 40,062 |
| Fork | 4,576 |
| 创建 | 2025-09-21 |
| v2.0.0 发布 | 2026-11-01 |
| v2.1.0 发布 | 2026-11-08 |
| 本模型使用版本 | `v2.0.0.dev0`（正式版发布前 2 天） |

Heretic 的默认目标是“去拒答”，默认打分器是**关键词拒答率**与 **KL 散度**，优化器是 Optuna 的 TPE。它支持可复现 manifest（`reproduce/reproduce.json`），但本仓库没有包含。

## 4.5 量化分发：真正的使用入口

| 仓库 | 近 30 天下载 | 点赞 | 最后修改 |
|:--|--:|--:|:--|
| `mradermacher/...-i1-GGUF` | 136,706 | 189 | 2026-10-31 |
| `mradermacher/...-GGUF` | 144,783 | 46 | 2026-10-31 |
| `Sakura721/...-GGUF` | 4,621 | 7 | — |
| `share72/...-i1-GGUF` | 3,562 | 0 | — |
| 原仓库 Safetensors | 7,088 | 879 | 2026-11-08 |

两个主要 GGUF 仓库合计 **281,489** 次下载，是原仓库的约 40 倍。这说明：

1. 绝大多数用户并不直接跑 BF16 Safetensors，而是用 4-bit/8-bit 量化在本地推理；
2. 因此 **GGUF 的 MTP 缺陷影响面远大于原仓库**；
3. 社区量化的质量、许可与安全性，实际上决定了这个模型的真实口碑。



# 5. 技术架构拆解

## 5.1 关键配置

| 配置项 | 值 | 说明 |
|:--|:--|:--|
| 架构 | `Qwen3_5ForConditionalGeneration` | 原生多模态生成模型 |
| 文本层数 | 32 | 24 层线性注意力 + 8 层全注意力 |
| 全注意力间隔 | 每 4 层一次 | 第 3、7、11、…、31 层为 full attention |
| 隐藏维度 | 4,096 | |
| Q / KV 头数 | 16 / 4 | GQA |
| Head dim | 256 | |
| 部分旋转 | 0.25 | RoPE 仅作用于 64 维 |
| RoPE theta | 10,000,000 | 长上下文 |
| M-RoPE | interleaved，11/11/10 | 多模态位置编码 |
| FFN 中间维 | 12,288 | SwiGLU |
| 词表 | 248,320 | padding 到 248,320 |
| 上下文 | 262,144 | 原生 |
| 视觉塔 | 27 层，hidden 1152，patch 16，merge 2 | 输出 4096 维 |
| MTP | 1 层，243M 参数 | 投机解码草稿头 |
| 精度 | BF16 | |
| 注意力输出门 | 开启 | Q 投影输出 8192 维（query + gate） |

## 5.2 参数分布（本次实测）

通过远程读取 5 个 Safetensors 文件的头部并累加 shape，得到精确参数量：

| 组件 | 参数量 | 占比 |
|:--|--:|--:|
| 文本 MLP（32 层 × 151M） | 4.832 B | 50.1% |
| 词嵌入 + LM head | 2.034 B | 21.1% |
| 线性注意力（24 层） | 1.618 B | 16.8% |
| 全注意力（8 层） | 0.470 B | 4.9% |
| 视觉塔 | 0.456 B | 4.7% |
| MTP 头 | 0.243 B | 2.5% |
| **合计** | **9.653 B** | **100%** |

拆分口径：

- **主模型（文本 + 视觉）**：9.410B，与 `index.json` 的 `total_parameters` 一致；
- **文本主干**：8.954B；
- **MTP 头**：0.243B（单独文件，不计入主模型 metadata）；
- **完整 checkpoint**：9.653B。

这也解释了为什么“9B”模型的实际权重是 19.33 GB：BF16 下 9.653B × 2 字节 ≈ 19.31 GB，加上文件头与对齐，正好 19.33 GB。

## 5.3 混合注意力：为什么长上下文更省

Qwen3.5 的文本层不是传统 Transformer 的“32 层全注意力”，而是：

- **24 层 Gated DeltaNet 线性注意力**：维护固定大小的递归状态，序列越长，状态不增长；
- **8 层全注意力**：每 4 层插入一次，负责精确的全局检索与长程依赖；
- **注意力输出门**：Q 投影同时产生 query 与 gate，提升表达力；
- **M-RoPE**：把位置编码拆分到时间/高/宽三个方向，适配图像与视频 token。

对部署的直接后果是 KV Cache 只来自 8 层全注意力：

```text
每 token 每层 KV = 2（K,V）× 4 头 × 256 维 × 2 字节 = 4 KB
8 层合计 = 32 KB / token
32K 上下文 ≈ 1.07 GB
128K 上下文 ≈ 4.29 GB
262K 上下文 ≈ 8.59 GB
```

相比 32 层全注意力的同规模模型，KV Cache 降到约 1/4。这是本模型在长上下文场景下真正的架构优势，与“去审查”无关。

## 5.4 MTP：0.243B 的投机解码头

MTP（Multi-Token Prediction）是挂在主模型上的一个单层草稿头，用来一次预测多个未来 token，配合投机解码提升吞吐。它的形状包括：

- `mtp.fc.weight`：4096 × 8192
- `mtp.layers.0.self_attn.q_proj.weight`：8192 × 4096（含输出门）
- `mtp.layers.0.mlp.*`：4096 ↔ 12288
- 两个 RMSNorm、q_norm/k_norm 等

关键点：作者明确说“Heretic 会忽略这些张量”，所以 **MTP 头是从母模型原样补回的，没有经过消融**。这既意味着投机解码行为不受去审查影响，也意味着 MTP 与主模型的行为一致性没有经过重新验证。

## 5.5 视觉塔：保留了，但没被评测

配置里有完整的 27 层视觉塔（hidden 1152、patch 16、spatial merge 2、输出 4096），权重中也有 333 个视觉张量。理论上它仍然是原生多模态模型，可以处理图像与视频 token。

但模型卡：

- 没有任何视觉基准（MMMU、DocVQA、ChartQA 等）；
- 没有图像输入示例；
- 没有说明 ARA 是否影响跨模态对齐。

因此，**视觉能力应视为“继承但未验证”**。如果你的场景依赖图像理解，必须自己补测，不能假设它与 Qwen3.5-9B 等价。

## 5.6 架构评价

优点：

- 混合线性注意力在长上下文下显著降低 KV 成本；
- 原生多模态，不需要外挂视觉编码器；
- MTP 为高吞吐服务提供了可选的加速路径；
- 32 层 / 4096 隐藏维度的 9B 稠密模型，单卡可部署，工程门槛低于 MoE。

代价：

- 线性注意力层对推理框架的实现质量敏感，不同后端的速度差异可能大于全注意力模型；
- 8 层全注意力仍然承担主要检索职责，超长上下文的质量取决于这 8 层；
- 视觉塔与 MTP 增加了权重体积和加载复杂度；
- `transformers 5.20.2` 是很新的版本，旧栈可能不兼容。



# 6. 去审查方法：Heretic 2.0 与 ARA

## 6.1 Heretic 的工作流

Heretic 不是训练，而是“行为定向修改”。它的基本循环是：

1. **准备对比提示**：一组“无害”提示与一组“有害/应拒答”提示；
2. **打分**：用 scorer 计算拒答率、KL 散度，或自定义指标；
3. **优化**：Optuna 的 TPE 在超参数空间里采样；
4. **修改**：modifier 根据参数直接改写模型权重矩阵；
5. **评估**：重复 2–4，直到拒答率下降且 KL 可控；
6. **保存/上传**：可选生成可复现 manifest。

Heretic 2.0 提供两种 modifier：

- **ARA（Arbitrary-Rank Ablation）**：2.0 的默认方法，专为 Heretic 开发；
- **Directional ablation / abliteration**：经典的拒答方向投影，支持 projected abliteration 与 norm preservation（MPOA）。

本模型使用的是 **ARA**。

## 6.2 ARA 的三个目标

根据 Heretic 作者在 PR #211 中的说明，ARA 不假设拒答方向、不假设秩，而是用 PyTorch hooks 捕获每个 Transformer 模块的输入/输出，然后直接优化模块矩阵。目标函数同时包含三项：

1. **保留无害行为**：对“无害”提示，模块输出尽量不变；
2. **拉近有害与无害**：对“有害”提示，输出尽量接近“无害”提示的输出；
3. **过度校正**：对“有害”提示，输出尽量远离它原先的输出，以突破更复杂的拒答机制。

目标函数是仿射凸的，初始矩阵已接近最优，因此 L-BFGS 通常 2–3 次迭代收敛；矩阵逐个优化，显存开销只比普通 abliteration 略高。ARA 的优点是自由度更高、不需要指定拒答流形的秩；代价是每次试验仍以拒答计数为主，调参时间不短。

## 6.3 本模型的 ARA 参数

| 参数 | 值 | 可能含义（按命名推断） |
|:--|--:|:--|
| `start_layer_index` | 9 | 从第 9 层开始修改 |
| `end_layer_index` | 24 | 到第 24 层结束 |
| `preserve_good_behavior_weight` | 0.8264 | 保留无害行为的权重较高 |
| `steer_bad_behavior_weight` | 0.0003 | 对“坏行为”直接引导的权重很低 |
| `overcorrect_relative_weight` | 0.9645 | 过度校正权重很高 |
| `neighbor_count` | 12 | 相邻层核宽度为 12 |

解读：

- **修改 16/32 层**，集中在中后段。这与“拒答表征在中后层更线性可分”的常见观察一致；
- `preserve_good_behavior_weight` 高、`steer_bad_behavior_weight` 低、`overcorrect_relative_weight` 高，说明优化器更偏向“保留原能力 + 用过校正推开拒答方向”，而不是强行把有害输出拉向某个目标；
- `neighbor_count=12` 表示消融并非只作用于单层，而是有跨层平滑，避免某一层被过度破坏。

这些解释是从参数名与 ARA 论文摘要推断的，作者没有在模型卡中逐项解释。

## 6.4 效果数据

| 指标 | 本模型 | 原模型（Jackrong 版） |
|:--|--:|--:|
| 拒答 | 3/100 | 100/100 |
| KL 散度 | 0.0422 | 0（定义上） |

怎么理解：

- **3/100** 意味着在 Heretic 的 100 条测试提示上，仍有 3 条被拒绝；不是“完全无拒答”，也不是“对任意有害请求都会服从”。
- **100/100** 的原模型拒答率异常整齐，说明测试提示很可能集中在明显触发拒答的类别；这不代表原模型对所有正常问题都拒答。
- **KL 0.0422** 是在某个校准语料上的平均分布偏移。0.04 量级不算“零损伤”，但在 Heretic 的实践中属于可接受范围；具体语料未公开。
- 这两个指标都来自**关键词拒答打分器**，不是人类评估，也不是 HarmBench/AdvBench 等标准安全基准。

## 6.5 改了什么、没改什么

| 组件 | 是否修改 | 说明 |
|:--|:--:|:--|
| 语言解码器第 9–24 层 | 是 | ARA 直接改写模块矩阵 |
| 语言解码器第 0–8、25–31 层 | 否 | 保留原权重 |
| 词嵌入 / LM head | 否 | 词表与输出分布不变 |
| 视觉塔 | 否 | 333 个视觉张量原样保留 |
| MTP 头 | 否 | 作者明确说 Heretic 忽略 MTP，后从母模型补回 |
| 分词器 / chat template | 否 | chat template 与底座字节一致 |
| 训练数据 / 知识 | 否 | 没有新训练，不增加新知识 |

这意味着：

- 模型的**知识边界**仍由 Qwen3.5-9B + Jackrong 蒸馏决定；
- 去审查改变的是**行为倾向**，不是能力；
- 如果底座本身不会某道数学题，去审查也不会让它会；
- 视觉与 MTP 未被消融，但也没有被重新对齐。

## 6.6 可复现性

Heretic 支持在模型仓库中放置 `reproduce/reproduce.json`，记录环境、配置、哈希，使他人可以在几分钟内重建（不重跑数小时优化）。本仓库**没有** `reproduce/` 目录，只有 README 中的 6 个 ARA 参数和版本号。

后果：

- 你无法验证“这 6 个参数 + 这个版本”是否真的生成了当前权重；
- 你无法判断作者是否在最终保存前做了额外合并、缩放或选择性替换；
- 不同人按同样参数重跑，可能得到不同结果（PyTorch 非确定性、硬件差异）。

因此，本模型的“可复现”仅限于“知道用了什么方法”，不等于“能重建同一模型”。



# 7. 仓库、权重与文件一致性核查

## 7.1 文件清单

| 文件 | 大小 | 用途 |
|:--|--:|:--|
| `README.md` | 38.6 KB | 模型卡（大部分为底座营销 HTML） |
| `config.json` | 3.0 KB | 架构配置 |
| `generation_config.json` | 142 B | 生成默认参数 |
| `tokenizer.json` | 20.0 MB | 分词器 |
| `tokenizer_config.json` | 1.2 KB | 特殊 token、chat template 配置 |
| `vocab.json` | 5.23 MB | 词表 |
| `added_tokens.json` | 904 B | 额外 token |
| `chat_template.jinja` | 8.7 KB | 对话模板 |
| `preprocessor_config.json` | 781 B | 图像预处理 |
| `processor_config.json` | 1.3 KB | 多模态处理器 |
| `video_preprocessor_config.json` | 817 B | 视频预处理 |
| `special_tokens_map.json` | 876 B | 特殊 token 映射 |
| `model-00001-of-00004.safetensors` | 4.94 GB | 文本/视觉权重分片 1 |
| `model-00002-of-00004.safetensors` | 4.99 GB | 分片 2 |
| `model-00003-of-00004.safetensors` | 4.95 GB | 分片 3 |
| `model-00004-of-00004.safetensors` | 3.93 GB | 分片 4 |
| `model-mtp.safetensors` | 486.6 MB | MTP 头（15 个张量） |
| `model.safetensors.index.json` | 70.2 KB | 权重索引 |
| **合计** | **19.33 GB** | |

## 7.2 一致性检查

| 检查项 | 结果 | 判定 |
|:--|:--|:--:|
| 索引键数 | 775 | 与母模型一致 |
| MTP 键数 | 15 | 已恢复 |
| 视觉张量 | 333 | 与底座一致 |
| MTP 文件张量 | 15，BF16，243,290,624 参数 | 与 `mtp_num_hidden_layers=1` 一致 |
| 主模型参数 | 9,409,813,744 | 与 `index.json` metadata 一致 |
| 总参数 | 9,653,104,368 | 含 MTP |
| 词表 | 248,320 | 与 config 一致 |
| EOS | `<|im_end|>` | 与 generation_config 一致 |
| PAD | `<|vision_pad|>` | 多模态 padding |
| 最大长度 | 262,144 | 与 config 一致 |
| config 与底座差异 | 仅序列化字段（dtype/torch_dtype、视觉 rope、partial_rotary 嵌套） | 架构未变 |

结论：**当前 commit 的 Safetensors 仓库在结构上是自洽的**。MTP 张量已补回，索引、config、文件三者匹配。

## 7.3 MTP 事故时间线

| 时间（UTC） | 事件 |
|:--|:--|
| 2026-10-30 10:21 | 仓库创建，发布 9B heretic 模型 |
| 2026-10-31 09:45 | mradermacher 发布 i1 GGUF 量化 |
| 2026-11-07 09:12 | 用户 `istone` 报告：GGUF 声明 MTP 但缺张量，llama.cpp 断言失败 |
| 2026-11-07 10:21 | 中文用户报告 LM Studio 加载失败、缺 MTP |
| 2026-11-07 12:56 | 作者回复“周一来看” |
| 2026-11-08 02:05–03:48 | 作者连续更新 README、config、补回 MTP 张量 |
| 2026-11-08 03:36 | commit：`Restore MTP tensors from the original model` |
| 2026-11-08 03:48 | commit：`Update config.json`，恢复 `mtp_num_hidden_layers=1` |
| 2026-11-08 13:07 | 作者称测试 mradermacher 量化“未遇到崩溃”，但承认未覆盖所有后端 |
| 2026-11-09 | 社区 GGUF 仍为 10-31 版本，未重新转换 |

## 7.4 独立验证：Q4_K_M 仍然是坏的

本次调查远程读取了 `mradermacher/...-GGUF` 的 `Q4_K_M` 文件前 16 MB，解析 GGUF v3 头部，得到（下表键名省略 `qwen35.` 前缀）：

| 项目 | 实测值 | 应有值 | 判定 |
|:--|:--|:--|:--:|
| 文件大小 | 5,629,111,264 B（5.63 GB） | — | — |
| 张量数 | 427 | 427（无 MTP） | — |
| `general.architecture` | `qwen35` | `qwen35` | OK |
| `block_count` | **33** | 32（无 MTP）或 33（含 MTP） | 与张量不符 |
| `nextn_predict_layers` | **1** | 1 | 与张量不符 |
| `context_length` | 262,144 | 262,144 | OK |
| `attention.recurrent_layers` | 33 项 | 32 项 | 多 1 项 |
| `blk.32.*` | **不存在** | 若 block_count=33 则应存在 | 缺失 |
| `nextn` / `eh_proj` | **0 个** | 若 nextn=1 则应存在 | 缺失 |
| `blk.*` 最大编号 | 31 | 31 | 只有 32 层 |
| 视觉张量 | 0（`mmproj` 单独文件） | 单独文件 | OK |

llama.cpp 的 `qwen35.cpp` 在加载时会检查 `layer.nextn.eh_proj`，缺失即触发：

```text
GGML_ASSERT(layer.nextn.eh_proj && "MTP block missing nextn.eh_proj") failed
```

这不是显存不足，也不是量化类型问题；它在分配显存之前就会崩溃。**所有基于 10-31 旧权重转换的 GGUF，包括 i1 与非 i1，都受影响。**

作者在 11-08 修复了上游 Safetensors，但没有重转量化。因此：

- 直接加载原仓库 BF16：应正常；
- 加载社区 GGUF：仍可能崩溃；
- 需要等 mradermacher 等维护者从 `e4bfa83` 重新转换，或自己转。

## 7.5 其他交付瑕疵

1. **`pipeline_tag` 与事实不符**：写的是 `text-generation`，但模型是 `image-text-to-text`，tags 里也同时有 `image-text-to-text`。
2. **模型卡缺用法**：没有 `from transformers import ...` 示例，没有 vLLM/llama.cpp 命令，没有 system prompt 建议，没有 thinking 模式说明。
3. **模型卡主体是底座营销页**：38 KB 中大部分是 Jackrong 的 HTML 模板，包含外部链接、徽章、游戏展示；真正属于 heretic 的内容只有开头两段和 6 个参数。
4. **语言声明不完整**：只列 6 种语言，但 Qwen3.5 官方支持 201 种；这是沿用了蒸馏版的声明，未做多语言评测。
5. **`transformers_version` 过新**：`5.20.2`，旧环境可能无法加载。
6. **MTP 文件名不遵循分片模式**：`model-mtp.safetensors` 不在 `model-0000X-of-00004` 序列里；依赖 glob 的工具可能漏掉，依赖 index 的工具则正常。
7. **缺 NOTICE/归属文件**：Apache-2.0 要求保留版权与许可声明，仓库只有 README 文字提及上游。
8. **缺安全/限制章节**：模型卡的“Limitations”是底座模型的通用限制，没有针对“去审查”的额外风险说明。



# 8. 基准测试复核

## 8.1 作者给出的 GSM8K

评测配置：NVFP4（FP8 E4M3）量化、vLLM、GSM8K 测试集跑 4 次取平均。

| 模型 | 准确率 |
|:--|--:|
| MiMo-V2.5-Pro | 99.60% |
| Llama-3.1-405B-Instruct | 96.80% |
| Llama-3.3-70B-Instruct | 94.84% |
| **DeepSeek-V4-Pro-Qwen3.5-9B** | **94.50%** |
| DeepSeek-V4-Pro（教师） | 92.60% |
| DeepSeek-V3 | 89.30% |

作者说“9B 学生略超教师，接近 Llama-3.3-70B”。这句话有三个问题：

1. **教师分数来自不同来源**：作者注明其他模型的参考分来自 `openai/gsm8k` 仓库，而不是在同一 harness 下重跑；
2. **4 次平均不是独立样本**：同一测试集跑 4 次只降低采样噪声，不消除协议差异；
3. **94.50 vs 94.84 的 0.34 分差距远小于噪声**，不能支撑“接近 70B”的排名结论。

## 8.2 作者给出的 MMLU-Pro

评测配置：Math / Physics / Chemistry 各 500 题，共 1,500 题；llama.cpp；MTP-Q8_0 GGUF，8K 上下文。

| 模型 | 构建 | Math | Physics | Chemistry | 平均 |
|:--|:--|--:|--:|--:|--:|
| **DeepSeek-V4-Pro-Qwen3.5-9B** | MTP-Q8_0 GGUF | **92.40** | **89.40** | **89.80** | **90.53** |
| Qwen3.5-9B | MTP-Q8_0 GGUF | 90.60 | 89.00 | 89.20 | 89.60 |
| Claude Mythos-distilled 27B | MTP-Q8 GGUF | 88.40 | 87.60 | 82.60 | 86.20 |
| Claude Mythos-distilled 9B | MTP-Q8_0 GGUF | 86.00 | 78.60 | 78.60 | 81.07 |
| DeepSeek-V4-Pro-Qwen3.5-4B | MTP-Q8 GGUF | 80.40 | 74.20 | 74.80 | 76.47 |

相对 Qwen3.5-9B：Math +1.80、Physics +0.40、Chemistry +0.60、平均 +0.93。

### 统计显著性

对每个子集 n=500、p≈0.9：

```text
单子集标准误 SE = sqrt(0.9 × 0.1 / 500) ≈ 1.34 个百分点
三子集平均 SE ≈ 1.34 / sqrt(3) ≈ 0.77 个百分点
差值 0.93 → z ≈ 1.2，双侧 p ≈ 0.23
95% 置信区间约 ±1.5 个百分点
```

也就是说，**+0.93 分的“平均最高”在统计上无法与“持平”区分**。如果真实准确率更接近 0.8，标准误还会更大（单子集 1.79，平均 1.03），显著性更弱。

作者没有报告方差、置信区间或随机种子，也没有说明 500 题是如何抽样的。MMLU-Pro 每个子集有数百到上千题，抽 500 题若不固定种子，换一批题就可能改变排名。

## 8.3 评测协议不一致

这是最严重的问题。Qwen 官方模型卡给出的 Qwen3.5-9B MMLU-Pro 是 **82.5**；本模型卡在同一列写的是 **89.60**，相差 **7.1 分**。

可能原因：

- 官方用完整 MMLU-Pro（或不同的 few-shot/CoT 协议），作者只取 3 个 STEM 子集；
- 官方用 0-shot 直接答题，作者用 8K 上下文的 MTP-Q8_0；
- 答案提取、系统提示、thinking 模式开关不同；
- 量化与后端不同。

无论原因是什么，结论都一样：**不能用这张表去和其他论文/模型卡的数字横向比较**。表内的 Qwen 基线是作者自己重测的，不是官方数字；表外的 Llama、DeepSeek、Claude Mythos 又是从不同来源拼来的。把三者放在同一张表里排名，方法上不成立。

另外，“Claude Mythos-distilled 27B/9B”不是常见的公开基线，无法从名称定位到可核验的模型卡；这类对比应视为作者自建参考，而非行业基准。

## 8.4 缺失的评测

模型卡声称“数学/STEM 推理”，但没有给出：

- MATH-500、AIME 2024/2025、GPQA、OlympiadBench；
- MMLU-Pro 全量（14 个子集）或 MMLU 全量；
- LiveCodeBench、HumanEval、SWE-bench（作者自己说没有代码数据）；
- 安全基准：HarmBench、AdvBench、ToxiGen、XSTest；
- 多语言基准：C-Eval、M-MMLU、M-RoPE 长上下文；
- 视觉基准：MMMU、DocVQA、ChartQA；
- 长上下文“大海捞针”与多跳检索；
- 校准/拒答权衡曲线。

因此，现有证据只能支持一个弱结论：**它在 GSM8K 和 MMLU-Pro 的三个 STEM 子集上可能略有提升**，不足以支持“全面 STEM 更强”或“接近 70B”的说法。

## 8.5 指令遵循

作者报告：在 1,500 道 MMLU-Pro 题上，要求“思考后只输出一个大写字母”，本模型 **97.2%** 给出单个字母，只有 **0.2%** 冗长复述；Qwen3.5-9B 官方为 37.3% / 62.1%，Claude Mythos-distilled 9B 为 69.6% / 21.1%。

这个结果如果属实，是比 +0.93 分更有价值的差异：蒸馏模型学会了“按格式收尾”，对生产环境的解析友好。但它：

- 不是标准 IFEval/IFEval-CN；
- 没有给出评分 rubric 与人工抽检；
- 对比模型的 system prompt 是否完全一致未说明；
- 只测了一种格式（单字母），不能外推到 JSON、表格、工具调用。

## 8.6 基准复核结论

| 声明 | 证据等级 | 复核意见 |
|:--|:--:|:--|
| GSM8K 94.50% | B/C | 数字具体，但参考分来自不同协议；0.34 分差距无意义 |
| MMLU-Pro 平均 90.53% | B/C | 3 子集 × 500 题；+0.93 不显著；与官方 Qwen 82.5 差 7.1 分，协议不一致 |
| 每正确答 token 少 36.1% | B | 方向可信，但依赖正确集与分词口径 |
| 格式遵循 97.2% | B | 有生产价值，但非标准基准，需自测 |
| “接近 Llama-3.3-70B” | C | 不在同一 harness，不能这样比 |
| “超越教师” | C | 教师分数来自第三方参考，不是同协议重跑 |

**建议：把这些数字当作“作者声称”，不要写进采购决策或对外宣传。** 如果要用，必须用自己的 1,000+ 题、固定种子、同一 harness 重跑，并报告均值 ± 95% CI。



# 9. 推理效率分析

## 9.1 Token 经济性

作者在同一 1,500 题 MMLU-Pro 样本上统计：

| 模型 | 准确率 | 平均推理 token/题 | 中位 token/正确答 | 每百万 token 正确数 |
|:--|--:|--:|--:|--:|
| **本模型** | 90.53% | 2,858 | **676** | **316.8** |
| Qwen3.5-9B | 89.60% | 4,425 | 3,214 | 202.5 |
| Claude Mythos-distilled 9B | 81.07% | 3,310 | 639 | 244.9 |

作者给出的相对变化：

- 对比 Qwen3.5-9B：每正确答 token 少 **36.1%**，准确率 +0.93；
- 对比 Mythos 9B：少 **22.7%**，准确率 +9.47；
- 每百万 token 正确数：比 Qwen 高 **56.4%**，比 Mythos 高 **29.3%**。

分学科 token 节省（对比 Qwen / Mythos）：

| 学科 | vs Qwen | vs Mythos |
|:--|--:|--:|
| Math | 47.4% | 35.6% |
| Physics | 30.8% | 10.8% |
| Chemistry | 32.1% | 23.3% |

## 9.2 怎么解读

这是整份模型卡里**最可信、也最有价值**的部分，原因：

1. 它不是“准确率更高”，而是“同样答对时更省 token”，这类指标不容易被采样噪声左右；
2. 中位数 676 vs 3,214 的差距极大（约 4.8 倍），说明本模型在简单题上更果断，不会像底座那样长篇自我怀疑；
3. 每百万 token 正确数同时受准确率与 token 长度影响，作者把两个维度都列出来了，口径相对清楚。

但仍有三个注意点：

- **平均值 2,858 vs 中位数 676**：分布严重右偏，少数超长推理拉高了均值；对成本敏感的线上服务，应按 P90/P99 而不是均值做容量规划。
- **“每正确答 token”依赖正确集**：如果准确率被高估，分母变小，效率会被高估；两者不是独立指标。
- **分词器相同**（同一 Qwen 词表），所以 token 比较是公平的；但不同后端（vLLM vs llama.cpp）对 thinking token 的截断/解析可能不同。

GSM8K 的 NVFP4 轨迹统计（2,638 条）：平均 1,627 token、中位 372、P90 3,042、每正确答 1,721。与 MMLU-Pro 的结论一致：**简单题很短，难题会展开**。

## 9.3 推理性能因素

| 因素 | 影响 |
|:--|:--|
| 混合注意力 | KV Cache 只有 8 层，长上下文显存约为同规模全注意力模型的 1/4 |
| MTP | 投机解码可提升 decode 吞吐，但取决于草稿接受率；官方未给本模型的加速比 |
| 262K 上下文 | 权重 + KV 在 BF16 下约 27.9 GB（262K 时），单卡 24 GB 不够 |
| 量化 | Q4_K_M 权重 5.63 GB，但数学精度会下降；需在自己的题集上重测 |
| 后端 | vLLM/SGLang 对 Qwen3.5 的支持来自 main 分支；llama.cpp 的 qwen35 实现较新，版本差异大 |



# 10. 部署评估

## 10.1 硬件矩阵（估算）

假设：BF16 权重 19.33 GB；KV Cache 按 8 层全注意力、BF16、4 KV 头 × 256 维计算；预留 10–20% 激活/碎片开销。

| 格式 | 权重 | 32K KV | 128K KV | 262K KV | 建议硬件 |
|:--|--:|--:|--:|--:|:--|
| BF16 | 19.33 GB | 1.07 GB | 4.29 GB | 8.59 GB | 24 GB 紧；32 GB 舒适；262K 需 40 GB+ |
| FP8 | ~9.7 GB | 0.54 GB | 2.15 GB | 4.30 GB | 16 GB（32K）；24 GB（128K） |
| NVFP4 | ~5.0 GB | 1.07 GB | 4.29 GB | 8.59 GB | 12 GB（32K）；24 GB（128K） |
| Q8_0 GGUF | 9.53 GB | 1.07 GB | 4.29 GB | 8.59 GB | 16 GB（32K）；24 GB（128K） |
| Q4_K_M GGUF | 5.63 GB | 1.07 GB | 4.29 GB | 8.59 GB | 8–12 GB（32K） |
| IQ4_XS GGUF | 5.23 GB | 1.07 GB | 4.29 GB | 8.59 GB | 8–12 GB（32K） |

注：

- NVFP4 需要 Blackwell 级 GPU（RTX 50 系 / B200 等）；老卡不支持。
- GGUF 的 KV 精度可设为 Q8/Q4，能进一步减半，但会损失长上下文质量。
- GGUF 的视觉能力需另加 `mmproj`：Q8_0 约 0.62 GB，F16 约 0.92 GB；表内 GGUF 体积仅指主模型。
- MTP 头额外 0.49 GB；不用 MTP 可忽略。
- 以上是单序列估算；批量服务需按并发数乘 KV。

## 10.2 推荐路径

| 场景 | 推荐 | 理由 |
|:--|:--|:--|
| NVIDIA GPU、追求吞吐 | vLLM / SGLang（main 分支） | 支持 Qwen3.5、连续批处理、MTP、OpenAI API |
| Apple Silicon / CPU | llama.cpp（最新构建） | Metal/CPU 友好；等 GGUF 重转后再用 |
| 单机实验 | Transformers + BF16 | 最简单，但 19.33 GB 权重，需 24 GB+ |
| 边缘设备 | Q4_K_M / IQ4_XS | 5–6 GB；但当前量化损坏，需自转 |
| Mac 16 GB | 4B 兄弟版更现实 | 9B Q4 约 5.6 GB 可加载，但长上下文与质量受限 |

## 10.3 Transformers 示例

以下示例按 Qwen3.5 的通用接口编写；不同 `transformers` 版本可能使用 `AutoModelForImageTextToText` 或 `Qwen3_5ForConditionalGeneration`，以实际版本为准。

```python
from transformers import AutoProcessor, AutoModelForImageTextToText
import torch

model_id = "xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic"

processor = AutoProcessor.from_pretrained(model_id)
model = AutoModelForImageTextToText.from_pretrained(
    model_id,
    dtype=torch.bfloat16,
    device_map="auto",
)

messages = [
    {"role": "system", "content": "You are a careful math and STEM assistant. Show your reasoning, then give the final answer."},
    {"role": "user", "content": [{"type": "text", "text": "Solve: ..."}]},
]

inputs = processor.apply_chat_template(
    messages,
    add_generation_prompt=True,
    tokenize=True,
    return_dict=True,
    return_tensors="pt",
).to(model.device)

with torch.no_grad():
    output = model.generate(
        **inputs,
        max_new_tokens=2048,
        do_sample=False,
    )

print(processor.decode(output[0][inputs["input_ids"].shape[-1]:], skip_special_tokens=True))
```

注意：

- 模型默认是 thinking 模式，输出 `<think>...</think>`；生产解析要能处理这段。
- 若显存不足，先降 `max_model_len`，不要先降精度。
- 多模态输入需要 `processor` 处理图像/视频，文本-only 场景可只传 text content。

## 10.4 vLLM 示例

```bash
# 需要支持 Qwen3.5 的 vLLM（main / nightly）
vllm serve xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic \
  --max-model-len 32768 \
  --reasoning-parser qwen3 \
  --port 8000

# 启用工具调用（如需要）
vllm serve xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic \
  --max-model-len 32768 \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --port 8000
```

MTP 投机解码的开启方式随 vLLM 版本变化，需查阅对应版本文档；不要假设 `--speculative-*` 参数在本模型上一定生效。

## 10.5 llama.cpp 示例与验证

```bash
# 前提：GGUF 已从修复后的 safetensors 重新转换
llama-server \
  -m DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic.Q4_K_M.gguf \
  --mmproj DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic.mmproj-f16.gguf \
  -c 32768 \
  -ngl 99 \
  --host 127.0.0.1 --port 8080
```

加载前先验证 GGUF 元数据与张量是否一致：

```python
import struct, json

path = "model.Q4_K_M.gguf"
with open(path, "rb") as f:
    magic, version, n_tensors, n_kv = struct.unpack("<IIQQ", f.read(24))
    # 省略 KV 解析；可用 gguf_dump.py / llama-gguf 工具
    print("tensors:", n_tensors)
```

更简单的办法是用 `llama.cpp` 自带的 `gguf_dump.py` 或 `llama-gguf` 查看：

```bash
python gguf_dump.py model.Q4_K_M.gguf | grep -E "block_count|nextn_predict_layers"
```

判定规则：

- 若 `block_count=33` 且 `nextn_predict_layers=1`，必须存在 `blk.32.*` 与 `nextn/eh_proj` 张量；否则会崩溃。
- 若没有 MTP，转换前把 `config.json` 的 `mtp_num_hidden_layers` 设为 `0`，并把 `nextn_predict_layers` 置 0。

## 10.6 本机可行性（Apple M5 / 16 GB）

- BF16：不可行（19.33 GB 权重 + KV）。
- Q8_0：9.53 GB 权重，16 GB 统一内存可加载，但 32K 上下文会紧张。
- Q4_K_M：5.63 GB 权重，理论可行；但当前社区 GGUF 因 MTP 缺陷会在 llama.cpp 加载时崩溃。
- 4B 兄弟版：更现实的选择；`xtools-at/DeepSeek-V4-Pro-Qwen3.5-4B-UNCENSORED-heretic` 已于 11-02 发布，文件结构类似，也带 `model-mtp.safetensors`。

本次调查**没有在本机执行推理**，因为需要先解决 GGUF 重转或下载 19 GB BF16 权重；上述为容量推算，不是实测帧率。



# 11. 风险、合规与伦理

## 11.1 安全风险

这是本模型最需要明确提示的部分。

| 风险 | 说明 | 缓解 |
|:--|:--|:--|
| 拒答被削弱 | 作者目标就是把拒答从 100/100 降到 3/100；剩余 3% 不代表安全边界 | 外部审核、允许列表、输出过滤 |
| 有害内容合规 | 模型可能配合生成违法/有害内容；没有任何内置 guardrail | 不要面向公众裸露；加系统提示与分类器 |
| 幻觉 | 数学/STEM 仍会算错；作者自己列为限制 | 工具校验、双模型复核、人工抽检 |
| 多模态攻击面 | 视觉塔保留但未评测；图像输入可能绕过文本过滤 | 图像审核、OCR/内容分类 |
| 提示注入 | 长上下文 + 工具调用场景下，外部内容可注入指令 | 隔离不可信内容、工具权限最小化 |
| 过度服从 | 去审查可能同时削弱“拒绝不安全请求”的能力 | 红队测试、拒答率/有用性权衡曲线 |

需要强调：**“3/100 拒答”不是“3% 有害”，也不是“97% 安全”。** 拒答率只是模型在特定提示集上说“不”的比例；它不衡量模型是否真的能造成伤害，也不衡量输出质量。

## 11.2 许可与法律

| 层 | 许可 | 结论 |
|:--|:--|:--|
| Qwen3.5-9B | Apache-2.0 | 允许商用、修改、再分发；需保留版权/许可声明 |
| Jackrong 蒸馏版 | Apache-2.0 | 同上 |
| DeepSeek-V4-Pro（教师） | MIT | 允许使用、修改、再分发；需保留版权/许可声明 |
| 本仓库 | Apache-2.0 | 与上游兼容 |
| Heretic 工具 | AGPL-3.0 | 修改/分发工具本身需开源；模型权重是否受 AGPL 约束存在解释空间，通常视为独立作品 |

要点：

- **许可链是干净的**：没有看到 GPL 污染或非商用限制。
- **教师输出用于蒸馏**：DeepSeek-V4-Pro 是 MIT，未看到禁止用输出训练其他模型的条款；但正式商用仍建议让法务核对 DeepSeek 的使用条款与输出政策。
- **Apache-2.0 的义务**：分发时要附 LICENSE、保留 NOTICE/版权声明、说明修改。本仓库没有 NOTICE 文件，README 只在致谢里提到上游；如果二次分发，建议自己补齐。
- **Heretic 的 AGPL**：如果你修改 Heretic 并把它作为服务提供，AGPL 的网络使用条款可能要求开源修改；但“用 Heretic 产出的权重”不等于“Heretic 的衍生代码”。保持工具与权重分离，风险较低。
- **平台政策**：Hugging Face 允许托管，但应用商店、云厂商、支付/广告平台可能禁止“uncensored”内容；上线前逐项核对。
- **地区法规**：
    - 欧盟：AI Act 对 GPAI 的透明度、版权政策、风险评估有要求；去审查模型用于公众服务需要额外说明。
    - 中国：《生成式人工智能服务管理暂行办法》要求内容安全、标识、备案；此类无护栏模型不适合直接面向公众提供服务。
    - 美国：无统一联邦 AI 法，但 FTC Act 第 5 条、州级法律、行业监管仍适用；虚假宣传与伤害责任不能忽视。
- **出口管制**：9B 模型不属于前沿大模型，通常不受出口管制；但若用于军事/监控等敏感场景，仍需单独评估。

> 以上不是法律意见。商用前请让法务确认许可、平台条款与属地法规。

## 11.3 供应链风险

| 风险 | 事实 | 建议 |
|:--|:--|:--|
| 非官方二次派生 | 个人账号的融合/消融，不是 DeepSeek/Qwen 官方 | 固定 commit，记录来源 |
| 无签名/无哈希 | README 没有权重 sha256；只有 HF LFS 指针 | 下载后自行计算并存档 |
| 同名镜像多 | 搜索到 25+ 个同名仓库，部分 0 下载 | 只认 canonical repo，警惕 typosquat |
| 量化滞后 | 社区 GGUF 仍是 10-31 旧权重 | 等重转或自转，验证元数据 |
| MTP 文件拆分 | `model-mtp.safetensors` 不在分片序列 | 用 index 加载；转换前检查是否被包含 |
| 模型卡外部链接 | README 含大量外链/徽章 | 视为数据，不要在生产中自动抓取 |

## 11.4 评测与声誉风险

- 模型卡的基准是**自报**，没有第三方 leaderboard 记录；
- “Claude Mythos-distilled”基线无法定位到可核验模型卡；
- 879 likes / 7,088 下载 vs 28 万 GGUF 下载，说明热度主要来自“本地能跑”，不是“评测领先”；
- 如果你对外宣称“接近 70B”或“超越教师”，可能构成误导性宣传。

## 11.5 伦理

- 去审查模型的正当用途包括：安全研究、红队、内容审核器训练、文学/创作自由实验；
- 不当用途包括：面向未成年人的无护栏聊天、违法内容生成、绕过平台安全策略；
- 如果部署，至少应：披露模型来源与限制、保留日志、提供人工申诉、对高风险请求加二次审核；
- 不要用“开源”作为免除责任的理由；许可证免责条款不等于运营者无责任。



# 12. 适用与不适用场景

| 场景 | 建议 | 理由 |
|:--|:--:|:--|
| 去审查/消融方法研究 | ✅ 推荐 | ARA + 9B 混合架构的公开案例，参数完整 |
| 安全红队与对齐研究 | ✅ 推荐（隔离环境） | 可作为“弱拒答”被测对象；需遵守伦理审查 |
| 本地数学/STEM 助手 | ⚠️ 可用，需人工复核 | GSM8K/MMLU-Pro 数字尚可，但无独立复现 |
| 成本敏感的推理服务 | ⚠️ 试点 | token 效率是亮点；需按自己的题集验证 |
| 长上下文文档分析 | ⚠️ 试点 | 架构支持 262K，但没有长上下文评测 |
| 图像/视频理解 | ❌ 不建议 | 视觉塔保留但零评测 |
| 代码生成/Agent | ❌ 不建议 | 训练无代码数据，作者自己说只有轻微迁移 |
| 消费级聊天机器人 | ❌ 不建议 | 去审查 + 无 guardrail + 合规风险 |
| 医疗/法律/金融建议 | ❌ 不建议 | 幻觉、责任、监管风险 |
| 未成年人产品 | ❌ 不建议 | 内容安全无法保证 |
| 受监管行业生产 | ❌ 不建议 | 缺安全评测、可复现性与供应商保障 |



# 13. 结论与行动建议

## 13.1 结论

1. **它不是“DeepSeek 官方 9B”**，而是 Qwen3.5-9B 的 DeepSeek 蒸馏版再去拒答；命名容易误导，采购/宣传时要写清楚。
2. **架构是先进的**：混合线性注意力、原生多模态、MTP、262K 上下文，9.65B 稠密规模，单卡可部署。
3. **去审查方法有技术含量**：ARA 不依赖拒答方向，直接优化模块矩阵；只改 16/32 层，KL 0.0422，思路清晰。
4. **证据质量不足**：基准自报、样本小、协议不统一、无置信区间、无原始日志、无可复现 manifest；“+0.93 分”不显著，“接近 70B”不成立。
5. **工程交付有瑕疵**：MTP 权重缺失导致社区 GGUF 崩溃；上游已修但量化未重转；模型卡缺用法与限制；`pipeline_tag` 与多模态事实不符。
6. **真正的亮点是 token 效率**：中位每正确答 676 token，对比 Qwen3.5-9B 的 3,214；如果独立复现，对成本敏感服务有价值。
7. **合规上“许可干净、用途敏感”**：Apache-2.0/MIT 链条兼容，但去审查属性不适合无护栏公众部署。

## 13.2 行动清单

### P0：如果明天要用

1. **固定版本**：只认 `e4bfa83c72896cbb4990c909967d6f27bb97bac4`；记录下载时间与文件哈希。
2. **不要直接用旧 GGUF**：10-31 的量化全部有 MTP 元数据缺陷；要么等 mradermacher 重转，要么自己从 Safetensors 转，并在加载前验证 `block_count` / `nextn` / `blk.32`。
3. **自建评测**：至少 1,000 题、固定种子、同一 harness，对比 Qwen3.5-9B、Jackrong 底座、本模型；报告均值与 95% CI。
4. **红队 + 外部审核**：测有害请求服从率、拒答率、过度拒答；上线前加输入/输出分类器与人工申诉。

### P1：如果准备试点

5. **补许可文件**：附 Apache-2.0 LICENSE、NOTICE、上游归属与修改说明。
6. **测长上下文**：32K/128K/262K 的 needle-in-a-haystack、多跳检索、成本曲线。
7. **测多模态**（如需要）：MMMU/DocVQA/ChartQA 小样本，确认视觉塔未被消融破坏。
8. **测 MTP**：草稿接受率、decode 吞吐、与不开 MTP 的质量差异。

### P2：如果长期跟踪

9. **关注上游**：mradermacher 是否重转、Heretic v2.1 是否影响 ARA、模型卡是否补评测。
10. **考虑 4B 兄弟版**：16 GB 设备更现实；但同样要检查 MTP 与量化状态。
11. **建立内部模型卡**：记录来源、许可、评测、限制、责任人，避免“模型卡即营销页”。

## 13.3 一句话建议

> **把它当作“研究工件”而不是“生产模型”：可以研究它的 ARA 方法、token 效率和混合架构；不要把它当作 DeepSeek 官方能力、不要相信未复现的基准、不要把旧 GGUF 直接上线。**



# 14. 附录

## 附录 A：复现本次调查的关键命令

```bash
# 1) 读取模型元数据（需要能访问 huggingface.co）
curl -sL "https://huggingface.co/api/models/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic?blobs=true"

# 2) 读取 config / index
curl -sL "https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic/raw/main/config.json"
curl -sL "https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic/raw/main/model.safetensors.index.json"

# 3) 读取讨论区
curl -sL "https://huggingface.co/api/models/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic/discussions"
curl -sL "https://huggingface.co/api/models/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-i1-GGUF/discussions"

# 4) 读取 commit 历史
curl -sL "https://huggingface.co/api/models/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic/commits/main"

# 5) 解析 Safetensors 头部（Range 读取，不下载全量）
python3 - <<'PY'
import json, struct, urllib.request
url = "https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic/resolve/main/model-mtp.safetensors"
n = struct.unpack("<Q", urllib.request.urlopen(urllib.request.Request(url, headers={"Range": "bytes=0-7"})).read(8))[0]
h = json.loads(urllib.request.urlopen(urllib.request.Request(url, headers={"Range": f"bytes=8-{8+n-1}"})).read())
print(h)
PY
```

## 附录 B：术语表

| 术语 | 含义 |
|:--|:--|
| Abliteration | 通过消融/投影移除模型拒答方向的技术 |
| ARA | Arbitrary-Rank Ablation，Heretic 2.0 的默认消融方法，不假设拒答流形秩 |
| KL divergence | 修改前后模型输出分布的散度，越低越接近原模型 |
| MTP | Multi-Token Prediction，多 token 预测草稿头，用于投机解码 |
| GQA | Grouped Query Attention，分组查询注意力 |
| Gated DeltaNet | 一种线性注意力/状态空间混合结构，固定大小递归状态 |
| M-RoPE | Multimodal RoPE，多模态旋转位置编码 |
| NVFP4 | NVIDIA 的 4-bit 浮点量化格式，需要 Blackwell 级 GPU |
| GGUF | llama.cpp 使用的量化模型文件格式 |
| mmproj | 多模态投影文件，配合 GGUF 主模型使用 |
| 蒸馏 | 用强教师模型的输出训练小学生模型 |
| SFT | Supervised Fine-Tuning，监督微调 |
| GSPO | Grouped Stepwise Preference Optimization，一种偏好优化方法 |

## 附录 C：参考链接

| 来源 | 链接 |
|:--|:--|
| 本模型 | [https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic](https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic) |
| 4B 兄弟版 | [https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-4B-UNCENSORED-heretic](https://huggingface.co/xtools-at/DeepSeek-V4-Pro-Qwen3.5-4B-UNCENSORED-heretic) |
| Jackrong 底座 | [https://huggingface.co/Jackrong/DeepSeek-V4-Pro-Qwen3.5-9B](https://huggingface.co/Jackrong/DeepSeek-V4-Pro-Qwen3.5-9B) |
| Qwen3.5-9B | [https://huggingface.co/Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) |
| DeepSeek-V4-Pro | [https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro) |
| Heretic 项目 | [https://github.com/p-e-w/heretic](https://github.com/p-e-w/heretic) |
| Heretic 官网 | [https://heretic-project.org](https://heretic-project.org) |
| ARA 设计 PR | [https://github.com/p-e-w/heretic/pull/211](https://github.com/p-e-w/heretic/pull/211) |
| mradermacher GGUF | [https://huggingface.co/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF](https://huggingface.co/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF) |
| i1 GGUF | [https://huggingface.co/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-i1-GGUF](https://huggingface.co/mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-i1-GGUF) |

## 附录 D：数据快照

| 字段 | 值 |
|:--|:--|
| 快照时间 | 2026-11-09 |
| 模型 commit | `e4bfa83c72896cbb4990c909967d6f27bb97bac4` |
| 仓库文件总大小 | 19,331,656,186 B（19.33 GB） |
| 主模型参数 | 9,409,813,744 |
| MTP 参数 | 243,290,624 |
| 总参数 | 9,653,104,368 |
| 索引键数 | 775 |
| MTP 张量数 | 15 |
| 视觉张量数 | 333 |
| 近 30 天下载 | 7,088 |
| 点赞 | 879 |
| 主要 GGUF 下载合计 | 281,489 |
| 原始 Q4_K_M 大小 | 5,629,111,264 B |
| Q4_K_M 张量数 | 427 |
| Q4_K_M `block_count` | 33 |
| Q4_K_M `nextn_predict_layers` | 1 |
| Q4_K_M `blk.32` | 不存在 |
| Q4_K_M `nextn/eh_proj` | 0 |

---

**报告完。** 本报告不提供有害请求的测试提示，也不建议在生产环境中关闭安全护栏。若需进一步做受控红队评测，建议在隔离环境、明确授权与伦理审查下进行。
