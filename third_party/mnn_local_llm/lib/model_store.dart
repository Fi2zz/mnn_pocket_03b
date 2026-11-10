import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Small files must match exactly; weight files tolerate up to 5% loss so a
/// slightly different quantization upload does not force a re-download.
bool isModelFileValid(MnnModelFile file, int actualBytes) {
  final minBytes =
      file.name.endsWith('.weight') ? (file.bytes * 0.95).floor() : file.bytes;
  return actualBytes >= minBytes;
}

double modelProgress(int receivedBytes, int totalBytes) {
  if (totalBytes <= 0) return 0;
  return receivedBytes / totalBytes;
}

String modelDownloadStatus(
  MnnModel model,
  int receivedBytes,
  int totalBytes,
) {
  const mib = 1024.0 * 1024.0;
  final pct = modelProgress(receivedBytes, totalBytes) * 100;
  return 'Downloading ${model.name}...\n'
      '${(receivedBytes / mib).toStringAsFixed(1)} / '
      '${(totalBytes / mib).toStringAsFixed(1)} MB '
      '(${pct.toStringAsFixed(1)}%)';
}

Future<bool> isModelComplete(Directory dir, MnnModel model) async {
  for (final file in model.files) {
    final local = File('${dir.path}/${file.name}');
    if (!await local.exists()) return false;
    if (!isModelFileValid(file, await local.length())) return false;
  }
  return true;
}

/// Owns the model directory on disk and downloads any missing/corrupt files.
class MnnModelStore {
  final MnnModel model;
  final Directory modelDir;
  final void Function(String status) onProgress;
  final Future<bool> Function(String message) onRetryRequired;
  final http.Client Function() clientFactory;
  final Duration retryDelay;

  MnnModelStore({
    required this.model,
    required this.modelDir,
    required this.onProgress,
    required this.onRetryRequired,
    http.Client Function()? clientFactory,
    this.retryDelay = const Duration(seconds: 2),
  }) : clientFactory = clientFactory ?? http.Client.new;

  Future<List<MnnModelFile>> missingFiles() async {
    final missing = <MnnModelFile>[];
    for (final file in model.files) {
      final local = File('${modelDir.path}/${file.name}');
      final valid = await local.exists() &&
          isModelFileValid(file, await local.length());
      if (!valid) missing.add(file);
    }
    return missing;
  }

  Future<void> ensureModel() async {
    await modelDir.create(recursive: true);

    if (await isModelComplete(modelDir, model)) {
      onProgress(
        'Model found (${(model.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
      return;
    }

    final missing = await missingFiles();
    var completedBytes = model.totalBytes -
        missing.fold<int>(0, (sum, file) => sum + file.bytes);

    for (final file in missing) {
      await _downloadFile(file, completedBytes);
      completedBytes += file.bytes;
    }

    if (!await isModelComplete(modelDir, model)) {
      throw Exception('Model files are incomplete after download');
    }
    onProgress('Download complete');
  }

  Future<void> _downloadFile(MnnModelFile file, int baseBytes) async {
    final target = File('${modelDir.path}/${file.name}');
    final part = File('${target.path}.part');
    var attempt = 0;

    while (true) {
      attempt++;
      http.Client? client;
      IOSink? sink;
      try {
        client = clientFactory();
        final request = http.Request('GET', Uri.parse(file.url));
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        if (await part.exists()) await part.delete();
        sink = part.openWrite();

        var received = baseBytes;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(modelDownloadStatus(model, received, model.totalBytes));
        }
        await sink.close();
        sink = null;
        client.close();
        client = null;

        if (!isModelFileValid(file, await part.length())) {
          throw Exception('Download incomplete: ${file.name}');
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        return;
      } catch (e) {
        await sink?.close();
        sink = null;
        client?.close();
        client = null;
        if (await part.exists()) await part.delete();

        final networkError = e is SocketException || e is http.ClientException;
        if (networkError || attempt >= 3) {
          final retry = await onRetryRequired(
            networkError
                ? 'Network error while downloading ${file.name}: $e'
                : 'Download failed for ${file.name}: $e',
          );
          if (retry) {
            attempt = 0;
            continue;
          }
          rethrow;
        }
        await Future<void>.delayed(retryDelay);
      }
    }
  }
}
