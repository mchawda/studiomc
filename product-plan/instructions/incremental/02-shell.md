# Milestone 2: Shell

## Goal
Application shell with sidebar navigation, top bar, and responsive layout.

## Tasks
1. Build AppShell widget with three-panel layout:
   - Left sidebar (280px, collapsible)
   - Center content area (flexible)
   - Right context panel (320px, toggleable)
2. Sidebar contents:
   - "New Chat" button (primary action, top)
   - Conversation list (scrollable, grouped: today/yesterday/older)
   - "Documents" nav item
   - Settings gear icon (bottom)
3. Top bar (inside center area):
   - Model name + speed rating badge (colored)
   - Mode selector: segmented control (Chat / Docs / Investigate)
   - Theme toggle (sun/moon icon)
4. Right panel: placeholder for context (model info / sources / trace)
5. Responsive behavior:
   - Desktop: sidebar always visible
   - Tablet (<1024px): sidebar collapses via hamburger
   - Mobile (<768px): sidebar as drawer overlay, bottom tab bar
6. Theme toggle: switches light/dark, persists to Settings

## Reference
- `product/shell/spec.md` — full shell specification
- `product/design-system/tokens.css` — design tokens

## Acceptance
- Three-panel layout renders correctly on macOS
- Sidebar shows conversation list with sample data
- Mode selector switches between Chat/Docs/Investigate labels
- Theme toggle switches light ↔ dark
- Sidebar collapses at tablet breakpoint
