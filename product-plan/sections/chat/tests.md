# Tests: Chat

## Sending Messages
- Action: Type message + send → streaming response appears token by token
- Verify: user message right-aligned, assistant message left-aligned
- Verify: auto-scroll follows new tokens
- Verify: conversation auto-titled after first exchange

## Conversation Management
- Action: Tap conversation in sidebar → loads that chat
- Action: Long-press conversation → rename/pin/delete options appear
- Action: Export → generates Markdown file
- Verify: pinned conversations stay at top of list

## Regenerate / Edit / Branch
- Action: Tap regenerate on assistant message → new response generated
- Action: Tap "Continue" on cut-off message → appends more content
- Action: Edit user message → new branch created, re-generates from that point
- Verify: branched messages have correct parent_message_id

## Modes
- Action: Switch to Docs mode → right panel shows groundedness meter
- Action: Switch to Investigate → right panel shows trace (placeholder until milestone 8)
- Verify: mode persists within conversation

## Presets
- Action: New chat → select "Coding" preset → system prompt changes
- Verify: preset chips visible only on new chat

## Empty State
- Given: no chats exist
- Verify: "Ask me anything" centered with suggested prompts

## Code Blocks
- Verify: code blocks syntax highlighted
- Verify: copy button works
- Verify: JetBrains Mono font applied
