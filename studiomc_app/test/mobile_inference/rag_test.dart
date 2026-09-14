// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

void main() {
  test('SimpleChunker splits long text with overlap', () {
    final text = List.generate(20, (i) => 'Sentence number $i about widgets.').join(' ');
    final chunks = SimpleChunker().split(text, maxChars: 80, overlap: 16);
    expect(chunks.length, greaterThan(1));
    expect(chunks.first.length, lessThanOrEqualTo(80));
    expect(chunks[1], contains(chunks[0].substring(chunks[0].length - 16)));
  });

  test('InMemoryChunkStore upserts and deletes by document', () async {
    final store = InMemoryChunkStore();
    await store.upsert(const TextChunk(
      id: 'c1',
      documentId: 'doc-a',
      text: 'alpha',
      index: 0,
    ));
    await store.upsert(const TextChunk(
      id: 'c2',
      documentId: 'doc-b',
      text: 'beta',
      index: 0,
    ));
    expect(await store.length, 2);

    await store.deleteDocument('doc-a');
    final remaining = await store.all();
    expect(remaining, hasLength(1));
    expect(remaining.single.documentId, 'doc-b');
  });

  test('SqliteChunkStore persists chunks on the host via FFI', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SqliteChunkStore.ensureTable(db);
    final store = SqliteChunkStore(db);

    await store.upsert(const TextChunk(
      id: 'c1',
      documentId: 'doc-a',
      text: 'alpha',
      index: 0,
      embedding: [0.1, 0.2],
    ));
    expect(await store.length, 1);
    expect((await store.all()).single.text, 'alpha');

    await store.deleteDocument('doc-a');
    expect(await store.length, 0);
    await db.close();
  });

  test('OnDeviceRag retrieves relevant chunks then generates without Python', () async {
    final engine = StubMobileInferenceEngine();
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/models/tiny.gguf',
    ));
    engine.cannedCompletion = 'retrieved answer';

    final rag = OnDeviceRag(engine: engine, store: InMemoryChunkStore());
    await rag.index(
      documentId: 'handbook',
      text: 'Refunds are issued within 14 days. Shipping takes five business days. '
          'The cafeteria serves lunch at noon.',
    );

    final hits = await rag.retrieve('How long for a refund?', topK: 2);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.text.toLowerCase(), contains('refund'));

    final tokens = await rag
        .retrieveThenGenerate(query: 'How long for a refund?', topK: 2)
        .toList();
    expect(tokens.join(), 'retrieved answer');
    expect(engine.lastPrompt, contains('Refunds'));
    expect(engine.lastPrompt, contains('How long for a refund?'));
  });

  test('OnDeviceRag numbers sources like CLaRa and returns citations', () async {
    final engine = StubMobileInferenceEngine();
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-4b',
      modelPath: '/models/4b.gguf',
    ));
    engine.cannedCompletion =
        'Refunds take 14 days [Source 1]. Shipping is five days [Source 2].';

    final rag = OnDeviceRag(engine: engine, store: InMemoryChunkStore());
    await rag.index(
      documentId: 'handbook',
      text: 'Refunds are issued within 14 days.',
      maxChars: 400,
    );
    await rag.index(
      documentId: 'shipping',
      text: 'Shipping takes five business days.',
      maxChars: 400,
    );

    final gen = await rag.retrieveThenGenerateCited(
      query: 'How long for a refund and shipping?',
      topK: 2,
    );
    expect(gen.citations, hasLength(2));
    expect(gen.citations.map((c) => c.sourceNumber), [1, 2]);

    final answer = (await gen.tokens.toList()).join();
    final prompt = engine.lastPrompt!;
    // CLaRa prompt shape: numbered source blocks + cite instruction + refusal rule.
    expect(prompt, contains('[Source 1 | doc='));
    expect(prompt, contains('[Source 2 | doc='));
    expect(prompt, contains('Cite each claim inline as [Source N]'));
    expect(prompt, contains('cannot answer from the given sources'));
    expect(prompt, contains('### Question'));

    final cited = gen.citedIn(answer);
    expect(cited, hasLength(2));
    expect(cited.map((c) => c.documentId).toSet(), {'handbook', 'shipping'});
    // Desktop Citation field names, so services/eval can score this directly.
    final json = cited.first.toJson();
    expect(json.keys, containsAll(['document_id', 'chunk_index', 'snippet', 'relevance_score']));
    // Unknown [Source 9] is dropped; duplicates are collapsed.
    expect(gen.citedIn('x [Source 1] y [Source 1] z [Source 9]'), hasLength(1));
  });

  test('OnDeviceRag with an empty store still prompts for a refusal', () async {
    final engine = StubMobileInferenceEngine();
    await engine.load(const LoadModelRequest(
      modelId: 'studiomc-0.6b',
      modelPath: '/models/tiny.gguf',
    ));
    final rag = OnDeviceRag(engine: engine, store: InMemoryChunkStore());
    final gen = await rag.retrieveThenGenerateCited(query: 'Who is the CEO?');
    expect(gen.citations, isEmpty);
    await gen.tokens.drain<void>();
    expect(engine.lastPrompt, contains('(no sources retrieved)'));
  });
}
