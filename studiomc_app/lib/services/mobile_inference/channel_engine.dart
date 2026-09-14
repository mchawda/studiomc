// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:flutter/services.dart';

import 'channel_contract.dart';
import 'engine.dart';

/// MobileInferenceEngine over the llama.cpp platform channel.
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

  @override
  Future<HardwareCapabilities> probe() async {
    final raw = await _methods.invokeMapMethod<String, dynamic>(
      MobileInferenceContract.probe,
    );
    if (raw == null) {
      return const HardwareCapabilities(
        ramBytes: 0,
        deviceClass: DeviceClass.phone,
      );
    }
    return MobileInferenceContract.decodeProbe(raw);
  }

  @override
  Future<void> load(LoadModelRequest request) async {
    final raw = await _methods.invokeMapMethod<String, dynamic>(
      MobileInferenceContract.load,
      MobileInferenceContract.encodeLoad(request),
    );
    if (raw?['ok'] != true) {
      throw ModelFileMissingException(request.modelPath);
    }
    _modelId = request.modelId;
    _modelPath = request.modelPath;
  }

  @override
  Future<void> unload() async {
    await _methods.invokeMapMethod<String, dynamic>(
      MobileInferenceContract.unload,
    );
    _modelId = null;
    _modelPath = null;
  }

  @override
  Future<CompletionResult> complete(CompletionRequest request) async {
    _requireLoaded();
    final raw = await _methods.invokeMapMethod<String, dynamic>(
      MobileInferenceContract.complete,
      MobileInferenceContract.encodeComplete(request),
    );
    return CompletionResult(
      text: raw?['text'] as String? ?? '',
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
    }, onError: controller.addError, onDone: () {
      if (!controller.isClosed) controller.close();
    });

    try {
      final raw = await _methods.invokeMapMethod<String, dynamic>(
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
        } catch (_) {}
      }
      await sub.cancel();
      if (!controller.isClosed) await controller.close();
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    _requireLoaded();
    final raw = await _methods.invokeMapMethod<String, dynamic>(
      MobileInferenceContract.embed,
      MobileInferenceContract.encodeEmbed(text),
    );
    final vector = raw?['vector'];
    if (vector is! List) return const [];
    return vector.map((v) => (v as num).toDouble()).toList();
  }

  void _requireLoaded() {
    if (!isLoaded) throw EngineNotLoadedException();
  }
}
