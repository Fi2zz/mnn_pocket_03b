import 'package:flutter_test/flutter_test.dart';
import 'package:onenm_local_llm/onenm_local_llm.dart';

void main() {
  test('MNN-Pocket ChatML template renders the expected prompt', () {
    const template = ChatTemplate(
      system: '<|im_start|>system\n{text}<|im_end|>\n',
      user: '<|im_start|>user\n{text}<|im_end|>\n',
      assistant: '<|im_start|>assistant\n{text}<|im_end|>\n',
      systemDefault: 'sys',
    );

    final prompt = template.format(
      messages: [(role: 'user', text: 'hello')],
    );

    expect(
      prompt,
      '<|im_start|>system\nsys<|im_end|>\n'
      '<|im_start|>user\nhello<|im_end|>\n'
      '<|im_start|>assistant\n',
    );
  });
}
