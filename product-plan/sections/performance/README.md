# Section: Performance Dashboard

## Overview
User-friendly performance monitoring. Shows Speed Rating, key metrics, and auto-tuning status. No technical jargon by default — advanced metrics behind toggle.

## Shell Integration
Inside shell — accessible via sidebar or model speed badge tap.

## Layout
- **Speed Rating** (hero): large badge (Fast/OK/Slow/Painful) with plain-English explanation
- **Key Metrics**: TTFT, tok/s displayed as simple bar/gauge visuals
- **System Status**: RAM, graphics memory, disk usage — shown as percentage bars
- **Auto-Tune Status**: what the Performance Tuner has adjusted
- **Advanced** (hidden): raw numbers, model load time, cache hit ratio, disk throughput, OOM events

## User Flows

### Flow 1: Check Performance
1. Tap speed badge in top bar (or Performance in sidebar)
2. See current Speed Rating + explanation
3. See key metrics visualized simply
4. If slow: see suggestion ("Try a smaller model for faster responses")

### Flow 2: View Advanced Metrics
1. Toggle "Show details" at bottom
2. See raw numbers: TTFT ms, tok/s, RAM MB, VRAM MB, disk MB/s
3. See historical chart of performance over recent chats
4. See auto-tune decisions log

### Flow 3: Export Diagnostics
1. Tap "Export diagnostics" button
2. Generates sanitized bundle (logs, benchmarks, model metadata — no chat content)
3. Save to file picker

## UI Requirements
- Speed Rating badge: color-coded (green/yellow/orange/red), large centered
- Metric gauges: simple arc or bar style, not technical charts
- Suggestion cards: when performance is degraded, show actionable suggestion
- Auto-tune indicator: "Settings optimized for your hardware" with expand for details
- Export button: single action, progress indicator while bundling

## Scope Boundaries
- No real-time live monitoring (snapshot on view)
- No manual performance tuning in default view (advanced only)
