# Tests: Documents

## Upload
- Upload PDF file: verify document card appears with PDF icon, filename, size
- Upload TXT file: verify accepted and card shows
- Upload MD file: verify accepted and card shows
- Upload unsupported file type: verify rejected with error message
- Drag-and-drop file: verify upload starts

## Ingestion
- After upload: verify "Preparing knowledge" progress shows
- Verify progress updates over time
- On completion: verify status changes to "Ready to chat" with checkmark
- Verify chunk count populates after processing

## Collections
- Create collection: verify it appears in collections list
- Add document to collection: verify document count updates
- Delete collection: verify removed (documents remain in library)

## Chat with Documents
- Tap "Chat with this document": verify chat opens in Docs mode
- Tap "Chat with collection": verify chat opens in Docs mode
- Send question: verify answer includes inline citation badges
- Tap citation badge: verify source snippet displays

## Quality Modes
- Fast mode: verify answer returns without citations
- Cited mode (default): verify answer includes citations + groundedness meter
- Deep mode: verify more thorough answer with multiple sources

## Groundedness
- Answer with sources: verify meter shows percentage (green > 70%, yellow 40-70%, red < 40%)
- Answer with no sources: verify "No source found" banner shows
- Verify source list in right panel matches inline citations

## Empty State
- No documents: verify "Upload your first document" with drag-drop zone
- No documents in collection: verify empty state with "Add documents" action
