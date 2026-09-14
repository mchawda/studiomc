// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:flutter/services.dart';

import 'channel_contract.dart';
import 'engine.dart';

/// MobileInferenceEngine over the llama.cpp platform channel.
///
/// Every host error surfaces as a typed exception from `engine.dart`
/// ([LlamaCppNotLinkedException], [ModelFileMissingException],
/// [EngineNotLoadedException], [MobileInferenceHostException]). Nothing
/// is swallowed into an empty result.
class ChannelMobileInferenceEngine implements MobileInferenceEngine {
  ChannelMobileInferenceEngine({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ??
            const MethodChannel(MobileInferenceContract.methodChannel),
        _events = eventChannel ??
            const EventChannel(MobileInferenceContract.tokenEventChannel);

  final MethodChannel _methods;
  final EventChannel _events;

  String? _modelId;
  String? _modelPath;

  @override
  bool get isLoaded => _modelId != null;

  @override
  String? get loadedModelId => _modelId;

  @override
  String? get loadedModelPath => _modelPath;

  Future<Map<String, dynamic>?> _invoke(
    String method, [
    Map<String, dynamic>? args,
    String? modelPath,
  ]) async {
    try {
      return await _methods.invokeMapMethod<String, dynamic>(method, args);
    } on PlatformException catch (e) {
      throw MobileInferenceContract.decodeError(
        e,
        method: method,
        modelPath: modelPath,
      );
    } on MissingPluginException catch (e) {
      // No native host registered at all (e.g. desktop or a build that
      // forgot to call MobileInferenceHost.register).
      throw LlamaCppNotLinkedException(method, e.message);
    }
  }

  @override
  Future<HardwareCapabilities> probe() async {
    final raw = await _invoke(MobileInferenceContract.probe);
    if (raw == null) {
      throw MobileInferenceHostException(
        code: MobileInferenceContract.errorBadPayload,
        method: MobileInferenceContract.probe,
        message: 'host returned null',
      );
    }
    return MobileInferenceContract.decodeProbe(raw);
  }

  @override
  Future<void> load(LoadModelRequest request) async {
    final raw = await _invoke(
      MobileInferenceContract.load,
      MobileInferenceContract.encodeLoad(request),
      request.modelPath,
    );
    if (raw?['ok'] != true) {
      throw ModelFileMissingException(request.modelPath);
    }
    _modelId = request.modelId;
    _modelPath = request.modelPath;
  }

  @override
  Future<void> unload() async {
    // Idempotent: nothing loaded means nothing to ask the host for.
    if (!isLoaded) return;
    try {
      await _invoke(MobileInferenceContract.unload);
    } finally {
      _modelId = null;
      _modelPath = null;
    }
  }

  @override
  Future<CompletionResult> complete(CompletionRequest request) async {
    _requireLoaded();
    final raw = await _invoke(
      MobileInferenceContract.complete,
      MobileInferenceContract.encodeComplete(request),
    );
    final text = raw?['text'];
    if (text is! String) {
      throw MobileInferenceHostException(
        code: MobileInferenceContract.errorBadPayload,
        method: MobileInferenceContract.complete,
        message: 'missing text',
      );
    }
    return CompletionResult(
      text: text,
      promptTokens: (raw?['promptTokens'] as num?)?.toInt() ?? 0,
      completionTokens: (raw?['completionTokens'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Stream<String> streamTokens(CompletionRequest request) async* {
    _requireLoaded();
    final controller = StreamController<String>();
    String? requestId;

    final sub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final map = Map<String, dynamic>.from(event);
      final eventReq = map['requestId'] as String?;
      if (requestId != null && eventReq != null && eventReq != requestId) {
        return;
      }
      if (map['done'] == true) {
        if (!controller.isClosed) controller.close();
        return;
      }
      final token = map['token'] as String?;
      if (token != null && !controller.isClosed) {
        controller.add(token);
      }
    }, onError: (Object error, StackTrace stack) {
      if (controller.isClosed) return;
      if (error is PlatformException) {
        controller.addError(
          MobileInferenceContract.decodeError(
            error,
            method: MobileInferenceContract.streamStart,
          ),
          stack,
        );
      } else {
        controller.addError(error, stack);
      }
    }, onDone: () {
      if (!controller.isClosed) controller.close();
    });

    try {
      final raw = await _invoke(
        MobileInferenceContract.streamStart,
        MobileInferenceContract.encodeComplete(request),
      );
      requestId = raw?['requestId'] as String?;
      yield* controller.stream;
    } finally {
      if (requestId != null) {
        try {
          await _methods.invokeMethod(
            MobileInferenceContract.streamCancel,
            MobileInferenceContract.encodeStreamCancel(requestId),
          );
        } catch (_) {
          // Cancel is best-effort; the host may already have finished.
        }
      }
      await sub.cancel();
      if (!controller.isClosed) await controller.close();
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    _requireLoaded();
    final raw = await _invoke(
      MobileInferenceContract.embed,
      MobileInferenceContract.encodeEmbed(text),
    );
    final vector = raw?['vector'];
    if (vector is! List || vector.isEmpty) {
      throw MobileInferenceHostException(
        code: MobileInferenceContract.errorBadPayload,
        method: MobileInferenceContract.embed,
        message: 'missing or empty vector',
      );
    }
    return vector.map((v) => (v as num).toDouble()).toList();
  }

  void _requireLoaded() {
    if (!isLoaded) throw EngineNotLoadedException();
  }
}
