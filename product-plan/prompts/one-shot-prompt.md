# One-Shot Implementation Prompt

You are building **Studiomc**, a local AI desktop app. Build the complete application from the implementation package provided.

## Context
- Read `product-overview.md` for the full product vision
- Read `instructions/one-shot-instructions.md` for all milestones
- Reference `design-system/` for visual tokens
- Reference `data-model/` for the SQLite schema
- Reference `sections/` for per-section specs, types, sample data, and tests

## Stack
- **Flutter (Dart)** for the app — macOS first, then Windows, then mobile
- **Python 3.11+ / FastAPI** for backend services (inference, model manager, documents, CLaRa, LRE)
- **SQLite** for storage
- **AirLLM** for inference (https://github.com/lyogavin/airllm)

## Rules
1. Follow the milestone order: Foundation → Shell → Onboarding → Chat → Models → Performance → Documents → Investigate → Settings
2. Each milestone should be independently deployable
3. Use the design tokens (blue/slate, Space Grotesk/Inter/JetBrains Mono)
4. Use the TypeScript interfaces as reference for Dart model classes
5. Use the sample data for development/testing
6. Follow the test specs in each section's `tests.md`
7. No jargon in UI copy — follow UX copy guidelines
8. App decides everything — minimize user choices
9. All services bind to 127.0.0.1 only
10. LRE is sandboxed — safe tools only, no shell access

## Ask Before Building
- Confirm Flutter version
- Confirm Python packaging approach (embedded vs system)
- Confirm any third-party packages for specific features
