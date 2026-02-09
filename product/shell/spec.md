# Application Shell — Studiomc

## Pattern
Sidebar (ChatGPT-style)

## Layout
- **Left sidebar** (collapsible): navigation + conversation list
- **Center**: main content area (chat, documents, models, settings)
- **Right panel** (contextual, collapsible): model info, speed rating, doc sources, investigate trace

## Sidebar Navigation
1. **New Chat** (primary action button, prominent at top)
2. **Recent Chats** (scrollable list, grouped by today/yesterday/older)
3. **Documents** (library + collections)
4. **Quick Actions** — Upload doc, search chats/docs
5. **Settings** (bottom of sidebar, gear icon)

## Top Bar (within center content area)
- Model indicator (name + speed rating badge: Fast/OK/Slow/Painful)
- Mode selector (Chat / Docs / Investigate)
- Theme toggle (light/dark)
- Memory toggle indicator (when active)

## Right Context Panel (toggleable)
- **In Chat mode**: active model info, speed rating, token stats
- **In Docs mode**: doc sources list, groundedness meter, citation links
- **In Investigate mode**: explainable trace panel (search/open/extract/cite steps)

## Screens Accessible via Shell
1. **Home / Chat** — default landing, new chat + recent conversations
2. **Documents** — library view, collections, "Chat with this document"
3. **Models** — recommended, installed, discover (curated), import (advanced only)
4. **Performance** — speed rating, TTFT, tok/s, usage graphs
5. **Settings** — privacy, theme, advanced toggle → model import, API endpoints, diagnostics, logs, support bundle, about/licenses

## Responsive Behavior
- **Desktop**: sidebar always visible (280px), right panel toggleable (320px)
- **Tablet**: sidebar collapsible via hamburger, right panel hidden by default
- **Mobile**: sidebar as drawer overlay, no right panel, bottom tab bar for main nav

## Design Tokens
- Colors: corporate-blue (blue/slate/slate), light + dark themes
- Typography: Space Grotesk headings, Inter body, JetBrains Mono code
- Radius: 0.5rem default
- See `design-system/tokens.css` for full CSS variables
