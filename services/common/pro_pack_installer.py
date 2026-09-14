# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Download + verify + extract the Studiomc Pro pack tarball.

Drives the install flow that the Flutter "Install Pro pack" dialog
ultimately triggers. Exposes a single async generator
:func:`install_pro_pack` that yields :class:`ProgressEvent` objects so
the FastAPI route can stream progress over Server-Sent Events:

* ``stage="download"`` — bytes downloaded / total
* ``stage="verify"``   — sha256 verification
* ``stage="extract"``  — tar entries processed
* ``stage="finalize"`` — VERSION + manifest written
* ``stage="done"``     — success
* ``stage="error"``    — fatal failure (message in ``error``)

The installer is **idempotent**: re-running it on top of a current
install short-circuits to ``already_installed`` immediately.

Disk layout written
-------------------
::

    $STUDIOMC_HOME/pro-env/
        VERSION
        INSTALLED_AT
        manifest.json     (a copy of the release manifest)
        bin/python
        lib/...

See ``services/common/pro_pack.py`` for the contract surfaced to the
rest of the codebase.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import shutil
import subprocess
import tarfile
import tempfile
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from common.config import ROOT
from common.pro_pack import (
    PRO_ENV_DIR,
    PRO_MANIFEST_FILE,
    PRO_VERSION_FILE,
    REQUIRED_PRO_VERSION,
    get_status,
)

logger = logging.getLogger("common.pro_pack_installer")


# ── Public types ──────────────────────────────────────────────────────

@dataclass
class ProgressEvent:
    """One progress tick streamed back to the Flutter UI.

    Sent over SSE as ``data: {json}`` lines so the client can render a
    live progress bar without polling.
    """

    stage: str            # download | verify | extract | finalize | done | error
    progress: float = 0.0  # 0.0 .. 1.0
    message: str = ""
    bytes_done: int = 0
    bytes_total: int = 0
    extra: dict[str, Any] = field(default_factory=dict)
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "stage": self.stage,
            "progress": round(self.progress, 4),
            "message": self.message,
            "bytes_done": self.bytes_done,
            "bytes_total": self.bytes_total,
            "extra": self.extra,
            "error": self.error,
        }


# ── Helpers ───────────────────────────────────────────────────────────

class ProPackInstallError(RuntimeError):
    """Raised inside the installer; rendered as an ``error`` event."""


async def _stream_download(
    client: httpx.AsyncClient,
    url: str,
    dest: Path,
) -> AsyncIterator[ProgressEvent]:
    """Download ``url`` to ``dest``, yielding progress events."""
    async with client.stream("GET", url, follow_redirects=True) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length") or 0)
        bytes_done = 0
        last_emitted = 0
        with dest.open("wb") as fh:
            async for chunk in resp.aiter_bytes(chunk_size=1 << 20):  # 1 MiB
                if not chunk:
                    continue
                fh.write(chunk)
                bytes_done += len(chunk)

                # Throttle progress events to once per ~5 MiB to keep SSE quiet.
                if bytes_done - last_emitted >= (5 << 20) or bytes_done == total:
                    last_emitted = bytes_done
                    yield ProgressEvent(
                        stage="download",
                        progress=(bytes_done / total) if total else 0.0,
                        message=f"Downloading Pro pack ({bytes_done >> 20} / {total >> 20 if total else '?'} MiB)",
                        bytes_done=bytes_done,
                        bytes_total=total,
                    )

        if total and bytes_done != total:
            raise ProPackInstallError(
                f"Truncated download: got {bytes_done}/{total} bytes"
            )


def _sha256_file(path: Path, *, chunk_size: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def _decompress_zstd(src: Path, dest: Path) -> None:
    """Decompress a .tar.zst → .tar using the ``zstd`` CLI.

    We shell out instead of bundling ``zstandard`` so the Core image
    stays slim. The CLI is preinstalled on macOS 14+ and most Linux
    distros; we surface a clear error when it isn't.
    """
    if not shutil.which("zstd"):
        raise ProPackInstallError(
            "The 'zstd' command is required to extract the Pro pack. "
            "Install it via `brew install zstd` (macOS) or "
            "`apt install zstd` (Linux)."
        )
    try:
        subprocess.run(
            ["zstd", "-d", "-q", "-f", str(src), "-o", str(dest)],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as exc:
        raise ProPackInstallError(
            f"zstd decompression failed: {exc.stderr.decode(errors='ignore').strip()}"
        ) from exc


def _safe_extract(tar_path: Path, dest_root: Path) -> int:
    """Extract a tar safely, returning member count.

    Hardening:
      * Reject members whose resolved path escapes ``dest_root``.
      * Reject absolute-path entries.
      * Reject symlinks/hardlinks whose target escapes ``dest_root``.
      * Strip dangerous device/character/FIFO entries.

    Python 3.12 introduced ``tarfile.data_filter``; we re-implement the
    relevant subset here so the installer keeps working on 3.11 and
    behaves identically across versions.
    """
    members = 0
    dest_root = dest_root.resolve()
    with tarfile.open(tar_path, "r") as tf:
        for member in tf:
            # Reject device/special files outright — Pro pack only ships
            # regular files, dirs, and symlinks.
            if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
                raise ProPackInstallError(
                    f"Refusing to extract device entry: {member.name}"
                )

            # Reject absolute paths.
            if member.name.startswith("/") or member.name.startswith("\\"):
                raise ProPackInstallError(
                    f"Refusing absolute path in tar: {member.name}"
                )

            target = (dest_root / member.name).resolve()
            try:
                target.relative_to(dest_root)
            except ValueError as exc:
                raise ProPackInstallError(
                    f"Refusing to extract suspicious tar entry: {member.name}"
                ) from exc

            # For symlinks/hardlinks, also resolve the link target and
            # ensure it stays under dest_root. Without this, an attacker
            # could ship "/etc/passwd" as a link target.
            if member.issym() or member.islnk():
                link_target = member.linkname
                if link_target.startswith("/") or link_target.startswith("\\"):
                    raise ProPackInstallError(
                        f"Refusing absolute link target in tar: {member.name} -> {link_target}"
                    )
                resolved_link = (target.parent / link_target).resolve()
                try:
                    resolved_link.relative_to(dest_root)
                except ValueError as exc:
                    raise ProPackInstallError(
                        f"Refusing link that escapes destination: "
                        f"{member.name} -> {link_target}"
                    ) from exc

            tf.extract(member, dest_root)
            members += 1
    return members


# ── Public entry point ───────────────────────────────────────────────

async def install_pro_pack(
    archive_url: str,
    expected_sha256: str,
    expected_version: str = REQUIRED_PRO_VERSION,
    *,
    manifest_url: str | None = None,
    timeout_seconds: float = 60 * 30,
) -> AsyncIterator[ProgressEvent]:
    """Download, verify, and extract the Pro pack tarball.

    Yields :class:`ProgressEvent` objects suitable for streaming over SSE.
    The very last event is always ``stage="done"`` or ``stage="error"``.

    Args:
        archive_url:      HTTPS URL to the ``.tar.zst`` (typically a
                          GitHub Releases asset).
        expected_sha256:  Hex digest the downloaded file must match.
                          Comes from the release ``manifest.json`` so
                          we can detect tampering or partial mirrors.
        expected_version: Version that should land in ``VERSION`` after
                          extraction (defaults to
                          :data:`REQUIRED_PRO_VERSION`).
        manifest_url:     Optional URL to the JSON manifest. When set we
                          fetch + persist it next to ``VERSION`` so the
                          UI can show package versions later.
        timeout_seconds:  Per-request timeout for the download.
    """
    try:
        # Idempotency check
        existing = get_status()
        if existing.installed and existing.version == expected_version:
            yield ProgressEvent(
                stage="done",
                progress=1.0,
                message=f"Pro pack {expected_version} already installed",
                extra={"already_installed": True, "version": existing.version},
            )
            return

        ROOT.mkdir(parents=True, exist_ok=True)
        # Stage everything in a tmp dir so a half-finished install can't
        # corrupt the live pro-env/.
        with tempfile.TemporaryDirectory(prefix="studiomc-pro-", dir=ROOT) as tmp:
            tmp_path = Path(tmp)
            archive_zst = tmp_path / "pack.tar.zst"
            archive_tar = tmp_path / "pack.tar"
            extract_root = tmp_path / "extract"
            extract_root.mkdir(parents=True, exist_ok=True)

            # 1. Download
            async with httpx.AsyncClient(timeout=timeout_seconds) as client:
                async for evt in _stream_download(client, archive_url, archive_zst):
                    yield evt

                if manifest_url:
                    try:
                        resp = await client.get(manifest_url)
                        resp.raise_for_status()
                        (tmp_path / "manifest.json").write_bytes(resp.content)
                    except httpx.HTTPError as exc:
                        logger.warning("Failed to fetch manifest: %s", exc)

            # 2. Verify
            yield ProgressEvent(stage="verify", progress=0.0, message="Verifying integrity")
            actual = await asyncio.to_thread(_sha256_file, archive_zst)
            if actual.lower() != expected_sha256.lower():
                raise ProPackInstallError(
                    f"sha256 mismatch — expected {expected_sha256}, got {actual}"
                )
            yield ProgressEvent(
                stage="verify",
                progress=1.0,
                message="Checksum OK",
                extra={"sha256": actual},
            )

            # 3. Decompress + extract
            yield ProgressEvent(stage="extract", progress=0.0, message="Decompressing")
            await asyncio.to_thread(_decompress_zstd, archive_zst, archive_tar)
            members = await asyncio.to_thread(_safe_extract, archive_tar, extract_root)
            yield ProgressEvent(
                stage="extract",
                progress=1.0,
                message=f"Extracted {members} files",
                extra={"member_count": members},
            )

            staged_env = extract_root / "pro-env"
            if not staged_env.is_dir():
                raise ProPackInstallError(
                    "Pro pack tarball is missing the top-level 'pro-env/' directory"
                )

            # 4. Finalize — atomic swap into ROOT/pro-env
            yield ProgressEvent(stage="finalize", progress=0.0, message="Installing")
            if PRO_ENV_DIR.exists():
                # Move the old env aside; keep it until the new one is in
                # place so we can roll back on failure.
                backup = PRO_ENV_DIR.with_suffix(".old")
                if backup.exists():
                    shutil.rmtree(backup, ignore_errors=True)
                PRO_ENV_DIR.rename(backup)
                try:
                    shutil.move(str(staged_env), str(PRO_ENV_DIR))
                except Exception:
                    # Roll back
                    if backup.exists():
                        backup.rename(PRO_ENV_DIR)
                    raise
                shutil.rmtree(backup, ignore_errors=True)
            else:
                shutil.move(str(staged_env), str(PRO_ENV_DIR))

            # Stamp version (overrides whatever shipped in the tarball,
            # making future "needs_upgrade" checks deterministic).
            PRO_VERSION_FILE.write_text(expected_version + "\n", encoding="utf-8")

            # Persist the release manifest so the UI can show "what's
            # inside this pack" later.
            manifest_src = tmp_path / "manifest.json"
            if manifest_src.exists():
                shutil.copy(manifest_src, PRO_MANIFEST_FILE)
            else:
                PRO_MANIFEST_FILE.write_text(
                    json.dumps(
                        {
                            "version": expected_version,
                            "sha256": expected_sha256,
                            "archive_url": archive_url,
                        },
                        indent=2,
                    ),
                    encoding="utf-8",
                )

            yield ProgressEvent(
                stage="finalize",
                progress=1.0,
                message=f"Installed Pro pack {expected_version}",
                extra={"path": str(PRO_ENV_DIR)},
            )

        yield ProgressEvent(
            stage="done",
            progress=1.0,
            message=f"Pro pack {expected_version} ready",
            extra={"version": expected_version, "python_path": str(PRO_ENV_DIR / "bin" / "python")},
        )

    except ProPackInstallError as exc:
        logger.error("Pro pack install failed: %s", exc)
        yield ProgressEvent(stage="error", error=str(exc), message=str(exc))
    except Exception as exc:
        logger.exception("Pro pack install crashed")
        yield ProgressEvent(stage="error", error=str(exc), message=f"Unexpected error: {exc}")


# ── Uninstall ─────────────────────────────────────────────────────────

def uninstall_pro_pack() -> bool:
    """Remove the Pro pack from disk. Returns ``True`` if anything was deleted."""
    if not PRO_ENV_DIR.exists():
        return False
    shutil.rmtree(PRO_ENV_DIR, ignore_errors=True)
    return True
