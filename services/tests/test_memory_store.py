# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Memory service: CRUD, scoping, and lexical retrieval.

Exercises :mod:`memory.store` against an in-process SQLite DB so the
tests stay hermetic and don't touch the user's real ``~/.studiomc``.
"""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from pathlib import Path

import pytest

from common import config as common_config
from common import database as common_database
from common.database import Database


@pytest.fixture
def isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Point the singleton DB at a fresh temp file per test."""
    db_file = tmp_path / "test.db"
    monkeypatch.setattr(common_config, "DB_PATH", db_file)
    # ``database.py`` imported ``DB_PATH`` at module load, so patch the
    # local symbol too — that's the binding the singleton actually uses.
    monkeypatch.setattr(common_database, "DB_PATH", db_file)

    # Wipe singleton between tests so each test gets its own DB.
    Database._instance = None  # type: ignore[attr-defined]
    yield
    Database._instance = None  # type: ignore[attr-defined]


def _run(coro):  # type: ignore[no-untyped-def]
    return asyncio.run(coro)


def test_add_and_get_memory_roundtrip(isolated_db: None) -> None:
    from memory.store import add_memory, get_memory

    async def go() -> None:
        mem = await add_memory(content="user prefers dark mode", key="ui_pref")
        assert mem.content == "user prefers dark mode"
        assert mem.key == "ui_pref"
        assert mem.scope == "global"
        assert mem.org_id == "local"
        assert mem.id.startswith("mem-")

        fetched = await get_memory(mem.id)
        assert fetched is not None
        assert fetched.content == mem.content

    _run(go())


def test_add_memory_rejects_empty_content(isolated_db: None) -> None:
    from memory.store import add_memory

    async def go() -> None:
        with pytest.raises(ValueError, match="empty"):
            await add_memory(content="   ")

    _run(go())


def test_add_memory_rejects_invalid_scope(isolated_db: None) -> None:
    from memory.store import add_memory

    async def go() -> None:
        with pytest.raises(ValueError, match="invalid scope"):
            await add_memory(content="x", scope="not-a-real-scope")

    _run(go())


def test_chat_scope_requires_scope_id(isolated_db: None) -> None:
    from memory.store import add_memory

    async def go() -> None:
        with pytest.raises(ValueError, match="requires scope_id"):
            await add_memory(content="x", scope="chat", scope_id=None)

    _run(go())


def test_update_memory(isolated_db: None) -> None:
    from memory.store import add_memory, get_memory, update_memory

    async def go() -> None:
        mem = await add_memory(content="original", tags=["a"])
        await update_memory(mem.id, content="updated", pinned=True)
        fetched = await get_memory(mem.id)
        assert fetched is not None
        assert fetched.content == "updated"
        assert fetched.pinned is True
        # Tags preserved when not passed.
        assert fetched.tags == ["a"]

    _run(go())


def test_update_unknown_memory_raises(isolated_db: None) -> None:
    from memory.store import update_memory

    async def go() -> None:
        with pytest.raises(KeyError):
            await update_memory("mem-doesnotexist", content="x")

    _run(go())


def test_delete_and_clear_memories(isolated_db: None) -> None:
    from memory.store import (
        add_memory,
        clear_memories,
        delete_memory,
        list_memories,
    )

    async def go() -> None:
        m1 = await add_memory(content="one")
        await add_memory(content="two")
        assert len(await list_memories()) == 2

        assert await delete_memory(m1.id) is True
        assert await delete_memory(m1.id) is False  # idempotent
        remaining = await list_memories()
        assert len(remaining) == 1
        assert remaining[0].content == "two"

        # Clear remaining.
        deleted = await clear_memories()
        assert deleted == 1
        assert await list_memories() == []

    _run(go())


def test_relevant_memories_pinned_always_returned(isolated_db: None) -> None:
    """A pinned memory must surface even if no query token matches it."""
    from memory.store import add_memory, relevant_memories

    async def go() -> None:
        await add_memory(content="user lives in Singapore", pinned=True)
        await add_memory(content="user enjoys gardening")
        results = await relevant_memories(query="totally unrelated topic")
        # Pinned memory should still be present; gardening one is filtered
        # out because it scored 0.
        contents = [m.content for m in results]
        assert any("Singapore" in c for c in contents)

    _run(go())


def test_relevant_memories_scoped_to_chat(isolated_db: None) -> None:
    """A chat-scoped memory should only appear when scope_id matches."""
    from memory.store import add_memory, relevant_memories

    async def go() -> None:
        await add_memory(
            content="discussing project Phoenix budget",
            scope="chat",
            scope_id="chat-1",
        )
        # Another chat with the same query content — must not leak.
        await add_memory(
            content="discussing project Phoenix budget",
            scope="chat",
            scope_id="chat-2",
        )

        in_chat_1 = await relevant_memories(query="Phoenix budget", scope_id="chat-1")
        assert all(m.scope_id == "chat-1" for m in in_chat_1)

    _run(go())


def test_format_for_prompt_renders_pinned_marker(isolated_db: None) -> None:
    from memory.store import Memory, format_for_prompt

    pinned = Memory(
        id="mem-1", org_id="local", scope="global", scope_id=None,
        key="loc", content="user is in SG", tags=[],
        source_message_id=None, confidence=1.0, pinned=True,
        created_at="2026-05-08T00:00:00", updated_at="2026-05-08T00:00:00",
    )
    rendered = format_for_prompt([pinned])
    assert "★" in rendered
    assert "[loc]" in rendered
    assert "user is in SG" in rendered
    assert format_for_prompt([]) == ""
