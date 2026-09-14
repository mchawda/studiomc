// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'engine.dart';

class TextChunk {
  final String id;
  final String documentId;
  final String text;
  final int index;
  final List<double>? embedding;

  const TextChunk({
    required this.id,
    required this.documentId,
    required this.text,
    required this.index,
    this.embedding,
  });

  TextChunk withEmbedding(List<double> vector) {
    return TextChunk(
      id: id,
      documentId: documentId,
      text: text,
      index: index,
      embedding: vector,
    );
  }
}

class ScoredChunk {
  final TextChunk chunk;
  final double score;

  const ScoredChunk({required this.chunk, required this.score});
}

abstract class ChunkStore {
  Future<void> upsert(TextChunk chunk);

  Future<List<TextChunk>> all();

  Future<void> deleteDocument(String documentId);

  Future<int> get length;
}

class InMemoryChunkStore implements ChunkStore {
  final Map<String, TextChunk> _chunks = {};

  @override
  Future<void> upsert(TextChunk chunk) async {
    _chunks[chunk.id] = chunk;
  }

  @override
  Future<List<TextChunk>> all() async => _chunks.values.toList();

  @override
  Future<void> deleteDocument(String documentId) async {
    _chunks.removeWhere((_, chunk) => chunk.documentId == documentId);
  }

  @override
  Future<int> get length async => _chunks.length;
}

/// Persistent chunk store. Use an injected [Database] (FFI in tests).
class SqliteChunkStore implements ChunkStore {
  SqliteChunkStore(this._db);

  final Database _db;

  static const table = 'rag_chunks';

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        text TEXT NOT NULL,
        embedding_json TEXT,
        chunk_index INTEGER NOT NULL
      )
    ''');
  }

  @override
  Future<void> upsert(TextChunk chunk) async {
    await _db.insert(
      table,
      {
        'id': chunk.id,
        'document_id': chunk.documentId,
        'text': chunk.text,
        'embedding_json':
            chunk.embedding == null ? null : jsonEncode(chunk.embedding),
        'chunk_index': chunk.index,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<TextChunk>> all() async {
    final rows = await _db.query(table, orderBy: 'document_id, chunk_index');
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    await _db.delete(table, where: 'document_id = ?', whereArgs: [documentId]);
  }

  @override
  Future<int> get length async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (rows.first['c'] as int?) ?? 0;
  }

  TextChunk _fromRow(Map<String, Object?> row) {
    final raw = row['embedding_json'] as String?;
    List<double>? embedding;
    if (raw != null && raw.isNotEmpty) {
      embedding = (jsonDecode(raw) as List<dynamic>)
          .map((v) => (v as num).toDouble())
          .toList();
    }
    return TextChunk(
      id: row['id'] as String,
      documentId: row['document_id'] as String,
      text: row['text'] as String,
      index: row['chunk_index'] as int,
      embedding: embedding,
    );
  }
}

class SimpleChunker {
  const SimpleChunker();

  List<String> split(String text, {int maxChars = 400, int overlap = 40}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.length <= maxChars) return [trimmed];
    if (overlap < 0) overlap = 0;
    if (overlap >= maxChars) overlap = maxChars ~/ 4;

    final chunks = <String>[];
    var start = 0;
    while (start < trimmed.length) {
      final end = start + maxChars < trimmed.length
          ? start + maxChars
          : trimmed.length;
      chunks.add(trimmed.substring(start, end));
      if (end >= trimmed.length) break;
      final next = end - overlap;
      start = next <= start ? end : next;
    }
    return chunks;
  }
}

/// Retrieve-then-generate on device. Chat can call this instead of Python RAG.
class OnDeviceRag {
  OnDeviceRag({
    required this.engine,
    ChunkStore? store,
    SimpleChunker? chunker,
  })  : store = store ?? InMemoryChunkStore(),
        chunker = chunker ?? const SimpleChunker();

  final MobileInferenceEngine engine;
  final ChunkStore store;
  final SimpleChunker chunker;

  Future<int> index({
    required String documentId,
    required String text,
    int maxChars = 400,
    int overlap = 40,
  }) async {
    await store.deleteDocument(documentId);
    final pieces = chunker.split(text, maxChars: maxChars, overlap: overlap);
    for (var i = 0; i < pieces.length; i++) {
      final embedding = await engine.embed(pieces[i]);
      await store.upsert(TextChunk(
        id: '$documentId#$i',
        documentId: documentId,
        text: pieces[i],
        index: i,
        embedding: embedding,
      ));
    }
    return pieces.length;
  }

  Future<List<ScoredChunk>> retrieve(String query, {int topK = 4}) async {
    final queryVec = await engine.embed(query);
    final scored = <ScoredChunk>[];
    for (final chunk in await store.all()) {
      final vec = chunk.embedding ?? await engine.embed(chunk.text);
      scored.add(ScoredChunk(
        chunk: chunk.embedding == null ? chunk.withEmbedding(vec) : chunk,
        score: cosineSimilarity(queryVec, vec),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.length <= topK) return scored;
    return scored.sublist(0, topK);
  }

  Stream<String> retrieveThenGenerate({
    required String query,
    List<ChatTurn> messages = const [],
    int topK = 4,
  }) async* {
    final hits = await retrieve(query, topK: topK);
    final context = hits.map((h) => h.chunk.text).join('\n\n');
    final prompt = StringBuffer()
      ..writeln('Use the following context to answer the question.')
      ..writeln()
      ..writeln(context)
      ..writeln()
      ..writeln('Question: $query');
    if (messages.isNotEmpty) {
      prompt.writeln();
      prompt.writeln(CompletionRequest(messages: messages).resolvedPrompt);
    }
    yield* engine.streamTokens(CompletionRequest(prompt: prompt.toString()));
  }
}
