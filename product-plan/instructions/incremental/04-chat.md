# Milestone 4: Chat

## Goal
Full chat experience with streaming, modes, branching, and conversation management.

## Tasks
1. Message list: scrollable, auto-scroll, user bubbles (right/primary), assistant bubbles (left/card)
2. Streaming via WebSocket: tokens appear one by one with cursor blink animation
3. Code blocks: syntax highlighted, copy button, JetBrains Mono
4. Input box: auto-growing textarea, send (Enter), attach file (paperclip), mode chips above on new chat
5. Preset selector (new chat only): Default / Writing / Coding / Tutor chips
6. Mode selector in top bar: Chat / Docs / Investigate (segmented control)
7. Regenerate button on assistant messages, Continue button if cut off
8. Edit user message → creates branch (new parent_message_id), re-generates from that point
9. Conversation list: tap to switch, long-press for rename/pin/delete/export
10. Right panel content per mode:
    - Chat: model info + speed rating + tok/s
    - Docs: groundedness meter + citations list
    - Investigate: trace panel (built in milestone 8)
11. Empty state: centered "Ask me anything" + 4 suggested prompt chips
12. Backend: POST /v1/chat/completions (OpenAI-compatible), WS /v1/chat/stream

## Reference
- `sections/chat/spec.md`, `types.ts`, `data.json`

## Acceptance
- Send message → streaming response appears token by token
- Conversation persists to SQLite + appears in sidebar
- Regenerate produces new response
- Edit creates visible branch
- Presets change system prompt
- Mode selector updates top bar label
