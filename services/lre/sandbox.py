"""Sandbox — security enforcement and budget tracking for LRE.

Every tool invocation goes through the sandbox which:
1. Validates inputs (no path traversal, no shell injection)
2. Restricts file access to DOCS_DIR
3. Tracks per-session budgets (tool calls, token count, wall-clock)
4. Refuses execution when any budget is exceeded
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from common.config import DOCS_DIR


# ── Budget defaults (from performance-engineering.md) ──

MAX_TOOL_CALLS = 6
MAX_TOKENS = 8_000           # 8k token hard cap on retrieved text
WALL_CLOCK_INVESTIGATE = 20  # seconds
WALL_CLOCK_DOCS = 8          # seconds

# Rough token estimate: 1 token ≈ 4 chars
CHARS_PER_TOKEN = 4

# ── Allowlisted tool names ──

ALLOWED_TOOLS: frozenset[str] = frozenset(
    {"search", "grep", "open", "summarize", "table_extract", "cite"}
)


class BudgetExceeded(Exception):
    """Raised when a sandbox budget limit is hit."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(reason)


class SecurityViolation(Exception):
    """Raised on disallowed operations (path traversal, etc.)."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(reason)


@dataclass
class SessionBudget:
    """Per-reasoning-run budget tracker."""

    tool_calls_remaining: int = MAX_TOOL_CALLS
    tokens_remaining: int = MAX_TOKENS
    wall_clock_start: float = field(default_factory=time.monotonic)
    wall_clock_limit: float = WALL_CLOCK_INVESTIGATE

    # ── queries ──

    @property
    def elapsed_s(self) -> float:
        return time.monotonic() - self.wall_clock_start

    @property
    def time_remaining_s(self) -> float:
        return max(0.0, self.wall_clock_limit - self.elapsed_s)

    @property
    def is_expired(self) -> bool:
        return self.elapsed_s >= self.wall_clock_limit

    # ── mutations ──

    def consume_tool_call(self) -> None:
        """Decrement tool-call counter; raise if exhausted."""
        if self.tool_calls_remaining <= 0:
            raise BudgetExceeded(
                f"Tool-call budget exhausted (max {MAX_TOOL_CALLS})."
            )
        if self.is_expired:
            raise BudgetExceeded(
                f"Wall-clock budget exceeded ({self.wall_clock_limit}s)."
            )
        self.tool_calls_remaining -= 1

    def consume_tokens(self, text: str) -> str:
        """Track token usage and truncate text if it would exceed cap.

        Returns the (possibly truncated) text that fits within the budget.
        """
        estimated_tokens = len(text) // CHARS_PER_TOKEN
        if estimated_tokens <= self.tokens_remaining:
            self.tokens_remaining -= estimated_tokens
            return text

        # Truncate to remaining budget
        allowed_chars = self.tokens_remaining * CHARS_PER_TOKEN
        self.tokens_remaining = 0
        truncated = text[:allowed_chars]
        return truncated + "\n\n[…truncated — token budget reached]"

    def status_dict(self) -> dict[str, Any]:
        return {
            "tool_calls_remaining": self.tool_calls_remaining,
            "tokens_remaining": self.tokens_remaining,
            "elapsed_s": round(self.elapsed_s, 2),
            "wall_clock_limit": self.wall_clock_limit,
        }


# ── Path validation ──


def validate_path(raw: str) -> Path:
    """Resolve a path and verify it lives under DOCS_DIR.

    Raises SecurityViolation on path traversal or access outside sandbox.
    """
    # Block obvious shell injection characters
    if any(c in raw for c in (";", "|", "&", "`", "$", "\n", "\r")):
        raise SecurityViolation(f"Illegal characters in path: {raw!r}")

    # Resolve to an absolute, symlink-free path
    docs_root = DOCS_DIR.resolve()
    resolved = (docs_root / raw).resolve()

    if not str(resolved).startswith(str(docs_root)):
        raise SecurityViolation(
            f"Path traversal blocked: {raw!r} resolves outside DOCS_DIR"
        )
    return resolved


def validate_doc_id(doc_id: str) -> str:
    """Ensure doc_id looks like a safe identifier (UUID-ish or slug)."""
    if not re.match(r"^[a-zA-Z0-9_\-]+$", doc_id):
        raise SecurityViolation(f"Invalid doc_id: {doc_id!r}")
    return doc_id


def validate_pattern(pattern: str) -> str:
    """Ensure a grep pattern is safe (no null bytes, bounded length)."""
    if "\x00" in pattern:
        raise SecurityViolation("Null byte in pattern")
    if len(pattern) > 500:
        raise SecurityViolation("Pattern too long (max 500 chars)")
    return pattern


def validate_tool_name(name: str) -> str:
    """Ensure the requested tool is on the allowlist."""
    if name not in ALLOWED_TOOLS:
        raise SecurityViolation(
            f"Tool {name!r} not allowed. Permitted: {sorted(ALLOWED_TOOLS)}"
        )
    return name
