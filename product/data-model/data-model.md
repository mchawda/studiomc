# Data Model

## Entities

### Settings
Key-value store for app configuration and preferences.
- key (PK), value

### Model
Registered AI model from any backend.
- id (PK), name, source (hf|local|ollama|lmstudio|frontier), source_ref, backend_id (FK→Backend, nullable), params_billion, quant, disk_bytes, arch, context_max, checksum, manifest_json, created_at, last_used_at
- Has many: Benchmarks, Chats

### Backend
A configured inference backend (local or cloud).
- id (PK), type (ollama|lmstudio|airllm|frontier), name, endpoint_url, api_key_ref (OS keychain reference, nullable), provider (openai|anthropic|google|mistral|custom, nullable for local), is_enabled, is_auto_detected, last_probed_at, status (connected|disconnected|error), created_at
- Has many: Models

### Benchmark
Performance measurement for a model on specific hardware.
- id (PK), model_id (FK→Model), hw_fingerprint, disk_read_mbps, ttft_ms, tok_per_s, notes, created_at

### Chat
A conversation session with a model and mode.
- id (PK), title, model_id (FK→Model), mode (default|writing|coding|tutor), created_at, updated_at
- Has many: Messages, ReasoningRuns

### Message
A single message in a conversation. Supports branching via parent_message_id.
- id (PK), chat_id (FK→Chat), role (system|user|assistant|tool), content, tokens, created_at, parent_message_id

### Document
An uploaded document for CLaRa/RAG processing.
- id (PK), filename, mime, bytes, sha256, created_at
- Has many: DocChunks. Belongs to many: Collections

### Collection
A folder/group of documents for scoped retrieval.
- id (PK), name, created_at
- Has many: Documents, VectorIndexes, ClaraIndexes

### CollectionDocument
Join table: collections ↔ documents.
- collection_id (FK), document_id (FK) — composite PK

### DocChunk
Text chunk (500–1000 tokens) from a document for embedding/retrieval.
- id (PK), document_id (FK→Document), chunk_index, text, token_count, metadata_json

### VectorIndex
Vector search index for a collection.
- id (PK), collection_id (FK→Collection), embed_model, dims, path, created_at

### ClaraVector
Compressed latent vector for a chunk (CLaRa compression engine).
- doc_chunk_id (FK→DocChunk), vector_blob, dims, compressor_version, created_at

### ClaraMapping
Source text offset mapping for citation from latent vectors.
- doc_chunk_id (FK→DocChunk), source_offsets_json, sha256

### ClaraIndex
CLaRa latent vector index for a collection.
- collection_id (FK→Collection), path, dims, created_at

### ClaraRun
A CLaRa query execution record.
- chat_id (FK→Chat), mode (fast|cited|investigate), top_k, cited_mode, metrics_json

### ReasoningRun
A reasoning/investigation session (LRE orchestrator).
- id (PK), chat_id (FK→Chat), mode (fast|cited|investigate), budgets_json, trace_json, citations_json, metrics_json, created_at

---

## SQL Schema

```sql
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE backends (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,           -- ollama|lmstudio|airllm|frontier
  name TEXT NOT NULL,
  endpoint_url TEXT,
  api_key_ref TEXT,             -- OS keychain reference (null for local)
  provider TEXT,                -- openai|anthropic|google|mistral|custom (null for local)
  is_enabled INTEGER NOT NULL DEFAULT 1,
  is_auto_detected INTEGER NOT NULL DEFAULT 0,
  last_probed_at TEXT,
  status TEXT NOT NULL DEFAULT 'disconnected', -- connected|disconnected|error
  created_at TEXT
);

CREATE TABLE models (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  source TEXT NOT NULL,         -- hf|local|ollama|lmstudio|frontier
  source_ref TEXT,
  backend_id TEXT,              -- FK to backends (null for built-in AirLLM)
  params_billion REAL,
  quant TEXT,
  disk_bytes INTEGER,
  arch TEXT,
  context_max INTEGER,
  checksum TEXT,
  manifest_json TEXT,
  created_at TEXT,
  last_used_at TEXT,
  FOREIGN KEY(backend_id) REFERENCES backends(id)
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
```
