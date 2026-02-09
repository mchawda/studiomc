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
}
