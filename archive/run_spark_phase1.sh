#!/bin/bash
# DGX Spark (GB10) — Phase 1: article-matched FP16 set, run as custom HF IDs.
# Mirrors the Blackwell/B70 article model set + per-model params for apples-to-apples
# comparison. Concurrency 1,4,8,16,32. Each model is an independent invocation so one
# failure does not abort the rest. Runs from the Mac in remote mode (--host).
set -u
HOST="puget@172.19.168.179"
CONC="1,4,8,16,32"
COMMON=(--host "$HOST" --pack team_llm --concurrency "$CONC" --skip-checksum)
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/_spark_phase1_logs"
mkdir -p "$LOG_DIR"

run() {
    local tag="$1"; shift
    echo "===================================================================="
    echo "  Phase1 model: $tag   ($(date '+%F %T'))"
    echo "===================================================================="
    ./run_benchmarks.sh "${COMMON[@]}" "$@" 2>&1 | tee "$LOG_DIR/${tag}.log"
    echo "  >> $tag exit: ${PIPESTATUS[0]}  ($(date '+%F %T'))"
}

# 1) Qwen2.5-3B-Instruct — in500 out500, 50 prompts, 30s window
run qwen2.5-3b   --model Qwen/Qwen2.5-3B-Instruct \
    --input-tokens 500 --output-tokens 500 --num-prompts 50 --measurement-interval 30000

# 2) Llama-3.1-8B-Instruct (gated; HF token present) — in500 out500, 50 prompts, 30s
run llama3.1-8b  --model meta-llama/Llama-3.1-8B-Instruct \
    --input-tokens 500 --output-tokens 500 --num-prompts 50 --measurement-interval 30000

# 3) DeepSeek-R1-Distill-Llama-8B — article used 30s window (force it; harness would auto-widen)
run deepseek-r1-distill-8b --model deepseek-ai/DeepSeek-R1-Distill-Llama-8B \
    --input-tokens 500 --output-tokens 500 --num-prompts 50 --measurement-interval 30000

# 4) Qwen3-8B — thinking model: 120s window, out500, 20 prompts
run qwen3-8b     --model Qwen/Qwen3-8B \
    --input-tokens 500 --output-tokens 500 --num-prompts 20 --measurement-interval 120000

# 5) Qwen3.6-27B — FP16 ~54GB: out200, 120s window, 10 prompts
run qwen3.6-27b  --model Qwen/Qwen3.6-27B \
    --input-tokens 500 --output-tokens 200 --num-prompts 10 --measurement-interval 120000

echo "ALL PHASE 1 MODELS DONE ($(date '+%F %T'))"
