# Section: Chat

## Overview
The core experience. ChatGPT-style conversation interface with streaming responses, conversation management, and three intelligence modes (Chat/Docs/Investigate). Displays inside the app shell sidebar layout.

## Shell Integration
Inside shell — sidebar visible with conversation list, center area is the chat, right panel shows context (model info, sources, trace).

## Layout
- **Left**: conversation list in sidebar (from shell)
- **Center**: chat messages area (scrollable) + input box (fixed bottom)
- **Right** (toggleable): context panel — model info, speed rating, doc sources, or investigate trace

## User Flows

### Flow 1: New Conversation
1. User taps "New Chat" in sidebar
2. Empty chat appears with welcome hint: "Ask me anything"
3. User types message → streaming response appears token by token
4. Conversation auto-titled after first exchange

### Flow 2: Mode Switch
1. User taps mode selector in top bar (Chat / Docs / Investigate)
2. **Chat**: normal conversation, no retrieval
3. **Docs**: answers cite uploaded documents, groundedness meter in right panel
4. **Investigate**: slower, shows trace panel on right with search/open/extract steps

### Flow 3: Conversation Management
- Rename: long-press or right-click conversation in sidebar
- Pin: pin to top of conversation list
- Export: export as Markdown file
- Branch: edit a previous message → creates a new branch (parent_message_id)

### Flow 4: Regenerate / Continue
- Regenerate: re-runs last assistant message
- Continue: appends to last assistant message if it was cut off
- Edit: edit any user message, re-generates from that point (branch)

## UI Requirements
- Streaming: tokens appear one by one with cursor blink
- Message bubbles: user (right-aligned, primary color bg), assistant (left-aligned, card bg)
- Code blocks: syntax highlighted, copy button, JetBrains Mono font
- Attach file: paperclip icon in input box, opens file picker
- Mode selector: segmented control in top bar (Chat | Docs | Investigate)
- Speed rating badge: next to model name in top bar (colored: green/yellow/orange/red)
- Input box: auto-growing textarea, send button, attach button, mode button
- Empty state: centered "Ask me anything" with suggested prompts
- Presets: Default / Writing / Coding / Tutor — affects system prompt, shown as chips above input on new chat

## Scope Boundaries
- No inline image generation
- No voice input (future)
- No multi-model conversations
