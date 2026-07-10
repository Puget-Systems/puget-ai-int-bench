#!/bin/bash
# DGX Spark (GB10) — Phase 1b: re-runs to complete the article-matched set.
#  1) Llama-3.1-8B via ungated unsloth mirror (official meta-llama repo 403s this account)
#  2) DeepSeek-R1-Distill-8B at 120s window (reasoning model — 30s couldn't stabilize at conc>=16
#     on the Spark's lower-bandwidth unified memory)
set -u
HOST="puget@172.19.168.179"
CONC="1,4,8,16,32"
COMMON=(--host "$HOST" --pack team_llm --concurrency "$CONC" --skip-checksum)
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results/_spark_phase1_logs"
mkdir -p "$LOG_DIR"

run() {
    local tag="$1"; shift
    echo "===================================================================="
    echo "  Phase1b model: $tag   ($(date '+%F %T'))"
    echo "===================================================================="
    ./run_benchmarks.sh "${COMMON[@]}" "$@" 2>&1 | tee "$LOG_DIR/${tag}.log"
    echo "  >> $tag exit: ${PIPESTATUS[0]}  ($(date '+%F %T'))"
}

# 1) Llama-3.1-8B (ungated mirror) — in500 out500, 50 prompts, 30s window
run llama3.1-8b-unsloth --model unsloth/Meta-Llama-3.1-8B-Instruct \
    --input-tokens 500 --output-tokens 500 --num-prompts 50 --measurement-interval 30000

# 2) DeepSeek-R1-Distill-8B — reasoning: 120s window, out500, 50 prompts
run deepseek-r1-distill-8b-120s --model deepseek-ai/DeepSeek-R1-Distill-Llama-8B \
    --input-tokens 500 --output-tokens 500 --num-prompts 50 --measurement-interval 120000

echo "ALL PHASE 1b DONE ($(date '+%F %T'))"
