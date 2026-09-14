#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_pro_pack.sh — Build the optional Studiomc Pro pack tarball
#
# Produces a relocatable virtual environment containing the heavy ML
# stack (PyTorch, transformers, peft, accelerate, sentence-transformers,
# and on Apple Silicon the MLX runtime). Users download this tarball on
# first use of the Training screen; the supervisor extracts it into
# ``$STUDIOMC_HOME/pro-env/`` and spawns trainer subprocesses with its
# Python interpreter.
#
# Output:
#   dist/pro-pack/studiomc-pro-<version>-<platform>.tar.zst
#   dist/pro-pack/studiomc-pro-<version>-<platform>.sha256
#   dist/pro-pack/studiomc-pro-<version>-<platform>.manifest.json
#
# Usage:
#   bash scripts/build/build_pro_pack.sh
#   PRO_PACK_VERSION=0.2.0 PYTHON_BIN=python3.11 bash scripts/build/build_pro_pack.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"

PRO_PACK_VERSION="${PRO_PACK_VERSION:-0.1.0}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"

# Where the venv is built (must be writable, plenty of free disk).
WORK_DIR="${PRO_PACK_WORK_DIR:-$PROJECT_ROOT/dist/pro-pack/build}"
OUT_DIR="$PROJECT_ROOT/dist/pro-pack"
ENV_DIR="$WORK_DIR/pro-env"

# ── Resolve platform tag (must match common/pro_pack.py expectations) ──

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S/$UNAME_M" in
    Darwin/arm64)   PLATFORM="macos-arm64" ;;
    Darwin/x86_64)  PLATFORM="macos-x64"   ;;
    Linux/x86_64)   PLATFORM="linux-x64"   ;;
    Linux/aarch64)  PLATFORM="linux-arm64" ;;
    *) echo "✗ Unsupported platform: $UNAME_S/$UNAME_M" ; exit 1 ;;
esac

# Pro pack pinned dependency versions. Bumping any of these requires
# bumping PRO_PACK_VERSION too — the supervisor refuses old packs.
TORCH_SPEC="torch>=2.2.0,<3.0"
SAFETENSORS_SPEC="safetensors>=0.4.0"
TRANSFORMERS_SPEC="transformers>=4.46.0"
ACCELERATE_SPEC="accelerate>=1.2.0"
PEFT_SPEC="peft>=0.13.0"
SENTENCEPIECE_SPEC="sentencepiece>=0.2.0"
SBERT_SPEC="sentence-transformers>=3.3.0"
TIKTOKEN_SPEC="tiktoken>=0.8.0"
HUB_SPEC="huggingface-hub>=0.27.0"

# MLX is Apple Silicon only and lives behind a separate gate.
MLX_SPEC="mlx>=0.22.0"
MLXLM_SPEC="mlx-lm>=0.22.0"

ARCHIVE_BASE="studiomc-pro-${PRO_PACK_VERSION}-${PLATFORM}"
ARCHIVE_PATH="$OUT_DIR/$ARCHIVE_BASE.tar.zst"
SHA_PATH="$OUT_DIR/$ARCHIVE_BASE.sha256"
MANIFEST_PATH="$OUT_DIR/$ARCHIVE_BASE.manifest.json"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Build Pro pack                          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "  Version:  $PRO_PACK_VERSION"
echo "  Platform: $PLATFORM"
echo "  Python:   $PYTHON_BIN ($($PYTHON_BIN --version 2>&1))"
echo "  Output:   $ARCHIVE_PATH"
echo ""

# ── 1. Reset workspace ────────────────────────────────────────────────

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# ── 2. Build the venv ─────────────────────────────────────────────────

echo "→ Creating venv …"
"$PYTHON_BIN" -m venv "$ENV_DIR"
# shellcheck disable=SC1091
source "$ENV_DIR/bin/activate"

python -m pip install --quiet --upgrade pip wheel setuptools

echo "→ Installing core ML stack …"
python -m pip install --quiet \
    "$TORCH_SPEC" \
    "$SAFETENSORS_SPEC" \
    "$TRANSFORMERS_SPEC" \
    "$ACCELERATE_SPEC" \
    "$PEFT_SPEC" \
    "$SENTENCEPIECE_SPEC" \
    "$SBERT_SPEC" \
    "$TIKTOKEN_SPEC" \
    "$HUB_SPEC"

if [ "$PLATFORM" = "macos-arm64" ]; then
    echo "→ Installing MLX (Apple Silicon) …"
    python -m pip install --quiet "$MLX_SPEC" "$MLXLM_SPEC"
fi

# Capture installed packages for the manifest NOW, while the venv still
# points at the build interpreter. Once pyvenv.cfg is rewritten below
# (``home = /usr/bin``) the venv python resolves its stdlib against
# /usr/lib/python3.x, which on the Linux runner does not exist for this
# interpreter; ``pip freeze`` then dies with
# "No module named '_posixsubprocess'".
python -m pip freeze --local > "$ENV_DIR/freeze.txt"

deactivate

# ── 3. Make the venv relocatable ──────────────────────────────────────
#
# The default venv writes absolute paths into bin/* shebangs and
# pyvenv.cfg. We rewrite them to ``/usr/bin/env python3`` so the
# extracted pack works no matter where the user installs it.

echo "→ Patching shebangs for relocatability …"
SHEBANG="#!/usr/bin/env python3"
find "$ENV_DIR/bin" -type f -print0 | while IFS= read -r -d '' f; do
    if head -c 2 "$f" 2>/dev/null | grep -q '^#!'; then
        # Replace any python interpreter shebang with the env-based one
        sed -i.bak "1s|^#!.*python.*|$SHEBANG|" "$f" 2>/dev/null || true
        rm -f "$f.bak"
    fi
done

# pyvenv.cfg holds the absolute path to the build python; clear it.
if [ -f "$ENV_DIR/pyvenv.cfg" ]; then
    sed -i.bak \
        -e 's|^home = .*|home = /usr/bin|' \
        -e 's|^executable = .*|executable = /usr/bin/python3|' \
        -e 's|^command = .*|command = relocated|' \
        "$ENV_DIR/pyvenv.cfg" 2>/dev/null || true
    rm -f "$ENV_DIR/pyvenv.cfg.bak"
fi

# ── 4. Strip dead weight ──────────────────────────────────────────────

echo "→ Stripping caches and tests …"
find "$ENV_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$ENV_DIR" -type d \( -name "tests" -o -name "test" \) -prune -exec rm -rf {} + 2>/dev/null || true
find "$ENV_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
find "$ENV_DIR" -type f -name "*.pyo" -delete 2>/dev/null || true

VENV_SIZE="$(du -sh "$ENV_DIR" | cut -f1)"
echo "  venv size: $VENV_SIZE"

# ── 5. Stamp VERSION + manifest into the venv root ────────────────────

echo "$PRO_PACK_VERSION" > "$ENV_DIR/VERSION"
date -u "+%Y-%m-%dT%H:%M:%SZ" > "$ENV_DIR/INSTALLED_AT"
# freeze.txt was written in step 2 (before the venv was relocated).

# ── 6. Tar + zstd ─────────────────────────────────────────────────────

echo "→ Creating tarball …"
if ! command -v zstd >/dev/null 2>&1; then
    echo "✗ zstd not found — install via: brew install zstd / apt install zstd" >&2
    exit 1
fi

# Tar the directory CONTENTS, not the parent dir, so users extract into
# pro-env/ directly. Use --no-xattrs so macOS metadata doesn't bloat it.
TAR_FLAGS=""
if tar --help 2>&1 | grep -q -- '--no-xattrs'; then
    TAR_FLAGS="--no-xattrs"
fi

(
    cd "$WORK_DIR"
    tar $TAR_FLAGS -cf - pro-env | zstd -19 -T0 -o "$ARCHIVE_PATH"
)

# ── 7. SHA256 ─────────────────────────────────────────────────────────

echo "→ Computing sha256 …"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}' > "$SHA_PATH"
else
    sha256sum "$ARCHIVE_PATH" | awk '{print $1}' > "$SHA_PATH"
fi
SHA256="$(cat "$SHA_PATH")"

# ── 8. Manifest JSON ──────────────────────────────────────────────────

ARCHIVE_BYTES="$(wc -c < "$ARCHIVE_PATH" | tr -d ' ')"

echo "→ Writing manifest …"
python3 - <<PY > "$MANIFEST_PATH"
import json, pathlib

freeze_txt = pathlib.Path("$ENV_DIR/freeze.txt").read_text().strip().splitlines()
packages = []
for line in freeze_txt:
    if "==" in line:
        name, version = line.split("==", 1)
        packages.append({"name": name.strip(), "version": version.strip()})

manifest = {
    "version": "$PRO_PACK_VERSION",
    "platform": "$PLATFORM",
    "archive": "$ARCHIVE_BASE.tar.zst",
    "archive_bytes": int("$ARCHIVE_BYTES"),
    "sha256": "$SHA256",
    "python": "$($PYTHON_BIN --version 2>&1)".strip(),
    "packages": packages,
}
print(json.dumps(manifest, indent=2))
PY

ARCHIVE_HUMAN="$(du -sh "$ARCHIVE_PATH" | cut -f1)"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ Pro pack built                                   ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Archive:  $ARCHIVE_PATH"
echo "║  Size:     $ARCHIVE_HUMAN"
echo "║  SHA256:   $SHA256"
echo "║  Manifest: $MANIFEST_PATH"
echo "╚══════════════════════════════════════════════════════╝"
