// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:studiomc_app/services/api_client.dart';

/// One persistent memory entry surfaced into the chat context.
class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.scope,
    required this.scopeId,
    required this.key,
    required this.content,
    required this.tags,
    required this.confidence,
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
    this.sourceMessageId,
  });

  final String id;
  final String scope; // 'global' | 'chat' | 'project'
  final String? scopeId;
  final String? key;
  final String content;
  final List<String> tags;
  final double confidence;
  final bool pinned;
  final String createdAt;
  final String updatedAt;
  final String? sourceMessageId;

  factory MemoryEntry.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return MemoryEntry(
      id: json['id'] as String,
      scope: (json['scope'] as String?) ?? 'global',
      scopeId: json['scope_id'] as String?,
      key: json['key'] as String?,
      content: json['content'] as String,
      tags: (rawTags is List)
          ? List<String>.from(rawTags.map((e) => '$e'))
          : <String>[],
      confidence: ((json['confidence'] as num?) ?? 1.0).toDouble(),
      pinned: (json['pinned'] as bool?) ?? false,
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
      sourceMessageId: json['source_message_id'] as String?,
    );
  }
}

class MemoryExtractionResult {
  MemoryExtractionResult({required this.candidates, required this.saved});
  final List<Map<String, dynamic>> candidates;
  final List<MemoryEntry> saved;
}

/// Dart client for the Studiomc Memory service (port 8109).
class MemoryService {
  MemoryService({ApiClient? client})
      : _api = client ?? ApiClient(baseUrl: ServiceUrls.memory);

  final ApiClient _api;

  Future<List<MemoryEntry>> list({
    String? scope,
    String? scopeId,
    int limit = 200,
  }) async {
    final qs = StringBuffer('?limit=$limit');
    if (scope != null) qs.write('&scope=$scope');
    if (scopeId != null) qs.write('&scope_id=$scopeId');
    final body = await _api.get('/v1/memories$qs');
    final data = body['data'] as List? ?? const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(MemoryEntry.fromJson)
        .toList(growable: false);
  }

  Future<MemoryEntry> add({
    required String content,
    String scope = 'global',
    String? scopeId,
    String? key,
    List<String>? tags,
    bool pinned = false,
    double confidence = 1.0,
    String? sourceMessageId,
  }) async {
    final body = await _api.post('/v1/memories', body: {
      'content': content,
      'scope': scope,
      'scope_id': ?scopeId,
      'key': ?key,
      'tags': tags ?? const <String>[],
      'pinned': pinned,
      'confidence': confidence,
      'source_message_id': ?sourceMessageId,
    });
    return MemoryEntry.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  Future<MemoryEntry> update(
    String id, {
    String? content,
    String? key,
    List<String>? tags,
    bool? pinned,
    double? confidence,
  }) async {
    final body = await _api.patch('/v1/memories/$id', body: {
      'content': ?content,
      'key': ?key,
      'tags': ?tags,
      'pinned': ?pinned,
      'confidence': ?confidence,
    });
    return MemoryEntry.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  Future<void> delete(String id) async {
    await _api.delete('/v1/memories/$id');
  }

  Future<int> clearAll({String? scope}) async {
    final qs = scope != null ? '?scope=$scope' : '';
    final body = await _api.delete('/v1/memories$qs');
    final data = (body['data'] as Map?)?.cast<String, dynamic>();
    return (data?['removed'] as num?)?.toInt() ?? 0;
  }

  Future<MemoryExtractionResult> extract({
    required String userMessage,
    required String assistantMessage,
    String? chatId,
    bool autoSave = true,
  }) async {
    final body = await _api.post('/v1/memories/extract', body: {
      'user_message': userMessage,
      'assistant_message': assistantMessage,
      'chat_id': ?chatId,
      'auto_save': autoSave,
    });
    final data = (body['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final cand = (data['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final saved = (data['saved'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MemoryEntry.fromJson)
        .toList(growable: false);
    return MemoryExtractionResult(candidates: cand, saved: saved);
  }
}
