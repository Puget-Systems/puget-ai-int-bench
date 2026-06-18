#!/bin/bash
# Driver script: single-GPU Qwen3-8B (TP=1) on one B70, for the article's
# single-GPU table. Qwen3 is a thinking model — its reasoning phase emits many
# internal tokens before visible output, so a 30s measurement window can show
# 0 tok/s at concurrency=1. We use a 120s window and fewer prompts.
#
# Explicit HF ID (custom path) → intel/llm-scaler-vllm image. --gpu-count 1
# forces TP=1 (single card). XPU vLLM needs --dtype float16 (no bfloat16).

set -uo pipefail

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"

echo "==========================================================="
echo "Qwen3-8B Single-GPU (TP=1) — Extended Measurement Window"
echo "Target Host: $HOST"
echo "  • gpu-count:            1 (single B70, TP=1)"
echo "  • dtype:                float16"
echo "  • measurement-interval: 120000ms (thinking model)"
echo "  • num-prompts:          20    concurrency: 1,4,8"
echo "==========================================================="
echo ""

./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model Qwen/Qwen3-8B \
    --gpu-count 1 \
    --concurrency "1,4,8" \
    --input-tokens 500 \
    --output-tokens 500 \
    --num-prompts 20 \
    --dtype float16 \
    --max-model-len 32768 \
    --measurement-interval 120000 \
    --skip-checksum

echo ""
echo "==========================================================="
echo "Qwen3-8B Single-GPU Benchmark Complete!"
echo "==========================================================="
