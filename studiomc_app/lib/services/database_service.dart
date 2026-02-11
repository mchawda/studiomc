// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// SQLite database service — single source of truth for local data.
class DatabaseService {
  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'studiomc.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE models (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        source TEXT NOT NULL,
        source_ref TEXT,
        params_billion REAL,
        quant TEXT,
        disk_bytes INTEGER,
        arch TEXT,
        context_max INTEGER,
        checksum TEXT,
        manifest_json TEXT,
        created_at TEXT,
        last_used_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE benchmarks (
        id TEXT PRIMARY KEY,
        model_id TEXT,
        hw_fingerprint TEXT,
        disk_read_mbps REAL,
        ttft_ms INTEGER,
        tok_per_s REAL,
        notes TEXT,
        created_at TEXT,
        FOREIGN KEY(model_id) REFERENCES models(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE chats (
        id TEXT PRIMARY KEY,
        title TEXT,
        model_id TEXT,
        mode TEXT,
        created_at TEXT,
        updated_at TEXT,
        FOREIGN KEY(model_id) REFERENCES models(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        tokens INTEGER,
        created_at TEXT,
        parent_message_id TEXT,
        FOREIGN KEY(chat_id) REFERENCES chats(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        filename TEXT,
        mime TEXT,
        bytes INTEGER,
        sha256 TEXT,
        created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE collection_documents (
        collection_id TEXT,
        document_id TEXT,
        PRIMARY KEY(collection_id, document_id),
        FOREIGN KEY(collection_id) REFERENCES collections(id),
        FOREIGN KEY(document_id) REFERENCES documents(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE doc_chunks (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        chunk_index INTEGER,
        text TEXT,
        token_count INTEGER,
        metadata_json TEXT,
        FOREIGN KEY(document_id) REFERENCES documents(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE reasoning_runs (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        mode TEXT NOT NULL,
        budgets_json TEXT NOT NULL,
        trace_json TEXT,
        citations_json TEXT,
        metrics_json TEXT,
        created_at TEXT,
        FOREIGN KEY(chat_id) REFERENCES chats(id)
      )
    ''');

    // Memory summaries — rolling context across sessions
    await db.execute('''
      CREATE TABLE memory_summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id TEXT NOT NULL,
        summary TEXT NOT NULL,
        token_count INTEGER,
        created_at TEXT,
        FOREIGN KEY(chat_id) REFERENCES chats(id)
      )
    ''');

    // Global memory — cross-session facts/preferences
    await db.execute('''
      CREATE TABLE memory_global (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fact TEXT NOT NULL,
        source_chat_id TEXT,
        created_at TEXT
      )
    ''');

    // Training adapters
    await db.execute('''
      CREATE TABLE adapters (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        base_model_id TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_ref TEXT,
        disk_bytes INTEGER DEFAULT 0,
        created_at TEXT,
        last_used_at TEXT,
        is_active INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(base_model_id) REFERENCES models(id)
      )
    ''');

    // Training runs
    await db.execute('''
      CREATE TABLE training_runs (
        id TEXT PRIMARY KEY,
        adapter_id TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        progress_percent REAL DEFAULT 0.0,
        eta_seconds INTEGER,
        error_message TEXT,
        metrics_json TEXT,
        started_at TEXT,
        completed_at TEXT,
        FOREIGN KEY(adapter_id) REFERENCES adapters(id)
      )
    ''');
  }

  // ── Chat operations ──

  Future<List<Map<String, dynamic>>> getChats() async {
    final db = await database;
    return db.query('chats', orderBy: 'updated_at DESC');
  }

  Future<Map<String, dynamic>> createChat(Map<String, dynamic> chat) async {
    final db = await database;
    await db.insert('chats', chat);
    return chat;
  }

  Future<void> updateChat(String id, Map<String, dynamic> data) async {
    final db = await database;
    await db.update('chats', data, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteChat(String id) async {
    final db = await database;
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [id]);
    await db.delete('chats', where: 'id = ?', whereArgs: [id]);
  }

  // ── Message operations ──

  Future<List<Map<String, dynamic>>> getMessages(String chatId) async {
    final db = await database;
    return db.query('messages',
        where: 'chat_id = ?', whereArgs: [chatId], orderBy: 'created_at ASC');
  }

  Future<void> insertMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert('messages', message);
  }

  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  // ── Settings operations ──

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── Search operations ──

  /// Search messages across all chats using LIKE matching.
  /// Returns messages whose content matches the query, along with chat info.
  Future<List<Map<String, dynamic>>> searchMessages(String query,
      {int limit = 50}) async {
    final db = await database;
    final searchTerm = '%$query%';
    return db.rawQuery(
      '''SELECT m.id, m.chat_id, m.role, m.content, m.created_at,
                c.title AS chat_title
         FROM messages m
         LEFT JOIN chats c ON c.id = m.chat_id
         WHERE m.content LIKE ?
         ORDER BY m.created_at DESC
         LIMIT ?''',
      [searchTerm, limit],
    );
  }

  // ── Document operations ──

  Future<List<Map<String, dynamic>>> getDocuments() async {
    final db = await database;
    return db.query('documents', orderBy: 'created_at DESC');
  }

  Future<void> insertDocument(Map<String, dynamic> doc) async {
    final db = await database;
    await db.insert('documents', doc);
  }

  Future<void> deleteDocument(String id) async {
    final db = await database;
    await db.delete('doc_chunks', where: 'document_id = ?', whereArgs: [id]);
    await db.delete('collection_documents',
        where: 'document_id = ?', whereArgs: [id]);
    await db.delete('documents', where: 'id = ?', whereArgs: [id]);
  }

  // ── Collection operations ──

  Future<List<Map<String, dynamic>>> getCollections() async {
    final db = await database;
    return db.query('collections', orderBy: 'created_at DESC');
  }

  Future<void> insertCollection(Map<String, dynamic> collection) async {
    final db = await database;
    await db.insert('collections', collection);
  }

  // ── Model operations ──

  Future<List<Map<String, dynamic>>> getModels() async {
    final db = await database;
    return db.query('models', orderBy: 'last_used_at DESC');
  }

  Future<void> insertModel(Map<String, dynamic> model) async {
    final db = await database;
    await db.insert('models', model,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteModel(String id) async {
    final db = await database;
    await db.delete('benchmarks', where: 'model_id = ?', whereArgs: [id]);
    await db.delete('models', where: 'id = ?', whereArgs: [id]);
  }

  // ── Benchmark operations ──

  Future<List<Map<String, dynamic>>> getBenchmarks(String modelId) async {
    final db = await database;
    return db.query('benchmarks',
        where: 'model_id = ?',
        whereArgs: [modelId],
        orderBy: 'created_at DESC');
  }

  Future<void> insertBenchmark(Map<String, dynamic> benchmark) async {
    final db = await database;
    await db.insert('benchmarks', benchmark);
  }

  // ── Memory operations ──

  /// Save a rolling summary for a chat.
  Future<void> saveChatSummary(
      String chatId, String summary, int tokenCount) async {
    final db = await database;
    // Keep only the latest summary per chat
    await db
        .delete('memory_summaries', where: 'chat_id = ?', whereArgs: [chatId]);
    await db.insert('memory_summaries', {
      'chat_id': chatId,
      'summary': summary,
      'token_count': tokenCount,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Get the latest summary for a chat.
  Future<String?> getChatSummary(String chatId) async {
    final db = await database;
    final rows = await db.query('memory_summaries',
        where: 'chat_id = ?', whereArgs: [chatId], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['summary'] as String?;
  }

  /// Save a global memory fact.
  Future<void> saveGlobalFact(String fact, {String? chatId}) async {
    final db = await database;
    await db.insert('memory_global', {
      'fact': fact,
      'source_chat_id': chatId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Get all global memory facts (most recent first, up to limit).
  Future<List<String>> getGlobalFacts({int limit = 20}) async {
    final db = await database;
    final rows = await db.query('memory_global',
        orderBy: 'created_at DESC', limit: limit);
    return rows.map((r) => r['fact'] as String).toList();
  }

  /// Get global facts with their IDs for management UI.
  Future<List<Map<String, dynamic>>> getGlobalFactsWithId(
      {int limit = 100}) async {
    final db = await database;
    return db.query('memory_global', orderBy: 'created_at DESC', limit: limit);
  }

  /// Update an existing global fact by ID.
  Future<void> updateGlobalFact(int id, String newFact) async {
    final db = await database;
    await db.update('memory_global', {'fact': newFact},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Delete a global fact by ID.
  Future<void> deleteGlobalFact(int id) async {
    final db = await database;
    await db.delete('memory_global', where: 'id = ?', whereArgs: [id]);
  }

  /// Ensure memory tables exist (for existing DBs created before memory).
  Future<void> ensureMemoryTables() async {
    final db = await database;
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memory_summaries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          chat_id TEXT NOT NULL,
          summary TEXT NOT NULL,
          token_count INTEGER,
          created_at TEXT,
          FOREIGN KEY(chat_id) REFERENCES chats(id)
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memory_global (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          fact TEXT NOT NULL,
          source_chat_id TEXT,
          created_at TEXT
        )
      ''');
    } catch (_) {}
  }

  // ── Adapter operations ──

  Future<List<Map<String, dynamic>>> getAdapters() async {
    final db = await database;
    return db.query('adapters', orderBy: 'created_at DESC');
  }

  Future<void> insertAdapter(Map<String, dynamic> adapter) async {
    final db = await database;
    await db.insert('adapters', adapter,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateAdapter(String id, Map<String, dynamic> data) async {
    final db = await database;
    await db.update('adapters', data, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAdapter(String id) async {
    final db = await database;
    await db.delete('training_runs', where: 'adapter_id = ?', whereArgs: [id]);
    await db.delete('adapters', where: 'id = ?', whereArgs: [id]);
  }

  // ── Training run operations ──

  Future<List<Map<String, dynamic>>> getTrainingRuns(
      {String? adapterId}) async {
    final db = await database;
    if (adapterId != null) {
      return db.query('training_runs',
          where: 'adapter_id = ?',
          whereArgs: [adapterId],
          orderBy: 'started_at DESC');
    }
    return db.query('training_runs', orderBy: 'started_at DESC');
  }

  Future<void> insertTrainingRun(Map<String, dynamic> run) async {
    final db = await database;
    await db.insert('training_runs', run);
  }

  Future<void> updateTrainingRun(
      String id, Map<String, dynamic> data) async {
    final db = await database;
    await db.update('training_runs', data, where: 'id = ?', whereArgs: [id]);
  }

  /// Ensure training tables exist (for existing DBs created before training).
  Future<void> ensureTrainingTables() async {
    final db = await database;
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS adapters (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          base_model_id TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_ref TEXT,
          disk_bytes INTEGER DEFAULT 0,
          created_at TEXT,
          last_used_at TEXT,
          is_active INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY(base_model_id) REFERENCES models(id)
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS training_runs (
          id TEXT PRIMARY KEY,
          adapter_id TEXT,
          status TEXT NOT NULL DEFAULT 'pending',
          progress_percent REAL DEFAULT 0.0,
          eta_seconds INTEGER,
          error_message TEXT,
          metrics_json TEXT,
          started_at TEXT,
          completed_at TEXT,
          FOREIGN KEY(adapter_id) REFERENCES adapters(id)
        )
      ''');
    } catch (_) {}
  }

  // ── Document content storage ──

  /// Store document text content locally.
  Future<void> saveDocumentContent(String docId, String content) async {
    final db = await database;
    await db.insert('doc_chunks', {
      'id': 'chunk-$docId-0',
      'document_id': docId,
      'chunk_index': 0,
      'text': content,
      'token_count': content.split(' ').length,
    });
  }

  /// Get all text content for a document.
  Future<String?> getDocumentContent(String docId) async {
    final db = await database;
    final rows = await db.query('doc_chunks',
        where: 'document_id = ?',
        whereArgs: [docId],
        orderBy: 'chunk_index ASC');
    if (rows.isEmpty) return null;
    return rows.map((r) => r['text'] as String).join('\n');
  }
}
