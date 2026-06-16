#!/bin/bash
# Driver script: B70 SINGLE-GPU (TP=1) baseline suite for the B70 article.
# Re-runs the article's single-GPU baseline models WITH --streaming so the
# detailed per-model tables get REAL TTFT/ITL (the original article faked TTFT
# as the latency value). Uniform methodology matching the multi-GPU re-run:
# 500 in / 500 out, concurrency 1,4,8, FP16, one B70 card (TP=1).
#
# XPU vLLM cannot serve bfloat16 -> --dtype float16. Ungated HF mirrors are used
# (no HF token on host): unsloth/* for Llama + Gemma, public repos otherwise.

set -uo pipefail   # NOT -e: one model failing must not abort the whole suite

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"
CONCURRENCY="1,4,8"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
DTYPE="float16"
MAX_MODEL_LEN=32768
MEAS_INTERVAL=60000   # 8B/9B @ conc=1 can run ~15-21s; 60s window is safe

# Article single-GPU baseline set (FP16), smallest -> largest.
MODELS=(
    "Qwen/Qwen2.5-3B-Instruct"
    "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
    "unsloth/meta-llama-3.1-8b-instruct"
    "unsloth/gemma-2-9b-it"
)

echo "=========================================================="
echo "B70 SINGLE-GPU (TP=1) Baseline Suite — Article Re-run"
echo "Target Host: $HOST"
echo "dtype:       $DTYPE   max-model-len: $MAX_MODEL_LEN"
echo "Streaming:   ENABLED (real TTFT + ITL)   Power: sampled per model"
echo "=========================================================="
echo ""

i=0
total=${#MODELS[@]}
for MODEL in "${MODELS[@]}"; do
    i=$((i + 1))
    echo "=== Model ${i}/${total}: ${MODEL} (TP=1) ==="
    ./run_benchmarks.sh \
        --host "$HOST" \
        --repo "$REPO" \
        --pack team_llm \
        --model "$MODEL" \
        --gpu-count 1 \
        --concurrency "$CONCURRENCY" \
        --input-tokens "$INPUT_TOKENS" \
        --output-tokens "$OUTPUT_TOKENS" \
        --num-prompts "$NUM_PROMPTS" \
        --dtype "$DTYPE" \
        --max-model-len "$MAX_MODEL_LEN" \
        --measurement-interval "$MEAS_INTERVAL" \
        --skip-checksum
    echo ""
done

echo "=========================================================="
echo "Single-GPU Baseline Suite Complete!"
echo "=========================================================="
