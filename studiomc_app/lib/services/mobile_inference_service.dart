// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'mobile_inference/mobile_inference.dart';

/// On-device LLM inference for mobile (iOS/Android).
///
/// Provides the same streaming chat interface as BundledInferenceService
/// and LocalInferenceService, but runs the model directly on-device. No
/// Python, no Ollama, no server.
///
/// Generation goes through a single [MobileInferenceEngine] (by default
/// [createMobileInferenceEngine], the fcllama-backed llama.cpp engine on
/// iOS/Android). On-device RAG and any other engine consumer should reuse
/// [engine] so one loaded model serves the whole app.
///
/// This class owns what the engine does not: downloading GGUFs from
/// HuggingFace, the on-disk model list, the memory guard, and the
/// ChangeNotifier state the screens watch.
class MobileInferenceService extends ChangeNotifier {
  MobileInferenceService({
    MobileInferenceEngine? engine,
    Future<Directory> Function()? modelsDir,
  })  : _engine = engine ?? createMobileInferenceEngine(),
        _modelsDirProvider = modelsDir ?? _defaultModelsDir;

  final MobileInferenceEngine _engine;
  final Future<Directory> Function() _modelsDirProvider;
  bool _available = false;
  bool _loading = false;
  String? _activeModel;
  List<MobileModel> _downloadedModels = [];
  double _tokPerS = 0.0;

  /// The engine chat, RAG and diagnostics share. Loaded via [loadModel].
  MobileInferenceEngine get engine => _engine;

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

  /// Largest GGUF we will map on a phone. Anything bigger is refused up
  /// front instead of letting the OS kill the app mid-load.
  static const int maxModelSizeMb = 1500;

  /// Load a specific model for inference.
  Future<bool> loadModel(String filename) async {
    if (_loading) return false;
    _loading = true;
    notifyListeners();

    try {
      final modelsDir = await _modelsDirProvider();
      final modelPath = '${modelsDir.path}/$filename';

      final modelFile = File(modelPath);
      if (!modelFile.existsSync()) {
        debugPrint('[mobile-llm] Model file not found: $modelPath');
        return _failLoad();
      }

      final fileSizeMb = modelFile.lengthSync() / (1024 * 1024);
      if (fileSizeMb > maxModelSizeMb) {
        debugPrint(
            '[mobile-llm] Model too large (${fileSizeMb.toInt()} MB). '
            'Max $maxModelSizeMb MB on mobile.');
        _downloadError =
            'Model too large (${fileSizeMb.toInt()} MB). '
            'Try a smaller model like Studiomc 0.6B.';
        return _failLoad();
      }

      // Metal on iPhone/iPad; Android stays on CPU until the NNAPI/Vulkan
      // path is validated on real devices. The simulator has no Metal, but
      // fcllama falls back to CPU there on its own.
      final gpuLayers = Platform.isIOS ? 99 : 0;

      await _engine.load(LoadModelRequest(
        modelId: filename,
        modelPath: modelPath,
        nCtx: 1024, // smaller context to reduce memory
        nBatch: 256,
        nGpuLayers: gpuLayers,
      ));

      _activeModel = filename;
      _available = true;
      _loading = false;
      debugPrint('[mobile-llm] Model loaded: $filename');
      notifyListeners();
      return true;
    } on LlamaCppNotLinkedException catch (e) {
      debugPrint('[mobile-llm] $e');
      _downloadError = 'On-device inference is not available in this build.';
      return _failLoad();
    } catch (e) {
      debugPrint('[mobile-llm] Failed to load model: $e');
      return _failLoad();
    }
  }

  bool _failLoad() {
    _loading = false;
    _available = false;
    notifyListeners();
    return false;
  }

  /// Stream a chat completion. Yields token strings as they arrive.
  ///
  /// [messages] use the OpenAI shape (`role`, `content` as a string or a
  /// list of `{type: text}` parts). Errors arrive as a single
  /// `[Error: ...]` token so the chat UI keeps its existing contract.
  Stream<String> streamChat({
    required List<Map<String, dynamic>> messages,
    String? model,
  }) async* {
    if (!_available || !_engine.isLoaded) {
      yield 'No model loaded. Go to the Models tab to download and activate a model.';
      return;
    }

    final turns = toChatTurns(messages);
    try {
      yield* _engine.streamTokens(CompletionRequest(
        messages: turns,
        maxTokens: 1024,
        temperature: 0.7,
        stop: defaultStopSequences,
      ));
    } catch (e) {
      yield '[Error: Inference failed: $e]';
    } finally {
      final engine = _engine;
      if (engine is FcllamaInferenceEngine && engine.lastTokensPerSecond > 0) {
        _tokPerS = engine.lastTokensPerSecond;
        notifyListeners();
      }
    }
  }

  /// Flatten OpenAI-style messages (string or `{type: text}` parts) into
  /// plain chat turns. Image parts are dropped: mobile models are text only.
  @visibleForTesting
  static List<ChatTurn> toChatTurns(List<Map<String, dynamic>> messages) {
    return messages.map((msg) {
      final role = msg['role'] as String? ?? 'user';
      final rawContent = msg['content'];
      String content;
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
      return ChatTurn(role: role, content: content);
    }).toList();
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
        await _unloadQuietly();
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

  Future<Directory> _getModelsDir() => _modelsDirProvider();

  static Future<Directory> _defaultModelsDir() async {
    final appDir = await getApplicationSupportDirectory();
    final modelsDir = Directory('${appDir.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir;
  }

  Future<void> _unloadQuietly() async {
    try {
      await _engine.unload();
    } catch (e) {
      debugPrint('[mobile-llm] Unload failed: $e');
    }
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
    if (_engine.isLoaded) {
      // Fire and forget: dispose is synchronous, the release is not.
      unawaited(_unloadQuietly());
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
