#!/bin/bash
# Driver script: B70 multi-GPU (TP=4) benchmark suite for the B70 article.
# Orchestrated locally via the shared harness; genai-perf runs ON the remote
# B70 host (native net) with --streaming, and GPU power is sampled per model.
#
# Reproduces the article's FP16 tables, now WITH measured TTFT/ITL + power.
# Models use explicit HF IDs (custom path) so the harness serves them on the
# intel/llm-scaler-vllm image — matching the article's multi-GPU setup.
#
# XPU vLLM cannot serve bfloat16, so all models are forced to --dtype float16
# (the article's choice). --max-model-len 32768 caps the KV cache.
# Intel runtime env (spawn / CCL_TOPO_P2P_ACCESS=0 / /dev/dri / TP=GPU_COUNT)
# comes from the app-pack intel-b70 packs/team_llm/docker-compose.yml.

set -uo pipefail   # NOT -e: one model failing must not abort the whole suite

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"
CONCURRENCY="1,4,8"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
DTYPE="float16"
MAX_MODEL_LEN=32768

# Article model set (FP16, cached on host), smallest → largest so the fast
# models validate the pipeline before the long 27B/35B runs.
MODELS=(
    "Qwen/Qwen2.5-3B-Instruct"
    "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
    "unsloth/meta-llama-3.1-8b-instruct"
    "Qwen/Qwen3.6-27B"
    "Qwen/Qwen3.6-35B-A3B"
)

echo "=========================================================="
echo "B70 Multi-GPU (TP=4) Benchmark Suite — Article Reproduction"
echo "Target Host: $HOST"
echo "Repository:  $REPO"
echo "dtype:       $DTYPE   max-model-len: $MAX_MODEL_LEN"
echo "Streaming:   ENABLED (real TTFT + ITL)   Power: sampled per model"
echo "=========================================================="
echo ""

i=0
total=${#MODELS[@]}
for MODEL in "${MODELS[@]}"; do
    i=$((i + 1))
    echo "=== Model ${i}/${total}: ${MODEL} (TP=4) ==="
    ./run_benchmarks.sh \
        --host "$HOST" \
        --repo "$REPO" \
        --pack team_llm \
        --model "$MODEL" \
        --concurrency "$CONCURRENCY" \
        --input-tokens "$INPUT_TOKENS" \
        --output-tokens "$OUTPUT_TOKENS" \
        --num-prompts "$NUM_PROMPTS" \
        --dtype "$DTYPE" \
        --max-model-len "$MAX_MODEL_LEN" \
        --skip-checksum
    echo ""
done

echo "=========================================================="
echo "Multi-GPU Benchmarks Complete!"
echo "=========================================================="
