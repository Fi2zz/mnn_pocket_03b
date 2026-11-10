import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mnn_local_llm/mnn_local_llm.dart';

const _fileA = MnnModelFile(name: 'a.json', url: 'http://test/a.json', bytes: 4);
const _fileW =
    MnnModelFile(name: 'w.weight', url: 'http://test/w.weight', bytes: 8);
const _model = MnnModel(
  id: 'test',
  name: 'Test',
  dirName: 'test-model',
  files: [_fileA, _fileW],
  minRamGB: 1,
  context: 2048,
  chatTemplate:
      MnnChatTemplate(system: '{text}', user: '{text}', assistant: '{text}'),
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mnn_model_store_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('small files need exact size and weights accept 95%', () {
    expect(isModelFileValid(_fileA, 4), isTrue);
    expect(isModelFileValid(_fileA, 3), isFalse);
    expect(isModelFileValid(_fileW, 7), isTrue);
    expect(isModelFileValid(_fileW, 6), isFalse);
  });

  test('progress and status render aggregate percentage', () {
    expect(modelProgress(50, 100), 0.5);
    const mib = 1024 * 1024;
    final status = modelDownloadStatus(_model, mib, 2 * mib);
    expect(status, contains('1.0 / 2.0 MB'));
    expect(status, contains('(50.0%)'));
  });

  test('complete directory requires every file at its minimum size', () async {
    await File('${tmp.path}/a.json').writeAsBytes(List.filled(4, 1));
    await File('${tmp.path}/w.weight').writeAsBytes(List.filled(8, 1));
    expect(await isModelComplete(tmp, _model), isTrue);

    await File('${tmp.path}/w.weight').writeAsBytes(List.filled(6, 1));
    expect(await isModelComplete(tmp, _model), isFalse);
    expect(await File('${tmp.path}/a.json').exists(), isTrue);
  });

  test('ensureModel downloads missing files and reports completion', () async {
    final progress = <String>[];
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.toString());
      final length = request.url.path.endsWith('a.json') ? 4 : 8;
      return http.Response.bytes(List.filled(length, 1), 200);
    });
    final store = MnnModelStore(
      model: _model,
      modelDir: tmp,
      onProgress: progress.add,
      onRetryRequired: (_) async => false,
      clientFactory: () => client,
      retryDelay: Duration.zero,
    );

    await store.ensureModel();

    expect(requests, ['http://test/a.json', 'http://test/w.weight']);
    expect(await File('${tmp.path}/a.json').length(), 4);
    expect(await File('${tmp.path}/w.weight').length(), 8);
    expect(progress.last, 'Download complete');
  });

  test('truncated weight is re-downloaded alone', () async {
    await File('${tmp.path}/a.json').writeAsBytes(List.filled(4, 1));
    await File('${tmp.path}/w.weight').writeAsBytes(List.filled(6, 1));

    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.toString());
      return http.Response.bytes(List.filled(8, 1), 200);
    });
    final store = MnnModelStore(
      model: _model,
      modelDir: tmp,
      onProgress: (_) {},
      onRetryRequired: (_) async => false,
      clientFactory: () => client,
      retryDelay: Duration.zero,
    );

    await store.ensureModel();

    expect(requests, ['http://test/w.weight']);
    expect(await File('${tmp.path}/w.weight').length(), 8);
  });

  test('HTTP failures retry with delay until success', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (attempts == 1) return http.Response('error', 500);
      final length = request.url.path.endsWith('a.json') ? 4 : 8;
      return http.Response.bytes(List.filled(length, 1), 200);
    });
    final store = MnnModelStore(
      model: _model,
      modelDir: tmp,
      onProgress: (_) {},
      onRetryRequired: (_) async => false,
      clientFactory: () => client,
      retryDelay: Duration.zero,
    );

    await store.ensureModel();

    expect(attempts, 3);
    expect(await isModelComplete(tmp, _model), isTrue);
  });

  test('offline download leaves no part file and rethrows', () async {
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });
    final store = MnnModelStore(
      model: _model,
      modelDir: tmp,
      onProgress: (_) {},
      onRetryRequired: (_) async => false,
      clientFactory: () => client,
      retryDelay: Duration.zero,
    );

    await expectLater(store.ensureModel(), throwsA(isA<SocketException>()));
    expect(await File('${tmp.path}/a.json.part').exists(), isFalse);
    expect(await File('${tmp.path}/w.weight.part').exists(), isFalse);
  });
}
