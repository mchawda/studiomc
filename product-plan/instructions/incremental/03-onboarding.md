# Milestone 3: Onboarding

## Goal
5-step wizard that takes user from install to first chat in under 2 minutes.

## Tasks
1. Standalone screen (no shell) with branded gradient background (blue tones)
2. Centered card (max-width 520px) with progress dots at top
3. Step 1 — Welcome: headline "Local AI. Private by default.", two buttons
4. Step 2 — Hardware Scan: auto-runs on enter, animated spinner → checkmarks for GPU/RAM/disk
5. Step 3 — Recommendation: hero model card with speed badge + explanation, collapsed alternatives
6. Step 4 — Download: progress bar + percentage + ETA, pause/resume buttons, auto-checksum
7. Step 5 — First Chat: card dissolves, shell appears, auto-navigates to chat
8. Smooth crossfade transitions (200ms) between steps
9. Backend endpoints: hardware scan, model recommendation, model download with progress streaming
10. "I already have a model" flow: file picker → micro-benchmark → first chat

## Reference
- `sections/onboarding/spec.md`, `types.ts`, `data.json`

## Acceptance
- Wizard flows through all 5 steps
- Hardware scan displays real system info in plain English (no "VRAM")
- Recommendation shows model with speed rating
- Download progress updates in real-time
- Completing onboarding transitions into shell with chat ready
