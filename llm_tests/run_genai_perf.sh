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
MEASUREMENT_INTERVAL=30000
REQUEST_TIMEOUT=""  # Per-request timeout in seconds (for thinking/reasoning models)

# Triton SDK image — update this to the latest available on nvcr.io
TRITON_SDK_IMAGE="nvcr.io/nvidia/tritonserver:25.04-py3-sdk"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --endpoint)             ENDPOINT="$2";             shift ;;
        --model)                MODEL_NAME="$2";           shift ;;
        --url)                  URL="$2";                  shift ;;
        --concurrency)          CONCURRENCY_LIST="$2";     shift ;;
        --input-tokens)         INPUT_TOKENS="$2";         shift ;;
        --output-tokens)        OUTPUT_TOKENS="$2";        shift ;;
        --num-prompts)          NUM_PROMPTS="$2";          shift ;;
        --results-dir)          RESULTS_DIR="$2";          shift ;;
        --context-lengths)      CONTEXT_LENGTHS="$2";      shift ;;
        --sdk-image)            TRITON_SDK_IMAGE="$2";     shift ;;
        --measurement-interval) MEASUREMENT_INTERVAL="$2"; shift ;;
        --request-timeout)      REQUEST_TIMEOUT="$2";      shift ;;
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
    # Ollama model names (e.g. qwen3.6:35b) contain colons which are invalid
    # HuggingFace repo IDs. Map to corresponding HF tokenizer for genai-perf.
    case "$MODEL_NAME" in
        qwen3.6*)       TOKENIZER_NAME="Qwen/Qwen3-30B-A3B" ;;
        qwen3*)         TOKENIZER_NAME="Qwen/Qwen3-30B-A3B" ;;
        deepseek-r1*)   TOKENIZER_NAME="deepseek-ai/DeepSeek-R1-Distill-Llama-70B" ;;
        nemotron-3*)    TOKENIZER_NAME="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4" ;;
        gemma4*)        TOKENIZER_NAME="unsloth/gemma-3-27b-it" ;;
        # Use ungated unsloth mirrors so the tokenizer downloads without a Meta gate
        # grant (the gated meta-llama/* repos 403 for accounts not on Meta's allowlist).
        llama4*)        TOKENIZER_NAME="unsloth/Llama-4-Scout-17B-16E-Instruct" ;;
        llama3.2*)      TOKENIZER_NAME="unsloth/Llama-3.2-1B-Instruct" ;;
        llama3*)        TOKENIZER_NAME="unsloth/Meta-Llama-3.1-8B-Instruct" ;;
        *)              TOKENIZER_NAME="HuggingFaceTB/SmolLM-135M" ;;  # Safe fallback
    esac
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

# ── Measurement-window profile (single source of truth) ───────────────────────
# Reasoning/thinking models emit a long internal phase before any visible token, so
# a short measurement window can capture zero completed requests and genai-perf aborts
# with "Failed to obtain stable measurement". This table is the ONE place that decides
# which models need the long (120s) window; it floors the interval for BOTH the vLLM and
# Ollama paths (matched against the HF id or the Ollama tag, case-insensitively), so
# neither path can regress. The per-concurrency auto-retry below is the safety net for
# anything this list misses (e.g. a slow dense model on bandwidth-limited hardware).
REASONING_LONG_INTERVAL=120000
REASONING_MODEL_GLOBS='qwen3 qwq deepseek-r1 nemotron gpt-oss magistral reason think cogito'
is_reasoning_model() {
    local name g
    name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for g in $REASONING_MODEL_GLOBS; do
        case "$name" in *"$g"*) return 0 ;; esac
    done
    return 1
}
if is_reasoning_model "$MODEL_NAME" && [ "${MEASUREMENT_INTERVAL:-0}" -lt "$REASONING_LONG_INTERVAL" ]; then
    echo "  ⏱  Reasoning model detected ($MODEL_NAME) → measurement window ${MEASUREMENT_INTERVAL}ms ⭢ ${REASONING_LONG_INTERVAL}ms"
    MEASUREMENT_INTERVAL=$REASONING_LONG_INTERVAL
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
if [ -n "$REQUEST_TIMEOUT" ]; then
    echo "  Request Timeout:   ${REQUEST_TIMEOUT}s (extended for thinking models)"
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

# ── One genai-perf pass (returns the genai-perf exit code; never aborts the script) ──
# Output is tee'd to GENAI_LOG so the caller can distinguish an unstable-measurement
# failure (retryable with a longer window) from a hard error (server crash, etc.).
GENAI_LOG="$(mktemp)"
SWEEP_FAILURES=0
SWEEP_SUCCESSES=0
genai_perf_run() {   # <conc> <ctx> <interval> <artifact_subdir>
    local conc="$1" ctx="$2" interval="$3" subdir="$4"
    # shellcheck disable=SC2086
    docker run --rm --net=host \
        -e NVIDIA_DISABLE_REQUIRE=1 \
        -e HF_TOKEN \
        -e HUGGINGFACE_HUB_TOKEN \
        -e HF_ENDPOINT \
        -v "$RESULTS_DIR:/work/results" \
        -w /work \
        "$TRITON_SDK_IMAGE" \
        genai-perf profile \
        -m "$MODEL_NAME" \
        --endpoint-type chat \
        --streaming \
        -u "$URL" \
        --num-prompts "$NUM_PROMPTS" \
        --synthetic-input-tokens-mean "$ctx" \
        --output-tokens-mean "$OUTPUT_TOKENS" \
        --concurrency "$conc" \
        --artifact-dir "results/${subdir}" \
        --measurement-interval "$interval" \
        --stability-percentage 999 \
        $TOKENIZER_ARG \
        -- --max-trials 3 2>&1 | tee "$GENAI_LOG"
    return "${PIPESTATUS[0]}"
}

# ── Sweep: context size × concurrency ─────────────────────────────────────────
IFS=',' read -ra CONC_ARRAY <<< "$CONCURRENCY_LIST"

for CTX in "${CTX_LIST[@]}"; do
    echo ""
    echo "── Context: ${CTX} input tokens ──────────────────────────────────────"

    for CONC in "${CONC_ARRAY[@]}"; do
        echo "  Running concurrency=${CONC}, input_tokens=${CTX}..."

        # Build a sub-dir per (context, concurrency) so results don't collide
        ARTIFACT_SUBDIR="ctx${CTX}_concurrency_${CONC}"

        # Build tokenizer arg if we resolved a HF-compatible name
        TOKENIZER_ARG=""
        if [ -n "${TOKENIZER_NAME:-}" ]; then
            TOKENIZER_ARG="--tokenizer $TOKENIZER_NAME"
        fi

        # Run; on an unstable-measurement failure (genai-perf couldn't complete enough
        # requests in the window — common for reasoning models or slow/bandwidth-bound
        # hardware at high concurrency), retry this level once with a doubled window.
        # This is the fail-safe net that catches whatever the reasoning table above misses.
        rc=0
        genai_perf_run "$CONC" "$CTX" "$MEASUREMENT_INTERVAL" "$ARTIFACT_SUBDIR" || rc=$?
        if [ "$rc" -ne 0 ] && grep -qiE 'stable measurement|measurement[ -]interval' "$GENAI_LOG"; then
            retry_interval=$(( MEASUREMENT_INTERVAL >= 120000 ? MEASUREMENT_INTERVAL * 2 : 240000 ))
            echo "  ⚠ Unstable measurement at concurrency=${CONC} (window ${MEASUREMENT_INTERVAL}ms) — retrying once at ${retry_interval}ms..."
            rc=0
            genai_perf_run "$CONC" "$CTX" "$retry_interval" "$ARTIFACT_SUBDIR" || rc=$?
        fi

        if [ "$rc" -ne 0 ]; then
            echo "  ✗ genai-perf failed at concurrency=${CONC}, input_tokens=${CTX} (rc=${rc}) — continuing"
            SWEEP_FAILURES=$((SWEEP_FAILURES + 1))
        else
            echo "  Done: concurrency=${CONC}, input_tokens=${CTX}"
            SWEEP_SUCCESSES=$((SWEEP_SUCCESSES + 1))
        fi
    done
done

rm -f "$GENAI_LOG" 2>/dev/null || true

echo ""
echo "=============================================="
echo "genai-perf benchmarks completed."
echo "  Levels passed: ${SWEEP_SUCCESSES}, failed: ${SWEEP_FAILURES}"
echo "Results saved to $RESULTS_DIR"
echo "=============================================="

# Exit non-zero only if NO concurrency level produced data (a real, total failure).
# A partial sweep (e.g. conc 1/4/8 pass, 16/32 fail) still yields usable data and is
# reported as success so the harness keeps it.
if [ "$SWEEP_SUCCESSES" -eq 0 ]; then
    exit 1
fi
exit 0