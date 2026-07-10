#!/bin/bash
# DGX Spark (GB10) — recovery/validation batch for the run-all soft failures.
# Re-runs the recoverable Phase 2 failures through the PATCHED bench scripts to both
# validate the fixes and complete the dataset. Uses the stock (GitHub) app-pack so this
# mirrors exactly what a real user gets + our bench-side fixes:
#   - run_genai_perf.sh: reasoning classifier (auto-120s) + auto-retry net + unsloth tokenizers
#   - run_comfyui_bench.py: prompt_id CSV fix
# Each model is independent (no set -e) so one failure can't abort the rest.
set -u
HOST="puget@172.19.168.179"
COMMON=(--host "$HOST" --skip-checksum)
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/_spark_recovery_logs"
mkdir -p "$LOG_DIR"

run() {
    local tag="$1"; shift
    echo "===================================================================="
    echo "  Recovery: $tag   ($(date '+%F %T'))"
    echo "===================================================================="
    ./run_benchmarks.sh "${COMMON[@]}" "$@" 2>&1 | tee "$LOG_DIR/${tag}.log"
    echo "  >> $tag exit: ${PIPESTATUS[0]}  ($(date '+%F %T'))"
}

# ── Ollama reasoning-window failures → classifier floors to 120s (no flag needed) ──
run ollama-qwen3-32b      --pack personal_llm --model qwen3:32b
run ollama-deepseek-70b   --pack personal_llm --model deepseek-r1:70b
run ollama-nemotron-super --pack personal_llm --model nemotron-3-super
# gemma4 is NOT in the reasoning table → exercises the auto-retry safety net (30s→240s)
run ollama-gemma4-31b     --pack personal_llm --model gemma4:31b
# llama4:scout → ungated unsloth tokenizer (was gated-403)
run ollama-llama4-scout   --pack personal_llm --model llama4:scout

# ── ComfyUI → prompt_id CSV fix ──────────────────────────────────────────────
run comfy-z-image  --pack comfy_ui --model z_image_turbo
run comfy-flux2    --pack comfy_ui --model flux2_dev

echo "ALL RECOVERY DONE ($(date '+%F %T'))"
