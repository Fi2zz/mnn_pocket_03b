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

  test('stream token event parses text', () {
    final event = MnnStreamEvent.fromChannel({
      'type': 'token',
      'text': '你',
    });
    expect(event.type, MnnStreamEventType.token);
    expect(event.text, '你');
  });

  test('stream done event parses stats and cancelled flag', () {
    final event = MnnStreamEvent.fromChannel({
      'type': 'done',
      'cancelled': true,
      'stats': {
        'promptTokens': 10,
        'decodeTokens': 20,
        'prefillUs': 100000,
        'decodeUs': 400000,
      },
    });
    expect(event.type, MnnStreamEventType.done);
    expect(event.cancelled, isTrue);
    expect(event.stats['decodeTokens'], 20);
  });

  test('stream error event parses message', () {
    final event = MnnStreamEvent.fromChannel({
      'type': 'error',
      'message': 'boom',
    });
    expect(event.type, MnnStreamEventType.error);
    expect(event.message, 'boom');
  });
}
