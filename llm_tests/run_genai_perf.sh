#!/bin/bash

# Puget Systems AI App Packs - genai-perf Benchmarking Script
# This script uses the NVIDIA Triton SDK container to run genai-perf against OpenAI-compatible endpoints.
# It can be run directly on the inference server (by the orchestrator or standalone).

set -e

# Default configurations
ENDPOINT="ollama"   # or "vllm"
CONCURRENCY_LIST="1"
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
MODEL_NAME=""
RESULTS_DIR=""
URL=""
CONTEXT_LENGTHS=""  # Comma-separated list of input token sizes (e.g. "4096,32768,131072")
                    # When set, overrides INPUT_TOKENS and runs a separate pass per size.

# Triton SDK image — update this to the latest available on nvcr.io
TRITON_SDK_IMAGE="nvcr.io/nvidia/tritonserver:25.04-py3-sdk"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --endpoint)        ENDPOINT="$2";        shift ;;
        --model)           MODEL_NAME="$2";       shift ;;
        --url)             URL="$2";              shift ;;
        --concurrency)     CONCURRENCY_LIST="$2"; shift ;;
        --input-tokens)    INPUT_TOKENS="$2";     shift ;;
        --output-tokens)   OUTPUT_TOKENS="$2";    shift ;;
        --num-prompts)     NUM_PROMPTS="$2";      shift ;;
        --results-dir)     RESULTS_DIR="$2";      shift ;;
        --context-lengths) CONTEXT_LENGTHS="$2";  shift ;;
        --sdk-image)       TRITON_SDK_IMAGE="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Configure target based on endpoint type
if [ "$ENDPOINT" == "ollama" ]; then
    URL="${URL:-http://localhost:11434}"
    if [ -z "$MODEL_NAME" ]; then
        MODEL_NAME=$(curl -s --connect-timeout 2 "${URL}/api/tags" 2>/dev/null | grep -o '"name":"[^"]*' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ -z "$MODEL_NAME" ]; then
            MODEL_NAME="llama3"  # Fallback
        fi
    fi
    echo "Configuring for Personal LLM (Ollama) at $URL"
elif [ "$ENDPOINT" == "vllm" ]; then
    URL="${URL:-http://localhost:8000}"
    if [ -z "$MODEL_NAME" ]; then
        MODEL_NAME=$(curl -s --connect-timeout 2 "${URL}/v1/models" 2>/dev/null | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4 || echo "")
        if [ -z "$MODEL_NAME" ]; then
            MODEL_NAME="Qwen/Qwen3-8B"  # Fallback
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

# Resolve to absolute path for Docker volume mount
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"

echo "=============================================="
echo "Starting genai-perf benchmark"
echo "  SDK image:         $TRITON_SDK_IMAGE"
echo "  Target:            $ENDPOINT ($URL)"
echo "  Model:             $MODEL_NAME"
echo "  Output Tokens:     $OUTPUT_TOKENS"
echo "  Num Prompts:       $NUM_PROMPTS"
echo "  Concurrency:       $CONCURRENCY_LIST"
if [ -n "$CONTEXT_LENGTHS" ]; then
    echo "  Context Lengths:   $CONTEXT_LENGTHS (tokens)"
else
    echo "  Input Tokens:      $INPUT_TOKENS"
fi
echo "  Results dir:       $RESULTS_DIR"
echo "=============================================="

# ── Build the list of context sizes to sweep ──────────────────────────────────
# If --context-lengths is set, use those; otherwise use INPUT_TOKENS as a single pass.
declare -a CTX_LIST=()
if [ -n "$CONTEXT_LENGTHS" ]; then
    IFS=',' read -ra CTX_LIST <<< "$CONTEXT_LENGTHS"
else
    CTX_LIST=("$INPUT_TOKENS")
fi

# ── Sweep: context size × concurrency ─────────────────────────────────────────
IFS=',' read -ra CONC_ARRAY <<< "$CONCURRENCY_LIST"

for CTX in "${CTX_LIST[@]}"; do
    echo ""
    echo "── Context: ${CTX} input tokens ──────────────────────────────────────"

    for CONC in "${CONC_ARRAY[@]}"; do
        echo "  Running concurrency=${CONC}, input_tokens=${CTX}..."

        # Build a sub-dir per (context, concurrency) so results don't collide
        ARTIFACT_SUBDIR="ctx${CTX}_concurrency_${CONC}"

        docker run --rm --net=host \
            -e NVIDIA_DISABLE_REQUIRE=1 \
            -v "$RESULTS_DIR:/work/results" \
            -w /work \
            "$TRITON_SDK_IMAGE" \
            genai-perf profile \
            -m "$MODEL_NAME" \
            --endpoint-type chat \
            -u "$URL" \
            --num-prompts "$NUM_PROMPTS" \
            --synthetic-input-tokens-mean "$CTX" \
            --output-tokens-mean "$OUTPUT_TOKENS" \
            --concurrency "$CONC" \
            --artifact-dir "results/${ARTIFACT_SUBDIR}" \
            --measurement-interval 120000 \
            --stability-percentage 999

        echo "  Done: concurrency=${CONC}, input_tokens=${CTX}"
    done
done

echo ""
echo "=============================================="
echo "genai-perf benchmarks completed."
echo "Results saved to $RESULTS_DIR"
echo "=============================================="