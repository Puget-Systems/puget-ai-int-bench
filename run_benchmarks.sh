#!/bin/bash

# Puget Systems AI Internal Benchmarks Orchestrator
# This script orchestrates the LLM and ComfyUI benchmarks.

set -e

echo "=============================================="
echo "Puget Systems AI App Pack Benchmarking Suite"
echo "=============================================="

# Define paths
RESULTS_DIR="$(pwd)/results"
LLM_TESTS_DIR="$(pwd)/llm_tests"
COMFYUI_TESTS_DIR="$(pwd)/comfyui_tests"

mkdir -p "$RESULTS_DIR"

# 1. System Information Logging
echo "Collecting System Specifications..."
SYSTEM_INFO_FILE="$RESULTS_DIR/system_specs.txt"
echo "System Specifications" > "$SYSTEM_INFO_FILE"
echo "-------------------" >> "$SYSTEM_INFO_FILE"
echo "Date: $(date)" >> "$SYSTEM_INFO_FILE"
echo "" >> "$SYSTEM_INFO_FILE"
echo "CPU Information:" >> "$SYSTEM_INFO_FILE"
lscpu | grep "Model name" >> "$SYSTEM_INFO_FILE" || echo "lscpu not available" >> "$SYSTEM_INFO_FILE"
echo "" >> "$SYSTEM_INFO_FILE"
echo "Memory Information:" >> "$SYSTEM_INFO_FILE"
free -h >> "$SYSTEM_INFO_FILE" || echo "free not available" >> "$SYSTEM_INFO_FILE"
echo "" >> "$SYSTEM_INFO_FILE"
echo "GPU Information:" >> "$SYSTEM_INFO_FILE"
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv >> "$SYSTEM_INFO_FILE"
else
    echo "nvidia-smi not found. No NVIDIA GPUs detected." >> "$SYSTEM_INFO_FILE"
fi
echo "Saved specs to $SYSTEM_INFO_FILE"

# 2. Detect Active App Packs & Run Tests
echo "Detecting Active App Packs..."

# Make sub-scripts executable
chmod +x "$LLM_TESTS_DIR/run_genai_perf.sh" || true

# Check for Personal LLM (Ollama)
if curl -s --connect-timeout 2 http://localhost:11434/api/tags > /dev/null; then
    echo "✅ Detected Personal LLM (Ollama) on port 11434!"
    echo "Starting genai-perf for Ollama..."
    # Run the benchmark (this outputs its own results to the results folder)
    cd "$LLM_TESTS_DIR" && ./run_genai_perf.sh --endpoint ollama --concurrency "1"
    cd - > /dev/null
else
    echo "❌ Personal LLM (Ollama) not detected on port 11434."
fi

# Check for Team LLM (vLLM)
if curl -s --connect-timeout 2 http://localhost:8000/v1/models > /dev/null; then
    echo "✅ Detected Team LLM (vLLM) on port 8000!"
    echo "Starting genai-perf for vLLM..."
    cd "$LLM_TESTS_DIR" && ./run_genai_perf.sh --endpoint vllm --concurrency "1,4,8,16"
    cd - > /dev/null
else
    echo "❌ Team LLM (vLLM) not detected on port 8000."
fi

echo "=============================================="
echo "Benchmarks Complete! Results saved to $RESULTS_DIR"
echo "=============================================="