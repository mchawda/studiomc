// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:fcllama/fllama.dart';
import 'package:fcllama/fllama_type.dart';
import 'package:flutter/services.dart';

import 'catalog.dart';
import 'channel_engine.dart';
import 'engine.dart';

/// The slice of the `fcllama` plugin the engine needs. Kept as an
/// interface so unit tests can drive the engine with a fake instead of a
/// phone, and so a future llama.cpp host can replace the plugin without
/// touching callers.
abstract class FcllamaBackend {
  Stream<Map<Object?, dynamic>>? get onTokenStream;

  Future<Map<Object?, dynamic>?> initContext(
    String modelPath, {
    required int nCtx,
    required int nBatch,
    required int nGpuLayers,
  });

  Future<String?> getFormattedChat(
    double contextId,
    List<ChatTurn> messages,
  );

  Future<Map<Object?, dynamic>?> completion(
    double contextId, {
    required String prompt,
    required int nPredict,
    required double temperature,
    required List<String> stop,
    required bool emitRealtimeCompletion,
  });

  Future<void> stopCompletion(double contextId);

  Future<void> releaseContext(double contextId);
}

/// Production backend: the real `fcllama` plugin (llama.cpp with Metal on
/// iOS, CPU/NNAPI on Android).
class PluginFcllamaBackend implements FcllamaBackend {
  PluginFcllamaBackend([FCllama? plugin]) : _plugin = plugin ?? FCllama.instance();

  final FCllama? _plugin;

  FCllama get _require {
    final plugin = _plugin;
    if (plugin == null) {
      throw MissingPluginException('fcllama plugin is not registered');
    }
    return plugin;
  }

  @override
  Stream<Map<Object?, dynamic>>? get onTokenStream => _plugin?.onTokenStream;

  @override
  Future<Map<Object?, dynamic>?> initContext(
    String modelPath, {
    required int nCtx,
    required int nBatch,
    required int nGpuLayers,
  }) {
    return _require.initContext(
      modelPath,
      nCtx: nCtx,
      nBatch: nBatch,
      nGpuLayers: nGpuLayers,
      useMlock: false,
      useMmap: true,
      emitLoadProgress: true,
    );
  }

  @override
  Future<String?> getFormattedChat(
    double contextId,
    List<ChatTurn> messages,
  ) {
    return _require.getFormattedChat(
      contextId,
      messages: [
        for (final turn in messages)
          RoleContent(role: turn.role, content: turn.content),
      ],
    );
  }

  @override
  Future<Map<Object?, dynamic>?> completion(
    double contextId, {
    required String prompt,
    required int nPredict,
    required double temperature,
    required List<String> stop,
    required bool emitRealtimeCompletion,
  }) {
    return _require.completion(
      contextId,
      prompt: prompt,
      temperature: temperature,
      topK: 40,
      topP: 0.9,
      nPredict: nPredict,
      penaltyRepeat: 1.1,
      stop: stop,
      emitRealtimeCompletion: emitRealtimeCompletion,
    );
  }

  @override
  Future<void> stopCompletion(double contextId) =>
      _require.stopCompletion(contextId: contextId);

  @override
  Future<void> releaseContext(double contextId) =>
      _require.releaseContext(contextId);
}

/// [MobileInferenceEngine] backed by the `fcllama` plugin that already
/// ships in the app. This is the engine mobile runs today.
///
/// * `probe` comes from the Studiomc channel host, which is live on both
///   platforms and knows RAM and accelerators; fcllama does not.
/// * `load`, `unload`, `complete`, `streamTokens` go through fcllama.
/// * `embed` is delegated to the channel host because fcllama 0.0.3 has
///   no embedding method (its C++ has `getEmbedding`, the plugin never
///   exposes it). Until native embed lands the host answers
///   `llama_cpp_not_linked`, which surfaces here as a typed
///   [LlamaCppNotLinkedException]. Nothing is faked.
///
/// Every failure is one of the typed exceptions in `engine.dart`.
class FcllamaInferenceEngine implements MobileInferenceEngine {
  FcllamaInferenceEngine({
    FcllamaBackend? backend,
    MobileInferenceEngine? host,
    bool Function(String path)? fileExists,
    int Function()? nowMillis,
  })  : _backend = backend ?? PluginFcllamaBackend(),
        _host = host ?? ChannelMobileInferenceEngine(),
        _fileExists = fileExists ?? _defaultFileExists,
        _nowMillis = nowMillis ?? _defaultNowMillis;

  static bool _defaultFileExists(String path) => File(path).existsSync();
  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;

  final FcllamaBackend _backend;
  final MobileInferenceEngine _host;
  final bool Function(String path) _fileExists;
  final int Function() _nowMillis;

  double? _contextId;
  LoadModelRequest? _loaded;
  Map<String, Object?> _modelKwargs = const {};
  double _lastTokensPerSecond = 0;

  /// Decode speed of the most recent generation (tokens per second).
  double get lastTokensPerSecond => _lastTokensPerSecond;

  /// The fcllama context handle, exposed for diagnostics only.
  double? get contextId => _contextId;

  @override
  bool get isLoaded => _contextId != null;

  @override
  String? get loadedModelId => _loaded?.modelId;

  @override
  String? get loadedModelPath => _loaded?.modelPath;

  @override
  Future<HardwareCapabilities> probe() => _host.probe();

  @override
  Future<void> load(LoadModelRequest request) async {
    if (!_fileExists(request.modelPath)) {
      throw ModelFileMissingException(request.modelPath);
    }
    if (isLoaded) await unload();

    final raw = await _guard(
      'load',
      () => _backend.initContext(
        request.modelPath,
        nCtx: request.nCtx,
        nBatch: request.nBatch,
        nGpuLayers: request.nGpuLayers,
      ),
    );
    final ctx = raw?['contextId'];
    if (ctx is! num || ctx <= 0) {
      throw MobileInferenceHostException(
        code: 'init_context_failed',
        method: 'load',
        message: 'fcllama returned contextId=$ctx for ${request.modelPath}',
      );
    }
    _contextId = ctx.toDouble();
    _loaded = request;
    _modelKwargs = {
      ...MobileModelCatalog.chatTemplateKwargsFor(
        modelId: request.modelId,
        modelPath: request.modelPath,
      ),
      ...request.chatTemplateKwargs,
    };
  }

  @override
  Future<void> unload() async {
    final ctx = _contextId;
    if (ctx == null) return;
    try {
      await _guard('unload', () => _backend.releaseContext(ctx));
    } finally {
      _contextId = null;
      _loaded = null;
      _modelKwargs = const {};
      if (_host.isLoaded) {
        try {
          await _host.unload();
        } catch (_) {
          // The host copy is best-effort; fcllama already released.
        }
      }
    }
  }

  @override
  Future<CompletionResult> complete(CompletionRequest request) async {
    final ctx = _requireLoaded();
    final prompt = await buildPrompt(request);
    final started = _nowMillis();
    final raw = await _guard(
      'complete',
      () => _backend.completion(
        ctx,
        prompt: prompt,
        nPredict: request.maxTokens,
        temperature: request.temperature,
        stop: request.stop.isEmpty ? defaultStopSequences : request.stop,
        emitRealtimeCompletion: false,
      ),
    );
    final text = raw?['text'];
    if (text is! String) {
      throw MobileInferenceHostException(
        code: 'bad_payload',
        method: 'complete',
        message: 'fcllama completion returned no text',
      );
    }
    final completionTokens = (raw?['tokens_predicted'] as num?)?.toInt() ?? 0;
    _recordSpeed(completionTokens, started);
    return CompletionResult(
      text: text,
      promptTokens: (raw?['tokens_evaluated'] as num?)?.toInt() ?? 0,
      completionTokens: completionTokens,
    );
  }

  @override
  Stream<String> streamTokens(CompletionRequest request) {
    final controller = StreamController<String>();
    final emitted = StringBuffer();
    StreamSubscription<Map<Object?, dynamic>>? tokens;
    double? ctx;
    var finished = false;
    var tokenCount = 0;

    Future<void> finish() async {
      if (finished) return;
      finished = true;
      await tokens?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller.onListen = () async {
      final started = _nowMillis();
      final String prompt;
      final double activeCtx;
      try {
        activeCtx = _requireLoaded();
        ctx = activeCtx;
        prompt = await buildPrompt(request);
      } catch (e, st) {
        controller.addError(e, st);
        await finish();
        return;
      }

      tokens = _backend.onTokenStream?.listen((event) {
        if (event['function'] != 'completion') return;
        final eventCtx = event['contextId'];
        if (eventCtx is num && eventCtx.toDouble() != activeCtx) return;
        final result = event['result'];
        if (result is! Map) return;
        final token = result['token'];
        if (token is String && token.isNotEmpty && !controller.isClosed) {
          tokenCount++;
          emitted.write(token);
          controller.add(token);
        }
      });

      try {
        final raw = await _guard(
          'streamStart',
          () => _backend.completion(
            activeCtx,
            prompt: prompt,
            nPredict: request.maxTokens,
            temperature: request.temperature,
            stop: request.stop.isEmpty ? defaultStopSequences : request.stop,
            emitRealtimeCompletion: true,
          ),
        );
        // The method result and the event channel are independent
        // platform messages; if the final text arrived before its last
        // token events, hand the caller the missing tail rather than
        // truncating the answer.
        final full = raw?['text'];
        if (full is String && !controller.isClosed) {
          final seen = emitted.toString();
          if (full.length > seen.length && full.startsWith(seen)) {
            controller.add(full.substring(seen.length));
          }
        }
        final predicted = (raw?['tokens_predicted'] as num?)?.toInt();
        _recordSpeed(predicted ?? tokenCount, started);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        await finish();
      }
    };

    controller.onCancel = () async {
      final running = ctx;
      if (!finished && running != null) {
        try {
          await _backend.stopCompletion(running);
        } catch (_) {
          // Generation may already be over; nothing to stop.
        }
      }
      await finish();
    };

    return controller.stream;
  }

  @override
  Future<List<double>> embed(String text) async {
    _requireLoaded();
    // fcllama exposes no embedding call, so the Studiomc channel host owns
    // embed. Load the same model there on first use; today the host
    // answers llama_cpp_not_linked and that typed error propagates.
    if (!_host.isLoaded) await _host.load(_loaded!);
    return _host.embed(text);
  }

  /// Render the prompt the model will see. Raw prompts pass through
  /// untouched; chat requests go through the GGUF's own template via
  /// fcllama, fall back to ChatML, then have the chat template kwargs
  /// (model defaults under request overrides) applied.
  Future<String> buildPrompt(CompletionRequest request) async {
    if (!request.isChat) return request.resolvedPrompt;
    final ctx = _requireLoaded();
    String? rendered;
    try {
      rendered = await _backend.getFormattedChat(ctx, request.messages);
    } catch (_) {
      rendered = null;
    }
    final base = (rendered == null || rendered.isEmpty)
        ? chatMlPrompt(request.messages)
        : rendered;
    return applyChatTemplateKwargs(base, {
      ..._modelKwargs,
      ...request.chatTemplateKwargs,
    });
  }

  /// Effective chat template kwargs for the loaded model.
  Map<String, Object?> get chatTemplateKwargs => Map.unmodifiable(_modelKwargs);

  double _requireLoaded() {
    final ctx = _contextId;
    if (ctx == null) throw EngineNotLoadedException();
    return ctx;
  }

  void _recordSpeed(int tokens, int startedMillis) {
    final elapsed = _nowMillis() - startedMillis;
    if (tokens > 0 && elapsed > 0) {
      _lastTokensPerSecond = tokens / (elapsed / 1000.0);
    }
  }

  Future<T> _guard<T>(String method, Future<T> Function() call) async {
    try {
      return await call();
    } on MissingPluginException catch (e) {
      throw LlamaCppNotLinkedException(method, e.message);
    } on PlatformException catch (e) {
      throw MobileInferenceHostException(
        code: e.code,
        method: method,
        message: e.message,
      );
    }
  }
}
