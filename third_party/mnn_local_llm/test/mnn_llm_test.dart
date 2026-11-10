import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnn_local_llm/mnn_local_llm.dart';

const _model = MnnModel(
  id: 'test',
  name: 'Test',
  dirName: 'test-model',
  files: [
    MnnModelFile(name: 'a.json', url: 'http://test/a.json', bytes: 4),
    MnnModelFile(name: 'w.weight', url: 'http://test/w.weight', bytes: 8),
  ],
  minRamGB: 1,
  context: 2048,
  chatTemplate: MnnChatTemplate(
    system: '<|im_start|>system\n{text}<|im_end|>\n',
    user: '<|im_start|>user\n{text}<|im_end|>\n',
    assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
  ),
);

class _FakePlatform extends MnnLocalLlmPlatform {
  String? loadedDir;
  String? lastPrompt;
  Map<String, dynamic>? lastSettings;
  bool cancelled = false;
  bool released = false;
  bool returnNull = false;
  bool throwOnFirstLoad = false;
  int loadCalls = 0;

  @override
  Future<bool?> loadModel(String dir) async {
    loadCalls++;
    if (throwOnFirstLoad && loadCalls == 1) {
      throw Exception('native load failed');
    }
    loadedDir = dir;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> generate(
      String prompt, Map<String, dynamic> settings) async {
    if (returnNull) return null;
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

void main() {
  late Directory tmp;
  late _FakePlatform platform;
  late MnnLlm ai;
  late List<String> progress;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mnn_llm_test');
    final modelDir = Directory('${tmp.path}/models/${_model.dirName}');
    await modelDir.create(recursive: true);
    await File('${modelDir.path}/a.json').writeAsBytes(List.filled(4, 1));
    await File('${modelDir.path}/w.weight').writeAsBytes(List.filled(8, 1));

    platform = _FakePlatform();
    MnnLocalLlmPlatform.instance = platform;
    progress = <String>[];
    ai = MnnLlm(
      model: _model,
      modelRoot: tmp,
      onProgress: progress.add,
      onRetryRequired: (_) async => false,
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('initialize loads the model directory and reports Ready', () async {
    await ai.initialize();
    expect(platform.loadedDir, '${tmp.path}/models/${_model.dirName}');
    expect(progress, contains('Ready'));
  });

  test('chat sends the exact prompt and records stats', () async {
    await ai.initialize();
    final reply = await ai.chat('hi', systemPrompt: 'sys');

    expect(reply, 'hello');
    expect(platform.lastPrompt, '<|im_start|>system\nsys<|im_end|>\n'
        '<|im_start|>user\nhi<|im_end|>\n'
        '<|im_start|>assistant\n');
    expect(platform.lastSettings, {
      'temperature': 0.4,
      'topK': 20,
      'topP': 0.8,
      'maxTokens': 768,
      'repeatPenalty': 1.1,
    });
    expect(ai.lastResult!.decodeTokensPerSecond, 50.0);
  });

  test('chat keeps assistant history for the next prompt', () async {
    await ai.initialize();
    await ai.chat('hi', systemPrompt: 'sys');
    await ai.chat('again', systemPrompt: 'sys');

    expect(platform.lastPrompt, contains('hi'));
    expect(platform.lastPrompt, contains('hello'));
    expect(platform.lastPrompt, contains('again'));
  });

  test('cancel and dispose delegate to the platform', () async {
    await ai.initialize();
    await ai.cancelGenerate();
    await ai.dispose();

    expect(platform.cancelled, isTrue);
    expect(platform.released, isTrue);
  });

  test('generate throws when the platform returns null', () async {
    await ai.initialize();
    platform.returnNull = true;

    await expectLater(
      ai.generate('hi'),
      throwsA(isA<Exception>()),
    );
  });

  test('load exception re-downloads and retries once', () async {
    platform.throwOnFirstLoad = true;
    final client = MockClient((request) async {
      final length = request.url.path.endsWith('a.json') ? 4 : 8;
      return http.Response.bytes(List.filled(length, 1), 200);
    });
    ai = MnnLlm(
      model: _model,
      modelRoot: tmp,
      onProgress: (_) {},
      onRetryRequired: (_) async => false,
      clientFactory: () => client,
    );

    await ai.initialize();

    expect(platform.loadCalls, 2);
    expect(
      await File('${tmp.path}/models/${_model.dirName}/a.json').exists(),
      isTrue,
    );
  });
}
