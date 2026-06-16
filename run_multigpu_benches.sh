#!/bin/bash
# Drivers script to automate rerunning the Multi-GPU benchmarks for B70 review.
# Orchestrated locally using genai-perf, executing remotely on B70 inference target.
#
# Assumes PCIe risers are removed, CCL_TOPO_P2P_ACCESS=1 is set in team_llm/docker-compose.yml.

set -euo pipefail

HOST="labs@172.19.28.207"
REPO="/Users/dustmoo/Sites/puget-docker-app-pack"
CONCURRENCY="1,4,8"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50

echo "=========================================================="
echo "Starting Multi-GPU Benchmark Suite (PCIe P2P Direct Enabled)"
echo "Target Host: $HOST"
echo "Repository:  $REPO"
echo "=========================================================="
echo ""

# 1. Qwen 3.6 35B MoE unquantized (Choice 1)
echo "=== Model 1/5: Qwen 3.6 35B MoE unquantized ==="
./run_benchmarks.sh \
    --host "$HOST" \
    --repo "$REPO" \
    --pack team_llm \
    --model 1 \
    --concurrency "$CONCURRENCY" \
    --input-tokens "$INPUT_TOKENS" \
    --output-tokens "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --skip-checksum
echo ""

# 2. Qwen 3.6 27B Dense unquantized (Choice 11)
echo "=== Model 2/5: Qwen 3.6 27B Dense unquantized ==="
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

# 3. Llama 3.1 8B Instruct (Custom)
echo "=== Model 3/5: Llama 3.1 8B Instruct ==="
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

# 4. DeepSeek R1 Distill Llama 8B (Custom)
echo "=== Model 4/5: DeepSeek R1 Distill Llama 8B ==="
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

# 5. Qwen 2.5 3B Instruct (Custom)
echo "=== Model 5/5: Qwen 2.5 3B Instruct ==="
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

echo "=========================================================="
echo "Multi-GPU Benchmarks Complete!"
echo "=========================================================="
