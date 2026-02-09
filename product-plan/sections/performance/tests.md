# Tests: Performance Dashboard

## Speed Rating Display
- Given active model with tok/s ≥ 10: verify Speed Rating shows "Fast" with green badge
- Given active model with tok/s 4-10: verify shows "OK" with yellow badge
- Given active model with tok/s 1-4: verify shows "Slow" with orange badge + suggestion to switch
- Given active model with tok/s < 1: verify shows "Painful" with red badge

## Metrics Display
- Verify TTFT gauge shows correct value from latest chat
- Verify tok/s gauge shows correct value
- Verify RAM bar shows used/total as percentage
- Verify GPU memory bar shows when GPU detected, hidden when CPU-only
- Verify disk usage bar renders

## Auto-Tune
- Verify "Settings optimized" indicator is visible
- Expand auto-tune: verify decision list shows setting + value + reason
- Verify decisions match what Performance Tuner applied

## Advanced Toggle
- Default: advanced metrics hidden
- Toggle on: raw numbers, historical chart, auto-tune log appear
- Toggle off: advanced section collapses

## Export Diagnostics
- Tap export: verify progress indicator shows
- Verify export completes and produces downloadable file
- Verify exported bundle contains logs, benchmarks, model metadata
- Verify exported bundle does NOT contain chat content
