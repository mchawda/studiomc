# Data Model

## Entities

| Entity | Description |
|--------|-------------|
| Settings | Key-value app configuration |
| Model | Registered AI model (downloaded or local) |
| Benchmark | Performance measurement per model per hardware |
| Chat | Conversation session with model + mode |
| Message | Single message, supports branching via parent_message_id |
| Document | Uploaded document for CLaRa/RAG processing |
| Collection | Folder grouping documents for scoped retrieval |
| CollectionDocument | Join table: collections ↔ documents |
| DocChunk | Text chunk (500-1000 tokens) for embedding |
| VectorIndex | Vector search index per collection |
| ClaraVector | Compressed latent vector per chunk (CLaRa) |
| ClaraMapping | Source text offset mapping for citations |
| ClaraIndex | CLaRa latent index per collection |
| ClaraRun | CLaRa query execution record |
| ReasoningRun | LRE investigation session with trace + citations |

See `schema.sql` for full CREATE TABLE statements.
