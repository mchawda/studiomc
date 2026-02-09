CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

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
);

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
);

CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  title TEXT,
  model_id TEXT,
  mode TEXT,
  created_at TEXT,
  updated_at TEXT,
  FOREIGN KEY(model_id) REFERENCES models(id)
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  tokens INTEGER,
  created_at TEXT,
  parent_message_id TEXT,
  FOREIGN KEY(chat_id) REFERENCES chats(id)
);

CREATE TABLE documents (
  id TEXT PRIMARY KEY,
  filename TEXT,
  mime TEXT,
  bytes INTEGER,
  sha256 TEXT,
  created_at TEXT
);

CREATE TABLE collections (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT
);

CREATE TABLE collection_documents (
  collection_id TEXT,
  document_id TEXT,
  PRIMARY KEY(collection_id, document_id),
  FOREIGN KEY(collection_id) REFERENCES collections(id),
  FOREIGN KEY(document_id) REFERENCES documents(id)
);

CREATE TABLE doc_chunks (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL,
  chunk_index INTEGER,
  text TEXT,
  token_count INTEGER,
  metadata_json TEXT,
  FOREIGN KEY(document_id) REFERENCES documents(id)
);

CREATE TABLE vector_indexes (
  id TEXT PRIMARY KEY,
  collection_id TEXT NOT NULL,
  embed_model TEXT NOT NULL,
  dims INTEGER NOT NULL,
  path TEXT NOT NULL,
  created_at TEXT,
  FOREIGN KEY(collection_id) REFERENCES collections(id)
);

CREATE TABLE clara_vectors (
  doc_chunk_id TEXT NOT NULL,
  vector_blob BLOB,
  dims INTEGER,
  compressor_version TEXT,
  created_at TEXT,
  FOREIGN KEY(doc_chunk_id) REFERENCES doc_chunks(id)
);

CREATE TABLE clara_mappings (
  doc_chunk_id TEXT NOT NULL,
  source_offsets_json TEXT,
  sha256 TEXT,
  FOREIGN KEY(doc_chunk_id) REFERENCES doc_chunks(id)
);

CREATE TABLE clara_indexes (
  collection_id TEXT NOT NULL,
  path TEXT NOT NULL,
  dims INTEGER NOT NULL,
  created_at TEXT,
  FOREIGN KEY(collection_id) REFERENCES collections(id)
);

CREATE TABLE clara_runs (
  chat_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  top_k INTEGER,
  cited_mode TEXT,
  metrics_json TEXT,
  FOREIGN KEY(chat_id) REFERENCES chats(id)
);

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
);
