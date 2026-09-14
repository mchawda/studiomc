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

/// One citation in the shape the desktop `Citation` schema uses
/// (`document_id`, `chunk_index`, `snippet`, `relevance_score`) so a
/// mobile answer can be scored by `services/eval` unchanged.
class RagCitation {
  final int sourceNumber;
  final String documentId;
  final int chunkIndex;
  final String snippet;
  final double relevanceScore;

  const RagCitation({
    required this.sourceNumber,
    required this.documentId,
    required this.chunkIndex,
    required this.snippet,
    required this.relevanceScore,
  });

  factory RagCitation.fromHit(int sourceNumber, ScoredChunk hit) {
    final text = hit.chunk.text;
    return RagCitation(
      sourceNumber: sourceNumber,
      documentId: hit.chunk.documentId,
      chunkIndex: hit.chunk.index,
      snippet: text.length > 300 ? text.substring(0, 300) : text,
      relevanceScore: hit.score,
    );
  }

  Map<String, dynamic> toJson() => {
        'source_number': sourceNumber,
        'document_id': documentId,
        'chunk_index': chunkIndex,
        'snippet': snippet,
        'relevance_score': relevanceScore,
      };
}

/// Result of retrieve-then-generate: the numbered sources that went into
/// the prompt plus the token stream. Consumers resolve `[Source N]`
/// markers in the answer against [citations] by `sourceNumber`.
class CitedGeneration {
  final List<RagCitation> citations;
  final Stream<String> tokens;

  const CitedGeneration({required this.citations, required this.tokens});

  /// Citations actually referenced by `[Source N]` in [answer], in order
  /// of first appearance. Unknown N is dropped, matching CLaRa.
  List<RagCitation> citedIn(String answer) {
    final seen = <int>{};
    final out = <RagCitation>[];
    for (final m in sourceMarkerPattern.allMatches(answer)) {
      final n = int.parse(m.group(1)!);
      if (!seen.add(n)) continue;
      for (final c in citations) {
        if (c.sourceNumber == n) {
          out.add(c);
          break;
        }
      }
    }
    return out;
  }

  static final sourceMarkerPattern =
      RegExp(r'\[Source\s+(\d+)\]', caseSensitive: false);
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

  /// Build the grounded prompt in the same shape as `clara.retriever`:
  /// numbered `[Source N | doc=… chunk=…]` blocks, cite-as-`[Source N]`
  /// instruction, and an explicit refusal rule.
  static String buildGroundedPrompt({
    required String query,
    required List<ScoredChunk> hits,
    List<ChatTurn> messages = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln(
      'Answer using ONLY the sources below. Cite each claim inline as '
      '[Source N]. If the sources do not contain the answer, say you '
      'cannot answer from the given sources.',
    );
    buf.writeln();
    buf.writeln('### Sources');
    if (hits.isEmpty) {
      buf.writeln('(no sources retrieved)');
    }
    for (var i = 0; i < hits.length; i++) {
      final c = hits[i].chunk;
      buf.writeln('[Source ${i + 1} | doc=${c.documentId} chunk=${c.index}]');
      buf.writeln(c.text);
      buf.writeln();
    }
    if (messages.isNotEmpty) {
      buf.writeln('### Conversation');
      for (final turn in messages) {
        buf.writeln('${turn.role}: ${turn.content}');
      }
      buf.writeln();
    }
    buf.writeln('### Question');
    buf.writeln(query);
    buf.writeln();
    buf.write('### Answer');
    return buf.toString();
  }

  /// Retrieve, then stream a cited answer. The returned [CitedGeneration]
  /// carries the numbered sources so the UI can render `[Source N]` links
  /// and the eval harness can score precision/recall.
  Future<CitedGeneration> retrieveThenGenerateCited({
    required String query,
    List<ChatTurn> messages = const [],
    int topK = 4,
  }) async {
    final hits = await retrieve(query, topK: topK);
    final citations = <RagCitation>[
      for (var i = 0; i < hits.length; i++) RagCitation.fromHit(i + 1, hits[i]),
    ];
    final prompt = buildGroundedPrompt(
      query: query,
      hits: hits,
      messages: messages,
    );
    return CitedGeneration(
      citations: citations,
      tokens: engine.streamTokens(CompletionRequest(prompt: prompt)),
    );
  }

  /// Token stream only. Prefer [retrieveThenGenerateCited] when the
  /// caller needs to show or score citations.
  Stream<String> retrieveThenGenerate({
    required String query,
    List<ChatTurn> messages = const [],
    int topK = 4,
  }) async* {
    final generation = await retrieveThenGenerateCited(
      query: query,
      messages: messages,
      topK: topK,
    );
    yield* generation.tokens;
  }
}
