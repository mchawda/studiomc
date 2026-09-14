# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Memory service — long-term, cross-conversation memory.

The memory service stores discrete "memories" (facts, preferences,
summaries) the assistant should remember across chats. Memories live in
the shared SQLite ``memories`` table and are surfaced into every chat's
system prompt by the orchestrator before inference.

Two extraction modes:

* **Auto (LLM)** — after each assistant turn, an extractor pass asks
  the local model to emit zero or more JSON memories. Best-effort;
  failures degrade silently.
* **Manual** — the user adds/edits/pins memories from the Flutter
  settings page.

Runs on port 8109 and is fully tenant-scoped (``org_id`` column).
"""
