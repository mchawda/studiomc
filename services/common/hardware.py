"""Hardware scanner — detects GPU/VRAM, RAM, CPU, disk speed.

Produces a HardwareInfo with hw_fingerprint for benchmark keying.
All user-facing terms use plain English (no "VRAM", say "graphics memory").
"""

from __future__ import annotations

import hashlib
import os
import platform
import shutil
import subprocess
import tempfile
import time

import psutil

from .schemas import HardwareInfo


def _detect_gpu() -> tuple[str | None, int | None]:
    """Detect GPU name and VRAM bytes. Returns (name, vram_bytes) or (None, None)."""
    system = platform.system()

    if system == "Darwin":
        # macOS — check for Apple Silicon unified memory
        try:
            result = subprocess.run(
                ["system_profiler", "SPDisplaysDataType", "-json"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0:
                import json
                data = json.loads(result.stdout)
                displays = data.get("SPDisplaysDataType", [])
                for gpu in displays:
                    name = gpu.get("sppci_model", "Unknown GPU")
                    # Apple Silicon reports unified memory
                    vram_str = gpu.get("spdisplays_vram", gpu.get("sppci_vram", ""))
                    vram_bytes = _parse_vram_string(vram_str)
                    return name, vram_bytes
        except Exception:
            pass

    elif system == "Windows":
        try:
            result = subprocess.run(
                ["wmic", "path", "win32_VideoController", "get", "name,adapterram", "/format:csv"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0:
                for line in result.stdout.strip().split("\n"):
                    parts = line.strip().split(",")
                    if len(parts) >= 3 and parts[1].strip():
                        vram = int(parts[1]) if parts[1].strip().isdigit() else None
                        return parts[2].strip(), vram
        except Exception:
            pass

    elif system == "Linux":
        # Try nvidia-smi
        try:
            result = subprocess.run(
                ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0:
                line = result.stdout.strip().split("\n")[0]
                parts = line.split(",")
                if len(parts) >= 2:
                    name = parts[0].strip()
                    vram_mb = float(parts[1].strip())
                    return name, int(vram_mb * 1024 * 1024)
        except Exception:
            pass

    return None, None


def _parse_vram_string(s: str) -> int | None:
    """Parse strings like '16 GB', '8192 MB' to bytes."""
    if not s:
        return None
    s = s.strip().lower()
    try:
        if "gb" in s:
            return int(float(s.replace("gb", "").strip()) * 1024 * 1024 * 1024)
        if "mb" in s:
            return int(float(s.replace("mb", "").strip()) * 1024 * 1024)
    except ValueError:
        pass
    return None


def _measure_disk_speed(test_size_mb: int = 256) -> tuple[str, float]:
    """Sequential read benchmark. Returns (disk_type_guess, read_mbps)."""
    test_bytes = test_size_mb * 1024 * 1024

    try:
        with tempfile.NamedTemporaryFile(delete=False) as f:
            tmp_path = f.name
            # Write test data
            chunk = b"\x00" * (1024 * 1024)  # 1MB
            for _ in range(test_size_mb):
                f.write(chunk)
            f.flush()
            os.fsync(f.fileno())

        # Clear OS cache if possible
        try:
            if platform.system() == "Darwin":
                subprocess.run(["purge"], capture_output=True, timeout=5)
        except Exception:
            pass

        # Read benchmark
        start = time.perf_counter()
        with open(tmp_path, "rb") as f:
            while f.read(1024 * 1024):
                pass
        elapsed = time.perf_counter() - start

        os.unlink(tmp_path)

        mbps = (test_bytes / (1024 * 1024)) / max(elapsed, 0.001)

        # Guess disk type
        if mbps > 1500:
            dtype = "nvme"
        elif mbps > 300:
            dtype = "sata_ssd"
        else:
            dtype = "hdd"

        return dtype, round(mbps, 1)

    except Exception:
        return "unknown", 0.0


def _compute_fingerprint(gpu: str | None, ram: int, cpu: str, disk_type: str) -> str:
    """Deterministic fingerprint for this hardware config."""
    parts = f"{gpu or 'none'}|{ram}|{cpu}|{disk_type}"
    return hashlib.sha256(parts.encode()).hexdigest()[:16]


def scan_hardware(quick: bool = False) -> HardwareInfo:
    """Full hardware scan. Set quick=True to skip disk benchmark."""
    gpu_name, vram_bytes = _detect_gpu()
    ram_bytes = psutil.virtual_memory().total
    cpu_name = platform.processor() or "Unknown CPU"
    cpu_cores = psutil.cpu_count(logical=False) or psutil.cpu_count() or 1

    if quick:
        disk_type, disk_mbps = "unknown", 0.0
    else:
        disk_type, disk_mbps = _measure_disk_speed()

    fingerprint = _compute_fingerprint(gpu_name, ram_bytes, cpu_name, disk_type)

    return HardwareInfo(
        gpu_name=gpu_name,
        vram_bytes=vram_bytes,
        ram_bytes=ram_bytes,
        cpu_name=cpu_name,
        cpu_cores=cpu_cores,
        disk_type=disk_type,
        disk_read_mbps=disk_mbps,
        hw_fingerprint=fingerprint,
    )


def compute_speed_rating(tok_per_s: float, ttft_ms: int) -> tuple[str, str]:
    """Returns (rating, explanation) in plain English.

    | Rating  | tok/s  | TTFT    |
    |---------|--------|---------|
    | Fast    | ≥10    | ≤2500ms |
    | OK      | ≥4     | ≤5000ms |
    | Slow    | ≥1     | ≤8000ms |
    | Painful | <1     | >8000ms |
    """
    if tok_per_s >= 10 and ttft_ms <= 2500:
        return "fast", "Responsive — feels like a normal conversation."
    elif tok_per_s >= 4 and ttft_ms <= 5000:
        return "ok", "Usable — you'll notice slight pauses."
    elif tok_per_s >= 1 and ttft_ms <= 8000:
        return "slow", "Noticeable lag — consider a smaller model for snappier replies."
    else:
        return "painful", "Very slow — we strongly recommend a smaller model for your hardware."
