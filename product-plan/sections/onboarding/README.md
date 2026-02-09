# Section: Onboarding

## Overview
5-step wizard that takes the user from install to first chat in under 2 minutes. Centered card layout on a branded background. Fully automatic — scan runs instantly, auto-selects best model, user just confirms and downloads.

## Shell Integration
Standalone — no sidebar or shell chrome during onboarding. Full-screen branded background with centered card.

## Layout
- Branded background (subtle gradient, blue tones)
- Centered card (max-width ~520px) with steps inside
- Progress indicator (dots or step numbers) at top of card
- Single primary action button per step

## User Flows

### Flow 1: New User
1. **Welcome** — "Local AI. Private by default." → tap "Get Started"
2. **Hardware Scan** — auto-runs immediately, shows animated progress, displays: GPU/graphics memory (or CPU-only), RAM, disk type + speed. Completes in 2-5 seconds.
3. **Recommendation** — "Best experience for you" shows 1 auto-selected model with plain-English explanation ("This model will feel responsive on your machine"). Collapsed "See other options" for alternatives. User taps "Download".
4. **Download** — progress bar with ETA, resumable, "Verify integrity" runs automatically after download.
5. **First Chat** — card dissolves, app shell appears, first message auto-sent: "You are a private local assistant. Ask me anything."

### Flow 2: Returning User (has model)
1. **Welcome** → tap "I already have a model"
2. **Import** — file picker or HF model ID input
3. **Quick Bench** — micro-benchmark runs (TTFT + tok/s for 32 tokens)
4. **First Chat** — same as above

## UI Requirements
- Step transitions: smooth crossfade (200ms)
- Hardware scan: animated spinner → checkmark per item
- Recommendation card: model name, size label ("compressed model, 4.2 GB"), speed prediction badge (Fast/OK)
- Download: progress bar with percentage + ETA, pause/resume button
- No back button on steps 4-5 (download committed)
- All copy follows UX copy guidelines (no jargon)

## Scope Boundaries
- No model browsing during onboarding — just accept recommendation or import
- No settings access during onboarding
- No advanced options visible
