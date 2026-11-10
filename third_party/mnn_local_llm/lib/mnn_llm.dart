import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'mnn_local_llm_platform_interface.dart';
import 'model_store.dart';
import 'models.dart';

typedef MnnProgressCallback = void Function(String status);
typedef MnnRetryCallback = Future<bool> Function(String message);

/// High-level MNN chat API: model download, native load, generation, cancel.
class MnnLlm {
  final MnnModel model;
  final MnnGenerationSettings settings;
  final MnnProgressCallback? onProgress;
  final MnnRetryCallback? onRetryRequired;
  final Directory? modelRoot;
  final http.Client Function()? clientFactory;

  bool _ready = false;
  final _history = <({String role, String text})>[];
  String? _systemPrompt;
  Directory? _modelDir;

  MnnGenerationResult? lastResult;

  MnnLlm({
    required this.model,
    this.settings = const MnnGenerationSettings(),
    this.onProgress,
    this.onRetryRequired,
    this.modelRoot,
    this.clientFactory,
  });

  void _report(String status) => onProgress?.call(status);

  Future<void> initialize() async {
    final root = modelRoot ?? await getApplicationDocumentsDirectory();
    final modelDir = Directory('${root.path}/${model.dirName}');
    await modelDir.create(recursive: true);
    _modelDir = modelDir;

    final store = MnnModelStore(
      model: model,
      modelDir: modelDir,
      onProgress: _report,
      onRetryRequired: onRetryRequired ?? (_) async => false,
      clientFactory: clientFactory,
    );

    await store.ensureModel();
    var loaded =
        await MnnLocalLlmPlatform.instance.loadModel(modelDir.path) == true;

    if (!loaded) {
      _report('Model load failed, re-downloading...');
      if (await modelDir.exists()) await modelDir.delete(recursive: true);
      await store.ensureModel();
      loaded =
          await MnnLocalLlmPlatform.instance.loadModel(modelDir.path) == true;
      if (!loaded) throw Exception('Failed to load MNN model');
    }

    _ready = true;
    _report('Ready');
  }

  Future<String> chat(String message, {String? systemPrompt}) async {
    if (!_ready) throw StateError('Call initialize() first');
    _systemPrompt = systemPrompt ?? _systemPrompt;

    _history.add((role: 'user', text: message));
    final prompt = model.chatTemplate.format(
      systemPrompt: _systemPrompt,
      messages: _history,
    );

    final reply = (await generate(prompt)).trim();
    _history.add((role: 'assistant', text: reply));
    return reply;
  }

  Future<String> generate(String prompt) async {
    if (!_ready) throw StateError('Call initialize() first');

    final result = await MnnLocalLlmPlatform.instance
        .generate(prompt, settings.toMap());
    if (result == null) {
      throw Exception('MNN generation failed');
    }

    final text = result['text'] as String? ?? '';
    if (text.isEmpty) {
      throw Exception('MNN generation failed');
    }

    final rawStats = result['stats'];
    final stats = rawStats is Map ? rawStats : const <dynamic, dynamic>{};
    lastResult = MnnGenerationResult.fromChannel(text, stats);
    return text;
  }

  Future<void> cancelGenerate() async {
    if (!_ready) return;
    await MnnLocalLlmPlatform.instance.cancelGenerate();
  }

  void clearHistory() {
    _history.clear();
  }

  Future<void> dispose() async {
    await MnnLocalLlmPlatform.instance.releaseModel();
    _ready = false;
    _modelDir = null;
  }

  String? get modelDirectory => _modelDir?.path;

  @visibleForTesting
  bool get isReady => _ready;
}
