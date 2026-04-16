// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:studiomc_app/services/api_client.dart';
import '../utils/platform_utils.dart';

/// Manages the SpliceLLM Python inference service.
///
/// This is the engine that can run models of ANY size by streaming
/// layers from disk — even 20B+ models on 8GB machines.
///
/// On launch:
///   1. Locates the Python venv and services directory
///   2. Starts the FastAPI inference service via uvicorn on port 8100
///   3. Provides OpenAI-compatible API at http://127.0.0.1:8100
///
/// The service auto-detects Ollama, LM Studio, and uses the built-in
/// SpliceLLM as fallback for models too large for RAM.
class BundledInferenceService extends ChangeNotifier {
  static const _port = 8100;
  static final _baseUrl = ServiceUrls.inference;

  final http.Client _http = http.Client();

  bool _available = false;
  bool _starting = false;
  String? _activeModel;
  List<String> _localModels = [];

  double _tokPerS = 0.0;

  // ── Getters ──
  bool get available => _available;
  bool get starting => _starting;
  String? get activeModel => _activeModel;
  List<String> get localModels => List.unmodifiable(_localModels);
  double get tokPerS => _tokPerS;

  String? _preferredModel;

  /// Initialize: wait for the inference service to become available.
  /// On mobile platforms, this is a no-op — mobile uses MobileInferenceService.
  ///
  /// ProcessLauncher is responsible for starting the backend (supervisor +
  /// child services). This class only DETECTS the running service; it never
  /// launches its own process to avoid the race condition where both
  /// ProcessLauncher and this class compete to own port 8100.
  ///
  /// Resolution order:
  ///   1. Check if already running at port 8100
  ///   2. Wait up to 60s for ProcessLauncher to bring it online
  ///   3. Start a background retry loop (handles slow first-launch)
  Future<bool> init({String? preferredModel}) async {
    if (isMobile) {
      debugPrint('[splicellm] Skipping — not available on mobile');
      _available = false;
      notifyListeners();
      return false;
    }

    _preferredModel = preferredModel;

    // 1. Check if service is already running
    if (await _checkHealth()) {
      debugPrint('[splicellm] Service already running at $_baseUrl');
      _available = true;
      await _loadModels();
      await _autoSelectModel(preferredModel);
      notifyListeners();
      return true;
    }

    // 2. ProcessLauncher is starting the supervisor which spawns inference
    //    as a child service. Wait for it to become healthy.
    debugPrint('[splicellm] Waiting for inference service on port $_port...');
    _starting = true;
    notifyListeners();

    final healthy =
        await _waitForHealth(timeout: const Duration(seconds: 60));
    if (healthy) {
      debugPrint('[splicellm] Inference service is now healthy');
      _available = true;
      _starting = false;
      await _loadModels();
      await _autoSelectModel(preferredModel);
      notifyListeners();
      return true;
    }

    // 3. Still not ready — start background retry loop so the service
    //    can be detected later (e.g. when user finishes onboarding).
    debugPrint('[splicellm] Inference not ready yet — continuing background retry');
    _starting = true;
    _available = false;
    notifyListeners();
    _startBackgroundRetry();
    return false;
  }

  Timer? _retryTimer;

  /// Keeps checking for the backend in the background every 5 seconds.
  void _startBackgroundRetry() {
    _retryTimer?.cancel();
    int attempts = 0;
    const maxAttempts = 60; // 5 minutes max

    _retryTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      attempts++;
      if (_available || attempts > maxAttempts) {
        timer.cancel();
        if (!_available) {
          debugPrint('[splicellm] Background retry gave up after $attempts attempts');
          _starting = false;
          notifyListeners();
        }
        return;
      }

      if (await _checkHealth()) {
        timer.cancel();
        debugPrint('[splicellm] Backend came online (background attempt $attempts)');
        _available = true;
        _starting = false;
        await _loadModels();
        await _autoSelectModel(_preferredModel);
        notifyListeners();
      }
    });
  }

  /// Re-check if the backend is available now.
  /// Call this before showing "no backend" errors — the backend may have
  /// started after the initial init() timed out.
  Future<bool> recheckAvailability() async {
    if (_available) return true;
    if (isMobile) return false;

    debugPrint('[splicellm] Rechecking availability...');
    if (await _checkHealth()) {
      debugPrint('[splicellm] Backend is now available (recheck)');
      _available = true;
      _starting = false;
      _retryTimer?.cancel();
      await _loadModels();
      await _autoSelectModel(_preferredModel);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Auto-select a model on the backend.
  ///
  /// Tries the preferred model first. If that fails (e.g. GGUF not loaded),
  /// falls back to the first Ollama model, then the first available model.
  Future<void> _autoSelectModel(String? preferredModel) async {
    await _loadModels();

    // Strategy: try preferred model first, then Ollama (most reliable),
    // then any available model. For each, verify the selection actually worked.

    // 1. Try preferred model
    if (preferredModel != null && preferredModel.isNotEmpty) {
      // Check if it matches an Ollama model first (more reliable)
      final ollamaMatch = _localModels
          .where((id) =>
              id.startsWith('ollama/') &&
              id.toLowerCase().contains(preferredModel.toLowerCase().split(':').first))
          .firstOrNull;

      if (ollamaMatch != null) {
        debugPrint('[splicellm] Preferred model matches Ollama: $ollamaMatch');
        final ok = await selectModel(ollamaMatch);
        if (ok) return;
      }

      // Try the raw model ID
      final modelId = preferredModel
          .replaceAll('.gguf', '')
          .replaceAll('.bin', '')
          .toLowerCase()
          .replaceAll(' ', '-');

      debugPrint('[splicellm] Auto-selecting preferred model: $modelId');
      final ok = await selectModel(modelId);
      if (ok) return;
      debugPrint('[splicellm] Preferred model selection failed');
    }

    // 2. Fallback: pick the first Ollama model (most reliable)
    final ollamaModel = _localModels
        .where((id) => id.startsWith('ollama/'))
        .firstOrNull;
    if (ollamaModel != null) {
      debugPrint('[splicellm] Falling back to Ollama model: $ollamaModel');
      final ok = await selectModel(ollamaModel);
      if (ok) return;
    }

    // 3. Last resort: any available model
    for (final model in _localModels) {
      debugPrint('[splicellm] Trying model: $model');
      final ok = await selectModel(model);
      if (ok) return;
    }

    debugPrint('[splicellm] No model could be selected');
  }

  /// Load model list from the service.
  Future<void> _loadModels() async {
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/v1/models'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final models = data['data'] as List<dynamic>? ?? [];
        _localModels = models
            .map((m) => (m as Map<String, dynamic>)['id'] as String? ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        _activeModel = data['active_model'] as String?;
      }
    } catch (e) {
      debugPrint('[splicellm] Failed to load models: $e');
    }
  }

  /// Select and load a model for inference.
  Future<bool> selectModel(String modelId,
      {String? backend, String? modelPath}) async {
    try {
      final body = <String, dynamic>{'model_id': modelId};
      if (backend != null) body['backend'] = backend;

      final resp = await _http.post(
        Uri.parse('$_baseUrl/v1/models/select'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _activeModel = data['active_model'] as String? ?? modelId;
        notifyListeners();
        return true;
      }
      debugPrint(
          '[splicellm] Model select failed: ${resp.statusCode} ${resp.body}');
      return false;
    } catch (e) {
      debugPrint('[splicellm] Model select error: $e');
      return false;
    }
  }

  /// Stream a chat completion via SSE. Yields token strings.
  /// Messages may contain multimodal content (images) in OpenAI format.
  Stream<String> streamChat({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (!_available) {
      yield '[Error: SpliceLLM not running]';
      return;
    }

    final body = jsonEncode({
      'model': model ?? _activeModel ?? 'auto',
      'messages': messages,
      'stream': true,
    });

    final request = http.Request(
        'POST', Uri.parse('$_baseUrl/v1/chat/completions'));
    request.headers['content-type'] = 'application/json';
    request.body = body;

    http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (e) {
      yield '[Error: Could not connect to SpliceLLM — $e]';
      return;
    }

    if (response.statusCode != 200) {
      yield '[Error: Engine returned ${response.statusCode}]';
      return;
    }

    int totalTokens = 0;
    final stopwatch = Stopwatch()..start();

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      for (final line in chunk.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed == 'data: [DONE]') continue;
        if (!trimmed.startsWith('data: ')) continue;

        try {
          final json =
              jsonDecode(trimmed.substring(6)) as Map<String, dynamic>;
          final choices = json['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          final content = delta?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            totalTokens++;
            yield content;
          }
          final finishReason = choices[0]['finish_reason'];
          if (finishReason != null) {
            stopwatch.stop();
            if (stopwatch.elapsedMilliseconds > 0) {
              _tokPerS =
                  totalTokens / (stopwatch.elapsedMilliseconds / 1000.0);
              notifyListeners();
            }
          }
        } catch (_) {}
      }
    }
  }

  /// Non-streaming completion.
  Future<String?> chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async {
    if (!_available) return null;

    try {
      final resp = await _http.post(
        Uri.parse('$_baseUrl/v1/chat/completions'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'model': model ?? _activeModel ?? 'auto',
          'messages': messages,
          'stream': false,
        }),
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;
      return choices[0]['message']['content'] as String?;
    } catch (e) {
      debugPrint('[splicellm] Chat completion error: $e');
      return null;
    }
  }

  /// Friendly model name.
  String humanName(String path) {
    var name = path.split('/').last;
    name = name
        .replaceAll('.gguf', '')
        .replaceAll('.bin', '')
        .replaceAll(RegExp(r'-q\d.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]instruct', caseSensitive: false), '')
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .trim();
    name = name.split(' ').map((w) {
      if (w.isEmpty) return w;
      if (RegExp(r'^\d').hasMatch(w)) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
    return name.isEmpty ? path.split('/').last : name;
  }

  // Switch model (restarts if needed).
  Future<bool> switchModel(String modelId) async {
    return await selectModel(modelId);
  }

  // ── Private helpers ──

  Future<bool> _checkHealth() async {
    try {
      final resp = await _http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data['status'] == 'ok';
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _waitForHealth(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _checkHealth()) return true;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _http.close();
    super.dispose();
  }
}
