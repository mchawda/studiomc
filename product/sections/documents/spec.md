# Section: Documents

## Overview
Document library with collections. Upload PDF/TXT/MD → CLaRa compression-native ingestion runs in background. Chat with documents using three modes: Fast answers, Cited answers, Deep research. Groundedness meter shows trust level.

## Shell Integration
Inside shell — accessible via sidebar "Documents" nav item. "Chat with this document" opens chat view in Docs mode.

## Layout
- **Library view**: grid or list of all documents with metadata (name, type, size, date)
- **Collections view**: folders grouping documents
- **Document detail**: preview + metadata + "Chat with this document" button
- **Ingestion progress**: inline on document card during "Preparing knowledge"

## User Flows

### Flow 1: Upload Documents
1. Tap "Upload" or drag-and-drop files
2. Accept PDF, TXT, MD files
3. UI shows: "Preparing knowledge (2–5 min)" with progress bar
4. Background: extract text → normalize → chunk (500-1000 tokens) → CLaRa compress → store latent vectors
5. When done: document card shows checkmark, "Ready to chat"

### Flow 2: Create Collection
1. Tap "New Collection" → name it
2. Drag documents into collection or select + add
3. Collection builds combined index automatically

### Flow 3: Chat with Documents
1. Tap "Chat with this document" (or select collection → "Chat")
2. Opens chat view in Docs mode automatically
3. User asks question → CLaRa retrieves latent vectors → generates answer with citations
4. Groundedness meter shows in right panel
5. Sources listed below answer with filename + snippet

### Flow 4: Quality Mode Toggle
1. In Docs/Investigate chat, toggle in right panel:
   - **Fast answers**: latent-only, fastest
   - **Cited answers**: latent + text snippets, shows citations (default)
   - **Deep research**: iterative retrieval, slower but thorough

## UI Requirements
- Document card: icon by type (PDF/TXT/MD), filename, size, date, status badge
- Ingestion progress: subtle progress bar on card, no jargon ("Preparing knowledge...")
- Collection: folder icon, document count, "Chat" button
- Empty state: "Upload your first document" with drag-drop zone
- Groundedness meter: percentage bar (green/yellow/red) + source count
- Citation inline: small source badge after relevant sentences in assistant response

## Scope Boundaries
- No document editing
- No OCR (PDF text extraction only)
- No image/table extraction from PDFs (text only, tables via heuristics in Investigate mode)
