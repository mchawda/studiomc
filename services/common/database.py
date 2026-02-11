"""SQLite database layer — async via aiosqlite.

Implements the full schema from product/data-model/data-model.md.
All tables created on first connection if they don't exist.
"""

from __future__ import annotations

import aiosqlite

from .config import DB_PATH, ensure_dirs

_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS models (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    source TEXT NOT NULL CHECK(source IN ('hf', 'local')),
    source_ref TEXT,
    params_billion REAL,
    quant TEXT,
    disk_bytes INTEGER,
    arch TEXT,
    context_max INTEGER,
    checksum TEXT,
    manifest_json TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_used_at TEXT
);

CREATE TABLE IF NOT EXISTS benchmarks (
    id TEXT PRIMARY KEY,
    model_id TEXT NOT NULL,
    hw_fingerprint TEXT NOT NULL,
    disk_read_mbps REAL,
    ttft_ms INTEGER,
    tok_per_s REAL,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(model_id) REFERENCES models(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY,
    title TEXT,
    model_id TEXT,
    mode TEXT NOT NULL DEFAULT 'default' CHECK(mode IN ('default', 'writing', 'coding', 'tutor')),
    pinned INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(model_id) REFERENCES models(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool')),
    content TEXT NOT NULL,
    tokens INTEGER,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    parent_message_id TEXT,
    FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE,
    FOREIGN KEY(parent_message_id) REFERENCES messages(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    mime TEXT,
    bytes INTEGER,
    sha256 TEXT,
    status TEXT NOT NULL DEFAULT 'uploaded' CHECK(status IN ('uploaded', 'extracting', 'chunking', 'indexing', 'ready', 'error')),
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS collection_documents (
    collection_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    PRIMARY KEY(collection_id, document_id),
    FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS doc_chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    text TEXT NOT NULL,
    token_count INTEGER,
    metadata_json TEXT,
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS vector_indexes (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL,
    embed_model TEXT NOT NULL,
    dims INTEGER NOT NULL,
    path TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS clara_vectors (
    doc_chunk_id TEXT NOT NULL,
    vector_blob BLOB,
    dims INTEGER,
    compressor_version TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(doc_chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS clara_mappings (
    doc_chunk_id TEXT NOT NULL,
    source_offsets_json TEXT,
    sha256 TEXT,
    FOREIGN KEY(doc_chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS clara_indexes (
    collection_id TEXT NOT NULL,
    path TEXT NOT NULL,
    dims INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS clara_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT NOT NULL,
    mode TEXT NOT NULL CHECK(mode IN ('fast', 'cited', 'investigate')),
    top_k INTEGER,
    cited_mode TEXT,
    metrics_json TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS reasoning_runs (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL,
    mode TEXT NOT NULL CHECK(mode IN ('fast', 'cited', 'investigate')),
    budgets_json TEXT NOT NULL,
    trace_json TEXT,
    citations_json TEXT,
    metrics_json TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS adapters (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    base_model_id TEXT NOT NULL,
    source_type TEXT NOT NULL CHECK(source_type IN ('collection', 'extract_paste', 'extract_file')),
    source_ref TEXT,
    disk_bytes INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_used_at TEXT,
    is_active INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(base_model_id) REFERENCES models(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS training_runs (
    id TEXT PRIMARY KEY,
    adapter_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'preparing', 'training', 'completed', 'failed')),
    progress_percent REAL DEFAULT 0.0,
    eta_seconds INTEGER,
    error_message TEXT,
    metrics_json TEXT,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    FOREIGN KEY(adapter_id) REFERENCES adapters(id) ON DELETE SET NULL
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_parent ON messages(parent_message_id);
CREATE INDEX IF NOT EXISTS idx_benchmarks_model ON benchmarks(model_id);
CREATE INDEX IF NOT EXISTS idx_doc_chunks_doc ON doc_chunks(document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_chats_updated ON chats(updated_at DESC);
"""


async def get_db() -> aiosqlite.Connection:
    """Open (or create) the database, apply schema, return connection."""
    ensure_dirs()
    db = await aiosqlite.connect(str(DB_PATH))
    db.row_factory = aiosqlite.Row
    await db.execute("PRAGMA journal_mode=WAL")
    await db.execute("PRAGMA foreign_keys=ON")
    await db.executescript(_SCHEMA)
    await db.commit()
    return db


class Database:
    """Singleton-ish async database wrapper used by all services."""

    _instance: Database | None = None
    _db: aiosqlite.Connection | None = None

    @classmethod
    async def instance(cls) -> Database:
        if cls._instance is None:
            cls._instance = Database()
            cls._instance._db = await get_db()
        return cls._instance

    @property
    def conn(self) -> aiosqlite.Connection:
        assert self._db is not None, "Database not initialized"
        return self._db

    async def execute(self, sql: str, params: tuple = ()) -> aiosqlite.Cursor:
        return await self.conn.execute(sql, params)

    async def executemany(self, sql: str, params_seq: list[tuple]) -> aiosqlite.Cursor:
        return await self.conn.executemany(sql, params_seq)

    async def fetchone(self, sql: str, params: tuple = ()) -> aiosqlite.Row | None:
        cursor = await self.conn.execute(sql, params)
        return await cursor.fetchone()

    async def fetchall(self, sql: str, params: tuple = ()) -> list[aiosqlite.Row]:
        cursor = await self.conn.execute(sql, params)
        return await cursor.fetchall()

    async def commit(self) -> None:
        await self.conn.commit()

    async def close(self) -> None:
        if self._db:
            await self._db.close()
            self._db = None
            Database._instance = None
