// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'engine.dart';

/// Host-side llama.cpp stand-in. Safe for CI; no phone or native lib.
class StubMobileInferenceEngine implements MobileInferenceEngine {
  StubMobileInferenceEngine({
    HardwareCapabilities? hardware,
    this.cannedCompletion = 'ok',
  }) : hardware = hardware ??
            const HardwareCapabilities(
              ramBytes: 8 * 1024 * 1024 * 1024,
              deviceClass: DeviceClass.phone,
              accelerators: {Accelerator.cpu},
              chipName: 'stub',
            );

  final HardwareCapabilities hardware;
  String cannedCompletion;
  String? lastPrompt;

  String? _modelId;
  String? _modelPath;

  @override
  bool get isLoaded => _modelId != null;

  @override
  String? get loadedModelId => _modelId;

  @override
  String? get loadedModelPath => _modelPath;

  @override
  Future<HardwareCapabilities> probe() async => hardware;

  @override
  Future<void> load(LoadModelRequest request) async {
    _modelId = request.modelId;
    _modelPath = request.modelPath;
  }

  @override
  Future<void> unload() async {
    _modelId = null;
    _modelPath = null;
  }

  @override
  Future<CompletionResult> complete(CompletionRequest request) async {
    _requireLoaded();
    lastPrompt = request.resolvedPrompt;
    final tokens = _tokenCount(cannedCompletion);
    return CompletionResult(
      text: cannedCompletion,
      promptTokens: _tokenCount(lastPrompt ?? ''),
      completionTokens: tokens,
    );
  }

  @override
  Stream<String> streamTokens(CompletionRequest request) async* {
    _requireLoaded();
    lastPrompt = request.resolvedPrompt;
    for (final token in _splitTokens(cannedCompletion)) {
      yield token;
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    _requireLoaded();
    return hashedEmbedding(text);
  }

  void _requireLoaded() {
    if (!isLoaded) throw EngineNotLoadedException();
  }

  int _tokenCount(String text) {
    if (text.trim().isEmpty) return 0;
    return _splitTokens(text).length;
  }

  List<String> _splitTokens(String text) {
    if (text.isEmpty) return const [];
    return RegExp(r'\S+|\s+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();
  }
}
