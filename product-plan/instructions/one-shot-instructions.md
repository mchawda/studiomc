# Studiomc — Full Implementation Instructions

## Milestone 1: Foundation
**Goal:** Project setup, design tokens, data model, routing.

### Tasks
1. Create Flutter project targeting macOS (primary), Windows, iOS, Android
2. Set up project structure:
   ```
   lib/
     screens/
     widgets/
     services/
     models/
     utils/
   services/
     inference/
     model_manager/
     documents/
     clara/
     lre/
     orchestrator/
   ```
3. Implement design tokens as Flutter theme:
   - Primary: blue-600 (light) / blue-400 (dark)
   - Background: slate-50 (light) / slate-900 (dark)
   - Fonts: Space Grotesk (headings), Inter (body), JetBrains Mono (code)
   - Border radius: 8px default
4. Create SQLite database with full schema (see `data-model/schema.sql`)
5. Create Dart model classes from TypeScript interfaces in each section
6. Set up routing: Onboarding → Home/Chat → Models → Documents → Performance → Settings
7. Set up Python service scaffold with FastAPI + WebSocket support

---

## Milestone 2: Shell
**Goal:** Application shell with sidebar navigation.

### Tasks
1. Build sidebar layout (ChatGPT-style):
   - Left sidebar (280px, collapsible): New Chat button, conversation list, Documents nav, Settings gear
   - Center: main content area
   - Right panel (320px, toggleable): context panel
2. Implement conversation list in sidebar (grouped: today/yesterday/older)
3. Top bar: model indicator + speed badge, mode selector (Chat/Docs/Investigate), theme toggle
4. Responsive: desktop (sidebar visible), tablet (hamburger), mobile (drawer + bottom tabs)
5. Theme toggle: light/dark mode switching with design tokens
6. Empty state for center area

---

## Milestone 3: Onboarding
**Goal:** 5-step wizard from install to first chat.

### Tasks
1. Centered card layout on branded gradient background (blue tones)
2. Step 1 — Welcome: "Local AI. Private by default." + Get Started / I already have a model
3. Step 2 — Hardware Scan: auto-run, animated progress, show GPU/RAM/disk in plain English
4. Step 3 — Recommendation: auto-selected best model, plain-English explanation, collapsed alternatives
5. Step 4 — Download: progress bar + ETA + pause/resume + auto-checksum verification
6. Step 5 — First Chat: dissolve card → show shell → auto-send system prompt
7. Backend: `GET /hardware/scan`, `POST /models/recommend`, `POST /models/download/{id}`
8. Smooth crossfade transitions between steps (200ms)
9. Progress dots at top of card

---

## Milestone 4: Chat
**Goal:** Full chat experience with streaming, modes, and conversation management.

### Tasks
1. Chat message list (scrollable, auto-scroll on new tokens)
2. Streaming token display via WebSocket (`WS /v1/chat/stream`)
3. Message bubbles: user (right, primary bg), assistant (left, card bg)
4. Code blocks: syntax highlighted, copy button, JetBrains Mono
5. Input box: auto-growing textarea, send button, attach file (paperclip), mode chips
6. Preset selector on new chat: Default / Writing / Coding / Tutor
7. Mode selector in top bar: Chat / Docs / Investigate
8. Regenerate, Continue, Edit message (creates branch via parent_message_id)
9. Conversation controls: rename, pin, export (Markdown)
10. Right panel — Chat mode: model info, speed rating
11. Right panel — Docs mode: groundedness meter, citation list
12. Right panel — Investigate mode: trace panel
13. Empty state: "Ask me anything" with suggested prompts
14. Backend: `POST /v1/chat/completions`, `WS /v1/chat/stream`

---

## Milestone 5: Models
**Goal:** Auto-managed model library with guardrails.

### Tasks
1. Models screen: Recommended (hero card), Installed (list), Discover (grid)
2. Model card: name, params (plain language), size, speed badge, active indicator
3. Switch model: tap → predicted speed shown → load if accepted
4. Guardrail modal for "Painful" models: slow warning + recommended alternative + Run Anyway
5. If Run Anyway: auto-set lower context, conservative batch, aggressive prefetch, "Slow mode" badge
6. Download from Discover: inline progress on card, pause/resume, checksum
7. Import (advanced settings only): HF model ID or local path + micro-benchmark
8. Backend: `POST /models/add`, `GET /models/status/{id}`, download/pause/resume/verify endpoints

---

## Milestone 6: Performance Dashboard
**Goal:** User-friendly performance monitoring.

### Tasks
1. Speed Rating hero: large colored badge (Fast=green, OK=yellow, Slow=orange, Painful=red)
2. Plain-English explanation + actionable suggestion if degraded
3. Key metrics: TTFT and tok/s as simple gauge/bar visuals
4. System status: RAM, GPU memory, disk as percentage bars
5. Auto-tune indicator: "Settings optimized for your hardware" + expandable details
6. Advanced toggle: raw numbers, historical chart, auto-tune log
7. Export diagnostics button: generates sanitized bundle (no chat content)
8. Backend: metrics collection per chat, speed rating derivation

---

## Milestone 7: Documents
**Goal:** Document library with CLaRa-powered cited answers.

### Tasks
1. Document library: grid/list view, upload (drag-drop + file picker), PDF/TXT/MD
2. Document card: type icon, filename, size, date, status badge, processing progress
3. Ingestion: "Preparing knowledge (2-5 min)" progress — extract → chunk → CLaRa compress
4. Collections: create, add docs, "Chat with collection"
5. "Chat with this document" button → opens chat in Docs mode
6. Quality toggle in right panel: Fast / Cited (default) / Deep
7. Groundedness meter: percentage bar + source count
8. Citations: inline badges in assistant response linking to source doc + snippet
9. Empty state: "Upload your first document" with drag-drop zone
10. Backend: `POST /docs/upload`, extract, `POST /clara/ingest`, `POST /clara/query`, `POST /clara/answer`

---

## Milestone 8: Investigate (LRE)
**Goal:** Deep reasoning with safe tools and explainable trace.

### Tasks
1. Investigate mode via mode selector
2. Recursive Orchestrator: plan → tool → observe → answer/sub-query loop
3. Trace panel (right): vertical timeline, steps animate in live, icons per tool type
4. Budget indicator: tool calls used/max, time used/max
5. LRE safe tools: search, grep, open, summarize, table_extract, cite
6. Citations in answer: inline badges with source links
7. Budget exceeded: yellow banner "I stopped because..." + "Try different approach?"
8. No evidence: "I can't find this in your documents" + "Broaden search?" — no fake confidence
9. Backend: `POST /reasoning/run`, LRE tool endpoints (internal), sandboxed execution
10. Security: no shell access, read-only on approved folders, strict parameter validation

---

## Milestone 9: Settings
**Goal:** Privacy, theme, and advanced configuration.

### Tasks
1. Settings screen: grouped list (Privacy, Appearance, About)
2. Privacy: local-only toggle (default on), telemetry opt-in
3. Appearance: theme picker (2 recommended + custom), dark/light toggle, live preview
4. About: version, "Open Source Licenses" → THIRD_PARTY_NOTICES + license texts + NOTICE
5. Advanced toggle: reveals Model Import, API Endpoints, Performance, Diagnostics, Folder Access
6. Model Import: HF ID input, local path picker, micro-benchmark
7. API Endpoints: local API toggle + URL/key display, frontier API key inputs (masked)
8. Performance tuning: context length, batch size, prefetch depth, threading sliders
9. Diagnostics: benchmarks view, log viewer, system status, export bundle
10. Folder Access: approved folders list, add/revoke for LRE permissions
