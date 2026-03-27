#!/bin/bash

# Puget Systems AI Internal Benchmarks Orchestrator
# Runs benchmarks on a remote inference server via SSH, or locally with --local.
#
# Usage:
#   ./run_benchmarks.sh --host puget@172.19.168.179
#   ./run_benchmarks.sh --host puget@172.19.168.179 --concurrency "1,4,8,16"
#   ./run_benchmarks.sh --local

set -e

# ============================================
# Defaults
# ============================================
HOST=""
LOCAL_MODE=false
CONCURRENCY="1,4,8,16"
SSH_KEY=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================
# Parse Arguments
# ============================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift ;;
        --local) LOCAL_MODE=true ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        --ssh-key) SSH_KEY="$2"; shift ;;
        -h|--help)
            echo "Puget Systems AI App Pack Benchmarking Suite"
            echo ""
            echo "Usage:"
            echo "  ./run_benchmarks.sh --host USER@IP     Run benchmarks on a remote server"
            echo "  ./run_benchmarks.sh --local            Run benchmarks on this machine"
            echo ""
            echo "Options:"
            echo "  --host USER@IP       SSH target (e.g., puget@172.19.168.179)"
            echo "  --local              Run on the current machine instead of remote"
            echo "  --concurrency LIST   Concurrency levels (default: 1,4,8,16)"
            echo "  --ssh-key PATH       Path to SSH private key (optional)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *) echo "Unknown parameter: $1. Use --help for usage."; exit 1 ;;
    esac
    shift
done

# Validate arguments
if [ "$LOCAL_MODE" = false ] && [ -z "$HOST" ]; then
    echo "❌ Error: You must specify either --host USER@IP or --local."
    echo "   Run with --help for usage information."
    exit 1
fi

# ============================================
# SSH Helpers
# ============================================
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# Run a command: remotely via SSH or locally
run_cmd() {
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
echo "=============================================="

if [ "$LOCAL_MODE" = true ]; then
    echo "Mode: Local (running on this machine)"
else
    echo "Mode: Remote (target: $HOST)"
    # Test SSH connectivity
    echo "Testing SSH connection..."
    if ! run_cmd "echo 'SSH connection successful'"; then
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
    TARGET_HOSTNAME=$(run_cmd "hostname -s 2>/dev/null || hostname")
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Local results directory
LOCAL_RESULTS_DIR="$SCRIPT_DIR/results/${TARGET_HOSTNAME}_${TIMESTAMP}"
mkdir -p "$LOCAL_RESULTS_DIR"

# Remote working directory (only used in remote mode)
REMOTE_WORK_DIR="/tmp/puget_bench_${TIMESTAMP}"
if [ "$LOCAL_MODE" = false ]; then
    run_cmd "mkdir -p $REMOTE_WORK_DIR"
fi

# ============================================
# 1. Collect System Specifications
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
VIRT_TYPE=$(run_cmd "systemd-detect-virt 2>/dev/null || echo 'unknown'")
if [ "$VIRT_TYPE" = "none" ] || [ "$VIRT_TYPE" = "unknown" ]; then
    echo "  Type: Bare Metal" >> "$SPEC_FILE"
else
    echo "  Type: Virtual Machine ($VIRT_TYPE)" >> "$SPEC_FILE"
fi
echo "" >> "$SPEC_FILE"

# CPU
echo "CPU Information:" >> "$SPEC_FILE"
run_cmd "lscpu | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core|Socket'" >> "$SPEC_FILE" 2>/dev/null || echo "  lscpu not available" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# Memory
echo "Memory Information:" >> "$SPEC_FILE"
run_cmd "free -h" >> "$SPEC_FILE" 2>/dev/null || echo "  free not available" >> "$SPEC_FILE"
echo "" >> "$SPEC_FILE"

# GPU
echo "GPU Information:" >> "$SPEC_FILE"
GPU_INFO=$(run_cmd "nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv" 2>/dev/null || echo "")
if [ -n "$GPU_INFO" ]; then
    echo "$GPU_INFO" >> "$SPEC_FILE"
else
    echo "  nvidia-smi not found. No NVIDIA GPUs detected." >> "$SPEC_FILE"
fi
echo "" >> "$SPEC_FILE"

# OS
echo "OS Information:" >> "$SPEC_FILE"
run_cmd "cat /etc/os-release 2>/dev/null | head -5" >> "$SPEC_FILE" || echo "  OS info not available" >> "$SPEC_FILE"

echo "✅ Saved specs to $SPEC_FILE"

# ============================================
# 2. Detect Active App Packs & Run Tests
# ============================================
echo ""
echo "Detecting Active App Packs on ${TARGET_HOSTNAME}..."

FOUND_PACKS=false

# Check for Personal LLM (Ollama)
if run_cmd "curl -s --connect-timeout 2 http://localhost:11434/api/tags" > /dev/null 2>&1; then
    echo "✅ Detected Personal LLM (Ollama) on port 11434!"
    FOUND_PACKS=true

    echo "Starting genai-perf for Ollama..."
    if [ "$LOCAL_MODE" = true ]; then
        cd "$SCRIPT_DIR/llm_tests"
        chmod +x run_genai_perf.sh
        ./run_genai_perf.sh --endpoint ollama --concurrency "1" --results-dir "$LOCAL_RESULTS_DIR"
        cd - > /dev/null
    else
        # Copy the bench script to the remote and run it there
        scp $SSH_OPTS "$SCRIPT_DIR/llm_tests/run_genai_perf.sh" "$HOST:$REMOTE_WORK_DIR/run_genai_perf.sh"
        run_cmd "chmod +x $REMOTE_WORK_DIR/run_genai_perf.sh && cd $REMOTE_WORK_DIR && ./run_genai_perf.sh --endpoint ollama --concurrency '1'"
    fi
else
    echo "❌ Personal LLM (Ollama) not detected on port 11434."
fi

# Check for Team LLM (vLLM)
if run_cmd "curl -s --connect-timeout 2 http://localhost:8000/v1/models" > /dev/null 2>&1; then
    echo "✅ Detected Team LLM (vLLM) on port 8000!"
    FOUND_PACKS=true

    echo "Starting genai-perf for vLLM..."
    if [ "$LOCAL_MODE" = true ]; then
        cd "$SCRIPT_DIR/llm_tests"
        chmod +x run_genai_perf.sh
        ./run_genai_perf.sh --endpoint vllm --concurrency "$CONCURRENCY" --results-dir "$LOCAL_RESULTS_DIR"
        cd - > /dev/null
    else
        # Copy the bench script to the remote and run it there
        scp $SSH_OPTS "$SCRIPT_DIR/llm_tests/run_genai_perf.sh" "$HOST:$REMOTE_WORK_DIR/run_genai_perf.sh"
        run_cmd "chmod +x $REMOTE_WORK_DIR/run_genai_perf.sh && cd $REMOTE_WORK_DIR && ./run_genai_perf.sh --endpoint vllm --concurrency '$CONCURRENCY'"
    fi
else
    echo "❌ Team LLM (vLLM) not detected on port 8000."
fi

if [ "$FOUND_PACKS" = false ]; then
    echo ""
    echo "⚠️  No active App Packs detected. Make sure vLLM or Ollama is running."
    exit 1
fi

# ============================================
# 3. Retrieve Results (remote mode only)
# ============================================
if [ "$LOCAL_MODE" = false ]; then
    echo ""
    echo "Retrieving results from ${TARGET_HOSTNAME}..."
    scp $SSH_OPTS -r "$HOST:$REMOTE_WORK_DIR/results/*" "$LOCAL_RESULTS_DIR/" 2>/dev/null || true

    # Cleanup remote temp dir
    run_cmd "rm -rf $REMOTE_WORK_DIR" 2>/dev/null || true
fi

# ============================================
# 4. Generate Summary Report
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