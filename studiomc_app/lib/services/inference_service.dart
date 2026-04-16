// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:studiomc_app/services/api_client.dart';

/// Handles chat completions (REST + WebSocket streaming) and
/// model selection via the local Inference service (port 8100).
class InferenceService {
  static InferenceService? _instance;
  final ApiClient _api;

  /// Active WebSocket connection for streaming, if any.
  WebSocket? _activeSocket;

  InferenceService._(this._api);

  factory InferenceService() {
    _instance ??= InferenceService._(
      ApiClient(baseUrl: ServiceUrls.inference),
    );
    return _instance!;
  }

  // ── Chat completions (non-streaming) ──────────────────────────────

  /// Send a chat completion request.
  ///
  /// [messages] is a list of `{role, content}` maps.
  /// Returns the assistant's reply as a string, or `null` on failure.
  Future<String?> chatCompletion({
    required List<Map<String, dynamic>> messages,
    String? model,
    bool stream = false,
  }) async {
    try {
      final body = <String, dynamic>{
        'messages': messages,
        if (model != null) 'model': model,
        'stream': stream,
      };
      final data = await _api.post('/v1/chat/completions', body: body);
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;
      return choices[0]['message']['content'] as String?;
    } catch (e) {
      logService('inference', 'Chat completion failed', error: e);
      return null;
    }
  }

  // ── WebSocket streaming ───────────────────────────────────────────

  /// Open a dart:io [WebSocket] to the inference streaming endpoint and
  /// return a broadcast [Stream] of token strings.
  ///
  /// The caller should also call [disconnectWebSocket] when the chat
  /// finishes or the user navigates away.
  Stream<String> connectWebSocket(String chatId) async* {
    final controller = StreamController<String>();

    try {
      _activeSocket = await WebSocket.connect(
        '${ServiceUrls.inference.replaceFirst('http', 'ws')}/v1/chat/stream',
      ).timeout(const Duration(seconds: 10));

      // Send initial handshake with chatId.
      _activeSocket!.add(jsonEncode({'chat_id': chatId}));

      _activeSocket!.listen(
        (raw) {
          try {
            final data = jsonDecode(raw as String) as Map<String, dynamic>;
            final type = data['type'] as String?;

            if (type == 'token') {
              controller.add(data['content'] as String? ?? '');
            } else if (type == 'done') {
              controller.close();
            } else if (type == 'error') {
              controller.addError(
                Exception(data['message'] ?? 'Streaming error'),
              );
              controller.close();
            }
          } catch (e) {
            logService('inference', 'WS parse error', error: e);
          }
        },
        onError: (Object error) {
          logService('inference', 'WS error', error: error);
          controller.addError(error);
          controller.close();
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
    } catch (e) {
      logService('inference', 'WS connect failed', error: e);
      controller.addError(e);
      controller.close();
    }

    yield* controller.stream;
  }

  /// Send a prompt payload over an already-open WebSocket.
  void sendMessage({
    required List<Map<String, dynamic>> messages,
    String? mode,
  }) {
    if (_activeSocket == null) {
      logService('inference', 'Cannot send — no active WebSocket');
      return;
    }
    _activeSocket!.add(jsonEncode({
      'messages': messages,
      if (mode != null) 'mode': mode,
    }));
  }

  /// Close the active streaming WebSocket, if any.
  Future<void> disconnectWebSocket() async {
    try {
      await _activeSocket?.close();
    } catch (e) {
      logService('inference', 'WS close error', error: e);
    }
    _activeSocket = null;
  }

  // ── Convenience streaming helper ──────────────────────────────────

  /// High-level streaming helper used by ChatScreen.
  /// Connects WebSocket, sends messages, and yields tokens.
  Stream<String> streamChat({
    required String chatId,
    required List<Map<String, dynamic>> messages,
    String? mode,
  }) async* {
    yield* connectWebSocket(chatId);
    // After connection is established, send the messages
    sendMessage(messages: messages, mode: mode);
  }

  // ── Model listing / selection ─────────────────────────────────────

  /// List models currently loaded / available in the inference engine.
  Future<List<Map<String, dynamic>>> getModels() async {
    try {
      final data = await _api.get('/v1/models');
      return (data['data'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ??
          [];
    } catch (e) {
      logService('inference', 'Failed to list models', error: e);
      return [];
    }
  }

  /// Tell the inference engine to load / switch to [modelId].
  Future<bool> selectModel(String modelId) async {
    try {
      await _api.post('/v1/models/select', body: {'model_id': modelId});
      return true;
    } catch (e) {
      logService('inference', 'Failed to select model', error: e);
      return false;
    }
  }
}
