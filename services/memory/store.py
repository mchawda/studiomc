# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""SQLite-backed memory store.

Provides the canonical CRUD + retrieval primitives over the ``memories``
table. Search uses two complementary signals:

* Pinned memories first.
* Lexical relevance via SQLite ``LIKE`` token matching (cheap, no extra
  dependency). When the CLaRa embeddings backend is available we plug
  in cosine search later — the schema already carries an ``embedding``
  BLOB column.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import asdict, dataclass
from typing import Any, Iterable

from common.database import Database

LOCAL_ORG = "local"


@dataclass
class Memory:
    id: str
    org_id: str
    scope: str
    scope_id: str | None
    key: str | None
    content: str
    tags: list[str]
    source_message_id: str | None
    confidence: float
    pinned: bool
    created_at: str
    updated_at: str

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        return d


def _row_to_memory(row: Any) -> Memory:
    tags_str = row["tags"] or ""
    return Memory(
        id=row["id"],
        org_id=row["org_id"],
        scope=row["scope"],
        scope_id=row["scope_id"],
        key=row["key"],
        content=row["content"],
        tags=[t for t in tags_str.split(",") if t],
        source_message_id=row["source_message_id"],
        confidence=float(row["confidence"] or 1.0),
        pinned=bool(row["pinned"]),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# ── CRUD ─────────────────────────────────────────────────────────────


async def list_memories(
    *,
    scope: str | None = None,
    scope_id: str | None = None,
    org_id: str = LOCAL_ORG,
    limit: int = 200,
) -> list[Memory]:
    db = await Database.instance()
    sql = "SELECT * FROM memories WHERE org_id = ?"
    params: list[Any] = [org_id]
    if scope:
        sql += " AND scope = ?"
        params.append(scope)
    if scope_id:
        sql += " AND scope_id = ?"
        params.append(scope_id)
    sql += " ORDER BY pinned DESC, updated_at DESC LIMIT ?"
    params.append(limit)
    rows = await db.fetchall(sql, tuple(params))
    return [_row_to_memory(r) for r in rows]


async def get_memory(memory_id: str, *, org_id: str = LOCAL_ORG) -> Memory | None:
    db = await Database.instance()
    row = await db.fetchone(
        "SELECT * FROM memories WHERE id = ? AND org_id = ?",
        (memory_id, org_id),
    )
    return _row_to_memory(row) if row else None


async def add_memory(
    *,
    content: str,
    scope: str = "global",
    scope_id: str | None = None,
    key: str | None = None,
    tags: Iterable[str] | None = None,
    source_message_id: str | None = None,
    confidence: float = 1.0,
    pinned: bool = False,
    org_id: str = LOCAL_ORG,
) -> Memory:
    if not content.strip():
        raise ValueError("memory content cannot be empty")
    if scope not in {"global", "chat", "project"}:
        raise ValueError(f"invalid scope: {scope}")
    if scope != "global" and not scope_id:
        raise ValueError(f"scope={scope} requires scope_id")
    memory_id = f"mem-{uuid.uuid4().hex[:12]}"
    db = await Database.instance()
    await db.execute(
        """
        INSERT INTO memories
            (id, org_id, scope, scope_id, key, content, tags,
             source_message_id, confidence, pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            memory_id,
            org_id,
            scope,
            scope_id,
            key,
            content.strip(),
            ",".join(sorted(set(tags or []))),
            source_message_id,
            float(confidence),
            int(bool(pinned)),
        ),
    )
    await db.commit()
    fetched = await get_memory(memory_id, org_id=org_id)
    assert fetched is not None
    return fetched


async def update_memory(
    memory_id: str,
    *,
    content: str | None = None,
    key: str | None = None,
    tags: Iterable[str] | None = None,
    pinned: bool | None = None,
    confidence: float | None = None,
    org_id: str = LOCAL_ORG,
) -> Memory:
    sets: list[str] = []
    params: list[Any] = []
    if content is not None:
        if not content.strip():
            raise ValueError("memory content cannot be empty")
        sets.append("content = ?")
        params.append(content.strip())
    if key is not None:
        sets.append("key = ?")
        params.append(key)
    if tags is not None:
        sets.append("tags = ?")
        params.append(",".join(sorted(set(tags))))
    if pinned is not None:
        sets.append("pinned = ?")
        params.append(int(bool(pinned)))
    if confidence is not None:
        sets.append("confidence = ?")
        params.append(float(confidence))
    sets.append("updated_at = datetime('now')")
    if not sets:
        memory = await get_memory(memory_id, org_id=org_id)
        if memory is None:
            raise KeyError(memory_id)
        return memory
    params.extend([memory_id, org_id])
    db = await Database.instance()
    cursor = await db.execute(
        f"UPDATE memories SET {', '.join(sets)} WHERE id = ? AND org_id = ?",
        tuple(params),
    )
    await db.commit()
    if cursor.rowcount == 0:
        raise KeyError(memory_id)
    memory = await get_memory(memory_id, org_id=org_id)
    assert memory is not None
    return memory


async def delete_memory(memory_id: str, *, org_id: str = LOCAL_ORG) -> bool:
    db = await Database.instance()
    cursor = await db.execute(
        "DELETE FROM memories WHERE id = ? AND org_id = ?",
        (memory_id, org_id),
    )
    await db.commit()
    return cursor.rowcount > 0


async def clear_memories(*, org_id: str = LOCAL_ORG, scope: str | None = None) -> int:
    db = await Database.instance()
    if scope:
        cursor = await db.execute(
            "DELETE FROM memories WHERE org_id = ? AND scope = ?",
            (org_id, scope),
        )
    else:
        cursor = await db.execute(
            "DELETE FROM memories WHERE org_id = ?",
            (org_id,),
        )
    await db.commit()
    return cursor.rowcount


# ── Retrieval ────────────────────────────────────────────────────────


_STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be",
    "been", "being", "to", "of", "in", "on", "at", "for", "with", "by",
    "as", "i", "you", "we", "they", "he", "she", "it", "this", "that",
    "what", "how", "when", "where", "why", "do", "does", "did", "can",
    "could", "would", "should", "will", "from", "into", "about", "than",
    "then", "so", "if", "not", "no", "yes", "my", "your", "our", "their",
}


def _tokenize(text: str) -> list[str]:
    tokens = re.findall(r"[a-zA-Z][a-zA-Z0-9_-]{2,}", text.lower())
    return [t for t in tokens if t not in _STOPWORDS]


async def relevant_memories(
    *,
    query: str,
    scope_id: str | None = None,
    org_id: str = LOCAL_ORG,
    limit: int = 8,
) -> list[Memory]:
    """Return memories scored by lexical relevance, pinned first.

    Strategy: fetch the user's pinned + scope-matched memories (cheap,
    bounded), then score by token overlap with the query. This is
    deliberately dependency-free; once embeddings are available, swap
    the scoring function out without changing the call sites.
    """
    candidates = await _candidate_pool(scope_id=scope_id, org_id=org_id)
    if not candidates:
        return []

    query_tokens = set(_tokenize(query))
    scored: list[tuple[float, Memory]] = []
    for mem in candidates:
        tokens = set(_tokenize(mem.content))
        if not tokens:
            score = 0.0
        else:
            overlap = len(query_tokens & tokens)
            score = overlap / max(1, len(query_tokens | tokens))
        # Pinned memories always make it through but rank below clear
        # query matches; recent updates break ties.
        scored.append((score + (0.05 if mem.pinned else 0.0), mem))

    scored.sort(key=lambda pair: pair[0], reverse=True)
    out: list[Memory] = []
    for score, mem in scored:
        if score == 0 and not mem.pinned:
            continue
        out.append(mem)
        if len(out) >= limit:
            break
    # Always include pinned that didn't already make the cut.
    for mem in candidates:
        if mem.pinned and mem not in out:
            out.append(mem)
            if len(out) >= limit:
                break
    return out


async def _candidate_pool(
    *,
    scope_id: str | None,
    org_id: str,
    pool_size: int = 200,
) -> list[Memory]:
    db = await Database.instance()
    if scope_id:
        rows = await db.fetchall(
            """
            SELECT * FROM memories
            WHERE org_id = ?
              AND (scope = 'global' OR (scope IN ('chat', 'project') AND scope_id = ?))
            ORDER BY pinned DESC, updated_at DESC
            LIMIT ?
            """,
            (org_id, scope_id, pool_size),
        )
    else:
        rows = await db.fetchall(
            """
            SELECT * FROM memories
            WHERE org_id = ? AND scope = 'global'
            ORDER BY pinned DESC, updated_at DESC
            LIMIT ?
            """,
            (org_id, pool_size),
        )
    return [_row_to_memory(r) for r in rows]


# ── Context formatting ──────────────────────────────────────────────


def format_for_prompt(memories: list[Memory]) -> str:
    """Render a memory list as a system-prompt fragment."""
    if not memories:
        return ""
    lines = [
        "## Long-term memory",
        "These facts about the user persist across conversations:",
    ]
    for m in memories:
        prefix = "★" if m.pinned else "•"
        label = f"[{m.key}] " if m.key else ""
        lines.append(f"{prefix} {label}{m.content}")
    return "\n".join(lines)


def memories_to_json(memories: list[Memory]) -> str:
    return json.dumps([m.to_dict() for m in memories], ensure_ascii=False)
