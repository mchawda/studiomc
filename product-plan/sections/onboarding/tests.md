# Tests: Onboarding

## Welcome Step
- Verify: "Local AI. Private by default." heading displays
- Verify: "Get Started" and "I already have a model" buttons visible
- Action: Tap "Get Started" → navigates to hardware scan

## Hardware Scan
- Verify: scan auto-runs on step entry
- Verify: GPU, RAM, disk info displayed in plain English (no "VRAM")
- Verify: animated progress → checkmarks when complete
- Verify: scan completes within 5 seconds

## Recommendation
- Verify: recommended model shown with speed badge (Fast/OK)
- Verify: plain-English explanation displayed
- Verify: "See other options" collapsed by default
- Action: Tap "Download" → navigates to download step

## Download
- Verify: progress bar shows percentage + ETA
- Verify: pause/resume buttons work
- Verify: checksum verification runs after download
- Edge: network interruption → download pauses, resumes when reconnected

## First Chat
- Verify: card dissolves, shell appears
- Verify: first chat auto-created with system prompt
- Verify: total flow completes in under 2 minutes (excluding download)
