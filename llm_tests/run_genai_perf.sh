#!/bin/bash

# Puget Systems AI App Packs - genai-perf Benchmarking Script
# This script uses the NVIDIA Triton SDK container to run genai-perf against OpenAI-compatible endpoints.
# It can be run directly on the inference server (by the orchestrator or standalone).

set -e

# Default configurations
ENDPOINT="ollama" # or "vllm"
CONCURRENCY_LIST="1"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
MODEL_NAME=""
RESULTS_DIR=""
URL=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --endpoint) ENDPOINT="$2"; shift ;;
        --model) MODEL_NAME="$2"; shift ;;
        --url) URL="$2"; shift ;;
        --concurrency) CONCURRENCY_LIST="$2"; shift ;;
        --input-tokens) INPUT_TOKENS="$2"; shift ;;
        --output-tokens) OUTPUT_TOKENS="$2"; shift ;;
        --num-prompts) NUM_PROMPTS="$2"; shift ;;
        --results-dir) RESULTS_DIR="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Configure target based on endpoint type
if [ "$ENDPOINT" == "ollama" ]; then
    # Use provided URL or default to localhost
    URL="${URL:-http://localhost:11434}"
    if [ -z "$MODEL_NAME" ]; then
        # Try to discover model (works when running on same machine as Ollama)
        MODEL_NAME=$(curl -s --connect-timeout 2 "${URL}/api/tags" 2>/dev/null | grep -o '"name":"[^"]*' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ -z "$MODEL_NAME" ]; then
            MODEL_NAME="llama3" # Fallback
        fi
    fi
    echo "Configuring for Personal LLM (Ollama) at $URL"
elif [ "$ENDPOINT" == "vllm" ]; then
    # Use provided URL or default to localhost
    URL="${URL:-http://localhost:8000}"
    if [ -z "$MODEL_NAME" ]; then
        # Try to discover model (works when running on same machine as vLLM)
        MODEL_NAME=$(curl -s --connect-timeout 2 "${URL}/v1/models" 2>/dev/null | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ -z "$MODEL_NAME" ]; then
            MODEL_NAME="Qwen/Qwen1.5-7B-Chat" # Fallback
        fi
    fi
    echo "Configuring for Team LLM (vLLM) at $URL"
else
    echo "Error: Invalid endpoint. Use 'ollama' or 'vllm'."
    exit 1
fi

# Set up results directory
if [ -z "$RESULTS_DIR" ]; then
    RESULTS_DIR="results/genai_perf_${ENDPOINT}_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$RESULTS_DIR"

echo "=============================================="
echo "Starting genai-perf benchmark"
echo "Target: $ENDPOINT ($URL)"
echo "Model: $MODEL_NAME"
echo "Input Tokens: $INPUT_TOKENS | Output Tokens: $OUTPUT_TOKENS"
echo "Concurrency Levels: $CONCURRENCY_LIST"
echo "Results: $RESULTS_DIR"
echo "=============================================="

# Loop through concurrency levels
IFS=',' read -ra CONC_ARRAY <<< "$CONCURRENCY_LIST"
for CONC in "${CONC_ARRAY[@]}"; do
    echo "Running benchmark with Concurrency: $CONC..."
    
    # We use the Triton SDK container which includes genai-perf
    # --net=host allows the container to reach localhost endpoints on the host machine
    docker run --rm --net=host \
        -e NVIDIA_DISABLE_REQUIRE=1 \
        -v "$(pwd)/$RESULTS_DIR:/work/results" \
        -w /work \
        nvcr.io/nvidia/tritonserver:24.08-py3-sdk \
        genai-perf profile \
        -m "$MODEL_NAME" \
        --endpoint-type chat \
        --service-kind openai \
        -u "$URL" \
        --num-prompts "$NUM_PROMPTS" \
        --synthetic-input-tokens-mean "$INPUT_TOKENS" \
        --output-tokens-mean "$OUTPUT_TOKENS" \
        --concurrency "$CONC" \
        --artifact-dir "results/concurrency_${CONC}" \
        -- \
        --measurement-interval 120000 \
        --stability-percentage 999
        
    echo "Finished Concurrency $CONC"
done

echo "=============================================="
echo "genai-perf benchmarks completed."
echo "Results saved to $RESULTS_DIR"
echo "=============================================="