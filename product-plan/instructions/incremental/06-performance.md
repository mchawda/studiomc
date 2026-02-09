# Milestone 6: Performance Dashboard

## Goal
User-friendly performance monitoring with Speed Rating and auto-tuning.

## Tasks
1. Performance screen accessible via sidebar or speed badge tap
2. Speed Rating hero: large colored badge (Fast=green, OK=yellow, Slow=orange, Painful=red)
3. Plain-English explanation below badge + suggestion if degraded
4. Key metrics: TTFT and tok/s as simple gauge visuals (arc or bar)
5. System status: RAM, GPU memory, disk usage as percentage bars with labels
6. Auto-tune indicator: "Settings optimized for your hardware" + expandable decision list
7. Advanced toggle (bottom): reveals raw numbers, historical per-chat chart, auto-tune log
8. Export diagnostics: button → progress → save sanitized bundle (never chat content)
9. Backend: collect metrics per chat (TTFT, tok/s, RAM, VRAM, disk), derive speed rating, performance tuner logic

## Reference
- `sections/performance/spec.md`, `types.ts`, `data.json`

## Acceptance
- Speed Rating displays correctly with color coding
- Metrics show real values from recent chats
- Auto-tune decisions listed with explanations
- Advanced toggle reveals detailed view
- Diagnostics export generates downloadable file
