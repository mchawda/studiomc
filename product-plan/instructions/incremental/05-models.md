# Milestone 5: Models

## Goal
Auto-managed model library with hardware-aware recommendations and guardrails.

## Tasks
1. Models screen: Recommended hero card (top), Installed list, Discover grid
2. Model card widget: name, param count (plain language), size, speed badge, active indicator
3. Tap installed model → shows predicted speed → loads as active (top bar updates)
4. Guardrail modal for "Painful" rated models:
   - "This will be slow on your hardware (estimated X tok/s)"
   - "Recommended alternative: Y (fast)"
   - Buttons: Use recommended / Run anyway
5. "Run anyway" auto-sets: lower context, conservative batch, aggressive prefetch, "Slow mode" badge in top bar
6. Discover: download button → inline progress on card → pause/resume → checksum verification
7. Import (only visible when advanced settings enabled): HF model ID input or local file picker
8. Backend: model CRUD, download manager with pause/resume, recommendation engine, micro-benchmark

## Reference
- `sections/models/spec.md`, `types.ts`, `data.json`

## Acceptance
- Recommended model highlighted at top
- Can switch between installed models
- Guardrail modal appears for slow models
- Download progress shows inline with pause/resume
- Speed rating badge updates in top bar on model switch
