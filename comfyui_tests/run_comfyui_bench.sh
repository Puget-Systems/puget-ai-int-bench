#!/bin/bash
# Puget Systems — ComfyUI Benchmark Shell Wrapper
#
# Analogous to llm_tests/run_genai_perf.sh — called by the main orchestrator
# to run a ComfyUI benchmark against a remote (or local) ComfyUI instance.
#
# Usage:
#   ./run_comfyui_bench.sh \
#       --url http://HOST:8188 \
#       --workflow ../comfyui_tests/workflows/z_image_turbo_txt2img_api.json \
#       --iterations 10 \
#       --results-dir /path/to/results

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run_comfyui_bench.py"

# ── Argument Parsing ──────────────────────────────────────────────────────────
URL=""
WORKFLOW=""
ITERATIONS=10
RESULTS_DIR=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --url)        URL="$2";        shift ;;
        --workflow)   WORKFLOW="$2";   shift ;;
        --iterations) ITERATIONS="$2"; shift ;;
        --results-dir) RESULTS_DIR="$2"; shift ;;
        -h|--help)
            echo "Usage: $0 --url URL --workflow PATH --iterations N --results-dir PATH"
            exit 0
            ;;
        *) echo -e "${RED}Unknown parameter: $1${NC}"; exit 1 ;;
    esac
    shift
done

if [ -z "$URL" ] || [ -z "$WORKFLOW" ] || [ -z "$RESULTS_DIR" ]; then
    echo -e "${RED}✗ --url, --workflow, and --results-dir are required.${NC}"
    exit 1
fi

if [ ! -f "$WORKFLOW" ]; then
    echo -e "${RED}✗ Workflow file not found: $WORKFLOW${NC}"
    exit 1
fi

# ── Python + Dependencies ─────────────────────────────────────────────────────
echo -e "  ${BLUE}Checking Python environment...${NC}"

PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3 python; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo -e "${RED}✗ Python 3 not found. Install Python 3.9+ to run ComfyUI benchmarks.${NC}"
    exit 1
fi

PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo -e "  ${GREEN}✓ Python ${PY_VERSION}${NC}"

# Install missing deps into a local venv so we don't pollute the system
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    echo -e "  ${BLUE}Creating venv at $VENV_DIR...${NC}"
    "$PYTHON" -m venv "$VENV_DIR"
fi

VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

# Ensure deps are installed (idempotent)
MISSING_DEPS=()
"$VENV_PY" -c "import requests" 2>/dev/null || MISSING_DEPS+=("requests")
"$VENV_PY" -c "import websockets" 2>/dev/null || MISSING_DEPS+=("websockets")

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo -e "  ${BLUE}Installing dependencies: ${MISSING_DEPS[*]}...${NC}"
    "$VENV_PIP" install --quiet "${MISSING_DEPS[@]}"
    echo -e "  ${GREEN}✓ Dependencies installed.${NC}"
else
    echo -e "  ${GREEN}✓ Dependencies already satisfied.${NC}"
fi

# ── Run Benchmark ─────────────────────────────────────────────────────────────
echo -e ""
echo -e "  ${BLUE}Starting ComfyUI benchmark...${NC}"
echo -e "  URL:        ${BLUE}${URL}${NC}"
echo -e "  Workflow:   ${YELLOW}$(basename "$WORKFLOW")${NC}"
echo -e "  Iterations: ${ITERATIONS}"
echo ""

mkdir -p "$RESULTS_DIR"

"$VENV_PY" "$RUNNER" \
    --url "$URL" \
    --workflow "$WORKFLOW" \
    --iterations "$ITERATIONS" \
    --results-dir "$RESULTS_DIR"

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo -e "  ${GREEN}✓ ComfyUI benchmark complete. Results in: $RESULTS_DIR${NC}"
else
    echo ""
    echo -e "  ${RED}✗ ComfyUI benchmark finished with errors (exit $EXIT_CODE).${NC}"
fi

exit $EXIT_CODE
