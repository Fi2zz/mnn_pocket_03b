import 'package:mnn_local_llm/mnn_local_llm.dart';

/// First metrics line shown under each assistant reply.
String formatMetaLine({
  String? device,
  required double seconds,
  required int chars,
  MnnGenerationResult? result,
  bool stopped = false,
}) {
  final parts = <String>[
    if (device != null && device.isNotEmpty) device,
    '${seconds.toStringAsFixed(2)}s',
    '$chars 字',
    if (result != null && result.decodeTokens > 0 && result.decodeMs > 0)
      '${result.decodeTokensPerSecond.round()} tok/s',
    if (stopped) '已停止',
  ];
  return parts.join(' · ');
}

/// Second metrics line with the sampling parameters actually used.
String formatSettingsLine(MnnGenerationSettings settings) {
  return 'T=${settings.temperature.toStringAsFixed(2)}'
      ' · top_p=${settings.topP.toStringAsFixed(2)}'
      ' · top_k=${settings.topK}'
      ' · max=${settings.maxTokens}'
      ' · repeat=${settings.repeatPenalty.toStringAsFixed(2)}';
}
