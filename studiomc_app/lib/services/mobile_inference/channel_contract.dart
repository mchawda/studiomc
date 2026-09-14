// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/services.dart';

import 'engine.dart';

/// Method names, payloads, and error codes for the llama.cpp mobile host.
///
/// Native iOS (`ios/Runner/AppDelegate.swift`) and Android
/// (`MobileInferenceHost.kt`) implement this channel. Until llama.cpp is
/// linked into the host, `probe` is live and every other method fails with
/// the typed `llama_cpp_not_linked` error. Generation on a phone today runs
/// through `FcllamaInferenceEngine`, which only asks this host for `probe`
/// and `embed`. `test/mobile_inference/channel_contract_test.dart` reads
/// both native sources and asserts they match these constants.
class MobileInferenceContract {
  static const methodChannel = 'studiomc.mobile_inference';
  static const tokenEventChannel = 'studiomc.mobile_inference/tokens';

  static const probe = 'probe';
  static const load = 'load';
  static const unload = 'unload';
  static const complete = 'complete';
  static const streamStart = 'streamStart';
  static const streamCancel = 'streamCancel';
  static const embed = 'embed';

  static const methods = <String>{
    probe,
    load,
    unload,
    complete,
    streamStart,
    streamCancel,
    embed,
  };

  /// Error codes the native host returns via `FlutterError` /
  /// `result.error`. iOS and Android must use these exact strings;
  /// `ChannelMobileInferenceEngine` maps them to typed exceptions.
  static const errorLlamaNotLinked = 'llama_cpp_not_linked';
  static const errorModelFileMissing = 'model_file_missing';
  static const errorNotLoaded = 'not_loaded';
  static const errorBadPayload = 'bad_payload';

  static const errorCodes = <String>{
    errorLlamaNotLinked,
    errorModelFileMissing,
    errorNotLoaded,
    errorBadPayload,
  };

  /// Turn a host-side [PlatformException] into the typed exception the
  /// engine interface documents. Unknown codes stay a
  /// [MobileInferenceHostException] so nothing is swallowed.
  static Exception decodeError(
    PlatformException error, {
    required String method,
    String? modelPath,
  }) {
    switch (error.code) {
      case errorLlamaNotLinked:
        return LlamaCppNotLinkedException(method, error.message);
      case errorModelFileMissing:
        return ModelFileMissingException(
          modelPath ?? error.details?.toString() ?? '',
        );
      case errorNotLoaded:
        return EngineNotLoadedException(error.message ?? 'not loaded');
      default:
        return MobileInferenceHostException(
          code: error.code,
          method: method,
          message: error.message,
        );
    }
  }

  static Map<String, dynamic> encodeLoad(LoadModelRequest request) {
    return {
      'modelId': request.modelId,
      'modelPath': request.modelPath,
      'nCtx': request.nCtx,
      'nGpuLayers': request.nGpuLayers,
    };
  }

  static Map<String, dynamic> encodeComplete(CompletionRequest request) {
    return {
      'prompt': request.resolvedPrompt,
      'maxTokens': request.maxTokens,
      'temperature': request.temperature,
      'stop': request.stop,
    };
  }

  static Map<String, dynamic> encodeEmbed(String text) => {'text': text};

  static Map<String, dynamic> encodeStreamCancel(String requestId) =>
      {'requestId': requestId};

  static HardwareCapabilities decodeProbe(Map<dynamic, dynamic> raw) {
    final accels = <Accelerator>{};
    final listed = raw['accelerators'];
    if (listed is List) {
      for (final item in listed) {
        final accel = _accelerator(item.toString());
        if (accel != null) accels.add(accel);
      }
    }
    if (accels.isEmpty) accels.add(Accelerator.cpu);

    return HardwareCapabilities(
      ramBytes: (raw['ramBytes'] as num?)?.toInt() ?? 0,
      deviceClass: _deviceClass(raw['deviceClass']?.toString()),
      accelerators: accels,
      chipName: raw['chipName'] as String?,
    );
  }

  static DeviceClass _deviceClass(String? value) {
    switch (value) {
      case 'tablet':
        return DeviceClass.tablet;
      case 'laptop':
        return DeviceClass.laptop;
      default:
        return DeviceClass.phone;
    }
  }

  static Accelerator? _accelerator(String value) {
    switch (value) {
      case 'neuralEngine':
        return Accelerator.neuralEngine;
      case 'nnapi':
        return Accelerator.nnapi;
      case 'metal':
        return Accelerator.metal;
      case 'vulkan':
        return Accelerator.vulkan;
      case 'gpu':
        return Accelerator.gpu;
      case 'cpu':
        return Accelerator.cpu;
      default:
        return null;
    }
  }
}
