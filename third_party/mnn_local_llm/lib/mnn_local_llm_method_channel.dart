import 'package:flutter/services.dart';

import 'mnn_local_llm_platform_interface.dart';

class MethodChannelMnnLocalLlm extends MnnLocalLlmPlatform {
  final MethodChannel methodChannel = const MethodChannel('mnn_local_llm');

  @override
  Future<bool?> loadModel(String modelDir) {
    return methodChannel.invokeMethod<bool>(
      'loadModel',
      {'modelDir': modelDir},
    );
  }

  @override
  Future<Map<String, dynamic>?> generate(
    String prompt,
    Map<String, dynamic> settings,
  ) async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'generate',
      {'prompt': prompt, ...settings},
    );
    return result;
  }

  @override
  Future<void> cancelGenerate() async {
    await methodChannel.invokeMethod('cancelGenerate');
  }

  @override
  Future<void> releaseModel() async {
    await methodChannel.invokeMethod('releaseModel');
  }
}
