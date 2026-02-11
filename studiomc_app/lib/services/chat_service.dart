// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';

/// A chat with its full message history, returned by [ChatService.getChat].
class ChatWithMessages {
  final Chat chat;
  final List<Message> messages;

  const ChatWithMessages({required this.chat, required this.messages});
}

/// Communicates with the Inference service's DB-backed chat endpoints
/// (port 8100) for CRUD on chats, messages, and history.
class ChatService {
  static ChatService? _instance;
  final ApiClient _api;

  ChatService._(this._api);

  factory ChatService() {
    _instance ??= ChatService._(
      ApiClient(baseUrl: ServiceUrls.inference),
    );
    return _instance!;
  }

  // ── Chat CRUD ─────────────────────────────────────────────────────

  /// List all chats, sorted by `updated_at` descending.
  Future<List<Chat>> listChats() async {
    try {
      final items = await _api.getList('/v1/chats');
      return items.map((e) => _parseChat(e as Map<String, dynamic>)).toList();
    } catch (e) {
      logService('chat', 'Failed to list chats', error: e);
      return [];
    }
  }

  /// Get a single chat by ID, including its full message history.
  Future<ChatWithMessages?> getChat(String chatId) async {
    try {
      final data = await _api.get('/v1/chats/$chatId');
      final chat = _parseChat(data);

      final msgList = (data['messages'] as List<dynamic>?) ?? [];
      final messages = msgList
          .map((m) => _parseMessage(m as Map<String, dynamic>))
          .toList();

      return ChatWithMessages(chat: chat, messages: messages);
    } catch (e) {
      logService('chat', 'Failed to get chat $chatId', error: e);
      return null;
    }
  }

  /// Create a new chat.
  Future<Chat?> createChat({
    required String title,
    required String modelId,
    PresetMode mode = PresetMode.defaultMode,
  }) async {
    try {
      final data = await _api.post('/v1/chats', body: {
        'title': title,
        'model_id': modelId,
        'mode': _presetModeToString(mode),
      });
      return _parseChat(data);
    } catch (e) {
      logService('chat', 'Failed to create chat', error: e);
      return null;
    }
  }

  /// Update a chat's title and/or pinned status.
  Future<bool> updateChat(
    String chatId, {
    String? title,
    bool? pinned,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (title != null) body['title'] = title;
      if (pinned != null) body['is_pinned'] = pinned;
      await _api.put('/v1/chats/$chatId', body: body);
      return true;
    } catch (e) {
      logService('chat', 'Failed to update chat $chatId', error: e);
      return false;
    }
  }

  /// Delete a chat and all its messages.
  Future<bool> deleteChat(String chatId) async {
    try {
      await _api.delete('/v1/chats/$chatId');
      return true;
    } catch (e) {
      logService('chat', 'Failed to delete chat $chatId', error: e);
      return false;
    }
  }

  /// Export a chat as a markdown-formatted string.
  Future<String?> exportChat(String chatId) async {
    try {
      final markdown = await _api.getRaw('/v1/chats/$chatId/export');
      return markdown;
    } catch (e) {
      logService('chat', 'Failed to export chat $chatId', error: e);
      return null;
    }
  }

  // ── Parsing helpers ───────────────────────────────────────────────

  Chat _parseChat(Map<String, dynamic> json) {
    return Chat(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      modelId: json['model_id'] as String? ?? '',
      mode: _parsePresetMode(json['mode'] as String?),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
      isPinned: json['is_pinned'] as bool? ?? false,
    );
  }

  Message _parseMessage(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String? ?? '',
      chatId: json['chat_id'] as String? ?? '',
      role: _parseRole(json['role'] as String?),
      content: json['content'] as String? ?? '',
      tokens: json['tokens'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      parentMessageId: json['parent_message_id'] as String?,
      isStreaming: json['is_streaming'] as bool? ?? false,
    );
  }

  PresetMode _parsePresetMode(String? s) {
    switch (s) {
      case 'default':
        return PresetMode.defaultMode;
      case 'writing':
        return PresetMode.writing;
      case 'coding':
        return PresetMode.coding;
      case 'tutor':
        return PresetMode.tutor;
      default:
        return PresetMode.defaultMode;
    }
  }

  String _presetModeToString(PresetMode mode) {
    switch (mode) {
      case PresetMode.defaultMode:
        return 'default';
      case PresetMode.writing:
        return 'writing';
      case PresetMode.coding:
        return 'coding';
      case PresetMode.tutor:
        return 'tutor';
    }
  }

  MessageRole _parseRole(String? s) {
    switch (s) {
      case 'system':
        return MessageRole.system;
      case 'user':
        return MessageRole.user;
      case 'assistant':
        return MessageRole.assistant;
      case 'tool':
        return MessageRole.tool;
      default:
        return MessageRole.user;
    }
  }
}
