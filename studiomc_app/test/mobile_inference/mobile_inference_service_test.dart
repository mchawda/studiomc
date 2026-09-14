// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';
import 'package:studiomc_app/services/mobile_inference_service.dart';

void main() {
  late Directory tmp;
  late StubMobileInferenceEngine engine;
  late MobileInferenceService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('studiomc-mobile-');
    engine = StubMobileInferenceEngine(cannedCompletion: 'on device');
    service = MobileInferenceService(
      engine: engine,
      modelsDir: () async => tmp,
    );
  });

  tearDown(() async {
    service.dispose();
    await tmp.delete(recursive: true);
  });

  Future<File> writeModel(String name, {int bytes = 16}) =>
      File('${tmp.path}/$name').writeAsBytes(List.filled(bytes, 0));

  test('init lists downloaded GGUFs without loading any', () async {
    await writeModel('studiomc-0.6b-q4_k_m.gguf');
    await writeModel('notes.txt');
    expect(await service.init(), isTrue);
    expect(service.downloadedModels.map((m) => m.filename),
        ['studiomc-0.6b-q4_k_m.gguf']);
    expect(service.available, isFalse);
    expect(engine.isLoaded, isFalse);
  });

  test('loadModel drives the shared engine and exposes it', () async {
    await writeModel('studiomc-0.6b-q4_k_m.gguf');
    var notified = 0;
    service.addListener(() => notified++);

    expect(await service.loadModel('studiomc-0.6b-q4_k_m.gguf'), isTrue);
    expect(service.available, isTrue);
    expect(service.activeModel, 'studiomc-0.6b-q4_k_m.gguf');
    expect(service.engine, same(engine));
    expect(engine.loadedModelId, 'studiomc-0.6b-q4_k_m.gguf');
    expect(engine.loadedModelPath, '${tmp.path}/studiomc-0.6b-q4_k_m.gguf');
    expect(notified, greaterThanOrEqualTo(2));
  });

  test('a missing file fails cleanly', () async {
    expect(await service.loadModel('ghost.gguf'), isFalse);
    expect(service.available, isFalse);
    expect(engine.isLoaded, isFalse);
  });

  test('streamChat flattens OpenAI messages into engine turns', () async {
    await writeModel('m.gguf');
    await service.loadModel('m.gguf');
    final tokens = await service.streamChat(messages: [
      {'role': 'system', 'content': 'Be brief.'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Hello'},
          {'type': 'image_url', 'image_url': 'data:...'},
          {'type': 'text', 'text': 'there'},
        ],
      },
    ]).toList();
    expect(tokens.join(), 'on device');
    expect(engine.lastPrompt, chatMlPrompt(const [
      ChatTurn(role: 'system', content: 'Be brief.'),
      ChatTurn(role: 'user', content: 'Hello there'),
    ]));
  });

  test('streamChat without a model keeps the legacy hint token', () async {
    final tokens = await service.streamChat(messages: [
      {'role': 'user', 'content': 'hi'},
    ]).toList();
    expect(tokens, hasLength(1));
    expect(tokens.first, startsWith('No model loaded'));
  });

  test('chatCompletion joins the stream', () async {
    await writeModel('m.gguf');
    await service.loadModel('m.gguf');
    expect(
      await service.chatCompletion(messages: [
        {'role': 'user', 'content': 'hi'},
      ]),
      'on device',
    );
  });

  test('deleting the active model unloads the engine', () async {
    await writeModel('m.gguf');
    await service.loadModel('m.gguf');
    expect(await service.deleteModel('m.gguf'), isTrue);
    expect(engine.isLoaded, isFalse);
    expect(service.available, isFalse);
    expect(service.activeModel, isNull);
    expect(service.downloadedModels, isEmpty);
  });

  test('toChatTurns defaults role to user and content to empty', () {
    final turns = MobileInferenceService.toChatTurns([
      {'content': 'x'},
      {'role': 'assistant'},
    ]);
    expect(turns.map((t) => t.role), ['user', 'assistant']);
    expect(turns.map((t) => t.content), ['x', '']);
  });
}
