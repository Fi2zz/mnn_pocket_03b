import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:onenm_local_llm/onenm_local_llm.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Optional headless smoke test: `flutter run --dart-define=AUTO_SMOKE=true`.
const bool _autoSmoke = bool.fromEnvironment('AUTO_SMOKE');

/// Optional routing evaluation: `flutter run --dart-define=AUTO_EVAL=true`.
const bool _autoEval = bool.fromEnvironment('AUTO_EVAL');

/// Optional ASR self-test: `flutter run --dart-define=AUTO_ASR=true`.
const bool _autoAsr = bool.fromEnvironment('AUTO_ASR');

const String _systemPrompt =
    '你是 MNN-Pocket，一个完全运行在手机本地的 AI 助手。回答简洁、准确，优先使用用户的语言。';

/// MNN-Pocket-0.3B, Q4_1 GGUF (183 MB), served by llama.cpp.
///
/// Note: this demo validates the *model*, not the MNN engine. The technical
/// report's 251 tok/s Android CPU number is MNN-specific and is not reproduced
/// by this llama.cpp build.
const ModelInfo _pocketModel = ModelInfo(
  id: 'mnn-pocket-0.3b',
  name: 'MNN-Pocket 0.3B',
  fileName: 'MNN-Pocket-0.3B-Instruct-Q4_1.gguf',
  ggufUrl:
      'https://modelscope.cn/models/MNN/MNN-Pocket-0.3B-GGUF/resolve/master/MNN-Pocket-0.3B-Instruct-Q4_1.gguf',
  sizeMB: 183,
  minRamGB: 1,
  // The vendored bridge is patched to n_ctx = 2048.
  context: 2048,
  chatTemplate: ChatTemplate(
    system: '<|im_start|>system\n{text}<|im_end|>\n',
    user: '<|im_start|>user\n{text}<|im_end|>\n',
    assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
    systemDefault: _systemPrompt,
  ),
);

const GenerationSettings _defaultSettings = GenerationSettings(
  temperature: 0.4,
  topK: 20,
  topP: 0.8,
  maxTokens: 256,
  repeatPenalty: 1.1,
);

const List<String> _suggestions = <String>[
  '用一句话介绍你自己',
  '把「我要退款」分类到：退款/物流/咨询/投诉，只输出标签',
  '从评论抽取属性和情感：包装很好，但遮瑕效果差一些',
];

const List<String> _intentLabels = <String>['退款', '物流', '咨询', '投诉', '其他'];
const List<String> _routeExamples = <String>[
  '我要退款',
  '快递到哪了',
  '这个多少钱',
  '我要投诉客服',
];

const List<_EvalCase> _defaultEvalCases = <_EvalCase>[
  _EvalCase('我要退款', '退款'),
  _EvalCase('申请退货退款', '退款'),
  _EvalCase('这个订单能退吗', '退款'),
  _EvalCase('钱什么时候退回来', '退款'),
  _EvalCase('收到货不对，我要退款', '退款'),
  _EvalCase('快递到哪了', '物流'),
  _EvalCase('什么时候发货', '物流'),
  _EvalCase('物流一直不更新', '物流'),
  _EvalCase('帮我查一下运单', '物流'),
  _EvalCase('为什么还没到', '物流'),
  _EvalCase('这个多少钱', '咨询'),
  _EvalCase('有优惠吗', '咨询'),
  _EvalCase('怎么使用', '咨询'),
  _EvalCase('保质期多久', '咨询'),
  _EvalCase('尺码怎么选', '咨询'),
  _EvalCase('我要投诉客服', '投诉'),
  _EvalCase('你们服务太差了', '投诉'),
  _EvalCase('我要找你们领导', '投诉'),
  _EvalCase('客服态度恶劣', '投诉'),
  _EvalCase('我要举报', '投诉'),
  _EvalCase('你好', '其他'),
  _EvalCase('谢谢', '其他'),
  _EvalCase('你是谁', '其他'),
  _EvalCase('讲个笑话', '其他'),
  _EvalCase('今天天气怎么样', '其他'),
];

void main() {
  runApp(const PocketApp());
}

class PocketApp extends StatelessWidget {
  const PocketApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0E6B5C));
    return MaterialApp(
      title: 'MNN-Pocket 0.3B',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF7F5F0),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F5F0),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const ChatPage(),
    );
  }
}

enum ModelPhase { idle, downloading, loading, ready, error }

class _Message {
  _Message(this.role, this.text, {this.meta});

  final String role; // 'user' | 'assistant'
  String text;
  String? meta;
}

class _EvalCase {
  const _EvalCase(this.query, this.expected);

  final String query;
  final String expected;
}

class _EvalResult {
  const _EvalResult(
    this.query,
    this.expected,
    this.predicted,
    this.ms,
    this.raw,
  );

  final String query;
  final String expected;
  final String predicted;
  final int ms;
  final String raw;

  bool get correct => expected == predicted;
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  OneNm? _ai;
  ModelPhase _phase = ModelPhase.idle;
  String _status = '首次使用需要下载模型（约 183 MB）';
  String? _error;
  String? _modelPath;
  double? _progress;
  bool _initializing = false;
  bool _busy = false;
  bool _smokeDone = false;

  int _tab = 0;
  final TextEditingController _routeInput = TextEditingController();
  bool _routing = false;
  String? _routeLabel;
  String? _routeRaw;
  int? _routeLatency;

  final AudioRecorder _recorder = AudioRecorder();
  sherpa_onnx.OnlineRecognizer? _asr;
  sherpa_onnx.VoiceActivityDetector? _vad;
  bool _asrLoading = false;
  bool _recording = false;
  bool _transcribing = false;
  Timer? _recordTimer;

  final TextEditingController _evalInput = TextEditingController();
  bool _evaluating = false;
  bool _evalDone = false;
  final List<_EvalResult> _evalResults = <_EvalResult>[];

  GenerationSettings _settings = _defaultSettings;
  final List<_Message> _messages = <_Message>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _messages.add(_welcome());
    _evalInput.text =
        _defaultEvalCases.map((c) => '${c.query}\t${c.expected}').join('\n');
    _bootstrap();
  }

  _Message _welcome() => _Message(
        'assistant',
        '你好，我是 MNN-Pocket 0.3B，完全跑在你的手机上。\n\n'
            '我擅长短文本理解、结构化抽取、意图判断和轻量生成；'
            '知识问答和复杂推理不是我的强项。',
        meta: '本地模型 · 零网络请求',
      );

  Future<String> _expectedModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/models/${_pocketModel.fileName}';
  }

  Future<void> _bootstrap() async {
    final path = await _expectedModelPath();
    if (!mounted) return;
    setState(() => _modelPath = path);
    final file = File(path);
    final exists = await file.exists();
    final length = exists ? await file.length() : 0;
    if (!mounted) return;
    if (exists && length > 150 * 1024 * 1024) {
      await _initModel();
    } else {
      setState(() => _phase = ModelPhase.idle);
    }
  }

  Future<void> _initModel() async {
    if (_initializing) return;
    _initializing = true;

    final old = _ai;
    _ai = null;
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }

    if (!mounted) {
      _initializing = false;
      return;
    }
    setState(() {
      _phase = ModelPhase.loading;
      _status = '正在准备模型…';
      _error = null;
      _progress = null;
    });

    final ai = OneNm(
      model: _pocketModel,
      settings: _settings,
      onProgress: _onProgress,
      onRetryRequired: _onRetry,
      debug: kDebugMode,
    );

    try {
      await ai.initialize();
      if (!mounted) {
        unawaited(ai.dispose());
        return;
      }
      setState(() {
        _ai = ai;
        _phase = ModelPhase.ready;
        _status = '模型已加载 · 完全离线';
        _progress = null;
      });
      if (_autoSmoke && !_autoEval && !_smokeDone) {
        _smokeDone = true;
        unawaited(_runSmoke());
      }
      if (_autoEval && !_evalDone) {
        _evalDone = true;
        unawaited(_runEval());
      }
      if (_autoAsr) {
        unawaited(_runAsrSelfTest());
      }
    } catch (e) {
      unawaited(ai.dispose());
      if (!mounted) return;
      setState(() {
        _phase = ModelPhase.error;
        _error = '$e';
        _status = '模型加载失败';
      });
    } finally {
      _initializing = false;
    }
  }

  void _onProgress(String message) {
    final now = DateTime.now();
    final important = message == 'Ready' ||
        message.startsWith('Download complete') ||
        message.contains('Loading') ||
        message.contains('Preparing') ||
        message.contains('Model found');
    if (!important && now.difference(_lastProgress).inMilliseconds < 120) {
      return;
    }
    _lastProgress = now;

    final match = RegExp(r'\((\d+(?:\.\d+)?)%\)').firstMatch(message);
    final value = match == null ? null : double.parse(match.group(1)!) / 100.0;
    if (!mounted) return;
    setState(() {
      _status = message;
      if (value != null) _progress = value;
      if (message.startsWith('Downloading')) {
        _phase = ModelPhase.downloading;
      } else if (message.contains('Loading') ||
          message.contains('Preparing') ||
          message.contains('Model found')) {
        _phase = ModelPhase.loading;
      }
    });
  }

  Future<bool> _onRetry(String message) async {
    if (!mounted) return false;
    final retry = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('下载中断'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
    return retry ?? false;
  }

  String _clean(String raw) {
    var text = raw.replaceAll(RegExp(r'<\|[^>]*\|>'), '');
    text = text.replaceAll(RegExp(r'^\s*assistant\s*', caseSensitive: false), '');
    return text.trim();
  }

  Future<void> _send([String? preset]) async {
    final ai = _ai;
    if (ai == null || _busy || _evaluating) return;
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty) return;

    _input.clear();
    setState(() {
      _messages.add(_Message('user', text));
      _messages.add(_Message('assistant', ''));
      _busy = true;
    });
    _scrollToBottom();

    final stopwatch = Stopwatch()..start();
    try {
      final reply = await ai.chat(text, systemPrompt: _systemPrompt);
      final clean = _clean(reply);
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _messages.last.text = clean.isEmpty ? '（模型没有返回内容）' : clean;
        _messages.last.meta =
            '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2)}s · ${clean.length} 字';
      });
      if (_autoSmoke) {
        debugPrint(
          '[SMOKE] ${clean.replaceAll('\n', ' ')} (${stopwatch.elapsedMilliseconds}ms)',
        );
      }
    } catch (e) {
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _messages.last.text = '推理出错：$e';
        _messages.last.meta = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  Future<void> _runSmoke() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted || _ai == null) return;
    await _send('用一句话介绍你自己');
  }

  Future<void> _runAsrSelfTest() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/asr/test.wav');
    if (!await file.exists()) {
      debugPrint('[ASR] test.wav not found at ${file.path}');
      return;
    }
    final asr = await _ensureAsr();
    if (asr == null) return;
    await _transcribe(file.path);
  }

  void _clear() {
    _ai?.clearHistory();
    setState(() {
      _messages
        ..clear()
        ..add(_welcome());
    });
  }

  Future<void> _applySettings(GenerationSettings settings) async {
    if (!mounted) return;
    setState(() => _settings = settings);
    await _initModel();
  }

  Future<void> _openSettings() async {
    var temperature = _settings.temperature;
    var topP = _settings.topP;
    var topK = _settings.topK.toDouble();
    var maxTokens = _settings.maxTokens.toDouble();

    final applied = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget slider({
            required String label,
            required double value,
            required double min,
            required double max,
            required int divisions,
            required String display,
            required ValueChanged<double> onChanged,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(display,
                        style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
                  ],
                ),
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ],
            );
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              24 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('生成参数',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                slider(
                  label: '温度',
                  value: temperature,
                  min: 0.1,
                  max: 1.5,
                  divisions: 28,
                  display: temperature.toStringAsFixed(2),
                  onChanged: (v) => setSheet(() => temperature = v),
                ),
                slider(
                  label: 'Top-P',
                  value: topP,
                  min: 0.1,
                  max: 1.0,
                  divisions: 18,
                  display: topP.toStringAsFixed(2),
                  onChanged: (v) => setSheet(() => topP = v),
                ),
                slider(
                  label: 'Top-K',
                  value: topK.clamp(1, 100),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  display: topK.round().toString(),
                  onChanged: (v) => setSheet(() => topK = v),
                ),
                slider(
                  label: '最大生成长度',
                  value: maxTokens.clamp(64, 1024),
                  min: 64,
                  max: 1024,
                  divisions: 15,
                  display: '${maxTokens.round()} tokens',
                  onChanged: (v) => setSheet(() => maxTokens = v),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('应用并重新加载模型'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '应用后会重新加载模型；已下载的文件不会重复下载。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (applied == true) {
      await _applySettings(
        GenerationSettings(
          temperature: temperature,
          topK: topK.round(),
          topP: topP,
          maxTokens: maxTokens.round(),
          repeatPenalty: 1.1,
        ),
      );
    }
  }

  Future<void> _openInfo() async {
    final path = _modelPath ?? await _expectedModelPath();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于这个 Demo'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '模型：MNN-Pocket-0.3B（约 302M 参数，Qwen3 架构）\n'
                '量化：Q4_1 GGUF（来自 QAT 权重）\n'
                '文件：约 183 MB\n'
                '上下文：2048 tokens（本地插件已改 n_ctx）\n'
                '运行时：llama.cpp（不是 MNN 引擎）\n'
                'ASR：X-ASR-zh-en 480ms（Zipformer2 / sherpa-onnx）',
              ),
              const SizedBox(height: 12),
              const Text(
                '说明：这个 Flutter Demo 用于验证模型效果与交互，'
                '不代表技术报告里的 MNN 引擎性能（Android CPU 解码 251 tok/s 为 MNN 数据）。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text('模型路径：',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(path, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String _buildRoutePrompt(String query) {
    return '<|im_start|>system\n'
        '你是一个意图分类器。只输出一个字母，不要解释，不要输出其他内容。<|im_end|>\n'
        '<|im_start|>user\n'
        '请把下面的句子分类到以下选项之一：\n'
        'A. 退款\n'
        'B. 物流\n'
        'C. 咨询\n'
        'D. 投诉\n'
        'E. 其他\n'
        '句子：$query\n'
        '只输出字母：<|im_end|>\n'
        '<|im_start|>assistant\n';
  }

  String _parseIntent(String raw) {
    const letterMap = <String, String>{
      'A': '退款',
      'B': '物流',
      'C': '咨询',
      'D': '投诉',
      'E': '其他',
    };
    final upper = raw.toUpperCase();
    final match = RegExp(r'(?<![A-Z])([A-E])(?![A-Z])').firstMatch(upper);
    if (match != null) return letterMap[match.group(1)!]!;
    for (final label in _intentLabels) {
      if (raw.contains(label)) return label;
    }
    return '未匹配';
  }

  Future<void> _route() async {
    final ai = _ai;
    if (ai == null || _routing || _busy || _evaluating) return;
    final query = _routeInput.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _routing = true;
      _routeLabel = null;
      _routeRaw = null;
      _routeLatency = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final raw = await ai.generate(_buildRoutePrompt(query));
      stopwatch.stop();
      if (!mounted) return;
      final clean = _clean(raw);
      final label = _parseIntent(clean);
      setState(() {
        _routeLabel = label;
        _routeRaw = clean.isEmpty ? raw.trim() : clean;
        _routeLatency = stopwatch.elapsedMilliseconds;
      });
      if (_autoSmoke) {
        debugPrint('[SMOKE-ROUTE] $query -> $label ($clean)');
      }
    } catch (e) {
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _routeLabel = '路由失败';
        _routeRaw = '$e';
        _routeLatency = stopwatch.elapsedMilliseconds;
      });
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Widget _buildRouting(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '闭集意图路由',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '用同一个 MNN-Pocket 模型，把一句话路由到 5 个标签之一。'
            '这是生成式路由，不是 Dec 指针头；准确率需要用自己的数据验证。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _routeInput,
                  minLines: 1,
                  maxLines: 3,
                  enabled: !_routing && !_busy && !_evaluating,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _route(),
                  decoration: InputDecoration(
                    hintText: '例如：我要退款 / 快递到哪了 / 这个多少钱',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: (_routing || _busy || _evaluating || _transcribing || _asrLoading)
                    ? null
                    : _toggleMic,
                tooltip: _recording ? '停止录音' : '语音输入',
                icon: Icon(_recording ? Icons.stop : Icons.mic),
              ),
            ],
          ),
          _listeningBanner(context),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _routeExamples
                .map(
                  (text) => ActionChip(
                    label: Text(text, style: const TextStyle(fontSize: 12)),
                    onPressed: (_routing || _busy || _evaluating)
                        ? null
                        : () => setState(() => _routeInput.text = text),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_routing || _busy || _evaluating) ? null : _route,
              icon: Icon(_routing ? Icons.hourglass_top : Icons.alt_route),
              label: Text(_routing ? '路由中…' : '路由'),
            ),
          ),
          if (_routing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 6),
          ],
          if (_routeLabel != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '路由结果',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _routeLabel!,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                  if (_routeLatency != null)
                    Text(
                      '${_routeLatency}ms · 本地推理',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (_routeRaw != null && _routeRaw!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text(
                        '原始输出',
                        style: TextStyle(fontSize: 12),
                      ),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            _routeRaw!,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            '标签集合：${_intentLabels.join(' / ')}',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '提示：路由建议低温度（0.2–0.4）和短输出；当前沿用“生成参数”里的设置，可在右上角调整。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleMic() async {
    if (_busy || _evaluating || _tab == 2 || _transcribing) return;
    if (_recording) {
      _recordTimer?.cancel();
      _recordTimer = null;
      final path = await _recorder.stop();
      if (mounted) setState(() => _recording = false);
      if (path != null) await _transcribe(path);
      return;
    }

    final asr = await _ensureAsr();
    if (asr == null) return;
    if (!await _recorder.hasPermission()) {
      _showSnack('需要麦克风权限');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/asr_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() => _recording = true);
      _recordTimer?.cancel();
      _recordTimer = Timer(const Duration(seconds: 15), () {
        if (mounted && _recording) _toggleMic();
      });
    } catch (e) {
      _showSnack('录音失败：$e');
    }
  }

  Future<sherpa_onnx.OnlineRecognizer?> _ensureAsr() async {
    if (_asr != null) return _asr;
    if (_asrLoading) return null;
    setState(() => _asrLoading = true);
    // Let the banner paint before the 586 MB model is loaded.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/asr');
      final int8Encoder = File('${dir.path}/encoder-480ms.int8.onnx');
      final int8Decoder = File('${dir.path}/decoder-480ms.int8.onnx');
      final int8Joiner = File('${dir.path}/joiner-480ms.int8.onnx');
      final fp32Encoder = File('${dir.path}/encoder-480ms.onnx');
      final fp32Decoder = File('${dir.path}/decoder-480ms.onnx');
      final fp32Joiner = File('${dir.path}/joiner-480ms.onnx');
      final tokens = File('${dir.path}/tokens.txt');
      final useInt8 = await int8Encoder.exists() &&
          await int8Decoder.exists() &&
          await int8Joiner.exists();
      final encoder = useInt8 ? int8Encoder : fp32Encoder;
      final decoder = useInt8 ? int8Decoder : fp32Decoder;
      final joiner = useInt8 ? int8Joiner : fp32Joiner;
      if (!await encoder.exists() ||
          !await decoder.exists() ||
          !await joiner.exists() ||
          !await tokens.exists()) {
        _showSnack('ASR 模型未安装：${dir.path}');
        return null;
      }
      sherpa_onnx.initBindings();
      final model = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: encoder.path,
          decoder: decoder.path,
          joiner: joiner.path,
        ),
        tokens: tokens.path,
        numThreads: 4,
        debug: false,
        modelType: 'zipformer2',
      );
      final config = sherpa_onnx.OnlineRecognizerConfig(
        feat: const sherpa_onnx.FeatureConfig(
          sampleRate: 16000,
          featureDim: 80,
        ),
        model: model,
        decodingMethod: 'greedy_search',
        enableEndpoint: false,
      );
      _asr = sherpa_onnx.OnlineRecognizer(config);

      final vadModel = File('${dir.path}/silero_vad.onnx');
      if (await vadModel.exists()) {
        _vad = sherpa_onnx.VoiceActivityDetector(
          config: sherpa_onnx.VadModelConfig(
            sileroVad: sherpa_onnx.SileroVadModelConfig(
              model: vadModel.path,
              threshold: 0.5,
              minSilenceDuration: 0.8,
              minSpeechDuration: 0.3,
              windowSize: 512,
              maxSpeechDuration: 20.0,
            ),
            sampleRate: 16000,
            numThreads: 1,
            debug: false,
          ),
          bufferSizeInSeconds: 60,
        );
      }
      debugPrint(
        '[ASR] model=${useInt8 ? 'int8' : 'fp32'} vad=${_vad != null ? 'on' : 'off'}',
      );
      return _asr;
    } catch (e) {
      _showSnack('ASR 初始化失败：$e');
      return null;
    } finally {
      if (mounted) setState(() => _asrLoading = false);
    }
  }

  Future<void> _transcribe(String path) async {
    final asr = _asr;
    if (asr == null) return;
    setState(() => _transcribing = true);
    final sw = Stopwatch()..start();
    try {
      final wave = sherpa_onnx.readWave(path);
      if (wave.samples.isEmpty) {
        throw Exception('音频为空或格式不支持');
      }

      final segments = <Float32List>[];
      final vad = _vad;
      if (vad != null) {
        vad.reset();
        const window = 512;
        for (var i = 0; i < wave.samples.length; i += window) {
          final end = i + window;
          final chunk = end <= wave.samples.length
              ? wave.samples.sublist(i, end)
              : wave.samples.sublist(i);
          vad.acceptWaveform(chunk);
          while (!vad.isEmpty()) {
            final seg = vad.front();
            if (seg.samples.isNotEmpty) segments.add(seg.samples);
            vad.pop();
          }
        }
        vad.flush();
        while (!vad.isEmpty()) {
          final seg = vad.front();
          if (seg.samples.isNotEmpty) segments.add(seg.samples);
          vad.pop();
        }
      }
      if (segments.isEmpty) {
        segments.add(wave.samples);
      }

      final texts = <String>[];
      const tailPad = 8000; // 0.5 s at 16 kHz, lets the streaming model emit the tail
      for (final segment in segments) {
        final padded = Float32List(segment.length + tailPad)
          ..setAll(0, segment);
        final stream = asr.createStream();
        stream.acceptWaveform(
          samples: padded,
          sampleRate: wave.sampleRate,
        );
        stream.inputFinished();
        while (asr.isReady(stream)) {
          asr.decode(stream);
        }
        final part = asr.getResult(stream).text.trim();
        stream.free();
        if (part.isNotEmpty) texts.add(part);
      }
      final text = texts.join(' ');
      sw.stop();
      debugPrint(
        '[VAD] segments=${segments.length} audio=${(wave.samples.length / wave.sampleRate).toStringAsFixed(1)}s',
      );
      if (!mounted) return;
      if (text.isEmpty) {
        _showSnack('没有识别到文字');
      } else {
        _applyTranscript(text);
        debugPrint(
          '[ASR] $text (${sw.elapsedMilliseconds}ms, ${(wave.samples.length / wave.sampleRate).toStringAsFixed(1)}s)',
        );
      }
    } catch (e) {
      if (mounted) _showSnack('转写失败：$e');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  void _applyTranscript(String text) {
    if (!mounted) return;
    setState(() {
      _recording = false;
      if (_tab == 0) {
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
      } else if (_tab == 1) {
        _routeInput.text = text;
        _routeInput.selection = TextSelection.collapsed(offset: text.length);
      }
    });
    _showSnack('已转写，确认后发送');
  }

  Widget _listeningBanner(BuildContext context) {
    if (!_asrLoading && !_recording && !_transcribing) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final label = _asrLoading
        ? '正在加载 ASR 模型（X-ASR 480ms，约 586MB）…'
        : _recording
            ? '正在录音…再次点击麦克风停止'
            : '正在转写…';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _recording ? scheme.errorContainer : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            _recording ? Icons.fiber_manual_record : Icons.graphic_eq,
            size: 18,
            color: _recording
                ? scheme.onErrorContainer
                : scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: _recording
                    ? scheme.onErrorContainer
                    : scheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_EvalCase> _parseEvalCases() {
    final cases = <_EvalCase>[];
    for (final line in _evalInput.text.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      String? query;
      String? label;
      final tab = text.lastIndexOf('\t');
      if (tab > 0) {
        query = text.substring(0, tab).trim();
        label = text.substring(tab + 1).trim();
      } else {
        final comma = text.lastIndexOf(RegExp(r'[,，]'));
        if (comma > 0) {
          query = text.substring(0, comma).trim();
          label = text.substring(comma + 1).trim();
        }
      }
      if (query == null || label == null) continue;
      if (query.isEmpty || !_intentLabels.contains(label)) continue;
      cases.add(_EvalCase(query, label));
    }
    return cases;
  }

  Future<void> _runEval() async {
    final ai = _ai;
    if (ai == null || _evaluating || _busy || _routing) return;
    final cases = _parseEvalCases();
    if (cases.isEmpty) {
      _showSnack('评测集为空：每行用 query<TAB>标签');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _tab = 2;
      _evaluating = true;
      _evalResults.clear();
    });
    final totalSw = Stopwatch()..start();
    for (final c in cases) {
      if (!mounted || !_evaluating) break;
      final sw = Stopwatch()..start();
      try {
        final raw = await ai.generate(_buildRoutePrompt(c.query));
        sw.stop();
        final clean = _clean(raw);
        final predicted = _parseIntent(clean);
        if (!mounted) return;
        setState(() {
          _evalResults.add(
            _EvalResult(c.query, c.expected, predicted, sw.elapsedMilliseconds, clean),
          );
        });
        final shortRaw =
            clean.length > 60 ? '${clean.substring(0, 60)}…' : clean;
        if (_autoEval) {
          debugPrint(
            '[EVAL] ${c.query}\t${c.expected}\t$predicted\t${sw.elapsedMilliseconds}ms\traw="$shortRaw"',
          );
        }
      } catch (e) {
        sw.stop();
        if (!mounted) return;
        setState(() {
          _evalResults.add(
            _EvalResult(c.query, c.expected, '错误', sw.elapsedMilliseconds, '$e'),
          );
        });
        if (_autoEval) {
          debugPrint('[EVAL] ${c.query}\t${c.expected}\tERROR\t${sw.elapsedMilliseconds}ms');
        }
      }
    }
    if (!mounted) return;
    setState(() => _evaluating = false);
    debugPrint(
      '[EVAL] done ${_evalResults.length}/${cases.length} in ${totalSw.elapsedMilliseconds}ms',
    );
  }

  void _stopEval() {
    setState(() => _evaluating = false);
  }

  int get _evalCorrect => _evalResults.where((r) => r.correct).length;

  double get _evalAccuracy =>
      _evalResults.isEmpty ? 0 : _evalCorrect / _evalResults.length;

  double _precision(String label) {
    final predicted = _evalResults.where((r) => r.predicted == label).length;
    if (predicted == 0) return 0;
    final correct = _evalResults
        .where((r) => r.expected == label && r.predicted == label)
        .length;
    return correct / predicted;
  }

  double _recall(String label) {
    final support = _evalResults.where((r) => r.expected == label).length;
    if (support == 0) return 0;
    final correct = _evalResults
        .where((r) => r.expected == label && r.predicted == label)
        .length;
    return correct / support;
  }

  double _f1(String label) {
    final p = _precision(label);
    final r = _recall(label);
    return (p + r) == 0 ? 0 : 2 * p * r / (p + r);
  }

  String _pct(double value) => '${(value * 100).toStringAsFixed(0)}%';

  Widget _evalPerLabelTable(ColorScheme scheme) {
    Widget cell(String text, {bool header = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: header ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      );
    }

    return Table(
      border: TableBorder.all(color: scheme.outlineVariant, width: 0.6),
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(0.9),
        2: FlexColumnWidth(0.9),
        3: FlexColumnWidth(1.0),
        4: FlexColumnWidth(1.0),
        5: FlexColumnWidth(0.9),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
          children: [
            cell('标签', header: true),
            cell('支持', header: true),
            cell('预测', header: true),
            cell('精确率', header: true),
            cell('召回率', header: true),
            cell('F1', header: true),
          ],
        ),
        for (final label in _intentLabels)
          TableRow(
            children: [
              cell(label, header: true),
              cell('${_evalResults.where((r) => r.expected == label).length}'),
              cell('${_evalResults.where((r) => r.predicted == label).length}'),
              cell(_pct(_precision(label))),
              cell(_pct(_recall(label))),
              cell(_pct(_f1(label))),
            ],
          ),
      ],
    );
  }

  Widget _evalConfusionTable(ColorScheme scheme) {
    final predictedColumns = <String>[..._intentLabels, '未匹配'];
    Widget cell(String text, {bool header = false, bool highlight = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: header ? FontWeight.w700 : FontWeight.w400,
            color: highlight ? scheme.primary : null,
          ),
        ),
      );
    }

    String predictedOf(_EvalResult r) =>
        _intentLabels.contains(r.predicted) ? r.predicted : '未匹配';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.all(color: scheme.outlineVariant, width: 0.6),
        defaultColumnWidth: const FixedColumnWidth(44),
        columnWidths: const {0: FixedColumnWidth(74)},
        children: [
          TableRow(
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
            children: [
              cell('真实 \\ 预测', header: true),
              for (final p in predictedColumns) cell(p, header: true),
            ],
          ),
          for (final e in _intentLabels)
            TableRow(
              children: [
                cell(e, header: true),
                for (final p in predictedColumns)
                  cell(
                    '${_evalResults.where((r) => r.expected == e && predictedOf(r) == p).length}',
                    highlight: e == p,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildEval(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _evalResults.length;
    final expectedTotal = _parseEvalCases().length;
    final correct = _evalCorrect;
    final accuracy = _evalAccuracy;
    final avgMs = _evalResults.isEmpty
        ? 0
        : _evalResults.fold<int>(0, (a, b) => a + b.ms) ~/ _evalResults.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '路由批量评测',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '每行一条：query<TAB>标签。默认 25 条，可自行替换。'
            '评测使用当前生成参数（建议温度 0.2–0.4）。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: _evalResults.isEmpty,
            title: Text(
              '评测集（$expectedTotal 条）',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            children: [
              TextField(
                controller: _evalInput,
                minLines: 10,
                maxLines: 18,
                enabled: !_evaluating,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _evaluating ? null : _runEval,
                  icon: Icon(
                    _evaluating ? Icons.hourglass_top : Icons.play_arrow,
                  ),
                  label: Text(_evaluating ? '评测中…' : '开始评测'),
                ),
              ),
              if (_evaluating) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _stopEval,
                  child: const Text('停止'),
                ),
              ],
            ],
          ),
          if (total > 0 || _evaluating) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: expectedTotal == 0 ? null : total / expectedTotal,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$total / $expectedTotal',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (total > 0) ...[
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '准确率',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${(accuracy * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$correct / $total 正确',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '平均 ${avgMs}ms/条',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '分类指标',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            _evalPerLabelTable(scheme),
            const SizedBox(height: 14),
            const Text(
              '混淆矩阵（行=真实，列=预测）',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            _evalConfusionTable(scheme),
            if (_evalResults.any((r) => !r.correct)) ...[
              const SizedBox(height: 14),
              const Text(
                '错例',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final r in _evalResults.where((r) => !r.correct).take(12))
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.query,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '期望 ${r.expected} · 预测 ${r.predicted} · ${r.ms}ms',
                        style: TextStyle(fontSize: 11.5, color: scheme.error),
                      ),
                      if (r.raw.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          '原始：${r.raw.length > 80 ? '${r.raw.substring(0, 80)}…' : r.raw}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_evalResults.where((r) => !r.correct).length > 12)
                Text(
                  '还有 ${_evalResults.where((r) => !r.correct).length - 12} 条未显示',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _ai?.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
    _vad?.free();
    _asr?.free();
    _input.dispose();
    _routeInput.dispose();
    _evalInput.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _phase == ModelPhase.ready && _ai != null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('MNN-Pocket 0.3B',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text(
              !ready
                  ? '端侧小模型实验'
                  : _tab == 0
                      ? '端侧 · GGUF Q4_1 · llama.cpp'
                      : _tab == 1
                          ? '闭集路由 · 5 个标签'
                          : '路由批量评测',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openInfo,
            tooltip: '关于',
            icon: const Icon(Icons.info_outline),
          ),
          if (ready && _tab == 0)
            IconButton(
              onPressed: (_busy || _evaluating) ? null : _openSettings,
              tooltip: '生成参数',
              icon: const Icon(Icons.tune),
            ),
          if (ready && _tab == 0)
            IconButton(
              onPressed: (_busy || _evaluating) ? null : _clear,
              tooltip: '清空对话',
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: !ready
            ? _buildSetup(context)
            : _tab == 0
                ? _buildChat(context)
                : _tab == 1
                    ? _buildRouting(context)
                    : _buildEval(context),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route),
            selectedIcon: Icon(Icons.alt_route),
            label: '意图路由',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: '评测',
          ),
        ],
      ),
    );
  }

  Widget _buildChat(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[index];
              final isLast = index == _messages.length - 1;
              return _Bubble(
                message: message,
                isLast: isLast,
                busy: _busy,
              );
            },
          ),
        ),
        if (_messages.length <= 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _suggestions
                    .map(
                      (text) => ActionChip(
                        label: Text(text, style: const TextStyle(fontSize: 12)),
                        onPressed: (_busy || _evaluating)
                            ? null
                            : () => _send(text),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _listeningBanner(context),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            8 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !_busy && !_evaluating,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _busy ? '正在本地推理…' : '问点什么…',
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: (_busy || _evaluating || _transcribing || _asrLoading) ? null : _toggleMic,
                tooltip: _recording ? '停止录音' : '语音输入',
                icon: Icon(
                  _recording ? Icons.stop_circle_outlined : Icons.mic_none,
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                onPressed: (_busy || _evaluating) ? null : () => _send(),
                tooltip: '发送',
                icon: Icon(_busy ? Icons.hourglass_top : Icons.arrow_upward),
                style: IconButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSetup(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final downloading = _phase == ModelPhase.downloading;
    final loading = _phase == ModelPhase.loading;
    final busy = downloading || loading;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(26),
              ),
              child: Icon(Icons.memory, size: 42, color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'MNN-Pocket 0.3B',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              '302M 参数 · Q4_1 GGUF · 183 MB',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _phase == ModelPhase.error
                          ? Icons.error_outline
                          : busy
                              ? Icons.downloading
                              : Icons.offline_bolt_outlined,
                      color: _phase == ModelPhase.error
                          ? scheme.error
                          : scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (busy) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: downloading ? _progress : null,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    downloading
                        ? '首次运行会从 ModelScope 下载约 183 MB，之后完全离线。'
                        : '正在把权重加载到内存，请稍候…',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy ? null : _initModel,
                    icon: Icon(busy ? Icons.hourglass_top : Icons.play_arrow),
                    label: Text(
                      downloading
                          ? '下载中…'
                          : loading
                              ? '加载中…'
                              : _phase == ModelPhase.error
                                  ? '重试'
                                  : '下载并加载模型',
                    ),
                  ),
                ),
                if (_phase == ModelPhase.error && _error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      _error!,
                      style: TextStyle(fontSize: 11, color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '这个 Demo 用 llama.cpp 跑 GGUF，用于验证模型效果；'
            'MNN 引擎的端侧性能需要另行集成，二者不要混为一谈。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          if (_modelPath != null) ...[
            Text('模型路径（也可用 adb 手动放入）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                )),
            const SizedBox(height: 4),
            SelectableText(
              _modelPath!,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _bootstrap,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('我放好文件了，重新检测'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.isLast,
    required this.busy,
  });

  final _Message message;
  final bool isLast;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final waiting = !isUser && message.text.isEmpty && isLast && busy;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.84,
        ),
        margin: EdgeInsets.only(
          left: isUser ? 40 : 0,
          right: isUser ? 0 : 40,
          bottom: 10,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? scheme.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 5),
            bottomRight: Radius.circular(isUser ? 5 : 18),
          ),
          border: isUser
              ? null
              : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: isUser
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Text(
                'MNN-Pocket',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  letterSpacing: 0.4,
                ),
              ),
            if (!isUser) const SizedBox(height: 3),
            if (waiting)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在本地推理…',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              SelectableText(
                message.text,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.55,
                  color: isUser ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
            if (message.meta != null) ...[
              const SizedBox(height: 5),
              Text(
                message.meta!,
                style: TextStyle(
                  fontSize: 10.5,
                  color: isUser
                      ? scheme.onPrimary.withValues(alpha: 0.75)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
