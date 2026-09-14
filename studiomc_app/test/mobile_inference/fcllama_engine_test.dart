// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

/// Scripted stand-in for the fcllama plugin. Records every call and
/// replays token events the way the native side does: `function`,
/// `contextId`, `result.token`.
class FakeFcllama implements FcllamaBackend {
  final calls = <String>[];
  final events = StreamController<Map<Object?, dynamic>>.broadcast();

  double nextContextId = 7;
  String? formattedChat;
  bool formattedChatThrows = false;
  String completionText = 'hello world';
  List<String> streamedTokens = const ['hello', ' world'];
  bool emitAllTokens = true;
  Object? completionError;
  int promptTokens = 5;

  String? lastPrompt;
  List<String>? lastStop;
  int? lastNPredict;
  int? lastNCtx;
  int? lastNBatch;
  int? lastGpuLayers;
  bool stopped = false;

  @override
  Stream<Map<Object?, dynamic>>? get onTokenStream => events.stream;

  @override
  Future<Map<Object?, dynamic>?> initContext(
    String modelPath, {
    required int nCtx,
    required int nBatch,
    required int nGpuLayers,
  }) async {
    calls.add('initContext');
    lastNCtx = nCtx;
    lastNBatch = nBatch;
    lastGpuLayers = nGpuLayers;
    return {'contextId': nextContextId};
  }

  @override
  Future<String?> getFormattedChat(
    double contextId,
    List<ChatTurn> messages,
  ) async {
    calls.add('getFormattedChat');
    if (formattedChatThrows) throw PlatformException(code: '505');
    return formattedChat;
  }

  @override
  Future<Map<Object?, dynamic>?> completion(
    double contextId, {
    required String prompt,
    required int nPredict,
    required double temperature,
    required List<String> stop,
    required bool emitRealtimeCompletion,
  }) async {
    calls.add('completion');
    lastPrompt = prompt;
    lastStop = stop;
    lastNPredict = nPredict;
    final error = completionError;
    if (error != null) throw error;
    if (emitRealtimeCompletion) {
      final toEmit =
          emitAllTokens ? streamedTokens : streamedTokens.sublist(0, 1);
      for (final token in toEmit) {
        events.add({
          'function': 'completion',
          'contextId': contextId,
          'result': {'token': token},
        });
        await Future<void>.delayed(Duration.zero);
      }
    }
    return {
      'text': completionText,
      'tokens_predicted': streamedTokens.length,
      'tokens_evaluated': promptTokens,
    };
  }

  @override
  Future<void> stopCompletion(double contextId) async {
    calls.add('stopCompletion');
    stopped = true;
  }

  @override
  Future<void> releaseContext(double contextId) async {
    calls.add('releaseContext');
  }
}

const _load = LoadModelRequest(
  modelId: 'studiomc-0.6b-q4_k_m.gguf',
  modelPath: '/models/studiomc-0.6b-q4_k_m.gguf',
  nCtx: 1024,
  nBatch: 256,
  nGpuLayers: 99,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFcllama fake;
  late StubMobileInferenceEngine host;
  late FcllamaInferenceEngine engine;
  var clock = 0;

  setUp(() {
    fake = FakeFcllama();
    host = StubMobileInferenceEngine();
    clock = 0;
    engine = FcllamaInferenceEngine(
      backend: fake,
      host: host,
      fileExists: (path) => path.startsWith('/models/'),
      nowMillis: () => clock += 500,
    );
  });

  tearDown(() => fake.events.close());

  group('load / unload', () {
    test('load hands fcllama the request shape and tracks the model', () async {
      await engine.load(_load);
      expect(engine.isLoaded, isTrue);
      expect(engine.loadedModelId, 'studiomc-0.6b-q4_k_m.gguf');
      expect(engine.loadedModelPath, '/models/studiomc-0.6b-q4_k_m.gguf');
      expect(engine.contextId, 7);
      expect(fake.lastNCtx, 1024);
      expect(fake.lastNBatch, 256);
      expect(fake.lastGpuLayers, 99);
    });

    test('a missing file is a typed error before fcllama is touched', () async {
      await expectLater(
        engine.load(const LoadModelRequest(
          modelId: 'x',
          modelPath: '/nowhere/x.gguf',
        )),
        throwsA(isA<ModelFileMissingException>()),
      );
      expect(fake.calls, isEmpty);
      expect(engine.isLoaded, isFalse);
    });

    test('a zero contextId is a host error, not a silent success', () async {
      fake.nextContextId = 0;
      await expectLater(
        engine.load(_load),
        throwsA(isA<MobileInferenceHostException>()
            .having((e) => e.code, 'code', 'init_context_failed')),
      );
      expect(engine.isLoaded, isFalse);
    });

    test('loading twice releases the first context', () async {
      await engine.load(_load);
      fake.nextContextId = 8;
      await engine.load(_load);
      expect(fake.calls, ['initContext', 'releaseContext', 'initContext']);
      expect(engine.contextId, 8);
    });

    test('unload is idempotent and clears the host copy', () async {
      await engine.unload();
      expect(fake.calls, isEmpty);
      await engine.load(_load);
      await engine.embed('warm the host');
      expect(host.isLoaded, isTrue);
      await engine.unload();
      expect(engine.isLoaded, isFalse);
      expect(host.isLoaded, isFalse);
      expect(fake.calls.last, 'releaseContext');
    });

    test('missing plugin surfaces as LlamaCppNotLinkedException', () async {
      final absent = FcllamaInferenceEngine(
        backend: PluginFcllamaBackend(),
        host: host,
        fileExists: (_) => true,
      );
      await expectLater(
        absent.load(_load),
        throwsA(isA<LlamaCppNotLinkedException>()
            .having((e) => e.method, 'method', 'load')),
      );
    });
  });

  group('complete', () {
    test('refuses when nothing is loaded', () {
      expect(
        () => engine.complete(const CompletionRequest(prompt: 'hi')),
        throwsA(isA<EngineNotLoadedException>()),
      );
    });

    test('maps fcllama token counts and text', () async {
      await engine.load(_load);
      final result =
          await engine.complete(const CompletionRequest(prompt: 'raw prompt'));
      expect(result.text, 'hello world');
      expect(result.promptTokens, 5);
      expect(result.completionTokens, 2);
      expect(fake.lastPrompt, 'raw prompt');
      expect(fake.lastStop, defaultStopSequences);
      expect(fake.lastNPredict, 256);
      expect(engine.lastTokensPerSecond, greaterThan(0));
    });

    test('a raw prompt is never rewritten', () async {
      await engine.load(_load);
      await engine.complete(const CompletionRequest(prompt: '### Answer'));
      expect(fake.lastPrompt, '### Answer');
      expect(fake.calls, isNot(contains('getFormattedChat')));
    });

    test('PlatformException becomes a typed host exception', () async {
      await engine.load(_load);
      fake.completionError = PlatformException(code: '505', message: 'busy');
      await expectLater(
        engine.complete(const CompletionRequest(prompt: 'x')),
        throwsA(isA<MobileInferenceHostException>()
            .having((e) => e.code, 'code', '505')
            .having((e) => e.method, 'method', 'complete')),
      );
    });
  });

  group('prompt building', () {
    const turns = [
      ChatTurn(role: 'system', content: 'Be brief.'),
      ChatTurn(role: 'user', content: 'Hi'),
    ];

    test('uses the GGUF template from fcllama when available', () async {
      fake.formattedChat = '<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n';
      await engine.load(const LoadModelRequest(
        modelId: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
        modelPath: '/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      ));
      final prompt =
          await engine.buildPrompt(const CompletionRequest(messages: turns));
      expect(prompt, fake.formattedChat);
    });

    test('falls back to ChatML when the template call fails', () async {
      fake.formattedChatThrows = true;
      await engine.load(const LoadModelRequest(
        modelId: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
        modelPath: '/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      ));
      final prompt =
          await engine.buildPrompt(const CompletionRequest(messages: turns));
      expect(prompt, chatMlPrompt(turns));
      expect(prompt, endsWith('<|im_start|>assistant\n'));
      expect(prompt, isNot(contains('<think>')));
    });

    test('studiomc-0.6b gets enable_thinking=false from the catalog', () async {
      fake.formattedChat =
          '<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n';
      await engine.load(_load);
      expect(engine.chatTemplateKwargs, {'enable_thinking': false});
      final prompt =
          await engine.buildPrompt(const CompletionRequest(messages: turns));
      expect(prompt, endsWith('<|im_start|>assistant\n$qwen3NoThinkSuffix'));
      // Applied once, even if a caller repeats the kwarg.
      final again = await engine.buildPrompt(const CompletionRequest(
        messages: turns,
        chatTemplateKwargs: {'enable_thinking': false},
      ));
      expect(again, prompt);
    });

    test('a request can turn thinking back on for the same model', () async {
      await engine.load(_load);
      final prompt = await engine.buildPrompt(const CompletionRequest(
        messages: turns,
        chatTemplateKwargs: {'enable_thinking': true},
      ));
      expect(prompt, isNot(contains('<think>')));
    });

    test('the kwargs reach the prompt fcllama actually receives', () async {
      await engine.load(_load);
      await engine.complete(const CompletionRequest(messages: turns));
      expect(fake.lastPrompt, endsWith(qwen3NoThinkSuffix));
      final streamed = await engine
          .streamTokens(const CompletionRequest(messages: turns))
          .toList();
      expect(streamed, ['hello', ' world']);
      expect(fake.lastPrompt, endsWith(qwen3NoThinkSuffix));
    });
  });

  group('streamTokens', () {
    test('errors on the stream when nothing is loaded', () async {
      await expectLater(
        engine.streamTokens(const CompletionRequest(prompt: 'x')).toList(),
        throwsA(isA<EngineNotLoadedException>()),
      );
    });

    test('yields fcllama tokens for this context only', () async {
      await engine.load(_load);
      // A stray event from another context must be ignored.
      unawaited(Future<void>.microtask(() => fake.events.add({
            'function': 'completion',
            'contextId': 99.0,
            'result': {'token': 'WRONG'},
          })));
      final tokens =
          await engine.streamTokens(const CompletionRequest(prompt: 'go')).toList();
      expect(tokens, ['hello', ' world']);
      expect(engine.lastTokensPerSecond, greaterThan(0));
    });

    test('replays the missing tail if the result beats the last event', () async {
      await engine.load(_load);
      fake.emitAllTokens = false;
      final tokens =
          await engine.streamTokens(const CompletionRequest(prompt: 'go')).toList();
      expect(tokens.join(), 'hello world');
    });

    test('cancelling mid-stream stops the native generation', () async {
      await engine.load(_load);
      fake.streamedTokens = List.generate(50, (i) => 't$i');
      final sub = engine
          .streamTokens(const CompletionRequest(prompt: 'go'))
          .listen(null);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(fake.stopped, isTrue);
    });

    test('completion failures surface as stream errors', () async {
      await engine.load(_load);
      fake.completionError = PlatformException(code: '500', message: 'oom');
      await expectLater(
        engine.streamTokens(const CompletionRequest(prompt: 'go')).toList(),
        throwsA(isA<MobileInferenceHostException>()
            .having((e) => e.method, 'method', 'streamStart')),
      );
    });
  });

  group('probe / embed via the channel host', () {
    test('probe is answered by the host, not fcllama', () async {
      final hw = await engine.probe();
      expect(hw.chipName, 'stub');
      expect(fake.calls, isEmpty);
    });

    test('embed loads the same model on the host and returns its vector', () async {
      await engine.load(_load);
      final vec = await engine.embed('hello');
      expect(vec, hashedEmbedding('hello'));
      expect(host.loadedModelPath, _load.modelPath);
    });

    test('embed refuses before load', () {
      expect(() => engine.embed('x'), throwsA(isA<EngineNotLoadedException>()));
    });

    test('a not-linked host makes embed a typed failure', () async {
      const channel = MethodChannel(MobileInferenceContract.methodChannel);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: MobileInferenceContract.errorLlamaNotLinked,
          message: 'llama.cpp is not linked yet.',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final real = FcllamaInferenceEngine(
        backend: fake,
        host: ChannelMobileInferenceEngine(),
        fileExists: (_) => true,
      );
      await real.load(_load);
      // Generation still works through fcllama...
      final result = await real.complete(const CompletionRequest(prompt: 'x'));
      expect(result.text, 'hello world');
      // ...while embed reports exactly what is missing.
      await expectLater(
        real.embed('x'),
        throwsA(isA<LlamaCppNotLinkedException>()),
      );
    });
  });

  group('createMobileInferenceEngine', () {
    test('returns the fcllama engine on phones and the channel engine elsewhere', () {
      expect(createMobileInferenceEngine(platform: TargetPlatform.iOS),
          isA<FcllamaInferenceEngine>());
      expect(createMobileInferenceEngine(platform: TargetPlatform.android),
          isA<FcllamaInferenceEngine>());
      expect(createMobileInferenceEngine(platform: TargetPlatform.macOS),
          isA<ChannelMobileInferenceEngine>());
      expect(createMobileInferenceEngine(stub: true),
          isA<StubMobileInferenceEngine>());
    });
  });
}
