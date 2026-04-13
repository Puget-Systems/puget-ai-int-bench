#!/bin/bash

# Puget Systems AI Internal Benchmarks — Legacy Remote/Local Mode
#
# This script preserves the original SSH-based benchmarking workflow
# for pointing at an already-running inference server.
#
# Called by run_benchmarks.sh when --host or --local is specified.
#
# Usage (via main script):
#   ./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP
#   ./run_benchmarks.sh --local

set -e

# ============================================
# Defaults
# ============================================
HOST=""
LOCAL_MODE=false
CONCURRENCY="1,4,8,16"
SSH_KEY=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================
# Parse Arguments
# ============================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift ;;
        --local) LOCAL_MODE=true ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        --ssh-key) SSH_KEY="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Validate arguments
if [ "$LOCAL_MODE" = false ] && [ -z "$HOST" ]; then
    echo "❌ Error: You must specify either --host USER@IP or --local."
    exit 1
fi

# ============================================
# SSH Helpers
# ============================================
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# Extract IP/hostname from USER@IP format
if [ -n "$HOST" ]; then
    REMOTE_IP="${HOST#*@}"
fi

# Run a command on the inference server (SSH) or locally
remote_cmd() {
    if [ "$LOCAL_MODE" = true ]; then
        eval "$@"
    else
        ssh $SSH_OPTS "$HOST" "$@"
    fi
}

# ============================================
# Banner
# ============================================
echo "=============================================="
echo "Puget Systems AI App Pack Benchmarking Suite"
echo "           (Legacy Remote Mode)"
echo "=============================================="

if [ "$LOCAL_MODE" = true ]; then
    echo "Mode: Local (benchmarking this machine)"
    BENCH_URL_BASE="http://localhost"
else
    echo "Mode: Remote (inference server: $HOST)"
    echo "  Specs collected via SSH from $HOST"
    echo "  Benchmark runs locally, pointed at $REMOTE_IP"
    BENCH_URL_BASE="http://${REMOTE_IP}"

    # Test SSH connectivity
    echo "Testing SSH connection..."
    if ! remote_cmd "echo 'SSH connection successful'"; then
        echo "❌ SSH connection failed. Make sure you have key-based auth set up:"
        echo "   ssh-copy-id $HOST"
        exit 1
    fi
fi

# ============================================
# Determine remote hostname for result naming
# ============================================
if [ "$LOCAL_MODE" = true ]; then
    TARGET_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
else
    TARGET_HOSTNAME=$(remote_cmd "hostname -s 2>/dev/null || hostname")
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Local results directory
LOCAL_RESULTS_DIR="$SCRIPT_DIR/results/${TARGET_HOSTNAME}_${TIMESTAMP}"
mkdir -p "$LOCAL_RESULTS_DIR"

# ============================================
# 1. Collect System Specifications (via SSH)
# ============================================
echo ""
echo "Collecting System Specifications from ${TARGET_HOSTNAME}..."
SPEC_FILE="$LOCAL_RESULTS_DIR/system_specs.txt"

echo "=============================================" > "$SPEC_FILE"
echo "System Specifications — $TARGET_HOSTNAME" >> "$SPEC_FILE"
echo "=============================================" >> "$SPEC_FILE"
echo "Date: $(date)" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# Hostname
echo "Hostname: $TARGET_HOSTNAME" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# Virtualization Detection
echo "Virtualization:" >> "$SPEC_FILE"
VIRT_TYPE=$(remote_cmd "systemd-detect-virt 2>/dev/null || echo 'unknown'")
if [ "$VIRT_TYPE" = "none" ] || [ "$VIRT_TYPE" = "unknown" ]; then
    echo "  Type: Bare Metal" >> "$SPEC_FILE"
else
    echo "  Type: Virtual Machine ($VIRT_TYPE)" >> "$SPEC_FILE"
fi
echo "" >> "$SPEC_FILE"

# CPU
echo "CPU Information:" >> "$SPEC_FILE"
remote_cmd "lscpu | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core|Socket'" >> "$SPEC_FILE" 2>/dev/null || echo "  lscpu not available" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# Memory
echo "Memory Information:" >> "$SPEC_FILE"
remote_cmd "free -h" >> "$SPEC_FILE" 2>/dev/null || echo "  free not available" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# GPU
echo "GPU Information:" >> "$SPEC_FILE"
GPU_INFO=$(remote_cmd "nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv" 2>/dev/null || echo "")
if [ -n "$GPU_INFO" ]; then
    echo "$GPU_INFO" >> "$SPEC_FILE"
else
    echo "  nvidia-smi not found. No NVIDIA GPUs detected." >> "$SPEC_FILE"
fi
echo "" >> "$SPEC_FILE"

# OS
echo "OS Information:" >> "$SPEC_FILE"
remote_cmd "cat /etc/os-release 2>/dev/null | head -5" >> "$SPEC_FILE" || echo "  OS info not available" >> "$SPEC_FILE"

echo "✅ Saved specs to $SPEC_FILE"

# ============================================
# 2. Detect Active App Packs & Run Benchmarks
# ============================================
echo ""
echo "Detecting Active App Packs on ${TARGET_HOSTNAME}..."

FOUND_PACKS=false

# Check for Personal LLM (Ollama) — detect via SSH, bench locally
if remote_cmd "curl -s --connect-timeout 2 http://localhost:11434/api/tags" > /dev/null 2>&1; then
    echo "✅ Detected Personal LLM (Ollama) on port 11434!"
    FOUND_PACKS=true

    # Discover model name from the remote server
    OLLAMA_MODEL=$(remote_cmd "curl -s http://localhost:11434/api/tags | grep -o '\"name\":\"[^\"]*' | head -n 1 | cut -d'\"' -f4" 2>/dev/null || echo "")

    echo "Starting genai-perf for Ollama (benchmark runs locally)..."
    cd "$SCRIPT_DIR/llm_tests"
    chmod +x run_genai_perf.sh
    ./run_genai_perf.sh \
        --endpoint ollama \
        --url "${BENCH_URL_BASE}:11434" \
        --concurrency "1" \
        --results-dir "$LOCAL_RESULTS_DIR" \
        ${OLLAMA_MODEL:+--model "$OLLAMA_MODEL"}
    cd - > /dev/null
else
    echo "❌ Personal LLM (Ollama) not detected on port 11434."
fi

# Check for Team LLM (vLLM) — detect via SSH, bench locally
if remote_cmd "curl -s --connect-timeout 2 http://localhost:8000/v1/models" > /dev/null 2>&1; then
    echo "✅ Detected Team LLM (vLLM) on port 8000!"
    FOUND_PACKS=true

    # Discover model name from the remote server
    VLLM_MODEL=$(remote_cmd "curl -s http://localhost:8000/v1/models | grep -o '\"id\":\"[^\"]*' | head -n 1 | cut -d'\"' -f4" 2>/dev/null || echo "")

    echo "Starting genai-perf for vLLM (benchmark runs locally)..."
    cd "$SCRIPT_DIR/llm_tests"
    chmod +x run_genai_perf.sh
    ./run_genai_perf.sh \
        --endpoint vllm \
        --url "${BENCH_URL_BASE}:8000" \
        --concurrency "$CONCURRENCY" \
        --results-dir "$LOCAL_RESULTS_DIR" \
        ${VLLM_MODEL:+--model "$VLLM_MODEL"}
    cd - > /dev/null
else
    echo "❌ Team LLM (vLLM) not detected on port 8000."
fi

if [ "$FOUND_PACKS" = false ]; then
    echo ""
    echo "⚠️  No active App Packs detected. Make sure vLLM or Ollama is running."
    exit 1
fi

# ============================================
# 3. Generate Summary Report
# ============================================
echo ""
echo "Generating summary report..."
SUMMARY_SCRIPT="$SCRIPT_DIR/llm_tests/generate_summary.py"
if [ -f "$SUMMARY_SCRIPT" ]; then
    python3 "$SUMMARY_SCRIPT" "$LOCAL_RESULTS_DIR" "$SPEC_FILE" || echo "⚠️  Summary generation failed (python3 required)"
else
    echo "⚠️  Summary script not found at $SUMMARY_SCRIPT"
fi

# ============================================
# Done
# ============================================
echo ""
echo "=============================================="
echo "Benchmarks Complete!"
echo "Results saved to: $LOCAL_RESULTS_DIR"
echo "=============================================="
echo ""
echo "Contents:"
ls -la "$LOCAL_RESULTS_DIR"
