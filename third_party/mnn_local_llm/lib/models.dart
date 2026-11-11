/// Chat template used to format multi-turn conversations.
///
/// Each string must contain `{text}`. `format` renders the system prompt,
/// every user/assistant message, and finally the assistant prefix so the
/// model continues the reply.
class MnnChatTemplate {
  final String system;
  final String user;
  final String assistant;
  final String systemDefault;

  const MnnChatTemplate({
    required this.system,
    required this.user,
    required this.assistant,
    this.systemDefault = 'You are a helpful assistant.',
  });

  String format({
    String? systemPrompt,
    required List<({String role, String text})> messages,
  }) {
    final buf = StringBuffer();
    buf.write(system.replaceAll('{text}', systemPrompt ?? systemDefault));
    for (final msg in messages) {
      final template = msg.role == 'user' ? user : assistant;
      buf.write(template.replaceAll('{text}', msg.text));
    }
    buf.write(assistant.split('{text}').first);
    return buf.toString();
  }
}

/// One file in an MNN model directory.
class MnnModelFile {
  final String name;
  final String url;
  final int bytes;

  const MnnModelFile({
    required this.name,
    required this.url,
    required this.bytes,
  });
}

/// Metadata for an MNN model directory.
class MnnModel {
  final String id;
  final String name;
  final String dirName;
  final List<MnnModelFile> files;
  final int minRamGB;

  /// Informational context length. MNN manages KV growth dynamically.
  final int context;
  final MnnChatTemplate chatTemplate;

  const MnnModel({
    required this.id,
    required this.name,
    required this.dirName,
    required this.files,
    required this.minRamGB,
    required this.context,
    required this.chatTemplate,
  });

  int get totalBytes => files.fold(0, (sum, file) => sum + file.bytes);
}

/// Sampling and generation parameters sent over the method channel.
class MnnGenerationSettings {
  final double temperature;
  final int topK;
  final double topP;
  final int maxTokens;
  final double repeatPenalty;

  const MnnGenerationSettings({
    this.temperature = 0.4,
    this.topK = 20,
    this.topP = 0.8,
    this.maxTokens = 768,
    this.repeatPenalty = 1.1,
  });

  Map<String, dynamic> toMap() => {
        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'maxTokens': maxTokens,
        'repeatPenalty': repeatPenalty,
      };
}

/// Text plus timing data returned by one generation.
class MnnGenerationResult {
  final String text;
  final int promptTokens;
  final int decodeTokens;

  /// Prefill and decode timings in milliseconds.
  final double prefillMs;
  final double decodeMs;

  const MnnGenerationResult({
    required this.text,
    required this.promptTokens,
    required this.decodeTokens,
    required this.prefillMs,
    required this.decodeMs,
  });

  factory MnnGenerationResult.fromChannel(
    String text,
    Map<dynamic, dynamic> stats,
  ) {
    int intOf(String key) => (stats[key] as num?)?.toInt() ?? 0;
    return MnnGenerationResult(
      text: text,
      promptTokens: intOf('promptTokens'),
      decodeTokens: intOf('decodeTokens'),
      prefillMs: intOf('prefillUs') / 1000.0,
      decodeMs: intOf('decodeUs') / 1000.0,
    );
  }

  double get prefillTokensPerSecond =>
      prefillMs > 0 ? promptTokens / prefillMs * 1000 : 0;

  double get decodeTokensPerSecond =>
      decodeMs > 0 ? decodeTokens / decodeMs * 1000 : 0;
}

enum MnnStreamEventType { token, done, error }

/// One event from the native streaming generation channel.
class MnnStreamEvent {
  final MnnStreamEventType type;
  final String text;
  final String? message;
  final Map<String, dynamic> stats;
  final bool cancelled;

  const MnnStreamEvent._({
    required this.type,
    this.text = '',
    this.message,
    this.stats = const {},
    this.cancelled = false,
  });

  const MnnStreamEvent.token(String text)
      : this._(type: MnnStreamEventType.token, text: text);

  const MnnStreamEvent.done({
    Map<String, dynamic> stats = const {},
    bool cancelled = false,
  }) : this._(
          type: MnnStreamEventType.done,
          stats: stats,
          cancelled: cancelled,
        );

  const MnnStreamEvent.error(String message)
      : this._(type: MnnStreamEventType.error, message: message);

  factory MnnStreamEvent.fromChannel(Map<dynamic, dynamic> event) {
    switch (event['type']) {
      case 'token':
        return MnnStreamEvent.token(event['text'] as String? ?? '');
      case 'done':
        final rawStats = event['stats'];
        return MnnStreamEvent.done(
          stats: rawStats is Map
              ? Map<String, dynamic>.from(rawStats)
              : const <String, dynamic>{},
          cancelled: event['cancelled'] as bool? ?? false,
        );
      case 'error':
        return MnnStreamEvent.error(
          event['message'] as String? ?? 'MNN stream error',
        );
      default:
        return MnnStreamEvent.error(
          'Unknown MNN stream event: ${event['type']}',
        );
    }
  }
}
