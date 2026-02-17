// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
  static const _baseUrl = 'http://127.0.0.1:$_port';

  final http.Client _http = http.Client();

  Process? _serverProcess;
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

  /// Path to the Python venv on the external drive (or bundled location).
  String? _venvPython;
  String? _servicesDir;

  String? _preferredModel;

  /// Initialize: find Python, start the inference service.
  /// On mobile platforms, this is a no-op — mobile uses MobileInferenceService.
  ///
  /// Resolution order:
  ///   1. Check if the service is already running at port 8100 (started by ProcessLauncher)
  ///   2. Try to start via Python venv (development mode)
  ///   3. Wait for ProcessLauncher to finish starting the bundled service
  ///   4. If still not ready, start a background retry loop
  Future<bool> init({String? preferredModel}) async {
    if (isMobile) {
      debugPrint('[splicellm] Skipping — not available on mobile');
      _available = false;
      notifyListeners();
      return false;
    }

    _preferredModel = preferredModel;

    // 1. Check if service is already running (e.g. started by ProcessLauncher)
    if (await _checkHealth()) {
      debugPrint('[splicellm] Service already running at $_baseUrl');
      _available = true;
      await _loadModels();
      await _autoSelectModel(preferredModel);
      notifyListeners();
      return true;
    }

    // 2. Try to start via Python venv (development mode)
    _resolveServicePaths();
    if (_venvPython != null && _servicesDir != null) {
      debugPrint('[splicellm] Starting via Python venv');
      final started = await _startService();
      if (started && preferredModel != null) {
        await _autoSelectModel(preferredModel);
      }
      return started;
    }

    // 3. ProcessLauncher may still be starting the bundled executable.
    //    Wait for the service to become healthy (up to 45s — supervisor does
    //    a full hardware scan + starts 7 child services sequentially).
    debugPrint('[splicellm] Waiting for backend to start...');
    _starting = true;
    notifyListeners();

    final healthy =
        await _waitForHealth(timeout: const Duration(seconds: 45));
    if (healthy) {
      debugPrint('[splicellm] Backend is now healthy');
      _available = true;
      _starting = false;
      await _loadModels();
      await _autoSelectModel(preferredModel);
      notifyListeners();
      return true;
    }

    // 4. Still not ready — start background retry loop so the service
    //    can be detected later (e.g. when user finishes onboarding).
    debugPrint('[splicellm] Backend not ready yet — continuing background retry');
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

  /// Resolve paths to the Python venv and services directory.
  void _resolveServicePaths() {
    // Try multiple locations for the services directory
    final candidates = <String>[
      // Development: relative to the Flutter project
      _joinPath(Directory.current.path, '..', 'services'),
      // Built app: bundled in Resources
      _joinPath(
          File(Platform.resolvedExecutable).parent.path,
          '..', 'Resources', 'services'),
      // External drive common location
      '/Volumes/External Drive/dev/projects/Studiomc/services',
    ];

    for (final dir in candidates) {
      final normalized = _normalizePath(dir);
      if (Directory(normalized).existsSync()) {
        _servicesDir = normalized;

        // Check for venv inside services dir
        final venvPython = _joinPath(normalized, '.venv', 'bin', 'python3');
        if (File(venvPython).existsSync()) {
          _venvPython = venvPython;
          debugPrint('[splicellm] Found venv at $venvPython');
          debugPrint('[splicellm] Services dir: $normalized');
          return;
        }
      }
    }

    // Fallback: try system Python
    try {
      final result = Process.runSync('which', ['python3']);
      if (result.exitCode == 0) {
        final systemPython = (result.stdout as String).trim();
        _venvPython = systemPython;
        debugPrint(
            '[splicellm] Using system Python: $systemPython');
      }
    } catch (_) {}
  }

  /// Start the Python inference service.
  Future<bool> _startService() async {
    if (_starting) return false;
    _starting = true;
    notifyListeners();

    // Kill any existing process on the port
    await _killExisting();

    try {
      debugPrint('[splicellm] Starting inference service...');
      debugPrint('[splicellm] Python: $_venvPython');
      debugPrint('[splicellm] Working dir: $_servicesDir');

      _serverProcess = await Process.start(
        _venvPython!,
        [
          '-m', 'uvicorn',
          'inference.app:app',
          '--host', '127.0.0.1',
          '--port', '$_port',
        ],
        workingDirectory: _servicesDir,
        environment: {
          ...Platform.environment,
          'PYTHONPATH': _servicesDir!,
        },
      );

      _serverProcess!.stdout
          .transform(utf8.decoder)
          .listen((data) => debugPrint('[splicellm] $data'));
      _serverProcess!.stderr
          .transform(utf8.decoder)
          .listen((data) => debugPrint('[studiomc-engine:err] $data'));

      _serverProcess!.exitCode.then((code) {
        debugPrint('[splicellm] Service exited: $code');
        _available = false;
        _serverProcess = null;
        notifyListeners();
      });

      // Wait for the service to become healthy
      final healthy =
          await _waitForHealth(timeout: const Duration(seconds: 30));

      if (healthy) {
        _available = true;
        await _loadModels();
        debugPrint('[splicellm] Service ready on port $_port');
      } else {
        debugPrint('[splicellm] Service failed to become healthy');
        _available = false;
      }

      _starting = false;
      notifyListeners();
      return healthy;
    } catch (e) {
      debugPrint('[splicellm] Failed to start: $e');
      _starting = false;
      _available = false;
      notifyListeners();
      return false;
    }
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
    } catch (_) {
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

  /// Stop the service.
  Future<void> stopServer() async {
    if (_serverProcess != null) {
      _serverProcess!.kill(ProcessSignal.sigterm);
      try {
        await _serverProcess!.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        _serverProcess!.kill(ProcessSignal.sigkill);
      }
      _serverProcess = null;
    }
    _available = false;
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

  Future<void> _killExisting() async {
    try {
      final result = await Process.run('lsof', ['-ti:$_port']);
      if (result.exitCode == 0) {
        final pids = (result.stdout as String).trim().split('\n');
        for (final pid in pids) {
          if (pid.isNotEmpty) {
            await Process.run('kill', ['-9', pid]);
          }
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    } catch (_) {}
  }

  String _joinPath(String a, String b, [String? c, String? d]) {
    var result = '$a/$b';
    if (c != null) result = '$result/$c';
    if (d != null) result = '$result/$d';
    return result;
  }

  String _normalizePath(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        return dir.resolveSymbolicLinksSync();
      }
    } catch (_) {}
    return path;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    stopServer();
    _http.close();
    super.dispose();
  }
}
