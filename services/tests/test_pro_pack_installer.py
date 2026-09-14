# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Pro pack installer: tar safety, idempotency, and progress events.

Tests the parts of :mod:`common.pro_pack_installer` that we can run
locally without actually downloading a multi-GB tarball:

* ``_safe_extract`` rejects path-traversal, absolute paths, and
  symlink-escape vectors. This is the security boundary that protects
  the user's home directory from a malicious release asset.
* The async ``install_pro_pack`` generator yields a ``done`` event when
  the pack is already installed (idempotency).
"""

from __future__ import annotations

import asyncio
import io
import tarfile
from pathlib import Path

import pytest

from common.pro_pack_installer import (
    ProPackInstallError,
    _safe_extract,
)


def _make_tar(tmp_path: Path, members: list[tarfile.TarInfo]) -> Path:
    """Build a tar containing the given pre-prepared members."""
    tar_path = tmp_path / "test.tar"
    with tarfile.open(tar_path, "w") as tf:
        for m in members:
            # Members with a non-zero size need real bytes attached.
            if m.isreg() and m.size > 0:
                tf.addfile(m, io.BytesIO(b"\x00" * m.size))
            else:
                tf.addfile(m)
    return tar_path


def test_safe_extract_rejects_path_traversal(tmp_path: Path) -> None:
    info = tarfile.TarInfo(name="../escape.txt")
    info.size = 4
    info.type = tarfile.REGTYPE
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    with pytest.raises(ProPackInstallError, match="suspicious"):
        _safe_extract(tar_path, dest)


def test_safe_extract_rejects_absolute_paths(tmp_path: Path) -> None:
    info = tarfile.TarInfo(name="/etc/passwd")
    info.size = 4
    info.type = tarfile.REGTYPE
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    with pytest.raises(ProPackInstallError, match="absolute"):
        _safe_extract(tar_path, dest)


def test_safe_extract_rejects_symlink_escape(tmp_path: Path) -> None:
    info = tarfile.TarInfo(name="evil-link")
    info.type = tarfile.SYMTYPE
    info.linkname = "../../etc/passwd"
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    with pytest.raises(ProPackInstallError, match="escapes"):
        _safe_extract(tar_path, dest)


def test_safe_extract_rejects_absolute_symlink_target(tmp_path: Path) -> None:
    info = tarfile.TarInfo(name="evil-link")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    with pytest.raises(ProPackInstallError, match="absolute link target"):
        _safe_extract(tar_path, dest)


def test_safe_extract_rejects_device_entries(tmp_path: Path) -> None:
    info = tarfile.TarInfo(name="bad-fifo")
    info.type = tarfile.FIFOTYPE
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    with pytest.raises(ProPackInstallError, match="device entry"):
        _safe_extract(tar_path, dest)


def test_safe_extract_accepts_well_formed_tar(tmp_path: Path) -> None:
    """A clean tar with one regular file under ``dest/`` should extract cleanly."""
    info = tarfile.TarInfo(name="pro-env/VERSION")
    info.size = 5
    info.type = tarfile.REGTYPE
    tar_path = _make_tar(tmp_path, [info])

    dest = tmp_path / "dest"
    dest.mkdir()
    count = _safe_extract(tar_path, dest)
    assert count == 1
    assert (dest / "pro-env" / "VERSION").is_file()


def test_install_pro_pack_short_circuits_when_already_installed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """If the right version is on disk, installer must yield ``done`` instantly."""
    from common import pro_pack
    from common.pro_pack_installer import install_pro_pack

    pro_env = tmp_path / "pro-env"
    pro_env.mkdir()
    (pro_env / "bin").mkdir()
    py = pro_env / "bin" / "python"
    py.touch()
    version_file = pro_env / "VERSION"
    version_file.write_text("0.0.0\n")

    # Re-route the module-level constants so the installer sees our temp dir.
    monkeypatch.setattr(pro_pack, "PRO_ENV_DIR", pro_env)
    monkeypatch.setattr(pro_pack, "PRO_VERSION_FILE", version_file)

    async def go() -> None:
        events = []
        async for evt in install_pro_pack(
            archive_url="https://example.com/never-fetched.tar.zst",
            expected_sha256="0" * 64,
            expected_version="0.0.0",
        ):
            events.append(evt)

        assert len(events) == 1
        assert events[0].stage == "done"
        assert events[0].extra.get("already_installed") is True

    asyncio.run(go())
