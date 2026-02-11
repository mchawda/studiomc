# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Safe tool implementations for the LRE runtime.

Each tool function:
- Accepts validated inputs only
- Returns a string result (already budget-capped by the caller)
- Includes duration_ms in its trace output
- NEVER performs file writes or shell execution
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from common.config import DOCS_DIR
from common.database import Database
from common.schemas import Citation, DocChunk

from lre.sandbox import (
    SecurityViolation,
    validate_doc_id,
    validate_path,
    validate_pattern,
)


def _ms_since(start: float) -> int:
    """Return elapsed milliseconds since *start* (monotonic)."""
    return int((time.monotonic() - start) * 1000)


def _doc_text_path(doc_id: str) -> Path:
    """Return the extracted.txt path for a document."""
    return DOCS_DIR / doc_id / "extracted.txt"


# ── search ──────────────────────────────────────────────────────────────


async def tool_search(query: str, scope: str | None = None) -> dict[str, Any]:
    """Search doc_chunks table with LIKE matching, optionally within a collection scope."""
    t0 = time.monotonic()

    db = await Database.instance()

    like_param = f"%{query}%"

    if scope:
        # Scope is a collection_id — join through collection_documents
        rows = await db.fetchall(
            """
            SELECT dc.id, dc.document_id, dc.chunk_index, dc.text, dc.token_count
            FROM doc_chunks dc
            JOIN collection_documents cd ON cd.document_id = dc.document_id
            WHERE cd.collection_id = ?
              AND dc.text LIKE ?
            ORDER BY dc.chunk_index
            LIMIT 20
            """,
            (scope, like_param),
        )
    else:
        rows = await db.fetchall(
            """
            SELECT id, document_id, chunk_index, text, token_count
            FROM doc_chunks
            WHERE text LIKE ?
            ORDER BY chunk_index
            LIMIT 20
            """,
            (like_param,),
        )

    results = [
        {
            "id": row["id"],
            "document_id": row["document_id"],
            "chunk_index": row["chunk_index"],
            "text": row["text"],
            "token_count": row["token_count"],
        }
        for row in rows
    ]

    return {
        "tool": "search",
        "results": results,
        "count": len(results),
        "duration_ms": _ms_since(t0),
    }


# ── grep ────────────────────────────────────────────────────────────────


async def tool_grep(
    pattern: str, files: list[str] | None = None
) -> dict[str, Any]:
    """Regex pattern search through extracted text files in DOCS_DIR."""
    t0 = time.monotonic()

    safe_pattern = validate_pattern(pattern)
    compiled = re.compile(safe_pattern, re.IGNORECASE)

    matches: list[dict[str, Any]] = []

    if files:
        # Validate each supplied path
        targets = [validate_path(f) for f in files]
    else:
        # Search all extracted.txt files under DOCS_DIR
        docs_root = DOCS_DIR.resolve()
        targets = sorted(docs_root.rglob("extracted.txt"))

    for fpath in targets:
        if not fpath.is_file():
            continue
        try:
            text = fpath.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        for line_no, line in enumerate(text.splitlines(), start=1):
            if compiled.search(line):
                matches.append(
                    {
                        "file": str(fpath.relative_to(DOCS_DIR.resolve())),
                        "line": line_no,
                        "text": line.strip()[:500],  # cap line length
                    }
                )
                if len(matches) >= 50:
                    break
        if len(matches) >= 50:
            break

    return {
        "tool": "grep",
        "matches": matches,
        "count": len(matches),
        "duration_ms": _ms_since(t0),
    }


# ── open ────────────────────────────────────────────────────────────────


def _parse_span(span: str | None) -> tuple[int | None, int | None]:
    """Parse a page-range span like 'p3-p5' into (start_page, end_page).

    Returns (None, None) if span is empty or unparseable.
    """
    if not span:
        return None, None
    m = re.match(r"p(\d+)(?:-p(\d+))?$", span.strip().lower())
    if not m:
        return None, None
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else start
    return start, end


def _slice_by_pages(text: str, start: int | None, end: int | None) -> str:
    """Extract text between page markers like [PAGE 3] ... [PAGE 6].

    Falls back to returning the full text if no markers are found.
    """
    if start is None:
        return text

    # Find page markers — convention: [PAGE N] or --- Page N ---
    page_pattern = re.compile(r"\[PAGE\s+(\d+)\]|---\s*Page\s+(\d+)\s*---", re.IGNORECASE)
    markers: list[tuple[int, int]] = []  # (page_num, char_offset)
    for m in page_pattern.finditer(text):
        page_num = int(m.group(1) or m.group(2))
        markers.append((page_num, m.start()))

    if not markers:
        # No page markers — return full text
        return text

    # Find start offset
    start_offset = 0
    for pn, offset in markers:
        if pn >= start:
            start_offset = offset
            break

    # Find end offset
    end_offset = len(text)
    if end is not None:
        for pn, offset in markers:
            if pn > end:
                end_offset = offset
                break

    return text[start_offset:end_offset]


async def tool_open(doc_id: str, span: str | None = None) -> dict[str, Any]:
    """Open a document section (read extracted text, optionally sliced by page)."""
    t0 = time.monotonic()

    safe_id = validate_doc_id(doc_id)
    text_path = _doc_text_path(safe_id)

    if not text_path.is_file():
        return {
            "tool": "open",
            "error": f"No extracted text for document {doc_id}",
            "text": "",
            "duration_ms": _ms_since(t0),
        }

    full_text = text_path.read_text(encoding="utf-8", errors="replace")
    start_page, end_page = _parse_span(span)
    sliced = _slice_by_pages(full_text, start_page, end_page)

    return {
        "tool": "open",
        "doc_id": doc_id,
        "span": span,
        "text": sliced,
        "char_count": len(sliced),
        "duration_ms": _ms_since(t0),
    }


# ── summarize ───────────────────────────────────────────────────────────


async def tool_summarize(
    doc_id: str, span: str | None = None, max_tokens: int = 300
) -> dict[str, Any]:
    """Return a truncated extract of a document section.

    Real summarization requires an LLM call — this is a best-effort stub
    that returns the first N tokens (approximated as chars / 4).
    """
    t0 = time.monotonic()

    # Reuse open to get the text
    open_result = await tool_open(doc_id, span)
    if open_result.get("error"):
        open_result["tool"] = "summarize"
        return open_result

    text: str = open_result["text"]
    max_chars = max_tokens * 4  # rough estimate

    if len(text) <= max_chars:
        summary = text
    else:
        # Truncate at a word boundary
        truncated = text[:max_chars]
        last_space = truncated.rfind(" ")
        if last_space > max_chars * 0.8:
            truncated = truncated[:last_space]
        summary = truncated + " …"

    return {
        "tool": "summarize",
        "doc_id": doc_id,
        "span": span,
        "summary": summary,
        "is_stub": True,  # flag: no real LLM summarization yet
        "duration_ms": _ms_since(t0),
    }


# ── table_extract ───────────────────────────────────────────────────────


def _extract_tables(text: str) -> list[list[list[str]]]:
    """Detect table-like patterns in text and return structured data.

    Supports:
    - Pipe-delimited tables (Markdown-style)
    - Tab-delimited rows
    Returns a list of tables, each being a list of rows (list of cells).
    """
    tables: list[list[list[str]]] = []

    # Strategy 1: Pipe-delimited tables ( | col | col | )
    pipe_lines: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if "|" in stripped and stripped.count("|") >= 2:
            # Skip Markdown separator lines (| --- | --- |)
            if re.match(r"^\|[\s\-:|]+\|$", stripped):
                continue
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            pipe_lines.append(cells)  # type: ignore[arg-type]
        else:
            if len(pipe_lines) >= 2:
                tables.append(pipe_lines)
            pipe_lines = []
    if len(pipe_lines) >= 2:
        tables.append(pipe_lines)

    # Strategy 2: Tab-delimited rows (only if no pipe tables found)
    if not tables:
        tab_lines: list[list[str]] = []
        for line in text.splitlines():
            if "\t" in line:
                cells = [c.strip() for c in line.split("\t")]
                tab_lines.append(cells)
            else:
                if len(tab_lines) >= 2:
                    tables.append(tab_lines)
                tab_lines = []
        if len(tab_lines) >= 2:
            tables.append(tab_lines)

    return tables


async def tool_table_extract(
    doc_id: str, span: str | None = None
) -> dict[str, Any]:
    """Extract table data from a document section."""
    t0 = time.monotonic()

    open_result = await tool_open(doc_id, span)
    if open_result.get("error"):
        open_result["tool"] = "table_extract"
        return open_result

    text: str = open_result["text"]
    raw_tables = _extract_tables(text)

    # Convert to JSON-friendly format
    tables_out: list[dict[str, Any]] = []
    for i, table in enumerate(raw_tables):
        header = table[0] if table else []
        rows = table[1:] if len(table) > 1 else []
        tables_out.append(
            {
                "table_index": i,
                "header": header,
                "rows": rows,
                "row_count": len(rows),
            }
        )

    return {
        "tool": "table_extract",
        "doc_id": doc_id,
        "span": span,
        "tables": tables_out,
        "table_count": len(tables_out),
        "duration_ms": _ms_since(t0),
    }


# ── cite ────────────────────────────────────────────────────────────────


async def tool_cite(
    doc_id: str, chunk_index: int, snippet: str = "", relevance_score: float = 1.0
) -> dict[str, Any]:
    """Create a Citation object from a doc_id + chunk reference."""
    t0 = time.monotonic()

    safe_id = validate_doc_id(doc_id)

    # Look up the document filename
    db = await Database.instance()
    row = await db.fetchone(
        "SELECT filename FROM documents WHERE id = ?", (safe_id,)
    )
    filename = row["filename"] if row else "unknown"

    # If no snippet provided, try to fetch from chunks
    if not snippet:
        chunk_row = await db.fetchone(
            "SELECT text FROM doc_chunks WHERE document_id = ? AND chunk_index = ?",
            (safe_id, chunk_index),
        )
        if chunk_row:
            snippet = chunk_row["text"][:300]

    citation = Citation(
        document_id=safe_id,
        filename=filename,
        chunk_index=chunk_index,
        snippet=snippet[:500],  # cap snippet length
        relevance_score=max(0.0, min(1.0, relevance_score)),
    )

    return {
        "tool": "cite",
        "citation": citation.model_dump(),
        "duration_ms": _ms_since(t0),
    }


# ── Dispatcher ──────────────────────────────────────────────────────────

TOOL_REGISTRY: dict[str, Any] = {
    "search": tool_search,
    "grep": tool_grep,
    "open": tool_open,
    "summarize": tool_summarize,
    "table_extract": tool_table_extract,
    "cite": tool_cite,
}
