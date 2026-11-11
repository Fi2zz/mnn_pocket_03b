import 'dart:async';
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
    final modelDir = Directory('${root.path}/models/${model.dirName}');
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
    var loaded = await _loadModel(modelDir.path);

    if (!loaded) {
      _report('Model load failed, re-downloading...');
      if (await modelDir.exists()) await modelDir.delete(recursive: true);
      await store.ensureModel();
      loaded = await _loadModel(modelDir.path);
      if (!loaded) throw Exception('Failed to load MNN model');
    }

    _ready = true;
    _report('Ready');
  }

  Future<bool> _loadModel(String path) async {
    try {
      return await MnnLocalLlmPlatform.instance.loadModel(path) == true;
    } catch (_) {
      return false;
    }
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

  /// Like [chat], but forwards each native token chunk through [onToken].
  Future<String> chatStream(
    String message, {
    String? systemPrompt,
    void Function(String chunk)? onToken,
  }) async {
    if (!_ready) throw StateError('Call initialize() first');
    _systemPrompt = systemPrompt ?? _systemPrompt;

    _history.add((role: 'user', text: message));
    final prompt = model.chatTemplate.format(
      systemPrompt: _systemPrompt,
      messages: _history,
    );

    final buffer = StringBuffer();
    final completer = Completer<void>();
    String? error;
    var cancelled = false;

    late final StreamSubscription<MnnStreamEvent> subscription;
    subscription = MnnLocalLlmPlatform.instance.stream.listen(
      (event) {
        switch (event.type) {
          case MnnStreamEventType.token:
            buffer.write(event.text);
            onToken?.call(event.text);
            break;
          case MnnStreamEventType.done:
            lastResult = MnnGenerationResult.fromChannel(
              buffer.toString(),
              event.stats,
            );
            cancelled = event.cancelled;
            if (!completer.isCompleted) completer.complete();
            break;
          case MnnStreamEventType.error:
            error = event.message ?? 'MNN stream error';
            if (!completer.isCompleted) completer.complete();
            break;
        }
      },
      onError: (Object e) {
        error = '$e';
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) {
          error ??= 'MNN stream closed';
          completer.complete();
        }
      },
    );

    try {
      final started = await MnnLocalLlmPlatform.instance.startGenerate(
        prompt,
        settings.toMap(),
      );
      if (started != true) {
        throw Exception('Failed to start MNN generation');
      }
      await completer.future;
    } finally {
      await subscription.cancel();
    }

    if (error != null) throw Exception(error);
    final reply = buffer.toString().trim();
    if (reply.isEmpty && !cancelled) {
      throw Exception('MNN generation failed');
    }
    _history.add((role: 'assistant', text: reply));
    return reply;
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
