# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Text extraction from PDF, TXT, and MD files.

Extracted text is written to DOCS_DIR/<doc_id>/extracted.txt.
"""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

import aiofiles
from PyPDF2 import PdfReader

from common.config import DOCS_DIR


# Maximum upload size: 100 MB
MAX_FILE_BYTES = 100 * 1024 * 1024

SUPPORTED_EXTENSIONS = {".pdf", ".txt", ".md"}
MIME_MAP = {
    ".pdf": "application/pdf",
    ".txt": "text/plain",
    ".md": "text/markdown",
}


def doc_dir(doc_id: str) -> Path:
    """Return the per-document storage directory, creating it if needed."""
    d = DOCS_DIR / doc_id
    d.mkdir(parents=True, exist_ok=True)
    return d


async def save_upload(doc_id: str, filename: str, content: bytes) -> Path:
    """Persist the uploaded file and return its path."""
    ext = Path(filename).suffix.lower()
    dest = doc_dir(doc_id) / f"original{ext}"
    async with aiofiles.open(dest, "wb") as f:
        await f.write(content)
    return dest


def compute_sha256(file_path: Path) -> str:
    """Compute the SHA-256 hex digest of a file."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


async def extract_text(doc_id: str, original_path: Path) -> str:
    """Extract text from the original file and write extracted.txt.

    Returns the full extracted text.
    Raises ValueError on unsupported format or extraction failure.
    """
    ext = original_path.suffix.lower()

    if ext == ".pdf":
        text = _extract_pdf(original_path)
    elif ext in (".txt", ".md"):
        text = await _extract_plaintext(original_path)
    else:
        raise ValueError(f"Unsupported file extension: {ext}")

    if not text.strip():
        raise ValueError("Extraction produced no text (file may be empty or image-only)")

    # Persist extracted text
    out_path = doc_dir(doc_id) / "extracted.txt"
    async with aiofiles.open(out_path, "w", encoding="utf-8") as f:
        await f.write(text)

    return text


# ── Private helpers ──────────────────────────────────────────────


def _extract_pdf(path: Path) -> str:
    """Extract text from a PDF using PyPDF2, page by page."""
    reader = PdfReader(str(path))
    pages: list[str] = []
    for i, page in enumerate(reader.pages):
        page_text = page.extract_text() or ""
        if page_text.strip():
            pages.append(f"--- Page {i + 1} ---\n{page_text}")
    return "\n\n".join(pages)


async def _extract_plaintext(path: Path) -> str:
    """Read a UTF-8 text file."""
    async with aiofiles.open(path, "r", encoding="utf-8") as f:
        return await f.read()
