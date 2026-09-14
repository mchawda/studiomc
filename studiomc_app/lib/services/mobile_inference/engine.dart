// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:math';

/// On-device form factor used by the mobile size policy.
enum DeviceClass { phone, tablet, laptop }

/// Accelerators the llama.cpp host can report.
enum Accelerator {
  neuralEngine,
  nnapi,
  metal,
  vulkan,
  gpu,
  cpu,
}

/// Snapshot of RAM and neural hardware. No Python sidecar.
class HardwareCapabilities {
  final int ramBytes;
  final DeviceClass deviceClass;
  final Set<Accelerator> accelerators;
  final String? chipName;

  const HardwareCapabilities({
    required this.ramBytes,
    required this.deviceClass,
    this.accelerators = const {Accelerator.cpu},
    this.chipName,
  });

  bool get hasNeuralAccel =>
      accelerators.contains(Accelerator.neuralEngine) ||
      accelerators.contains(Accelerator.nnapi);

  int get ramGb => ramBytes ~/ (1024 * 1024 * 1024);
}

class ChatTurn {
  final String role;
  final String content;

  const ChatTurn({required this.role, required this.content});
}

class LoadModelRequest {
  final String modelId;
  final String modelPath;
  final int nCtx;
  final int nBatch;
  final int nGpuLayers;

  /// Per-model chat template kwargs (mirrors `chat_template_kwargs` in
  /// `services/model_manager/registry.py`). Merged under any kwargs a
  /// [CompletionRequest] carries; the catalog supplies defaults for known
  /// ids so callers rarely need to set this.
  final Map<String, Object?> chatTemplateKwargs;

  const LoadModelRequest({
    required this.modelId,
    required this.modelPath,
    this.nCtx = 1024,
    this.nBatch = 256,
    this.nGpuLayers = 99,
    this.chatTemplateKwargs = const {},
  });
}

/// Stop strings shared by every ChatML / Llama 3 / Mistral style GGUF we ship.
const List<String> defaultStopSequences = ['<|im_end|>', '<|eot_id|>', '</s>'];

class CompletionRequest {
  final String? prompt;
  final List<ChatTurn> messages;
  final int maxTokens;
  final double temperature;
  final List<String> stop;

  /// Chat template kwargs for this request. `enable_thinking: false`
  /// turns a Qwen3 hybrid model into a plain instruct model by emitting an
  /// empty `<think></think>` block, exactly as the Jinja template does.
  final Map<String, Object?> chatTemplateKwargs;

  const CompletionRequest({
    this.prompt,
    this.messages = const [],
    this.maxTokens = 256,
    this.temperature = 0.7,
    this.stop = const [],
    this.chatTemplateKwargs = const {},
  });

  /// True when the engine must build a prompt from [messages].
  bool get isChat => (prompt == null || prompt!.isEmpty) && messages.isNotEmpty;

  String get resolvedPrompt {
    if (prompt != null && prompt!.isNotEmpty) return prompt!;
    if (messages.isEmpty) return '';
    return chatMlPrompt(messages);
  }
}

/// ChatML rendering used when the model ships no template llama.cpp can
/// apply. Ends with the open assistant header so generation continues it.
String chatMlPrompt(List<ChatTurn> messages) {
  final buf = StringBuffer();
  for (final turn in messages) {
    buf.writeln('<|im_start|>${turn.role}');
    buf.writeln(turn.content);
    buf.writeln('<|im_end|>');
  }
  buf.writeln('<|im_start|>assistant');
  return buf.toString();
}

/// Empty reasoning block Qwen3's template emits for `enable_thinking=false`.
const String qwen3NoThinkSuffix = '<think>\n\n</think>\n\n';

/// Apply the chat template kwargs llama.cpp's legacy
/// `llama_chat_apply_template` cannot: it is a fixed template matcher with
/// no Jinja variables, so `enable_thinking=false` must be reproduced by
/// hand on the rendered assistant header. Only kwargs with a known
/// rendering are applied; unknown keys are ignored on purpose.
String applyChatTemplateKwargs(
  String renderedPrompt,
  Map<String, Object?> kwargs,
) {
  var prompt = renderedPrompt;
  if (kwargs['enable_thinking'] == false &&
      !prompt.trimRight().endsWith('</think>')) {
    prompt = '${prompt.trimRight()}\n$qwen3NoThinkSuffix';
  }
  return prompt;
}

class CompletionResult {
  final String text;
  final int promptTokens;
  final int completionTokens;

  const CompletionResult({
    required this.text,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

class EngineNotLoadedException implements Exception {
  final String message;
  EngineNotLoadedException([this.message = 'No on-device model is loaded']);

  @override
  String toString() => 'EngineNotLoadedException: $message';
}

class ModelFileMissingException implements Exception {
  final String path;
  ModelFileMissingException(this.path);

  @override
  String toString() => 'ModelFileMissingException: $path';
}

/// The native host answered `llama_cpp_not_linked`: the app was built
/// without the llama.cpp library, so on-device generation cannot run.
/// Callers should fall back to the stub or a remote backend and tell the
/// user, never retry silently.
class LlamaCppNotLinkedException implements Exception {
  final String method;
  final String? hostMessage;
  LlamaCppNotLinkedException(this.method, [this.hostMessage]);

  @override
  String toString() =>
      'LlamaCppNotLinkedException: llama.cpp is not linked on this build '
      '(method=$method)${hostMessage == null ? '' : ': $hostMessage'}';
}

/// Any other structured failure from the native host (bad payload,
/// unknown code). Carries the raw code so logs stay actionable.
class MobileInferenceHostException implements Exception {
  final String code;
  final String method;
  final String? message;
  MobileInferenceHostException({
    required this.code,
    required this.method,
    this.message,
  });

  @override
  String toString() =>
      'MobileInferenceHostException($code) in $method'
      '${message == null ? '' : ': $message'}';
}

/// llama.cpp (or a host-side stub) without a Python process.
abstract class MobileInferenceEngine {
  Future<HardwareCapabilities> probe();

  Future<void> load(LoadModelRequest request);

  Future<void> unload();

  bool get isLoaded;

  String? get loadedModelId;

  String? get loadedModelPath;

  Future<CompletionResult> complete(CompletionRequest request);

  Stream<String> streamTokens(CompletionRequest request);

  Future<List<double>> embed(String text);
}

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (sqrt(na) * sqrt(nb));
}

/// Deterministic bag-of-words embedding used by the stub and RAG tests.
List<double> hashedEmbedding(String text, {int dim = 32}) {
  final vec = List<double>.filled(dim, 0);
  final tokens = text.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
  for (final raw in tokens) {
    if (raw.isEmpty) continue;
    _accumulate(vec, raw.hashCode);
    if (raw.length >= 4) {
      _accumulate(vec, raw.substring(0, 4).hashCode);
    }
    if (raw.length >= 6) {
      _accumulate(vec, raw.substring(0, 6).hashCode);
    }
  }
  var norm = 0.0;
  for (final v in vec) {
    norm += v * v;
  }
  if (norm > 0) {
    final scale = 1 / sqrt(norm);
    for (var i = 0; i < vec.length; i++) {
      vec[i] *= scale;
    }
  }
  return vec;
}

void _accumulate(List<double> vec, int hash) {
  vec[hash.abs() % vec.length] += 1;
}
