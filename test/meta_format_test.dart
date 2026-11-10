import 'package:flutter_test/flutter_test.dart';
import 'package:mnn/meta_format.dart';
import 'package:mnn_local_llm/mnn_local_llm.dart';

void main() {
  test('meta without stats omits tok/s', () {
    expect(
      formatMetaLine(device: 'SM6435 · 7.2GB', seconds: 6.5, chars: 310),
      'SM6435 · 7.2GB · 6.50s · 310 字',
    );
  });

  test('meta with stats appends rounded tok/s', () {
    final r = MnnGenerationResult.fromChannel('x', {
      'promptTokens': 55,
      'decodeTokens': 100,
      'prefillUs': 500000,
      'decodeUs': 2000000,
    });
    expect(
      formatMetaLine(device: 'SM6435', seconds: 6.5, chars: 310, result: r),
      'SM6435 · 6.50s · 310 字 · 50 tok/s',
    );
  });

  test('stopped suffix is preserved', () {
    expect(
      formatMetaLine(seconds: 1.0, chars: 5, stopped: true),
      '1.00s · 5 字 · 已停止',
    );
  });

  test('settings line matches current UI format', () {
    expect(
      formatSettingsLine(const MnnGenerationSettings()),
      'T=0.40 · top_p=0.80 · top_k=20 · max=768 · repeat=1.10',
    );
  });
}
