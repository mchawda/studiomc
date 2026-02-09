import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Provides local LLM inference via Ollama's API.
///
/// Ollama exposes an OpenAI-compatible API at http://127.0.0.1:11434.
/// This service auto-detects Ollama, lists available models, and
/// provides streaming chat completions — zero backend required.
class LocalInferenceService extends ChangeNotifier {
  static const _ollamaBase = 'http://127.0.0.1:11434';
  final http.Client _http = http.Client();

  bool _available = false;
  bool get available => _available;

  String? _activeModel;
  String? get activeModel => _activeModel;

  List<OllamaModel> _models = [];
  List<OllamaModel> get models => List.unmodifiable(_models);

  double _tokPerS = 0.0;
  double get tokPerS => _tokPerS;

  /// Probe Ollama and list models. Call once at startup.
  /// Probe Ollama. If [preferredModel] is set (e.g. from settings),
  /// select it if available, or pull it via Ollama if needed.
  Future<bool> init({String? preferredModel}) async {
    try {
      final resp = await _http
          .get(Uri.parse('$_ollamaBase/api/tags'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) {
        _available = false;
        return false;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = data['models'] as List<dynamic>? ?? [];
      _models = list.map((m) => OllamaModel.fromJson(m)).toList();
      _available = true;

      // Map GGUF filenames (from onboarding) to Ollama model tags
      final ollamaTag = _ggufToOllamaTag(preferredModel);

      // Try to find the preferred model in Ollama's list
      if (ollamaTag != null) {
        final match = _models.cast<OllamaModel?>().firstWhere(
            (m) => m!.name == ollamaTag ||
                m.name.startsWith(ollamaTag.split(':').first),
            orElse: () => null);
        if (match != null) {
          _activeModel = match.name;
        } else {
          // Model not in Ollama yet — pull it in the background
          _pullModel(ollamaTag);
        }
      }

      // Only fall back to first model if NO preference was expressed at all
      if (_activeModel == null && _models.isNotEmpty) {
        _activeModel = _models.first.name;
      }
      notifyListeners();
      return true;
    } catch (_) {
      // Try to start Ollama
      try {
        await _startOllama();
        return await init(preferredModel: preferredModel); // retry once
      } catch (_) {
        _available = false;
        return false;
      }
    }
  }

  /// Map a GGUF filename or Ollama tag to a known Ollama model tag.
  String? _ggufToOllamaTag(String? name) {
    if (name == null || name.isEmpty) return null;
    // Already an Ollama tag (contains colon)
    if (name.contains(':')) return name;
    final lower = name.toLowerCase();
    // Map common GGUF filenames to Ollama tags
    if (lower.contains('llama-3.2') || lower.contains('llama3.2')) {
      if (lower.contains('1b')) return 'llama3.2:1b';
      if (lower.contains('3b')) return 'llama3.2:3b';
      if (lower.contains('8b')) return 'llama3.2';  // 8B is the default size
      return 'llama3.2';
    }
    if (lower.contains('llama-3.1') || lower.contains('llama3.1')) {
      if (lower.contains('8b')) return 'llama3.1:8b';
      return 'llama3.1';
    }
    if (lower.contains('mistral')) return 'mistral';
    if (lower.contains('phi-3') || lower.contains('phi3')) return 'phi3';
    if (lower.contains('phi-2') || lower.contains('phi2')) return 'phi';
    if (lower.contains('qwen')) {
      if (lower.contains('3')) return 'qwen3';
      return 'qwen2.5';
    }
    if (lower.contains('gemma')) return 'gemma2';
    // Can't determine — return name as-is
    return name;
  }

  /// Pull a model from Ollama in the background. Non-blocking.
  Future<void> _pullModel(String tag) async {
    try {
      // Fire-and-forget pull request
      _http.post(
        Uri.parse('$_ollamaBase/api/pull'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': tag, 'stream': false}),
      );
    } catch (_) {
      // Ignore pull errors — user can still use whatever models are available
    }
  }

  Future<void> _startOllama() async {
    // Try to launch ollama serve in the background
    final result = await Process.run('which', ['ollama']);
    if (result.exitCode != 0) throw Exception('Ollama not installed');

    final ollamaPath = (result.stdout as String).trim();
    // Start ollama serve (it auto-backgrounds)
    await Process.start(ollamaPath, ['serve'],
        mode: ProcessStartMode.detached);
    // Give it a moment to start
    await Future.delayed(const Duration(seconds: 2));
  }

  /// Select a model by exact Ollama tag.
  void selectModel(String name) {
    _activeModel = name;
    notifyListeners();
  }

  /// Select a model using the user's stored preference (GGUF filename or
  /// Ollama tag). Maps the preference to an Ollama tag and switches if found.
  void selectModelByPreference(String preference) {
    final tag = _ggufToOllamaTag(preference);
    if (tag == null) return;
    final match = _findModelMatch(tag);
    if (match != null && match.name != _activeModel) {
      _activeModel = match.name;
      notifyListeners();
    }
  }

  /// Find a model in the local list matching an Ollama tag prefix.
  OllamaModel? _findModelMatch(String tag) {
    return _models.cast<OllamaModel?>().firstWhere(
        (m) => m!.name == tag || m.name.startsWith('$tag:') || m.name.startsWith(tag),
        orElse: () => null);
  }

  /// Friendly display name from Ollama model tag.
  String humanName(String tag) {
    // "qwen3-vl:4b" → "Qwen3 VL 4B"
    // "llama3.2:8b" → "Llama3.2 8B"
    final base = tag.split(':').first;
    final variant = tag.contains(':') ? tag.split(':').last : '';
    final pretty = base
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty
            ? '${w[0].toUpperCase()}${w.substring(1)}'
            : '')
        .join(' ');
    return variant.isNotEmpty
        ? '$pretty ${variant.toUpperCase()}'
        : pretty;
  }

  /// Stream a chat completion. Yields token strings as they arrive.
  Stream<String> streamChat({
    required List<Map<String, String>> messages,
    String? model,
  }) async* {
    final modelToUse = model ?? _activeModel;
    if (modelToUse == null) {
      yield '[Error: No model selected]';
      return;
    }

    final body = jsonEncode({
      'model': modelToUse,
      'messages': messages,
      'stream': true,
    });

    final request = http.Request(
        'POST', Uri.parse('$_ollamaBase/api/chat'));
    request.headers['content-type'] = 'application/json';
    request.body = body;

    http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (e) {
      yield '[Error: Could not connect to Ollama — $e]';
      return;
    }

    if (response.statusCode != 200) {
      yield '[Error: Ollama returned ${response.statusCode}]';
      return;
    }

    int totalTokens = 0;
    final stopwatch = Stopwatch()..start();

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      // Ollama streams newline-delimited JSON
      for (final line in chunk.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final msg = json['message'] as Map<String, dynamic>?;
          final content = msg?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            totalTokens++;
            yield content;
          }
          if (json['done'] == true) {
            stopwatch.stop();
            if (stopwatch.elapsedMilliseconds > 0) {
              _tokPerS = totalTokens /
                  (stopwatch.elapsedMilliseconds / 1000.0);
              notifyListeners();
            }
          }
        } catch (_) {
          // Skip malformed lines
        }
      }
    }
  }

  /// Non-streaming completion.
  Future<String?> chatCompletion({
    required List<Map<String, String>> messages,
    String? model,
  }) async {
    final modelToUse = model ?? _activeModel;
    if (modelToUse == null) return null;

    try {
      final resp = await _http.post(
        Uri.parse('$_ollamaBase/api/chat'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'model': modelToUse,
          'messages': messages,
          'stream': false,
        }),
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return (data['message'] as Map<String, dynamic>?)?['content'] as String?;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _http.close();
    super.dispose();
  }
}

/// Minimal model descriptor from Ollama's /api/tags response.
class OllamaModel {
  final String name;
  final String family;
  final String parameterSize;
  final String quantization;
  final int sizeBytes;

  OllamaModel({
    required this.name,
    required this.family,
    required this.parameterSize,
    required this.quantization,
    required this.sizeBytes,
  });

  factory OllamaModel.fromJson(Map<String, dynamic> json) {
    final details = json['details'] as Map<String, dynamic>? ?? {};
    return OllamaModel(
      name: json['name'] as String? ?? '',
      family: details['family'] as String? ?? '',
      parameterSize: details['parameter_size'] as String? ?? '',
      quantization: details['quantization_level'] as String? ?? '',
      sizeBytes: json['size'] as int? ?? 0,
    );
  }
}
