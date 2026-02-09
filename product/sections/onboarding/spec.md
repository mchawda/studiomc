# Section: Onboarding

## Overview
5-step wizard that takes the user from install to first chat in under 2 minutes. Centered card layout on a branded background. Fully automatic — scan runs instantly, detects existing backends (Ollama, LM Studio), auto-selects best model across all sources, user just confirms. If user already has models running via Ollama/LM Studio, no download needed.

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
2. **Hardware + Backend Scan** — auto-runs immediately:
   - Hardware: GPU/graphics memory (or CPU-only), RAM, disk type + speed. Animated spinner → checkmark per item.
   - Backend detection: probes Ollama (`localhost:11434`) and LM Studio (`localhost:1234`).
   - If Ollama found: "Ollama detected — [N] models available" with green checkmark.
   - If LM Studio found: "LM Studio detected — [N] models loaded" with green checkmark.
   - If neither found: no error shown, just hardware results. Built-in engine always available.
   - Completes in 2-5 seconds.
3. **Recommendation** — "Best experience for you" shows 1 auto-selected model:
   - If Ollama/LM Studio has a good model loaded: recommends it (no download needed, badge shows "Local via Ollama").
   - If no local backend models: recommends from curated list for download via AirLLM (badge shows "Local via Studiomc").
   - Smart memory note for larger models: "Studiomc's smart memory makes this work on your hardware."
   - Collapsed "See other options" for alternatives across all backends.
   - User taps "Continue" (if model ready) or "Download" (if needed).
4. **Download** (skip if model already available) — progress bar with ETA, resumable:
   - If Ollama backend: runs `ollama pull` under the hood.
   - If HuggingFace/AirLLM: direct download with pause/resume, checksum verification.
   - If model was already loaded in Ollama/LM Studio: this step is skipped entirely.
5. **First Chat** — card dissolves, app shell appears, first message auto-sent: "You are a private local assistant. Ask me anything."

### Flow 2: Returning User (has model)
1. **Welcome** → tap "I already have a model"
2. **Import** — three options:
   - Browse local file path
   - Enter HuggingFace model ID
   - Enter Ollama model name
3. **Quick Bench** — micro-benchmark runs (TTFT + tok/s for 32 tokens)
4. **First Chat** — same as above

### Flow 3: User with Ollama/LM Studio already running
1. **Welcome** → tap "Get Started"
2. **Hardware + Backend Scan** — detects Ollama with models already loaded
3. **Recommendation** — recommends best model already available (no download)
4. **Skip download** — straight to first chat
5. **First Chat** — instant start, zero wait

## UI Requirements
- Step transitions: smooth crossfade (200ms)
- Hardware scan: animated spinner → checkmark per item
- Backend detection: Ollama/LM Studio logos with connection status (green checkmark / grey dash)
- Recommendation card: model name, size label ("compressed model, 4.2 GB"), speed prediction badge (Fast/OK), backend badge ("Local via Ollama" / "Local via Studiomc")
- Smart memory callout: subtle text when recommending larger model — "Studiomc's smart memory makes this work"
- Download: progress bar with percentage + ETA, pause/resume button
- No back button on steps 4-5 (download committed)
- All copy follows UX copy guidelines (no jargon)

## Scope Boundaries
- No model browsing during onboarding — just accept recommendation or import
- No settings access during onboarding
- No advanced options visible
- No frontier/cloud API setup during onboarding — that's in Settings → Advanced after first chat
- No auto-install of Ollama or LM Studio — just detect if already running
