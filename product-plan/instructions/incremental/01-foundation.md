# Milestone 1: Foundation

## Goal
Project setup, design tokens, data model, routing, backend scaffold.

## Tasks
1. Create Flutter project: `flutter create --platforms=macos,windows,ios,android studiomc`
2. Set up folder structure (lib/screens, widgets, services, models, utils)
3. Implement Flutter theme from design tokens:
   - Primary: blue-600/blue-400, Background: slate-50/slate-900
   - Fonts: Space Grotesk (display), Inter (body), JetBrains Mono (mono)
   - Border radius: 8px
4. Add Google Fonts dependency
5. Create SQLite database using `sqflite` package with full schema from `data-model/schema.sql`
6. Create Dart model classes for all entities
7. Set up GoRouter routing: /onboarding, /chat, /models, /documents, /performance, /settings
8. Create Python service scaffold: FastAPI app with WebSocket support, CORS for localhost
9. Create service stubs for: inference, model_manager, documents, clara, lre, orchestrator
10. Verify: app launches, shows blank screen, database created, Python service starts

## Acceptance
- Flutter app runs on macOS
- Theme applies correctly (fonts, colors, dark/light)
- SQLite database created with all tables
- Python FastAPI starts on 127.0.0.1:8000
- Router navigates between placeholder screens
