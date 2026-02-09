# Section: Models

## Overview
Auto-managed model library. The app recommends and downloads the best model automatically. Users see installed models and can discover curated options. Manual import (HF ID / local path) hidden in advanced settings.

## Shell Integration
Inside shell — accessible via sidebar navigation or top bar model indicator.

## Layout
- **Recommended** (top): auto-selected best model for this machine, with speed badge
- **Installed**: list of downloaded models with status, size, last used
- **Discover**: curated list filtered by hardware compatibility
- **Import** (advanced only): HF model ID input or local file picker

## User Flows

### Flow 1: View Models
1. Tap "Models" in sidebar (or model name in top bar)
2. See recommended model highlighted at top
3. Installed models listed below with speed rating + size
4. "Discover more" section shows compatible curated models

### Flow 2: Switch Model
1. Tap a different installed model
2. App shows predicted speed rating for that model
3. If "Painful": show guardrail modal (slow warning + recommended alternative)
4. If accepted: model loads, top bar updates

### Flow 3: Download New Model
1. Browse Discover section → tap model → "Download"
2. Progress bar with pause/resume
3. Checksum verification after download
4. Model appears in Installed list

### Flow 4: Import (Advanced)
1. Settings → Advanced → Import Model
2. Enter HF model ID or browse local path
3. Micro-benchmark runs
4. Model added to Installed

## UI Requirements
- Model card: name, param count (plain language: "8 billion parameters"), size ("4.2 GB"), speed badge, "Active" indicator
- Guardrail modal for painful models (see ux-spec.md)
- Download progress inline on model card
- No delete unless in advanced settings
- Curated models: show "Works well on your machine" vs "May be slow"

## Scope Boundaries
- No model fine-tuning
- No model comparison benchmarks (just speed rating)
- No quantization selection (app auto-picks best quant)
