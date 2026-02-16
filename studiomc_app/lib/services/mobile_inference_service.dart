// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:fcllama/fllama.dart';
import 'package:fcllama/fllama_type.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-device LLM inference for mobile (iOS/Android) using fcllama (llama.cpp).
///
/// Provides the same streaming chat interface as BundledInferenceService
/// and LocalInferenceService, but runs the model directly on-device
/// using fcllama — no Python, no Ollama, no server.
///
/// Supports:
///   - Downloading GGUF models from HuggingFace
///   - Streaming token generation with GPU acceleration (Metal on iOS)
///   - Model management (list, delete, switch)
class MobileInferenceService extends ChangeNotifier {
  final FCllama? _llama = FCllama.instance();
  double? _contextId;
  bool _available = false;
  bool _loading = false;
  String? _activeModel;
  List<MobileModel> _downloadedModels = [];
  double _tokPerS = 0.0;

  // Download state
  double _downloadProgress = 0;
  String? _downloadingModel;
  String _downloadStatus = '';
  String? _downloadError;

  // ── Getters ──
  bool get available => _available;
  bool get loading => _loading;
  String? get activeModel => _activeModel;
  List<MobileModel> get downloadedModels =>
      List.unmodifiable(_downloadedModels);
  double get tokPerS => _tokPerS;
  double get downloadProgress => _downloadProgress;
  String? get downloadingModel => _downloadingModel;
  String get downloadStatus => _downloadStatus;
  String? get downloadError => _downloadError;

  /// Initialize the service: scan for downloaded models.
  /// Does NOT auto-load a model to avoid OOM on low-memory devices.
  /// Call [loadModel] explicitly when the user activates one.
  Future<bool> init({String? preferredModel}) async {
    await _scanDownloadedModels();

    if (_downloadedModels.isEmpty) {
      _available = false;
      notifyListeners();
      return false;
    }

    // Just mark that models are available; don't load yet
    notifyListeners();
    return true;
  }

  /// Load a specific model for inference.
  Future<bool> loadModel(String filename) async {
    if (_loading || _llama == null) return false;
    _loading = true;
    notifyListeners();

    try {
      // Release previous context
      if (_contextId != null) {
        await _llama.releaseContext(_contextId!);
        _contextId = null;
      }

      final modelsDir = await _getModelsDir();
      final modelPath = '${modelsDir.path}/$filename';

      if (!File(modelPath).existsSync()) {
        debugPrint('[mobile-llm] Model file not found: $modelPath');
        _loading = false;
        _available = false;
        notifyListeners();
        return false;
      }

      // Use GPU layers on real devices; 0 on simulator (no Metal)
      final gpuLayers = Platform.isIOS ? 99 : 0;

      final result = await _llama.initContext(
        modelPath,
        nCtx: 2048,
        nBatch: 512,
        nGpuLayers: gpuLayers,
        useMlock: true,
        useMmap: true,
        emitLoadProgress: true,
      );

      final ctxId = result?['contextId'];
      if (ctxId == null || (ctxId is num && ctxId <= 0)) {
        debugPrint('[mobile-llm] Failed to init context for: $filename');
        _loading = false;
        _available = false;
        notifyListeners();
        return false;
      }

      _contextId = (ctxId as num).toDouble();
      _activeModel = filename;
      _available = true;
      _loading = false;
      debugPrint('[mobile-llm] Model loaded: $filename (ctx=$_contextId)');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[mobile-llm] Failed to load model: $e');
      _available = false;
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  /// Stream a chat completion. Yields token strings as they arrive.
  Stream<String> streamChat({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (!_available || _contextId == null || _llama == null) {
      yield 'No model loaded. Go to the Models tab to download and activate a model.';
      return;
    }

    // Build the prompt using fcllama's getFormattedChat
    final roleContents = messages.map((msg) {
      final role = msg['role'] as String? ?? 'user';
      String content;
      final rawContent = msg['content'];
      if (rawContent is List) {
        final textParts = <String>[];
        for (final part in rawContent) {
          if (part is Map && part['type'] == 'text') {
            textParts.add(part['text'] as String? ?? '');
          }
        }
        content = textParts.join(' ');
      } else {
        content = rawContent as String? ?? '';
      }
      return RoleContent(role: role, content: content);
    }).toList();

    // Try to get a formatted prompt from the model's chat template
    String prompt;
    try {
      final formatted =
          await _llama.getFormattedChat(_contextId!, messages: roleContents);
      prompt = formatted ?? _buildChatMLPrompt(roleContents);
    } catch (_) {
      prompt = _buildChatMLPrompt(roleContents);
    }

    int totalTokens = 0;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();
    final tokenController = StreamController<String>();

    // Listen for streaming tokens
    StreamSubscription<Map<Object?, dynamic>>? sub;
    sub = _llama.onTokenStream?.listen((data) {
      final fn = data['function'] as String?;
      if (fn == 'completion') {
        final result = data['result'];
        if (result is Map) {
          final token = result['token'] as String?;
          if (token != null && token.isNotEmpty) {
            totalTokens++;
            tokenController.add(token);
          }
        }
      }
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    }, onError: (e) {
      if (!completer.isCompleted) completer.complete();
    });

    // Start completion
    try {
      _llama.completion(
        _contextId!,
        prompt: prompt,
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        nPredict: 1024,
        penaltyRepeat: 1.1,
        stop: ['<|im_end|>', '<|eot_id|>', '</s>'],
        emitRealtimeCompletion: true,
      ).then((_) {
        if (!completer.isCompleted) completer.complete();
      }).catchError((e) {
        if (!completer.isCompleted) completer.complete();
      });

      // Yield tokens as they arrive
      await for (final token in tokenController.stream) {
        yield token;
        if (completer.isCompleted) break;
      }

      // Wait for completion to finish
      await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {},
      );
    } catch (e) {
      yield '[Error: Inference failed — $e]';
    } finally {
      await sub?.cancel();
      await tokenController.close();
      stopwatch.stop();
      if (stopwatch.elapsedMilliseconds > 0 && totalTokens > 0) {
        _tokPerS = totalTokens / (stopwatch.elapsedMilliseconds / 1000.0);
        notifyListeners();
      }
    }
  }

  /// Non-streaming completion.
  Future<String?> chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async {
    final buffer = StringBuffer();
    await for (final token in streamChat(messages: messages, model: model)) {
      if (token.startsWith('[Error:')) return null;
      buffer.write(token);
    }
    return buffer.isEmpty ? null : buffer.toString();
  }

  /// Build ChatML prompt as fallback.
  String _buildChatMLPrompt(List<RoleContent> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      buf.writeln('<|im_start|>${msg.role}');
      buf.writeln(msg.content);
      buf.writeln('<|im_end|>');
    }
    buf.writeln('<|im_start|>assistant');
    return buf.toString();
  }

  // ── Model Download ──

  /// Download a GGUF model from a URL. Streams progress.
  Future<bool> downloadModel({
    required String url,
    required String filename,
    required String displayName,
  }) async {
    if (_downloadingModel != null) return false;

    _downloadingModel = filename;
    _downloadProgress = 0;
    _downloadStatus = 'Starting download...';
    _downloadError = null;
    notifyListeners();

    try {
      final modelsDir = await _getModelsDir();
      final destFile = File('${modelsDir.path}/$filename');

      int existingBytes = 0;
      if (await destFile.exists()) {
        existingBytes = await destFile.length();
      }

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      client.autoUncompress = false;

      final request = await client.getUrl(Uri.parse(url));
      if (existingBytes > 0) {
        request.headers.add('Range', 'bytes=$existingBytes-');
      }

      final response = await request.close();

      if (response.statusCode == 416) {
        _downloadingModel = null;
        await _scanDownloadedModels();
        notifyListeners();
        return true;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('HTTP ${response.statusCode}');
      }

      int totalBytes = 0;
      if (response.statusCode == 206) {
        final contentRange = response.headers.value('content-range') ?? '';
        if (contentRange.contains('/')) {
          final total = contentRange.split('/').last;
          if (total != '*') totalBytes = int.parse(total);
        }
      } else {
        totalBytes = response.contentLength;
        existingBytes = 0;
      }

      int receivedBytes = existingBytes;
      final fileMode =
          response.statusCode == 206 ? FileMode.append : FileMode.write;
      final raf = await destFile.open(mode: fileMode);
      final stopwatch = Stopwatch()..start();

      try {
        await for (final chunk in response) {
          await raf.writeFrom(chunk);
          receivedBytes += chunk.length;

          final progress =
              totalBytes > 0 ? receivedBytes / totalBytes : 0.0;
          final sessionMb = (receivedBytes - existingBytes) / (1024 * 1024);
          final seconds = stopwatch.elapsedMilliseconds / 1000;
          final speed = seconds > 0 ? sessionMb / seconds : 0.0;

          _downloadProgress = progress;
          _downloadStatus =
              '${(receivedBytes / (1024 * 1024)).toStringAsFixed(0)} MB'
              '${totalBytes > 0 ? " / ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB" : ""}'
              ' — ${speed.toStringAsFixed(1)} MB/s';
          notifyListeners();
        }
      } finally {
        await raf.close();
        client.close();
      }

      _downloadingModel = null;
      _downloadProgress = 1.0;
      _downloadStatus = 'Complete';
      await _scanDownloadedModels();
      notifyListeners();
      return true;
    } catch (e) {
      _downloadError = 'Download failed: $e';
      _downloadingModel = null;
      notifyListeners();
      return false;
    }
  }

  /// Delete a downloaded model.
  Future<bool> deleteModel(String filename) async {
    try {
      final modelsDir = await _getModelsDir();
      final file = File('${modelsDir.path}/$filename');
      if (await file.exists()) {
        await file.delete();
      }

      if (_activeModel == filename) {
        if (_contextId != null) {
          _llama?.releaseContext(_contextId!);
        }
        _contextId = null;
        _activeModel = null;
        _available = false;
      }

      await _scanDownloadedModels();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[mobile-llm] Delete failed: $e');
      return false;
    }
  }

  // ── Private helpers ──

  Future<void> _scanDownloadedModels() async {
    try {
      final modelsDir = await _getModelsDir();
      if (!await modelsDir.exists()) {
        _downloadedModels = [];
        return;
      }

      _downloadedModels = await modelsDir
          .list()
          .where((f) => f.path.endsWith('.gguf'))
          .asyncMap((f) async {
        final stat = await f.stat();
        return MobileModel(
          filename: f.path.split('/').last,
          sizeBytes: stat.size,
        );
      }).toList();
    } catch (_) {
      _downloadedModels = [];
    }
  }

  Future<Directory> _getModelsDir() async {
    final appDir = await getApplicationSupportDirectory();
    final modelsDir = Directory('${appDir.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir;
  }

  /// Friendly display name from GGUF filename.
  String humanName(String filename) {
    var name = filename
        .replaceAll('.gguf', '')
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
    return name.isEmpty ? filename : name;
  }

  @override
  void dispose() {
    if (_contextId != null) {
      _llama?.releaseContext(_contextId!);
    }
    super.dispose();
  }
}

/// A downloaded model on device.
class MobileModel {
  final String filename;
  final int sizeBytes;

  const MobileModel({required this.filename, required this.sizeBytes});

  String get sizeLabel {
    if (sizeBytes > 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}
