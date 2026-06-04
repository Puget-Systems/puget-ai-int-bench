#!/bin/bash
# Driver script to automate running the AMD GPU (ROCm) benchmarks.
# Orchestrated locally using genai-perf, executing remotely on AMD inference target.
# Following conventions and models from the B70 review article, adapted for 2x GPUs.

set -euo pipefail

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"
CONCURRENCY="1,4,8"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50

echo "=========================================================="
echo "Starting AMD ROCm Multi-GPU Benchmark Suite"
echo "Target Host: $HOST"
echo "Repository:  $REPO"
echo "=========================================================="
echo ""

# 1. Qwen 2.5 3B Instruct (TP=1)
echo "=== Model 1/9: Qwen 2.5 3B Instruct (TP=1) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 12 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 2. Qwen 2.5 3B Instruct (TP=2)
echo "=== Model 2/9: Qwen 2.5 3B Instruct (TP=2) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model Qwen/Qwen2.5-3B-Instruct \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 3. Qwen 3 8B Dense (TP=1)
echo "=== Model 3/9: Qwen 3 8B Dense (TP=1) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 10 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 4. Llama 3.1 8B Instruct (TP=1)
echo "=== Model 4/9: Llama 3.1 8B Instruct (TP=1) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 13 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 5. Llama 3.1 8B Instruct (TP=2)
echo "=== Model 5/9: Llama 3.1 8B Instruct (TP=2) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model meta-llama/Llama-3.1-8B-Instruct \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 6. DeepSeek R1 Distill Llama 8B (TP=1)
echo "=== Model 6/9: DeepSeek R1 Distill Llama 8B (TP=1) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 14 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 7. DeepSeek R1 Distill Llama 8B (TP=2)
echo "=== Model 7/9: DeepSeek R1 Distill Llama 8B (TP=2) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model deepseek-ai/DeepSeek-R1-Distill-Llama-8B \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 8. Qwen 3.6 27B Dense unquantized (TP=2)
echo "=== Model 8/9: Qwen 3.6 27B Dense (TP=2) ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 11 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 9. ComfyUI Z-Image Turbo
echo "=== Pack 9/9: ComfyUI Z-Image Turbo ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack comfy_ui \
    --model z_image_turbo \
    --comfy-iterations 10 \
    --skip-checksum
echo ""

echo "=========================================================="
echo "AMD ROCm GPU Benchmarks Complete!"
echo "=========================================================="
