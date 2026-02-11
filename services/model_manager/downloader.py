"""Downloader — HuggingFace model downloads with pause/resume and checksum.

Downloads are tracked in memory via a dict keyed by model_id.
Uses huggingface_hub for file discovery, then streams via httpx with
Range-header support for pause/resume.
"""

from __future__ import annotations

import asyncio
import fnmatch
import hashlib
import logging
import os
import shutil
import time
from pathlib import Path
from typing import Any

import httpx

from common.config import DOWNLOADS_DIR, MODELS_DIR
from common.schemas import ModelDownloadStatus

logger = logging.getLogger("model_manager.downloader")

# ── In-memory download state ──

_downloads: dict[str, ModelDownloadStatus] = {}
_download_tasks: dict[str, asyncio.Task] = {}
_pause_events: dict[str, asyncio.Event] = {}  # cleared = paused, set = running

# Chunk size for streaming downloads (512 KB)
_CHUNK_SIZE = 512 * 1024


def get_download_status(model_id: str) -> ModelDownloadStatus | None:
    """Return current download status for a model, or None if not tracked."""
    return _downloads.get(model_id)


def get_all_download_statuses() -> dict[str, ModelDownloadStatus]:
    """Return all tracked download statuses."""
    return dict(_downloads)


async def start_download(
    model_id: str,
    source_ref: str,
    filename_pattern: str = "*.gguf",
) -> ModelDownloadStatus:
    """Start downloading a model from HuggingFace Hub.

    Args:
        model_id: Internal model identifier.
        source_ref: HuggingFace repo id (e.g. "bartowski/Llama-3.2-1B-Instruct-GGUF").
        filename_pattern: Glob pattern for the file to download.

    Returns:
        The initial ModelDownloadStatus.
    """
    # If already downloading, return existing status
    if model_id in _downloads and _downloads[model_id].status in ("downloading", "pending"):
        return _downloads[model_id]

    status = ModelDownloadStatus(
        model_id=model_id,
        progress=0.0,
        downloaded_bytes=0,
        total_bytes=0,
        speed_mbps=0.0,
        status="pending",
    )
    _downloads[model_id] = status

    # Create an event that starts in "set" state (running, not paused)
    pause_event = asyncio.Event()
    pause_event.set()
    _pause_events[model_id] = pause_event

    # Launch background download task
    task = asyncio.create_task(_download_worker(model_id, source_ref, filename_pattern))
    _download_tasks[model_id] = task

    return status


async def pause_download(model_id: str) -> ModelDownloadStatus | None:
    """Pause an active download.

    Clears the pause event so the download loop breaks after the current
    chunk, then waits for resume.  The partial file stays on disk and the
    next resume will continue via HTTP Range headers.
    """
    status = _downloads.get(model_id)
    if status is None:
        return None

    if status.status == "downloading":
        status.status = "paused"
        status.speed_mbps = 0.0
        # Clear the event to signal the worker to pause
        event = _pause_events.get(model_id)
        if event:
            event.clear()

    return status


async def resume_download(model_id: str) -> ModelDownloadStatus | None:
    """Resume a paused download.

    Sets the pause event so the download loop wakes up and opens a new
    HTTP connection with a Range header from the current byte offset.
    """
    status = _downloads.get(model_id)
    if status is None:
        return None

    if status.status == "paused":
        status.status = "downloading"
        event = _pause_events.get(model_id)
        if event:
            event.set()

    return status


async def cancel_download(model_id: str) -> bool:
    """Cancel and clean up a download."""
    task = _download_tasks.pop(model_id, None)
    if task and not task.done():
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    _downloads.pop(model_id, None)
    _pause_events.pop(model_id, None)

    # Clean up partial files
    dl_path = DOWNLOADS_DIR / model_id
    if dl_path.exists():
        shutil.rmtree(dl_path, ignore_errors=True)

    return True


async def verify_checksum(model_id: str) -> str | None:
    """Compute SHA-256 checksum of the downloaded model file.

    Returns the hex digest, or None if the model directory/file doesn't exist.
    """
    model_dir = MODELS_DIR / model_id
    if not model_dir.exists():
        return None

    # Find the main GGUF file
    gguf_files = list(model_dir.glob("*.gguf"))
    if not gguf_files:
        # Fallback: hash whatever is there
        files = list(model_dir.iterdir())
        if not files:
            return None
        target = max(files, key=lambda f: f.stat().st_size)
    else:
        target = gguf_files[0]

    return await asyncio.to_thread(_sha256_file, target)


def _sha256_file(path: Path) -> str:
    """Compute SHA-256 hash of a file (blocking, run in thread)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(8 * 1024 * 1024)  # 8 MB chunks
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


# ── HuggingFace file resolution (runs in thread) ──

def _resolve_hf_file(
    source_ref: str,
    filename_pattern: str,
    status: ModelDownloadStatus,
) -> tuple[str, str] | None:
    """Resolve the target filename and download URL from HuggingFace.

    Returns (target_filename, download_url) or None on error (sets status).
    """
    from huggingface_hub import HfApi

    api = HfApi()
    try:
        files_info = api.list_repo_files(source_ref)
        matching = [f for f in files_info if fnmatch.fnmatch(f, filename_pattern)]

        if not matching:
            for pattern in ("*.gguf", "*.bin", "*.safetensors"):
                matching = [f for f in files_info if fnmatch.fnmatch(f, pattern)]
                if matching:
                    break

        if not matching:
            status.status = "error"
            status.error = (
                f"No model files found matching '{filename_pattern}' in {source_ref}"
            )
            return None

        target_file = _pick_best_file(matching, source_ref)

        # Get file size for progress tracking
        try:
            repo_info = api.repo_info(source_ref)
            for sibling in repo_info.siblings or []:
                if sibling.rfilename == target_file:
                    status.total_bytes = sibling.size or 0
                    break
        except Exception:
            pass

        # Construct the direct download URL
        download_url = (
            f"https://huggingface.co/{source_ref}/resolve/main/{target_file}"
        )
        return target_file, download_url

    except Exception as e:
        status.status = "error"
        status.error = f"HF resolution error: {e}"
        return None


# ── Background download worker ──

async def _download_worker(
    model_id: str,
    source_ref: str,
    filename_pattern: str,
) -> None:
    """Background task that performs the actual download with pause/resume."""
    status = _downloads[model_id]
    pause_event = _pause_events[model_id]

    try:
        status.status = "downloading"

        # 1) Resolve the file to download (blocking HF API call)
        result = await asyncio.to_thread(
            _resolve_hf_file, source_ref, filename_pattern, status
        )
        if result is None:
            return  # Error already recorded in status

        target_file, download_url = result
        local_filename = target_file.split("/")[-1]

        # 2) Stream-download with pause/resume support
        await _download_file_with_pause(
            model_id, download_url, local_filename, status, pause_event
        )

        # 3) If download completed, finalize
        if status.status == "downloading" and status.progress >= 1.0:
            await asyncio.to_thread(_finalize_download, model_id)
            status.status = "verifying"

            checksum = await verify_checksum(model_id)
            if checksum:
                status.status = "complete"
                status.progress = 1.0
                logger.info(
                    "Download complete for %s, checksum=%s",
                    model_id,
                    checksum[:16],
                )
            else:
                status.status = "error"
                status.error = (
                    "Checksum verification failed — no file found after download."
                )

    except asyncio.CancelledError:
        status.status = "error"
        status.error = "Download cancelled."
        raise

    except Exception as e:
        logger.exception("Download failed for %s", model_id)
        status.status = "error"
        status.error = str(e)


async def _download_file_with_pause(
    model_id: str,
    download_url: str,
    local_filename: str,
    status: ModelDownloadStatus,
    pause_event: asyncio.Event,
) -> None:
    """Stream-download a file with pause/resume via HTTP Range headers.

    When the pause event is cleared the loop breaks after the current chunk.
    The partial file stays on disk.  On resume the loop reopens a new HTTP
    connection with ``Range: bytes=<offset>-`` and appends to the file.
    """
    dl_dir = DOWNLOADS_DIR / model_id
    dl_dir.mkdir(parents=True, exist_ok=True)
    dest_path = dl_dir / local_filename

    while status.status in ("downloading", "paused"):
        # If paused, wait until resumed
        if not pause_event.is_set():
            await pause_event.wait()
            # After waking, re-check status (could have been cancelled)
            if status.status not in ("downloading",):
                return

        # Determine resume offset from existing partial file
        resume_offset = 0
        if dest_path.exists():
            resume_offset = dest_path.stat().st_size

        # If we already know total and have all bytes, we're done
        if status.total_bytes > 0 and resume_offset >= status.total_bytes:
            status.downloaded_bytes = resume_offset
            status.progress = 1.0
            return

        headers: dict[str, str] = {}
        if resume_offset > 0:
            headers["Range"] = f"bytes={resume_offset}-"

        session_start = time.time()
        session_bytes = 0
        paused_out = False

        try:
            async with httpx.AsyncClient(
                follow_redirects=True, timeout=300.0
            ) as client:
                async with client.stream(
                    "GET", download_url, headers=headers
                ) as resp:
                    if resp.status_code == 416:
                        # Range not satisfiable — file already complete
                        status.downloaded_bytes = resume_offset
                        status.total_bytes = resume_offset
                        status.progress = 1.0
                        return

                    if resp.status_code not in (200, 206):
                        status.status = "error"
                        status.error = (
                            f"HTTP {resp.status_code} from HuggingFace"
                        )
                        return

                    # Parse total size from headers
                    if resp.status_code == 206:
                        content_range = resp.headers.get("content-range", "")
                        if "/" in content_range:
                            total_str = content_range.split("/")[-1]
                            if total_str != "*":
                                status.total_bytes = int(total_str)
                    elif "content-length" in resp.headers:
                        status.total_bytes = int(
                            resp.headers["content-length"]
                        )
                        resume_offset = 0  # Server ignored Range

                    file_mode = (
                        "ab" if resp.status_code == 206 else "wb"
                    )

                    with open(dest_path, file_mode) as f:
                        async for chunk in resp.aiter_bytes(
                            chunk_size=_CHUNK_SIZE
                        ):
                            f.write(chunk)
                            session_bytes += len(chunk)
                            status.downloaded_bytes = (
                                resume_offset + session_bytes
                            )

                            if status.total_bytes > 0:
                                status.progress = min(
                                    status.downloaded_bytes
                                    / status.total_bytes,
                                    1.0,
                                )

                            elapsed = time.time() - session_start
                            if elapsed > 0:
                                status.speed_mbps = round(
                                    (session_bytes / (1024 * 1024)) / elapsed,
                                    2,
                                )

                            # Check pause flag after writing each chunk
                            if not pause_event.is_set():
                                f.flush()
                                paused_out = True
                                break

            if paused_out:
                # Wait for resume then loop back with Range header
                await pause_event.wait()
                continue

            # Stream completed normally
            if status.total_bytes == 0:
                status.total_bytes = status.downloaded_bytes
            status.progress = 1.0
            return

        except (httpx.ReadTimeout, httpx.ConnectError, httpx.RemoteProtocolError):
            # Connection dropped — if paused, wait and retry; otherwise error
            if not pause_event.is_set() or status.status == "paused":
                await pause_event.wait()
                continue
            status.status = "error"
            status.error = "Connection lost during download."
            return


def _pick_best_file(files: list[str], model_id: str) -> str:
    """From a list of repo files, pick the best model file to download."""
    # Prefer files with Q4_K_M in name (matches our curated quant)
    for f in files:
        if "Q4_K_M" in f.upper():
            return f

    # Prefer files with q4_k_m (lowercase)
    for f in files:
        if "q4_k_m" in f.lower():
            return f

    # Otherwise pick the first file
    return files[0]


def _finalize_download(model_id: str) -> None:
    """Move downloaded files from staging to final models directory."""
    src = DOWNLOADS_DIR / model_id
    dest = MODELS_DIR / model_id
    dest.mkdir(parents=True, exist_ok=True)

    if not src.exists():
        return

    # Move all model files (skip HF cache metadata)
    for item in src.rglob("*"):
        if item.is_file() and not item.name.startswith("."):
            rel = item.relative_to(src)
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(item), str(target))

    # Clean up staging
    shutil.rmtree(src, ignore_errors=True)
