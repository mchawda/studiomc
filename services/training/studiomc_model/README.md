# Studiomc 4B pipeline

Specialized 4B for grounded QA, mandatory `[Source N]` citations, refuse-when-empty, and LRE tool JSON.

**Base:** `Qwen/Qwen3-4B-Instruct-2507` (catalog GGUF: `bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF` / `Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf`).

Run from `services/` with the Pro pack interpreter for `train` / `export`. `generate` and `dry-run` need no GPU and no Unsloth.

```bash
# 1. Write SFT JSONL (fixtures + optional eval harness export)
python -m training.studiomc_model generate --out /tmp/studiomc-4b-sft.jsonl
python -m training.studiomc_model generate --out /tmp/studiomc-4b-sft.jsonl --from-eval eval/data/gold.jsonl

# 2. Count rows / confirm Unsloth is optional
python -m training.studiomc_model dry-run

# 3. Train (Pro pack + `pip install unsloth`). Skip on machines without a GPU.
python -m training.studiomc_model train \
  --data /tmp/studiomc-4b-sft.jsonl \
  --output ~/Library/Application\ Support/Studiomc/adapters/studiomc-4b \
  --max-steps 80 \
  --export-gguf ~/Library/Application\ Support/Studiomc/models/studiomc-4b/studiomc-4b-q4_k_m.gguf

# Optional QAT (int8-int4) for later ExecuTorch / CoreML phone builds
python -m training.studiomc_model train --data /tmp/studiomc-4b-sft.jsonl --output /tmp/s4b --qat

# 4. Export only
python -m training.studiomc_model export \
  --adapter-dir ~/Library/Application\ Support/Studiomc/adapters/studiomc-4b/adapter \
  --gguf ~/Library/Application\ Support/Studiomc/models/studiomc-4b/studiomc-4b-q4_k_m.gguf
```

Repo wrapper (adds `services/` to `sys.path`):

```bash
python scripts/train/train_studiomc_4b.py dry-run
```

Desktop Autopilot id: `studiomc-4b`. ExecuTorch / CoreML are follow-ups; this pipeline ships GGUF.
