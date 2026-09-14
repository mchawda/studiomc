// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('contract method names are the llama.cpp platform API', () {
    expect(MobileInferenceContract.methodChannel, 'studiomc.mobile_inference');
    expect(MobileInferenceContract.tokenEventChannel, 'studiomc.mobile_inference/tokens');
    expect(MobileInferenceContract.methods, {
      'probe',
      'load',
      'unload',
      'complete',
      'streamStart',
      'streamCancel',
      'embed',
    });
  });

  test('load payload uses app-support model path', () {
    final payload = MobileInferenceContract.encodeLoad(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/var/mobile/support/models/studiomc-0.6b/studiomc-0.6b-q4_k_m.gguf',
      nCtx: 1024,
      nGpuLayers: 99,
    ));
    expect(payload, {
      'modelId': 'studiomc-0.6b',
      'modelPath': '/var/mobile/support/models/studiomc-0.6b/studiomc-0.6b-q4_k_m.gguf',
      'nCtx': 1024,
      'nGpuLayers': 99,
    });
  });

  test('ChannelMobileInferenceEngine talks to a mocked llama.cpp host', () async {
    const channel = MethodChannel(MobileInferenceContract.methodChannel);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'probe':
          return {
            'ramBytes': 8 * 1024 * 1024 * 1024,
            'deviceClass': 'tablet',
            'accelerators': ['nnapi', 'gpu'],
            'chipName': 'Dimensity',
          };
        case 'load':
          return {'ok': true, 'contextId': 1};
        case 'complete':
          return {'text': 'native hello', 'promptTokens': 2, 'completionTokens': 3};
        case 'embed':
          return {
            'vector': List<double>.generate(8, (i) => i.toDouble()),
          };
        case 'unload':
          return {'ok': true};
        default:
          return null;
      }
    });

    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final engine = ChannelMobileInferenceEngine();
    final hw = await engine.probe();
    expect(hw.deviceClass, DeviceClass.tablet);
    expect(hw.accelerators, containsAll({Accelerator.nnapi, Accelerator.gpu}));

    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-4b',
      modelPath: '/models/studiomc-4b.gguf',
    ));
    expect(engine.isLoaded, isTrue);

    final result = await engine.complete(const CompletionRequest(prompt: 'hi'));
    expect(result.text, 'native hello');
    expect(result.completionTokens, 3);

    final vector = await engine.embed('hi');
    expect(vector, [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]);

    await engine.unload();
    expect(engine.isLoaded, isFalse);
    expect(calls.map((c) => c.method),
        ['probe', 'load', 'complete', 'embed', 'unload']);
  });

  test('ChannelMobileInferenceEngine streams tokens from the event channel', () async {
    const method = MethodChannel(MobileInferenceContract.methodChannel);
    const events = EventChannel(MobileInferenceContract.tokenEventChannel);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'load') return {'ok': true, 'contextId': 7};
      if (call.method == 'streamStart') return {'requestId': 'req-1'};
      if (call.method == 'streamCancel') return {'ok': true};
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          sink.success({'requestId': 'req-1', 'token': 'on-'});
          sink.success({'requestId': 'req-1', 'token': 'device'});
          sink.success({'requestId': 'req-1', 'done': true});
        },
      ),
    );

    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });

    final engine = ChannelMobileInferenceEngine();
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/models/tiny.gguf',
    ));
    final tokens = await engine
        .streamTokens(const CompletionRequest(prompt: 'go'))
        .toList();
    expect(tokens, ['on-', 'device']);
  });
}
