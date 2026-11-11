import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mnn_local_llm_method_channel.dart';
import 'models.dart';

/// Platform-agnostic interface for the MNN inference backend.
abstract class MnnLocalLlmPlatform extends PlatformInterface {
  MnnLocalLlmPlatform() : super(token: _token);

  static final Object _token = Object();

  static MnnLocalLlmPlatform _instance = MethodChannelMnnLocalLlm();

  static MnnLocalLlmPlatform get instance => _instance;

  static set instance(MnnLocalLlmPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool?> loadModel(String modelDir) {
    throw UnimplementedError('loadModel() has not been implemented.');
  }

  Future<Map<String, dynamic>?> generate(
    String prompt,
    Map<String, dynamic> settings,
  ) {
    throw UnimplementedError('generate() has not been implemented.');
  }

  Stream<MnnStreamEvent> get stream {
    throw UnimplementedError('stream has not been implemented.');
  }

  Future<bool?> startGenerate(
    String prompt,
    Map<String, dynamic> settings,
  ) {
    throw UnimplementedError('startGenerate() has not been implemented.');
  }

  Future<void> cancelGenerate() {
    throw UnimplementedError('cancelGenerate() has not been implemented.');
  }

  Future<void> releaseModel() {
    throw UnimplementedError('releaseModel() has not been implemented.');
  }
}
