// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'engine.dart';

/// Method names and payloads for the llama.cpp mobile host.
///
/// Native iOS/Android implement this channel. Until llama.cpp is linked,
/// `probe` is live and load/complete/embed return `llama_cpp_not_linked`.
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

  static const errorLlamaNotLinked = 'llama_cpp_not_linked';

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
