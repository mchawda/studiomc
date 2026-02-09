# Tests: Models

## Model Library
- Verify: recommended model highlighted at top with "Recommended" badge
- Verify: installed models listed with speed rating + size
- Verify: discover section shows compatible curated models

## Switch Model
- Action: Tap installed model → model loads, top bar updates
- Verify: speed badge in top bar updates to new model's rating

## Guardrail Modal
- Given: user selects model rated "Painful"
- Verify: modal shows slow warning with estimated tok/s
- Verify: recommended alternative shown
- Action: Tap "Use recommended" → switches to recommended model
- Action: Tap "Run anyway" → loads model with "Slow mode" badge

## Download
- Action: Tap download on discover model → progress shows inline
- Verify: pause/resume buttons work
- Verify: checksum verification runs after download
- Verify: model appears in installed list when complete

## Import (Advanced)
- Given: advanced settings enabled
- Action: Enter HF model ID → micro-benchmark runs → model added
- Action: Browse local path → model added
- Given: advanced settings disabled → import option not visible
