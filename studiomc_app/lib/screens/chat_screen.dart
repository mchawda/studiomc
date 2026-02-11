// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/services/chat_service.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/services/inference_service.dart';
import 'package:studiomc_app/services/bundled_inference_service.dart';
import 'package:studiomc_app/services/local_inference_service.dart';
import 'package:studiomc_app/services/orchestrator_service.dart';
import 'package:studiomc_app/services/settings_service.dart';
import 'package:studiomc_app/widgets/chat/branch_indicator.dart';
import 'package:studiomc_app/widgets/chat/chat_input.dart';
import 'package:studiomc_app/widgets/chat/context_panel.dart';
import 'package:studiomc_app/widgets/chat/conversation_controls.dart';
import 'package:studiomc_app/widgets/chat/empty_state.dart';
import 'package:studiomc_app/widgets/chat/groundedness_meter.dart';
import 'package:studiomc_app/widgets/chat/memory_toggle.dart';
import 'package:studiomc_app/widgets/chat/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final String? chatId;

  const ChatScreen({super.key, this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // ── State ──
  ChatMode _chatMode = ChatMode.chat;
  PresetMode _selectedPreset = PresetMode.defaultMode;
  bool? _showContextPanel; // null = auto-decide based on model state
  bool _isStreaming = false;
  bool _isLoading = true;
  String? _error;

  // ── Preset system prompts ──
  static const _presetSystemPrompts = <PresetMode, String>{
    PresetMode.defaultMode:
        'You are a helpful, friendly AI assistant. Provide clear, accurate, '
        'and concise responses. Be direct and informative.',
    PresetMode.writing:
        'You are a creative writing assistant. Focus on prose quality, voice, '
        'tone, and narrative structure. Offer constructive feedback on writing. '
        'When generating text, use vivid language and engaging prose. Help with '
        'brainstorming, editing, and refining written work.',
    PresetMode.coding:
        'You are a precise coding assistant. Provide clear code examples in '
        'properly formatted code blocks. Explain technical concepts accurately. '
        'Focus on best practices, clean code, and performance. When debugging, '
        'be systematic and thorough. Prefer concise, working code over verbose '
        'explanations.',
    PresetMode.tutor:
        'You are a Socratic tutor. Guide learning through thoughtful questions '
        'rather than giving direct answers. Help the learner discover concepts '
        'on their own. Ask probing questions, provide hints when needed, and '
        'encourage critical thinking. Celebrate progress and build confidence.',
  };

  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _streamSub;

  // Live data
  String _chatId = '';
  String _chatTitle = 'New Chat';
  bool _isPinned = false;
  String _modelName = '';
  SpeedRating _speedRating = SpeedRating.ok;
  double _tokPerS = 0;
  List<Message> _messages = [];
  List<Citation> _citations = [];
  List<TraceStep> _traceSteps = [];
  double _groundedness = 0;

  // ── Memory toggle state ──
  bool _memoryEnabled = true;

  // ── Attached document IDs for this chat ──
  final List<String> _attachedDocIds = [];

  // ── Branching state ──
  // Maps a parent message ID to the currently selected child index
  final Map<String, int> _branchSelections = {};

  @override
  void initState() {
    super.initState();
    _chatId = widget.chatId ?? '';
    _loadMemoryPreference();
    _loadData();
    // Listen for model changes from LocalInferenceService
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final local = context.read<LocalInferenceService>();
      local.addListener(_onModelChanged);
    });
  }

  void _onModelChanged() {
    if (!mounted) return;
    final local = context.read<LocalInferenceService>();
    if (local.activeModel != null) {
      final newName = local.humanName(local.activeModel!);
      if (newName != _modelName) {
        setState(() {
          _modelName = newName;
          _tokPerS = local.tokPerS;
        });
      }
    }
  }

  Future<void> _loadMemoryPreference() async {
    final enabled = await MemoryToggle.loadPreference();
    if (mounted) setState(() => _memoryEnabled = enabled);
  }

  Future<void> _loadPreset(DatabaseService db) async {
    if (_chatId.isEmpty) return;
    final value = await db.getSetting('chat_preset_$_chatId');
    if (value != null && mounted) {
      final preset = PresetMode.values.where((p) => p.name == value).firstOrNull;
      if (preset != null) {
        setState(() => _selectedPreset = preset);
      }
    }
  }

  void _handlePresetChanged(PresetMode preset) {
    setState(() => _selectedPreset = preset);
    // Persist per conversation (fire-and-forget)
    if (_chatId.isNotEmpty) {
      final db = context.read<DatabaseService>();
      db.setSetting('chat_preset_$_chatId', preset.name);
    }
  }

  Future<void> _loadData() async {
    final db = context.read<DatabaseService>();
    final api = context.read<ApiClient>();
    final settings = context.read<SettingsService>();
    final bundledInference = context.read<BundledInferenceService>();
    final localInference = context.read<LocalInferenceService>();

    try {
      // 1) Ollama (primary for small models)
      if (localInference.available) {
        if (settings.hasActiveModel) {
          localInference.selectModelByPreference(settings.activeModelId!);
        }
        if (localInference.activeModel != null) {
          _modelName = localInference.humanName(localInference.activeModel!);
        }
      }

      // 2) SpliceLLM (for large models)
      if (_modelName.isEmpty &&
          bundledInference.available &&
          bundledInference.activeModel != null) {
        _modelName = bundledInference.activeModel!;
      }

      // 3) Backend inference service fallback
      if (_modelName.isEmpty && api.isAvailable) {
        try {
          final inference = context.read<InferenceService>();
          final models = await inference.getModels();
          if (models.isNotEmpty) {
            _modelName = models.first['id'] ?? 'Unknown';
          }
        } catch (_) {}
      }

      // 4) Friendly name from settings
      if (_modelName.isEmpty && settings.hasActiveModel) {
        _modelName = _humanModelName(settings.activeModelId!);
      }

      // Load chat details and messages
      if (_chatId.isNotEmpty) {
        // Try loading via ChatService first
        if (api.isAvailable) {
          try {
            final chatService = ChatService();
            final chatData = await chatService.getChat(_chatId);
            if (chatData != null) {
              _chatTitle = chatData.chat.title;
              _isPinned = chatData.chat.isPinned;
              _messages = chatData.messages;
            }
          } catch (_) {
            // Fall back to local DB
            await _loadMessagesFromDb(db);
          }
        } else {
          await _loadMessagesFromDb(db);
        }

        // Load persisted preset for this conversation
        await _loadPreset(db);
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMessagesFromDb(DatabaseService db) async {
    final rows = await db.getMessages(_chatId);
    _messages = rows
        .map((r) => Message(
              id: r['id'] as String,
              chatId: r['chat_id'] as String,
              role: _parseRole(r['role'] as String),
              content: r['content'] as String,
              tokens: r['tokens'] as int? ?? 0,
              createdAt:
                  DateTime.tryParse(r['created_at'] as String? ?? '') ??
                      DateTime.now(),
              parentMessageId: r['parent_message_id'] as String?,
            ))
        .toList();

    // Load chat title from DB
    final chats = await db.getChats();
    final chatRow = chats.where((c) => c['id'] == _chatId).firstOrNull;
    if (chatRow != null) {
      _chatTitle = chatRow['title'] as String? ?? 'Untitled';
    }
  }

  /// Turn a GGUF filename into a friendly model name.
  String _humanModelName(String filename) {
    // "llama-3.2-8b-instruct-q4_k_m.gguf" → "Llama 3.2 8B"
    var name = filename
        .replaceAll('.gguf', '')
        .replaceAll('.bin', '')
        .replaceAll(RegExp(r'-q\d.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]instruct', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]chat', caseSensitive: false), '')
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .trim();
    // Title case
    name = name.split(' ').map((w) {
      if (w.isEmpty) return w;
      if (RegExp(r'^\d').hasMatch(w)) return w; // keep numbers as-is
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
    return name.isEmpty ? filename : name;
  }

  MessageRole _parseRole(String role) {
    switch (role) {
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

  String _roleToString(MessageRole role) {
    switch (role) {
      case MessageRole.system:
        return 'system';
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.tool:
        return 'tool';
    }
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _scrollController.dispose();
    try {
      context.read<LocalInferenceService>().removeListener(_onModelChanged);
    } catch (_) {}
    super.dispose();
  }

  // ── Conversation controls ──

  Future<void> _handleRename(String newTitle) async {
    if (_chatId.isEmpty) return;
    final api = context.read<ApiClient>();

    if (api.isAvailable) {
      await ChatService().updateChat(_chatId, title: newTitle);
    } else {
      final db = context.read<DatabaseService>();
      await db.updateChat(_chatId, {'title': newTitle});
    }

    setState(() => _chatTitle = newTitle);
  }

  Future<void> _handlePin(bool pin) async {
    if (_chatId.isEmpty) return;
    final api = context.read<ApiClient>();

    if (api.isAvailable) {
      await ChatService().updateChat(_chatId, pinned: pin);
    }
    setState(() => _isPinned = pin);
  }

  Future<void> _handleExport() async {
    if (_chatId.isEmpty) return;
    // The ConversationControls widget handles the actual export
    // via its built-in _handleExport. We just supply the markdown content.
  }

  Future<String?> _getMarkdownContent() async {
    if (_chatId.isEmpty) return null;
    final api = context.read<ApiClient>();

    if (api.isAvailable) {
      return ChatService().exportChat(_chatId);
    }

    // Fallback: build markdown from local messages
    final buffer = StringBuffer();
    buffer.writeln('# $_chatTitle\n');
    for (final msg in _messages) {
      if (msg.role == MessageRole.system) continue;
      final roleName =
          msg.role == MessageRole.user ? 'You' : 'Assistant';
      buffer.writeln('**$roleName:**\n');
      buffer.writeln('${msg.content}\n');
      buffer.writeln('---\n');
    }
    return buffer.toString();
  }

  // ── Memory toggle ──

  void _handleMemoryToggle(bool enabled) {
    setState(() => _memoryEnabled = enabled);
    MemoryToggle.savePreference(enabled);
  }

  // ── Branching helpers ──

  /// Build a map from parent_message_id -> list of children messages.
  Map<String?, List<Message>> _buildChildrenMap() {
    final childrenMap = <String?, List<Message>>{};
    for (final msg in _messages) {
      childrenMap.putIfAbsent(msg.parentMessageId, () => []).add(msg);
    }
    return childrenMap;
  }

  /// Walk the message tree following selected branches to produce the
  /// visible linear message list.
  List<Message> _getVisibleMessages() {
    final childrenMap = _buildChildrenMap();

    // Check if any messages actually use branching
    final hasBranching =
        _messages.any((m) => m.parentMessageId != null);

    if (!hasBranching) {
      // No branching — return flat list as-is
      return _messages.where((m) => m.role != MessageRole.system).toList();
    }

    // Walk from root messages (those with no parent)
    final visible = <Message>[];
    var currentChildren = childrenMap[null] ?? [];

    while (currentChildren.isNotEmpty) {
      // Filter out system messages for display
      final displayable =
          currentChildren.where((m) => m.role != MessageRole.system).toList();

      if (displayable.isEmpty) {
        // All children are system messages; try to follow one
        final first = currentChildren.first;
        currentChildren = childrenMap[first.id] ?? [];
        continue;
      }

      // Determine which branch to show
      final parentId = currentChildren.first.parentMessageId;
      final selectedIdx = _branchSelections[parentId ?? ''] ?? 0;
      final idx = selectedIdx.clamp(0, displayable.length - 1);
      final selected = displayable[idx];

      visible.add(selected);
      currentChildren = childrenMap[selected.id] ?? [];
    }

    return visible;
  }

  /// Get branch info for a message: how many siblings and current index.
  ({int current, int total}) _getBranchInfo(Message message) {
    final childrenMap = _buildChildrenMap();
    final siblings = childrenMap[message.parentMessageId] ?? [];
    final displayable =
        siblings.where((m) => m.role != MessageRole.system).toList();

    if (displayable.length <= 1) return (current: 1, total: 1);

    final idx = displayable.indexWhere((m) => m.id == message.id);
    return (current: idx + 1, total: displayable.length);
  }

  void _navigateBranch(Message message, int direction) {
    final childrenMap = _buildChildrenMap();
    final siblings = childrenMap[message.parentMessageId] ?? [];
    final displayable =
        siblings.where((m) => m.role != MessageRole.system).toList();

    final currentIdx = displayable.indexWhere((m) => m.id == message.id);
    final newIdx = (currentIdx + direction).clamp(0, displayable.length - 1);

    setState(() {
      _branchSelections[message.parentMessageId ?? ''] = newIdx;
    });
  }

  // ── Real messaging ──

  Future<void> _sendMessage(String text) async {
    if (_isStreaming || text.trim().isEmpty) return;

    final db = context.read<DatabaseService>();
    final bundledInference = context.read<BundledInferenceService>();
    final localInference = context.read<LocalInferenceService>();

    // Create chat if needed
    if (_chatId.isEmpty) {
      _chatId = 'chat-${DateTime.now().millisecondsSinceEpoch}';
      _chatTitle = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      await db.createChat({
        'id': _chatId,
        'title': _chatTitle,
        'model_id': _modelName,
        'mode': _chatMode.name,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      // Persist initial preset for this conversation
      await db.setSetting('chat_preset_$_chatId', _selectedPreset.name);
    }

    // Determine parent message ID for branching
    final parentMsgId = _messages.isNotEmpty ? _messages.last.id : null;

    // Add user message
    final userMsgId = 'msg-${DateTime.now().millisecondsSinceEpoch}';
    final userMsg = Message(
      id: userMsgId,
      chatId: _chatId,
      role: MessageRole.user,
      content: text,
      tokens: text.split(' ').length,
      createdAt: DateTime.now(),
      parentMessageId: parentMsgId,
    );

    await db.insertMessage({
      'id': userMsgId,
      'chat_id': _chatId,
      'role': 'user',
      'content': text,
      'tokens': text.split(' ').length,
      'created_at': DateTime.now().toIso8601String(),
      if (parentMsgId != null) 'parent_message_id': parentMsgId,
    });

    setState(() {
      _messages.add(userMsg);
    });
    _scrollToBottom();

    // Routing: prefer Ollama for small models, SpliceLLM for large
    final useOllama = localInference.available;
    final useStudiomc = bundledInference.available;
    if (!useOllama && !useStudiomc) {
      setState(() {
        _error = 'No inference engine available. Download a model first.';
      });
      return;
    }

    final assistantMsgId =
        'msg-stream-${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _isStreaming = true;
      _messages.add(Message(
        id: assistantMsgId,
        chatId: _chatId,
        role: MessageRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        isStreaming: true,
        parentMessageId: userMsgId,
      ));
    });
    _scrollToBottom();

    try {
      // Route based on chat mode: docs/investigate → orchestrator, chat → streaming inference
      if (_chatMode == ChatMode.docs || _chatMode == ChatMode.investigate) {
        await _sendViaOrchestrator(text, assistantMsgId, userMsgId, db);
        return;
      }

      // Build messages payload with preset system prompt, memory, and context
      final messagesPayload = <Map<String, String>>[];

      // Inject preset system prompt
      final systemPrompt = _presetSystemPrompts[_selectedPreset];
      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        messagesPayload.add({
          'role': 'system',
          'content': systemPrompt,
        });
      }

      if (_memoryEnabled) {
        // Inject global facts and chat summary as system context
        try {
          await db.ensureMemoryTables();
          final facts = await db.getGlobalFacts(limit: 10);
          final chatSummary =
              _chatId.isNotEmpty ? await db.getChatSummary(_chatId) : null;

          final memoryParts = <String>[];
          if (facts.isNotEmpty) {
            memoryParts.add('User facts: ${facts.join('. ')}');
          }
          if (chatSummary != null) {
            memoryParts.add('Previous context: $chatSummary');
          }
          if (memoryParts.isNotEmpty) {
            messagesPayload.add({
              'role': 'system',
              'content':
                  'You have memory enabled. Here is context from previous interactions:\n${memoryParts.join('\n')}',
            });
          }
        } catch (_) {}
      }

      // Inject document context if any documents are attached
      if (_attachedDocIds.isNotEmpty) {
        try {
          final docParts = <String>[];
          for (final docId in _attachedDocIds) {
            final content = await db.getDocumentContent(docId);
            if (content != null && content.isNotEmpty) {
              // Truncate to ~2000 chars to fit context window
              final truncated = content.length > 2000
                  ? content.substring(0, 2000)
                  : content;
              docParts.add(truncated);
            }
          }
          if (docParts.isNotEmpty) {
            messagesPayload.add({
              'role': 'system',
              'content':
                  'The user has uploaded documents. Use them to answer questions:\n\n${docParts.join('\n\n---\n\n')}',
            });
          }
        } catch (_) {}
      }

      messagesPayload.addAll(_messages
          .where((m) => !m.isStreaming)
          .map((m) => {
                'role': _roleToString(m.role),
                'content': m.content,
              })
          .toList());

      final buffer = StringBuffer();
      int tokenCount = 0;

      // ── Routing: Ollama for models that fit in memory, SpliceLLM only
      //    for models that exceed GPU/RAM capacity. ──
      var usingStudiomcFallback = false;
      int ollamaRetries = 0;
      const maxOllamaRetries = 2;
      final modelFits = localInference.activeModelFitsInMemory;

      Stream<String> tokenStream;
      if (useOllama) {
        tokenStream = localInference.streamChat(messages: messagesPayload);
      } else {
        tokenStream = bundledInference.streamChat(messages: messagesPayload);
        usingStudiomcFallback = true;
      }

      void retryOllama() {
        ollamaRetries++;
        debugPrint('[chat] Retrying Ollama (attempt $ollamaRetries/$maxOllamaRetries)…');
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
          if (idx != -1) {
            _messages[idx] = Message(
              id: assistantMsgId,
              chatId: _chatId,
              role: MessageRole.assistant,
              content: 'Model loading, please wait…',
              createdAt: _messages[idx].createdAt,
              isStreaming: true,
              parentMessageId: userMsgId,
            );
          }
        });
        // Wait briefly for Ollama to finish loading the model
        Future.delayed(const Duration(seconds: 3), () {
          if (!mounted) return;
          buffer.clear();
          tokenCount = 0;
          final retryStream = localInference.streamChat(messages: messagesPayload);
          _streamSub = retryStream.listen(
            (t) => _handleStreamToken(
              t, buffer, assistantMsgId, userMsgId, () => tokenCount++,
              useStudiomc: useStudiomc,
              modelFits: modelFits,
              ollamaRetries: ollamaRetries,
              maxRetries: maxOllamaRetries,
              retryFn: retryOllama,
              fallbackFn: () => _fallbackToSpliceLLM(
                messagesPayload, buffer, assistantMsgId, userMsgId, text, db,
                () => tokenCount++, () => tokenCount,
              ),
            ),
            onDone: () => _onStreamDone(
              buffer, tokenCount, assistantMsgId, userMsgId, text, db,
              localInference.tokPerS),
            onError: (e) => _onStreamError(e, assistantMsgId),
          );
        });
      }

      void fallbackToSplice() {
        _fallbackToSpliceLLM(
          messagesPayload, buffer, assistantMsgId, userMsgId, text, db,
          () => tokenCount++, () => tokenCount,
        );
      }

      _streamSub = tokenStream.listen(
        (token) {
          // Detect Ollama error tokens
          if (!usingStudiomcFallback && token.startsWith('[Error')) {
            _streamSub?.cancel();
            debugPrint('[chat] Ollama error: $token');

            // If model fits in memory → retry Ollama (it's probably loading)
            // If model is too large → fall back to SpliceLLM
            if (modelFits) {
              if (ollamaRetries < maxOllamaRetries) {
                retryOllama();
              } else {
                // Exhausted retries — show error, don't use SpliceLLM for small models
                debugPrint('[chat] Ollama retries exhausted for small model');
                _onStreamError('Ollama is not responding. Check that it\'s running.', assistantMsgId);
              }
            } else if (useStudiomc) {
              // Model too large for GPU → SpliceLLM is appropriate
              fallbackToSplice();
            } else {
              _onStreamError('Model may be too large. No fallback available.', assistantMsgId);
            }
            return;
          }

          buffer.write(token);
          tokenCount++;
          setState(() {
            final idx =
                _messages.indexWhere((m) => m.id == assistantMsgId);
            if (idx != -1) {
              _messages[idx] = Message(
                id: assistantMsgId,
                chatId: _chatId,
                role: MessageRole.assistant,
                content: buffer.toString(),
                tokens: tokenCount,
                createdAt: _messages[idx].createdAt,
                isStreaming: true,
                parentMessageId: userMsgId,
              );
            }
          });
          _scrollToBottom();
        },
        onDone: () async {
          final finalContent = buffer.toString();

          // Update tok/s from whichever engine was used
          _tokPerS = usingStudiomcFallback
              ? bundledInference.tokPerS
              : localInference.tokPerS;

          // Save to DB
          await db.insertMessage({
            'id': assistantMsgId,
            'chat_id': _chatId,
            'role': 'assistant',
            'content': finalContent,
            'tokens': tokenCount,
            'created_at': DateTime.now().toIso8601String(),
            'parent_message_id': userMsgId,
          });

          // Update chat timestamp
          await db.updateChat(_chatId, {
            'updated_at': DateTime.now().toIso8601String(),
          });

          // Save memory summary if enabled
          if (_memoryEnabled && finalContent.isNotEmpty) {
            try {
              await db.ensureMemoryTables();
              // Build a compact summary of the last exchange
              final summaryText =
                  'User asked: ${text.length > 200 ? text.substring(0, 200) : text}. '
                  'Assistant replied: ${finalContent.length > 300 ? finalContent.substring(0, 300) : finalContent}';
              await db.saveChatSummary(
                  _chatId, summaryText, tokenCount);
            } catch (_) {}
          }

          setState(() {
            _isStreaming = false;
            final idx =
                _messages.indexWhere((m) => m.id == assistantMsgId);
            if (idx != -1) {
              _messages[idx] = Message(
                id: assistantMsgId,
                chatId: _chatId,
                role: MessageRole.assistant,
                content: finalContent,
                tokens: tokenCount,
                createdAt: _messages[idx].createdAt,
                isStreaming: false,
                parentMessageId: userMsgId,
              );
            }
          });
        },
        onError: (e) {
          setState(() {
            _isStreaming = false;
            _error = 'Streaming failed: $e';
            // Remove the empty streaming message
            _messages.removeWhere((m) => m.id == assistantMsgId);
          });
        },
      );
    } catch (e) {
      setState(() {
        _isStreaming = false;
        _error = 'Failed to connect: $e';
        _messages.removeWhere((m) => m.id == assistantMsgId);
      });
    }
  }

  /// Create a branch from a specific message by re-sending from that point.
  void _branchFromMessage(Message message) {
    if (_isStreaming) return;

    // Find the index of this message
    final idx = _messages.indexOf(message);
    if (idx < 0) return;

    // Get the last user message up to this point
    Message? lastUserMsg;
    for (int i = idx; i >= 0; i--) {
      if (_messages[i].role == MessageRole.user) {
        lastUserMsg = _messages[i];
        break;
      }
    }

    if (lastUserMsg != null) {
      _sendMessage(lastUserMsg.content);
    }
  }

  void _regenerateLastResponse() {
    if (_isStreaming) return;

    final db = context.read<DatabaseService>();

    setState(() {
      if (_messages.isNotEmpty &&
          _messages.last.role == MessageRole.assistant) {
        final removed = _messages.removeLast();
        db.deleteMessage(removed.id);
      }
    });

    final lastUserMsg = _messages.lastWhere(
      (m) => m.role == MessageRole.user,
      orElse: () => _messages.first,
    );

    _sendMessage(lastUserMsg.content);
  }

  /// Send message via orchestrator (for docs/investigate modes).
  Future<void> _sendViaOrchestrator(
    String text,
    String assistantMsgId,
    String userMsgId,
    DatabaseService db,
  ) async {
    final orchestrator = context.read<OrchestratorService>();

    // Map ChatMode to orchestrator mode
    String orchestratorMode;
    switch (_chatMode) {
      case ChatMode.docs:
        orchestratorMode = 'cited';
        break;
      case ChatMode.investigate:
        orchestratorMode = 'investigate';
        break;
      default:
        orchestratorMode = 'fast';
    }

    try {
      // Show "thinking" status
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
        if (idx != -1) {
          _messages[idx] = Message(
            id: assistantMsgId,
            chatId: _chatId,
            role: MessageRole.assistant,
            content: 'Planning and researching...',
            createdAt: _messages[idx].createdAt,
            isStreaming: true,
            parentMessageId: userMsgId,
          );
        }
      });

      // Call orchestrator
      final result = await orchestrator.runReasoning(
        chatId: _chatId,
        userQuery: text,
        mode: orchestratorMode,
        collectionId: _attachedDocIds.isNotEmpty ? 'default' : null,
      );

      final answer = result['answer'] as String? ?? '';
      final citations = result['citations'] as List<dynamic>? ?? [];
      final groundednessValue = (result['groundedness'] as num?)?.toDouble() ?? 0.0;
      final trace = result['trace'] as List<dynamic>? ?? [];
      final metrics = result['metrics'] as Map<String, dynamic>? ?? {};
      final tokenCount = (answer.split(' ').length);

      // Update citations, groundedness, and trace in state
      setState(() {
        _citations = citations
            .map((c) => Citation(
                  documentId: c['document_id'] ?? '',
                  filename: c['filename'] ?? '',
                  chunkIndex: c['chunk_index'] ?? 0,
                  snippet: c['snippet'] ?? '',
                  relevanceScore: (c['relevance_score'] ?? 0.0).toDouble(),
                ))
            .toList();

        _groundedness = groundednessValue;

        _traceSteps = trace
            .map((t) => TraceStep(
                  id: t['tool'] ?? '',
                  type: t['tool'] ?? '',
                  description: (t['input'] as Map<String, dynamic>?)?.toString() ?? '',
                  result: t['output'] ?? '',
                  durationMs: t['duration_ms'] ?? 0,
                ))
            .toList();
      });

      // Save to DB
      await db.insertMessage({
        'id': assistantMsgId,
        'chat_id': _chatId,
        'role': 'assistant',
        'content': answer,
        'tokens': tokenCount,
        'created_at': DateTime.now().toIso8601String(),
        'parent_message_id': userMsgId,
      });

      await db.updateChat(_chatId, {
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Update UI with final answer
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
        if (idx != -1) {
          _messages[idx] = Message(
            id: assistantMsgId,
            chatId: _chatId,
            role: MessageRole.assistant,
            content: answer,
            tokens: tokenCount,
            createdAt: _messages[idx].createdAt,
            isStreaming: false,
            parentMessageId: userMsgId,
          );
        }
        _isStreaming = false;
      });

      _scrollToBottom();
    } catch (e) {
      setState(() {
        _error = 'Orchestrator failed: $e';
        _isStreaming = false;
      });
    }
  }

  /// Helper: process a token in the fallback stream.
  /// Handle a token from the stream, with error detection and smart routing.
  void _handleStreamToken(
    String token,
    StringBuffer buffer,
    String assistantMsgId,
    String userMsgId,
    VoidCallback incrementTokens, {
    required bool useStudiomc,
    required bool modelFits,
    required int ollamaRetries,
    required int maxRetries,
    required VoidCallback retryFn,
    required VoidCallback fallbackFn,
  }) {
    // Detect Ollama error tokens
    if (token.startsWith('[Error')) {
      _streamSub?.cancel();
      debugPrint('[chat] Ollama error in retry: $token');
      if (modelFits && ollamaRetries < maxRetries) {
        retryFn();
      } else if (!modelFits && useStudiomc) {
        fallbackFn();
      } else {
        _onStreamError('Ollama error: $token', assistantMsgId);
      }
      return;
    }
    // Normal token — pass through
    _onStreamToken(token, buffer, assistantMsgId, userMsgId, incrementTokens);
  }

  /// Fall back to SpliceLLM for models too large for GPU.
  void _fallbackToSpliceLLM(
    List<Map<String, String>> messagesPayload,
    StringBuffer buffer,
    String assistantMsgId,
    String userMsgId,
    String userText,
    dynamic db,
    VoidCallback incrementTokens,
    int Function() getTokenCount,
  ) {
    final localInference = context.read<LocalInferenceService>();
    final bundledInference = context.read<BundledInferenceService>();

    buffer.clear();
    debugPrint('[chat] Model too large for GPU → routing to SpliceLLM');

    setState(() {
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = Message(
          id: assistantMsgId,
          chatId: _chatId,
          role: MessageRole.assistant,
          content: 'Model too large for GPU. Switching to SpliceLLM…',
          createdAt: _messages[idx].createdAt,
          isStreaming: true,
          parentMessageId: userMsgId,
        );
      }
    });

    bundledInference.selectModel(localInference.activeModel ?? 'auto');
    final fallbackStream = bundledInference.streamChat(messages: messagesPayload);
    _streamSub = fallbackStream.listen(
      (t) => _onStreamToken(t, buffer, assistantMsgId, userMsgId, incrementTokens),
      onDone: () => _onStreamDone(
        buffer, getTokenCount(), assistantMsgId, userMsgId, userText, db,
        bundledInference.tokPerS),
      onError: (e) => _onStreamError(e, assistantMsgId),
    );
  }

  void _onStreamToken(String token, StringBuffer buffer, String assistantMsgId,
      String userMsgId, VoidCallback incrementTokens) {
    buffer.write(token);
    incrementTokens();
    final tokenCount = buffer.length; // approximate
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = Message(
          id: assistantMsgId,
          chatId: _chatId,
          role: MessageRole.assistant,
          content: buffer.toString(),
          tokens: tokenCount,
          createdAt: _messages[idx].createdAt,
          isStreaming: true,
          parentMessageId: userMsgId,
        );
      }
    });
    _scrollToBottom();
  }

  /// Helper: handle stream completion.
  Future<void> _onStreamDone(
      StringBuffer buffer,
      int tokenCount,
      String assistantMsgId,
      String userMsgId,
      String userText,
      dynamic db,
      double tokPerS) async {
    final finalContent = buffer.toString();
    _tokPerS = tokPerS;

    // Save to DB
    await db.insertMessage({
      'id': assistantMsgId,
      'chat_id': _chatId,
      'role': 'assistant',
      'content': finalContent,
      'tokens': tokenCount,
      'created_at': DateTime.now().toIso8601String(),
      'parent_message_id': userMsgId,
    });
    await db.updateChat(_chatId, {
      'updated_at': DateTime.now().toIso8601String(),
    });

    setState(() {
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = Message(
          id: assistantMsgId,
          chatId: _chatId,
          role: MessageRole.assistant,
          content: finalContent,
          tokens: tokenCount,
          createdAt: _messages[idx].createdAt,
          isStreaming: false,
          parentMessageId: userMsgId,
        );
      }
      _isStreaming = false;
    });
  }

  /// Helper: handle stream error.
  void _onStreamError(dynamic error, String assistantMsgId) {
    setState(() {
      _isStreaming = false;
      _error = 'Error: $error';
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = Message(
          id: assistantMsgId,
          chatId: _chatId,
          role: MessageRole.assistant,
          content: '[Error: $error]',
          createdAt: _messages[idx].createdAt,
          isStreaming: false,
        );
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 768;
    final visibleMessages = _getVisibleMessages();
    final hasMessages = visibleMessages.isNotEmpty;

    // Panel hidden by default. User toggles it manually.
    final showPanel = _showContextPanel ?? false;

    return Column(
      children: [
        // ── Top bar ──
        _buildTopBar(theme, isMobile, showPanel),

        // Error banner
        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.error.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(Icons.warning_rounded,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => _error = null),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

        // ── Body ──
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Row(
                  children: [
                    Expanded(
                      child: _buildMainContent(
                          theme, hasMessages, visibleMessages),
                    ),
                    if (!isMobile && showPanel)
                      ContextPanel(
                        chatMode: _chatMode,
                        modelName: _modelName,
                        speedRating: _speedRating,
                        tokPerS: _tokPerS,
                        citations: _citations,
                        groundedness: _groundedness,
                        traceSteps: _traceSteps,
                        onModelSelected: () {
                          // Model was picked from browser → hide panel, reload
                          setState(() {
                            _showContextPanel = false;
                          });
                          _loadData();
                        },
                      ),
                  ],
                ),
        ),

        // ── Input bar ──
        ChatInput(
          onSend: _sendMessage,
          memoryEnabled: _memoryEnabled,
          onMemoryToggled: _handleMemoryToggle,
          currentModelName: _modelName,
          onModelChanged: (modelId) {
            final localInference = context.read<LocalInferenceService>();
            localInference.selectModel(modelId);
            setState(() {
              _modelName = localInference.humanName(modelId);
            });
          },
          onDocumentUploaded: (docId) {
            setState(() => _attachedDocIds.add(docId));
          },
        ),
      ],
    );
  }

  Widget _buildTopBar(ThemeData theme, bool isMobile, bool showPanel) {
    final hasActiveChat = _chatId.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          // Left side: conversation controls (if active chat)
          if (hasActiveChat && !isMobile)
            FutureBuilder<String?>(
              future: _getMarkdownContent(),
              builder: (context, snapshot) {
                return ConversationControls(
                  title: _chatTitle,
                  isPinned: _isPinned,
                  markdownContent: snapshot.data,
                  displayMode: ConversationControlsDisplay.inline,
                  onRename: _handleRename,
                  onPin: _handlePin,
                  onExport: _handleExport,
                );
              },
            ),

          const Spacer(),

          // Center: mode tabs
          if (!isMobile) ...[
            _buildModeTab(theme, 'Chat', ChatMode.chat, Icons.chat_outlined),
            const SizedBox(width: 4),
            _buildModeTab(
                theme, 'Docs', ChatMode.docs, Icons.description_outlined),
            const SizedBox(width: 4),
            _buildModeTab(theme, 'Investigate', ChatMode.investigate,
                Icons.search_rounded),
          ] else ...[
            PopupMenuButton<ChatMode>(
              initialValue: _chatMode,
              onSelected: (mode) {
                setState(() => _chatMode = mode);
              },
              icon: Icon(
                _chatModeIcon(_chatMode),
                size: 20,
                color: theme.colorScheme.primary,
              ),
              itemBuilder: (context) => const [
                PopupMenuItem(value: ChatMode.chat, child: Text('Chat')),
                PopupMenuItem(value: ChatMode.docs, child: Text('Docs')),
                PopupMenuItem(
                    value: ChatMode.investigate, child: Text('Investigate')),
              ],
            ),
          ],

          const Spacer(),

          // Right side: panel toggle
          if (!isMobile)
            IconButton(
              icon: Icon(
                showPanel
                    ? Icons.view_sidebar
                    : Icons.view_sidebar_outlined,
                size: 20,
              ),
              tooltip: showPanel ? 'Hide panel' : 'Show panel',
              onPressed: () =>
                  setState(() => _showContextPanel = !showPanel),
              style: IconButton.styleFrom(
                foregroundColor: showPanel
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModeTab(
      ThemeData theme, String label, ChatMode mode, IconData icon) {
    final isActive = _chatMode == mode;
    return TextButton.icon(
      onPressed: () {
        setState(() {
          _chatMode = mode;
        });
      },
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor:
            isActive ? theme.colorScheme.primary : theme.colorScheme.secondary,
        backgroundColor:
            isActive ? theme.colorScheme.primary.withValues(alpha: 0.08) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: GoogleFonts.inter(
            fontSize: 9,
            fontWeight: isActive ? FontWeight.w500 : FontWeight.w400),
      ),
    );
  }

  Widget _buildMainContent(
      ThemeData theme, bool hasMessages, List<Message> visibleMessages) {
    switch (_chatMode) {
      case ChatMode.chat:
        return hasMessages
            ? _buildMessageList(theme, visibleMessages)
            : ChatEmptyState(onSuggestionTap: _sendMessage);
      case ChatMode.docs:
        return _buildDocsView(theme, hasMessages, visibleMessages);
      case ChatMode.investigate:
        return _buildInvestigateView(theme, hasMessages, visibleMessages);
    }
  }

  Widget _buildDocsView(
      ThemeData theme, bool hasMessages, List<Message> visibleMessages) {
    if (!hasMessages) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined,
                size: 48,
                color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('Document-Grounded Chat',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(color: theme.colorScheme.onSurface)),
            const SizedBox(height: 8),
            Text(
              'Ask questions and get answers grounded in your uploaded documents.\nCitations and sources are shown in the side panel.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.secondary),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.06),
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              Icon(Icons.description_outlined,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Docs mode — responses are grounded in your documents',
                  style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary)),
            ],
          ),
        ),
        // Inline groundedness meter — shown when we have citations or after a response
        if (_citations.isNotEmpty || _groundedness > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: GroundednessMeter(
              percentage: _groundedness,
              sourceCount: _citations.length,
              compact: true,
            ),
          ),
        Expanded(child: _buildMessageList(theme, visibleMessages)),
      ],
    );
  }

  Widget _buildInvestigateView(
      ThemeData theme, bool hasMessages, List<Message> visibleMessages) {
    if (!hasMessages) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded,
                size: 48,
                color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('Investigate Mode',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(color: theme.colorScheme.onSurface)),
            const SizedBox(height: 8),
            Text(
              'Deep-dive into topics with full trace visibility.\nSee every search, retrieval, and reasoning step in the side panel.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.secondary),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.06),
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded,
                  size: 16, color: theme.colorScheme.tertiary),
              const SizedBox(width: 8),
              Text('Investigate mode — full trace steps visible in side panel',
                  style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.tertiary)),
            ],
          ),
        ),
        // Inline groundedness meter
        if (_citations.isNotEmpty || _groundedness > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: GroundednessMeter(
              percentage: _groundedness,
              sourceCount: _citations.length,
              compact: true,
            ),
          ),
        Expanded(child: _buildMessageList(theme, visibleMessages)),
      ],
    );
  }

  Widget _buildMessageList(ThemeData theme, List<Message> visibleMessages) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: visibleMessages.length,
      itemBuilder: (context, index) {
        final message = visibleMessages[index];
        final branchInfo = _getBranchInfo(message);

        return Column(
          crossAxisAlignment: message.role == MessageRole.user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            MessageBubble(
              message: message,
              onRegenerate: (message.role == MessageRole.assistant &&
                      index == visibleMessages.length - 1 &&
                      !_isStreaming)
                  ? _regenerateLastResponse
                  : null,
              onCopy: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied to clipboard',
                        style: GoogleFonts.inter(fontSize: 9)),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                    width: 200,
                  ),
                );
              },
            ),

            // Branch indicator — only if message has siblings
            if (branchInfo.total > 1)
              Padding(
                padding: EdgeInsets.only(
                  left: message.role == MessageRole.user ? 0 : 24,
                  right: message.role == MessageRole.user ? 24 : 0,
                  bottom: 4,
                ),
                child: BranchIndicator(
                  currentBranch: branchInfo.current,
                  totalBranches: branchInfo.total,
                  onPrevious: () => _navigateBranch(message, -1),
                  onNext: () => _navigateBranch(message, 1),
                ),
              ),
          ],
        );
      },
    );
  }

  IconData _chatModeIcon(ChatMode mode) {
    switch (mode) {
      case ChatMode.chat:
        return Icons.chat_outlined;
      case ChatMode.docs:
        return Icons.description_outlined;
      case ChatMode.investigate:
        return Icons.search_rounded;
    }
  }
}
