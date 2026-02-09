# Section: Investigate (LRE)

## Overview
Deep reasoning mode powered by the Local Reasoning Environment. The model uses safe tools to search, grep, open, summarize, and cite documents. Shows an explainable trace panel so users see exactly what happened. Bounded by budgets to stay predictable.

## Shell Integration
Inside shell — activated via mode selector (Chat / Docs / **Investigate**). Right panel shows trace.

## Layout
- **Center**: same chat interface as Chat section
- **Right panel**: explainable trace panel (collapsible steps)
- **Top bar**: mode shows "Investigate" with depth/budget indicator

## User Flows

### Flow 1: Start Investigation
1. User switches to Investigate mode (or types a complex document question)
2. User sends query
3. Recursive Orchestrator runs: plan → tool → observe → decide (answer or sub-query)
4. Each step appears live in the trace panel on the right
5. Final answer appears in chat with citations

### Flow 2: Read Trace
1. Trace panel shows collapsible steps:
   - "Search: 'revenue growth' in Work Documents" (45ms)
   - "Opened: quarterly-report-q4.pdf (p3–p4)" (12ms)
   - "Extracted: table rows 12–17" (28ms)
   - "Cited: quarterly-report-q4.pdf" (8ms)
2. User can expand each step to see details
3. Total time and budget usage shown at bottom

### Flow 3: Budget Exceeded
1. If query exceeds budgets (6 tool calls, depth 2, 8k tokens, 20s)
2. Model returns best-effort answer
3. Shows: "I stopped because I reached the search limit. Here's what I found so far."
4. Suggestion: "Want me to try a different approach?"

### Flow 4: No Evidence Found
1. If system cannot find evidence in documents
2. Shows: "I can't find this in your documents. Want me to broaden the search or check another folder?"
3. No fake confidence — ever

## UI Requirements
- Trace panel: vertical timeline of steps, each with icon (search/open/extract/cite), description, duration
- Steps animate in as they execute (live feel)
- Budget indicator: small bar showing tool calls used / max, time used / max
- Citations in answer: inline badges linking to source document + span
- "Stopped" banner: yellow warning style when budget exceeded
- "No source" banner: clear, honest, actionable

## Scope Boundaries
- No general shell access — LRE is sandboxed, safe tools only
- No file writes — read-only access to user-approved folders
- No image analysis from documents
- Max 6 tool calls, depth 2, 8k tokens, 20s wall-clock per query

## LRE Safe Tools
| Tool | Description |
|------|-------------|
| `search(query, scope)` | Search across documents/collections |
| `grep(pattern, files)` | Pattern match in specific files |
| `open(doc_id, span)` | Open a document at specific section |
| `summarize(doc_id, span)` | Summarize a document section |
| `table_extract(doc_id, span)` | Extract table data (regex + heuristics) |
| `cite(doc_id, span)` | Return citation object for source |
