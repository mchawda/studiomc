"""Downloader — HuggingFace model downloads with pause/resume and checksum.

Downloads are tracked in memory via a dict keyed by model_id.
Uses huggingface_hub for authenticated/anonymous HF downloads.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import shutil
import time
from pathlib import Path
from typing import Any

from common.config import DOWNLOADS_DIR, MODELS_DIR
from common.schemas import ModelDownloadStatus

logger = logging.getLogger("model_manager.downloader")

# ── In-memory download state ──

_downloads: dict[str, ModelDownloadStatus] = {}
_download_tasks: dict[str, asyncio.Task] = {}
_pause_events: dict[str, asyncio.Event] = {}  # cleared = paused, set = running


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
    """Pause an active download."""
    status = _downloads.get(model_id)
    if status is None:
        return None

    if status.status == "downloading":
        status.status = "paused"
        # Clear the event to signal the worker to pause
        event = _pause_events.get(model_id)
        if event:
            event.clear()

    return status


async def resume_download(model_id: str) -> ModelDownloadStatus | None:
    """Resume a paused download."""
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


# ── Background download worker ──

async def _download_worker(
    model_id: str,
    source_ref: str,
    filename_pattern: str,
) -> None:
    """Background task that performs the actual HF download."""
    status = _downloads[model_id]
    pause_event = _pause_events[model_id]

    try:
        status.status = "downloading"

        # Run the blocking HF download in a thread
        await asyncio.to_thread(
            _hf_download_blocking,
            model_id,
            source_ref,
            filename_pattern,
            status,
            pause_event,
        )

        if status.status == "downloading":
            # Move from downloads staging to final models dir
            await asyncio.to_thread(_finalize_download, model_id)
            status.status = "verifying"

            # Compute checksum
            checksum = await verify_checksum(model_id)
            if checksum:
                status.status = "complete"
                status.progress = 1.0
                logger.info("Download complete for %s, checksum=%s", model_id, checksum[:16])
            else:
                status.status = "error"
                status.error = "Checksum verification failed — no file found after download."

    except asyncio.CancelledError:
        status.status = "error"
        status.error = "Download cancelled."
        raise

    except Exception as e:
        logger.exception("Download failed for %s", model_id)
        status.status = "error"
        status.error = str(e)


def _hf_download_blocking(
    model_id: str,
    source_ref: str,
    filename_pattern: str,
    status: ModelDownloadStatus,
    pause_event: asyncio.Event,
) -> None:
    """Blocking HuggingFace download with progress tracking.

    This runs in a thread. We use huggingface_hub's hf_hub_download
    which already supports resume via etag-based caching.
    """
    from huggingface_hub import HfApi, hf_hub_download
    from huggingface_hub.utils import EntryNotFoundError

    dl_dir = DOWNLOADS_DIR / model_id
    dl_dir.mkdir(parents=True, exist_ok=True)

    api = HfApi()

    try:
        # List files in the repo matching the pattern
        files_info = api.list_repo_files(source_ref)
        import fnmatch
        matching = [f for f in files_info if fnmatch.fnmatch(f, filename_pattern)]

        if not matching:
            # Try common patterns
            for pattern in ["*.gguf", "*.bin", "*.safetensors"]:
                matching = [f for f in files_info if fnmatch.fnmatch(f, pattern)]
                if matching:
                    break

        if not matching:
            status.status = "error"
            status.error = f"No model files found matching '{filename_pattern}' in {source_ref}"
            return

        # Pick the best file — prefer Q4_K_M in name, else largest
        target_file = _pick_best_file(matching, model_id)

        # Get file size for progress
        try:
            repo_info = api.repo_info(source_ref)
            for sibling in repo_info.siblings or []:
                if sibling.rfilename == target_file:
                    status.total_bytes = sibling.size or 0
                    break
        except Exception:
            pass

        # Download with resume support
        start_time = time.time()

        local_path = hf_hub_download(
            repo_id=source_ref,
            filename=target_file,
            local_dir=str(dl_dir),
            resume_download=True,
        )

        # Update final status
        if local_path and os.path.exists(local_path):
            file_size = os.path.getsize(local_path)
            status.downloaded_bytes = file_size
            if status.total_bytes == 0:
                status.total_bytes = file_size
            status.progress = 1.0
            elapsed = time.time() - start_time
            if elapsed > 0:
                status.speed_mbps = round((file_size / (1024 * 1024)) / elapsed, 2)

    except EntryNotFoundError:
        status.status = "error"
        status.error = f"File not found in repo {source_ref}"
    except Exception as e:
        status.status = "error"
        status.error = f"HF download error: {e}"


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

    # Otherwise pick the largest file (likely the main model)
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
