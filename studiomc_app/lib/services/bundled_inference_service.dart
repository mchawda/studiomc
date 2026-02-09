import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Manages the bundled llama-server binary — zero external dependencies.
///
/// On launch:
///   1. Locates llama-server in the app bundle Resources/bin/
///   2. Starts it on a local port with the active model
///   3. Provides an OpenAI-compatible API at http://127.0.0.1:{port}
///
/// Models are GGUF files downloaded from HuggingFace, stored in
/// ~/Library/Application Support/com.studiomc/models/
class BundledInferenceService extends ChangeNotifier {
  static const _defaultPort = 8690;
  static const _baseUrl = 'http://127.0.0.1:$_defaultPort';

  final http.Client _http = http.Client();

  Process? _serverProcess;
  bool _available = false;
  bool _starting = false;
  String? _activeModel; // Full path to loaded GGUF
  String? _activeModelName; // Friendly name
  List<String> _localModels = []; // Paths to available GGUF files

  double _tokPerS = 0.0;

  // ── Getters ──
  bool get available => _available;
  bool get starting => _starting;
  String? get activeModel => _activeModelName;
  String? get activeModelPath => _activeModel;
  List<String> get localModels => List.unmodifiable(_localModels);
  double get tokPerS => _tokPerS;

  /// Initialize: scan for local models, optionally start server with preferred model.
  Future<bool> init({String? preferredModel}) async {
    await _scanLocalModels();

    // Resolve preferred model to a local GGUF path
    String? modelPath;
    if (preferredModel != null) {
      modelPath = _resolveModel(preferredModel);
    }
    modelPath ??= _localModels.isNotEmpty ? _localModels.first : null;

    if (modelPath == null) {
      // No models available — service ready but not running
      _available = false;
      notifyListeners();
      return false;
    }

    return await startServer(modelPath);
  }

  /// Scan the models directory for GGUF files.
  Future<void> _scanLocalModels() async {
    final modelsDir = await _modelsDirectory();
    if (!await modelsDir.exists()) {
      _localModels = [];
      return;
    }

    final models = <String>[];
    await for (final entity in modelsDir.list()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.gguf')) {
        models.add(entity.path);
      }
    }
    _localModels = models;
  }

  /// Start llama-server with a specific model.
  Future<bool> startServer(String modelPath) async {
    if (_starting) return false;
    _starting = true;
    notifyListeners();

    // Kill existing server if running
    await stopServer();

    final serverBin = _findServerBinary();
    if (serverBin == null) {
      debugPrint('[bundled-inference] llama-server binary not found');
      _starting = false;
      notifyListeners();
      return false;
    }

    try {
      final binDir = File(serverBin).parent.path;

      // Set DYLD_LIBRARY_PATH so llama-server can find its dylibs
      final env = Map<String, String>.from(Platform.environment);
      env['DYLD_LIBRARY_PATH'] = binDir;

      _serverProcess = await Process.start(
        serverBin,
        [
          '--model', modelPath,
          '--host', '127.0.0.1',
          '--port', '$_defaultPort',
          '--ctx-size', '4096',
          '--n-gpu-layers', '99', // Use Metal/GPU fully
          '--flash-attn', // Enable flash attention
        ],
        environment: env,
      );

      _serverProcess!.stdout
          .transform(utf8.decoder)
          .listen((data) => debugPrint('[llama-server] $data'));
      _serverProcess!.stderr
          .transform(utf8.decoder)
          .listen((data) => debugPrint('[llama-server:err] $data'));

      _serverProcess!.exitCode.then((code) {
        debugPrint('[bundled-inference] llama-server exited: $code');
        _available = false;
        _serverProcess = null;
        notifyListeners();
      });

      // Wait for server to become healthy
      final healthy = await _waitForHealth(timeout: const Duration(seconds: 30));

      _activeModel = modelPath;
      _activeModelName = _friendlyName(modelPath);
      _available = healthy;
      _starting = false;
      notifyListeners();
      return healthy;
    } catch (e) {
      debugPrint('[bundled-inference] Failed to start: $e');
      _starting = false;
      _available = false;
      notifyListeners();
      return false;
    }
  }

  /// Switch to a different model (restarts server).
  Future<bool> switchModel(String modelPath) async {
    return await startServer(modelPath);
  }

  /// Stop the server.
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

  /// Stream a chat completion. Yields token strings.
  Stream<String> streamChat({
    required List<Map<String, String>> messages,
  }) async* {
    if (!_available) {
      yield '[Error: Inference engine not running]';
      return;
    }

    final body = jsonEncode({
      'model': _activeModelName ?? 'local',
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
      yield '[Error: Could not connect to inference engine — $e]';
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
          // Check for finish_reason
          final finishReason = choices[0]['finish_reason'];
          if (finishReason != null) {
            stopwatch.stop();
            if (stopwatch.elapsedMilliseconds > 0) {
              _tokPerS =
                  totalTokens / (stopwatch.elapsedMilliseconds / 1000.0);
              notifyListeners();
            }
          }
        } catch (_) {
          // Skip malformed SSE lines
        }
      }
    }
  }

  /// Non-streaming completion.
  Future<String?> chatCompletion({
    required List<Map<String, String>> messages,
  }) async {
    if (!_available) return null;

    try {
      final resp = await _http.post(
        Uri.parse('$_baseUrl/v1/chat/completions'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'model': _activeModelName ?? 'local',
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

  /// Friendly model name from GGUF file path.
  String humanName(String path) => _friendlyName(path);

  // ── Private helpers ──

  Future<bool> _waitForHealth({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await _http
            .get(Uri.parse('$_baseUrl/health'))
            .timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          if (data['status'] == 'ok') return true;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  String? _findServerBinary() {
    // 1. Check app bundle Resources/bin/
    final executable = Platform.resolvedExecutable;
    final appDir = File(executable).parent.path;
    // In a macOS .app: .app/Contents/MacOS/studiomc_app
    // Resources at: .app/Contents/Frameworks/App.framework/Resources/
    // But we put binaries in: .app/Contents/Resources/bin/
    final bundledPath = '$appDir/../Resources/bin/llama-server';
    if (File(bundledPath).existsSync()) return bundledPath;

    // 2. Check relative to project (development)
    // When running via `flutter run`, executable is in build/macos/...
    final devPaths = [
      '$appDir/../../../../../../macos/Runner/Resources/bin/llama-server',
      // Direct path for development
      '${Directory.current.path}/macos/Runner/Resources/bin/llama-server',
    ];
    for (final p in devPaths) {
      if (File(p).existsSync()) return p;
    }

    // 3. Check PATH (fallback, e.g. if user installed llama.cpp)
    try {
      final result = Process.runSync('which', ['llama-server']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (_) {}

    return null;
  }

  Future<Directory> _modelsDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory('${appDir.path}/models');
  }

  /// Resolve a model preference (GGUF filename, path, or partial name) to a local path.
  String? _resolveModel(String preference) {
    // Exact path
    if (File(preference).existsSync()) return preference;

    // Match by filename
    final lower = preference.toLowerCase();
    for (final path in _localModels) {
      final filename = path.split('/').last.toLowerCase();
      if (filename == lower || filename.contains(lower)) return path;
    }
    return null;
  }

  /// Convert GGUF path to friendly name.
  String _friendlyName(String path) {
    var name = path.split('/').last;
    name = name
        .replaceAll('.gguf', '')
        .replaceAll('.bin', '')
        .replaceAll(RegExp(r'-q\d.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]instruct', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]chat', caseSensitive: false), '')
        .replaceAll(RegExp(r'Meta-', caseSensitive: false), '')
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .trim();
    // Title case
    name = name.split(' ').map((w) {
      if (w.isEmpty) return w;
      if (RegExp(r'^\d').hasMatch(w)) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
    return name.isEmpty ? path.split('/').last : name;
  }

  @override
  void dispose() {
    stopServer();
    _http.close();
    super.dispose();
  }
}
