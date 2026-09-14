// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

void main() {
  late StubMobileInferenceEngine engine;

  setUp(() {
    engine = StubMobileInferenceEngine(
      hardware: const HardwareCapabilities(
        ramBytes: 8 * 1024 * 1024 * 1024,
        deviceClass: DeviceClass.phone,
        accelerators: {Accelerator.neuralEngine},
        chipName: 'stub-chip',
      ),
    );
  });

  test('probe returns injected hardware without a device', () async {
    final hw = await engine.probe();
    expect(hw.deviceClass, DeviceClass.phone);
    expect(hw.ramBytes, 8 * 1024 * 1024 * 1024);
    expect(hw.hasNeuralAccel, isTrue);
    expect(hw.chipName, 'stub-chip');
  });

  test('load and unload track the active GGUF path', () async {
    expect(engine.isLoaded, isFalse);
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/tmp/support/models/studiomc-0.6b/studiomc-0.6b-q4_k_m.gguf',
    ));
    expect(engine.isLoaded, isTrue);
    expect(engine.loadedModelId, 'studiomc-0.6b');
    expect(engine.loadedModelPath, contains('studiomc-0.6b-q4_k_m.gguf'));

    await engine.unload();
    expect(engine.isLoaded, isFalse);
    expect(engine.loadedModelId, isNull);
  });

  test('complete and stream require a loaded model', () async {
    expect(
      () => engine.complete(const CompletionRequest(prompt: 'hi')),
      throwsA(isA<EngineNotLoadedException>()),
    );
    expect(
      () => engine.streamTokens(const CompletionRequest(prompt: 'hi')).toList(),
      throwsA(isA<EngineNotLoadedException>()),
    );
  });

  test('complete returns canned text and stream yields the same tokens', () async {
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/models/tiny.gguf',
    ));
    engine.cannedCompletion = 'hello from stub';

    final result = await engine.complete(
      const CompletionRequest(prompt: 'say hello', maxTokens: 16),
    );
    expect(result.text, 'hello from stub');
    expect(result.completionTokens, greaterThan(0));

    final tokens = await engine
        .streamTokens(const CompletionRequest(prompt: 'say hello'))
        .toList();
    expect(tokens.join(), 'hello from stub');
  });

  test('embed is deterministic and similar texts are closer than unrelated', () async {
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/models/tiny.gguf',
    ));

    final a = await engine.embed('the cat sat on the mat');
    final b = await engine.embed('a cat sat on a mat');
    final c = await engine.embed('quantum chromodynamics lattice');
    expect(a.length, 32);
    expect(a, await engine.embed('the cat sat on the mat'));
    expect(cosineSimilarity(a, b), greaterThan(cosineSimilarity(a, c)));
  });
}
