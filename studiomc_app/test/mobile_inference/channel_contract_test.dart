// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

/// Native hosts implementing the contract. `flutter test` runs from the
/// package root, so these are relative to `studiomc_app/`.
const _iosHost = 'ios/Runner/AppDelegate.swift';
const _androidHost =
    'android/app/src/main/kotlin/com/studiomc/studiomc_app/MobileInferenceHost.kt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native hosts implement the same contract', () {
    final ios = File(_iosHost).readAsStringSync();
    final android = File(_androidHost).readAsStringSync();

    test('channel names match on iOS and Android', () {
      for (final src in [ios, android]) {
        expect(src, contains('"${MobileInferenceContract.methodChannel}"'));
        expect(src, contains('"${MobileInferenceContract.tokenEventChannel}"'));
      }
    });

    test('every method name is handled on both platforms', () {
      for (final method in MobileInferenceContract.methods) {
        expect(ios, contains('"$method"'), reason: 'iOS lacks $method');
        expect(android, contains('"$method"'), reason: 'Android lacks $method');
      }
    });

    test('not-linked error code is identical on both platforms', () {
      for (final src in [ios, android]) {
        expect(src, contains('"${MobileInferenceContract.errorLlamaNotLinked}"'));
      }
    });

    test('probe payload keys match decodeProbe on both platforms', () {
      for (final key in ['ramBytes', 'deviceClass', 'accelerators', 'chipName']) {
        expect(ios, contains('"$key"'), reason: 'iOS probe lacks $key');
        expect(android, contains('"$key"'), reason: 'Android probe lacks $key');
      }
    });
  });

  group('typed errors', () {
    test('decodeError maps every contract code to a typed exception', () {
      Exception decode(String code) => MobileInferenceContract.decodeError(
            PlatformException(code: code, message: 'm', details: '/p.gguf'),
            method: 'load',
          );
      expect(decode(MobileInferenceContract.errorLlamaNotLinked),
          isA<LlamaCppNotLinkedException>());
      expect(decode(MobileInferenceContract.errorModelFileMissing),
          isA<ModelFileMissingException>());
      expect(decode(MobileInferenceContract.errorNotLoaded),
          isA<EngineNotLoadedException>());
      final unknown = decode('something_else');
      expect(unknown, isA<MobileInferenceHostException>());
      expect((unknown as MobileInferenceHostException).code, 'something_else');
      expect(MobileInferenceContract.errorCodes, hasLength(4));
    });

    test('a not-linked host fails load/complete/embed loudly, never silently',
        () async {
      const channel = MethodChannel(MobileInferenceContract.methodChannel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'probe') {
          return {'ramBytes': 4 * 1024 * 1024 * 1024, 'deviceClass': 'phone'};
        }
        throw PlatformException(
          code: MobileInferenceContract.errorLlamaNotLinked,
          message: 'llama.cpp is not linked yet.',
          details: call.method,
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final engine = ChannelMobileInferenceEngine();
      final hw = await engine.probe();
      expect(hw.deviceClass, DeviceClass.phone);

      await expectLater(
        engine.load(const LoadModelRequest(
          modelId: 'studiomc-0.6b',
          modelPath: '/models/tiny.gguf',
        )),
        throwsA(isA<LlamaCppNotLinkedException>()
            .having((e) => e.method, 'method', 'load')),
      );
      expect(engine.isLoaded, isFalse);

      // Not loaded, so the engine refuses before touching the host.
      expect(() => engine.complete(const CompletionRequest(prompt: 'x')),
          throwsA(isA<EngineNotLoadedException>()));
      expect(() => engine.embed('x'), throwsA(isA<EngineNotLoadedException>()));
      // Unload with nothing loaded is a no-op, not an error.
      await engine.unload();
    });

    test('missing native plugin surfaces as LlamaCppNotLinkedException',
        () async {
      const channel = MethodChannel('studiomc.mobile_inference.absent');
      final engine = ChannelMobileInferenceEngine(methodChannel: channel);
      await expectLater(
          engine.probe(), throwsA(isA<LlamaCppNotLinkedException>()));
    });

    test('malformed host payloads are rejected, not zero-filled', () async {
      const channel = MethodChannel(MobileInferenceContract.methodChannel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'load':
            return {'ok': true};
          case 'embed':
            return {'vector': <double>[]};
          case 'complete':
            return {'promptTokens': 1};
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final engine = ChannelMobileInferenceEngine();
      await engine.load(const LoadModelRequest(
        modelId: 'studiomc-4b',
        modelPath: '/models/a.gguf',
      ));
      expect(
        () => engine.embed('x'),
        throwsA(isA<MobileInferenceHostException>()
            .having((e) => e.code, 'code', MobileInferenceContract.errorBadPayload)),
      );
      expect(
        () => engine.complete(const CompletionRequest(prompt: 'x')),
        throwsA(isA<MobileInferenceHostException>()
            .having((e) => e.method, 'method', 'complete')),
      );
    });
  });

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
