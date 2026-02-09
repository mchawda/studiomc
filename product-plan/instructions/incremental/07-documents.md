# Milestone 7: Documents

## Goal
Document library with CLaRa-powered ingestion and cited answers.

## Tasks
1. Documents screen: grid/list toggle, upload button + drag-drop zone
2. Document card: type icon (PDF/TXT/MD), filename, size, date, status, progress bar during processing
3. Upload flow: accept files → "Preparing knowledge" with progress → "Ready to chat"
4. Backend ingestion pipeline: extract text → normalize → chunk (500-1000 tokens) → CLaRa compress → store latent vectors
5. Collections: create/rename/delete, add documents, document count badge
6. "Chat with this document" / "Chat with collection" → opens chat in Docs mode
7. Quality toggle in right panel: Fast (latent-only) / Cited (default, latent + snippets) / Deep (iterative)
8. Groundedness meter in right panel: percentage bar (green/yellow/red) + source count
9. Citations: inline badges in assistant responses → tap to see source snippet
10. "No source found" banner when system cannot ground answer
11. Empty state: "Upload your first document" with prominent drag-drop zone
12. Backend: upload, extract, CLaRa ingest + status, CLaRa query, CLaRa answer with citations

## Reference
- `sections/documents/spec.md`, `types.ts`, `data.json`
- `product/performance-engineering.md` for CLaRa implementation phases

## Acceptance
- Upload PDF/TXT/MD files successfully
- Ingestion shows progress, completes to "Ready"
- Collections group documents
- "Chat with document" opens Docs mode with cited answers
- Groundedness meter shows accurate source percentage
- Citations link to source documents
