# Milestone 8: Investigate (LRE)

## Goal
Deep reasoning with safe tools, recursive orchestration, and explainable trace.

## Tasks
1. Investigate mode activates via mode selector in top bar
2. Right panel becomes trace panel with vertical timeline
3. Recursive Orchestrator: plan → tool call → observe result → decide (answer or sub-query)
4. Trace steps animate in live as they execute:
   - Icon per tool type (search/grep/open/summarize/table_extract/cite)
   - Description text
   - Duration badge
5. Budget indicator at bottom of trace: tool calls X/6, depth X/2, tokens X/8k, time X/20s
6. LRE safe tools implementation:
   - `search(query, scope)` — search across documents/collections
   - `grep(pattern, files)` — pattern match in specific files
   - `open(doc_id, span)` — open document at section
   - `summarize(doc_id, span)` — summarize section
   - `table_extract(doc_id, span)` — extract table data
   - `cite(doc_id, span)` — return citation object
7. Citations in final answer: inline badges with source links
8. Budget exceeded: yellow banner "I stopped because I reached the search limit" + "Try different approach?"
9. No evidence: "I can't find this in your documents" + "Broaden search?" — never fake confidence
10. Backend: POST /reasoning/run, LRE tool endpoints, sandboxed execution (no shell, read-only)
11. Security: approved folders only, strict parameter validation, no file writes

## Reference
- `sections/investigate/spec.md`, `types.ts`, `data.json`
- `product/security-and-licensing.md` for LRE security model

## Acceptance
- Investigate mode shows trace panel with live step animation
- Tools execute and return results
- Budget indicator updates in real-time
- Budget exceeded shows honest explanation
- No evidence shows honest "I can't find" message
- Citations link correctly to source documents
- No unauthorized file system access
