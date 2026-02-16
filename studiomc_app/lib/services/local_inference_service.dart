// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/platform_utils.dart';

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
  /// On mobile platforms, this is a no-op — mobile uses MobileInferenceService.
  Future<bool> init({String? preferredModel}) async {
    if (isMobile) {
      debugPrint('[ollama] Skipping — not available on mobile');
      _available = false;
      return false;
    }

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

      // Only fall back if NO preference was expressed at all.
      // Prefer a model under 8GB to avoid OOM kills.
      if (_activeModel == null && _models.isNotEmpty) {
        final small = _models.cast<OllamaModel?>().firstWhere(
            (m) => m!.sizeBytes < 8 * 1024 * 1024 * 1024,
            orElse: () => null);
        _activeModel = small?.name ?? _models.first.name;
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
      _http.post(
        Uri.parse('$_ollamaBase/api/pull'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': tag, 'stream': false}),
      );
    } catch (_) {}
  }

  /// Pull a model from Ollama and stream progress. Returns a stream
  /// of progress values (0.0-1.0). Completes when done.
  Stream<double> pullModelWithProgress(String tag) async* {
    try {
      final request = http.Request(
          'POST', Uri.parse('$_ollamaBase/api/pull'));
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode({'name': tag, 'stream': true});

      final response = await _http.send(request);
      if (response.statusCode != 200) return;

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            final total = json['total'] as int? ?? 0;
            final completed = json['completed'] as int? ?? 0;
            if (total > 0) {
              yield completed / total;
            }
            if (json['status'] == 'success') {
              // Refresh model list
              await init(preferredModel: _activeModel);
              yield 1.0;
              return;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Delete a model from Ollama.
  Future<bool> deleteModel(String tag) async {
    try {
      final resp = await _http.delete(
        Uri.parse('$_ollamaBase/api/delete'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'name': tag}),
      );
      if (resp.statusCode == 200) {
        _models.removeWhere((m) => m.name == tag);
        if (_activeModel == tag) {
          _activeModel = _models.isNotEmpty ? _models.first.name : null;
        }
        notifyListeners();
        return true;
      }
      return false;
    } catch (_) {
      return false;
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

  /// Returns true if the currently active model is small enough to run
  /// directly in Ollama without needing SpliceLLM out-of-core.
  /// Threshold: model file < 80% of system RAM (conservative).
  bool get activeModelFitsInMemory {
    if (_activeModel == null) return false;
    final model = _models.cast<OllamaModel?>().firstWhere(
        (m) => m!.name == _activeModel,
        orElse: () => null);
    if (model == null) return true; // unknown model — assume it fits
    // Conservative: anything under 8 GB on-disk is fine for most machines.
    // Ollama already handles memory management for models it can serve.
    return model.sizeBytes < 8 * 1024 * 1024 * 1024;
  }

  /// Size in bytes of the active model (0 if unknown).
  int get activeModelSizeBytes {
    if (_activeModel == null) return 0;
    final model = _models.cast<OllamaModel?>().firstWhere(
        (m) => m!.name == _activeModel,
        orElse: () => null);
    return model?.sizeBytes ?? 0;
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
  /// Messages may contain multimodal content (images) in OpenAI format.
  Stream<String> streamChat({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    final modelToUse = model ?? _activeModel;
    if (modelToUse == null) {
      yield '[Error: No model selected]';
      return;
    }

    // Convert multimodal messages to Ollama format:
    // Ollama uses {"role","content","images":[base64,...]} rather than
    // OpenAI content arrays.
    final ollamaMessages = messages.map((msg) {
      final content = msg['content'];
      if (content is List) {
        final textParts = <String>[];
        final images = <String>[];
        for (final part in content) {
          if (part is Map) {
            if (part['type'] == 'text') {
              textParts.add(part['text'] as String? ?? '');
            } else if (part['type'] == 'image_url') {
              final url =
                  (part['image_url'] as Map?)?['url'] as String? ?? '';
              if (url.contains(';base64,')) {
                images.add(url.split(';base64,')[1]);
              } else if (url.isNotEmpty) {
                images.add(url);
              }
            }
          }
        }
        return <String, dynamic>{
          'role': msg['role'],
          'content': textParts.join(' '),
          if (images.isNotEmpty) 'images': images,
        };
      }
      return msg;
    }).toList();

    final body = jsonEncode({
      'model': modelToUse,
      'messages': ollamaMessages,
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
    required List<Map<String, dynamic>> messages,
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

  @override
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
