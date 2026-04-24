#!/bin/bash

# Puget Systems AI App Pack — Automated Benchmark Suite
#
# End-to-end benchmark orchestrator that targets a remote inference server
# to download, install, launch, benchmark, and tear down App Packs automatically.
# Benchmarking client (genai-perf) runs locally.
#
# Usage:
#   ./run_benchmarks.sh --host USER@IP                     # Interactive mode targeting a remote server
#   ./run_benchmarks.sh --host USER@IP --cache-proxy URL   # With cache proxy
#   ./run_benchmarks.sh --host USER@IP --pack team_llm --model 1
#   ./run_benchmarks.sh --host USER@IP --run-all

set -euo pipefail

# ============================================
# ANSI Color Codes
# ============================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# ============================================
# Constants
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PACK_REPO="https://github.com/Puget-Systems/puget-docker-app-packs.git"
APP_PACK_BRANCH="main"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/puget-bench"
CONFIG_FILE="$CONFIG_DIR/bench.conf"

# ============================================
# Defaults
# ============================================
HOST=""
CACHE_PROXY=""
PACK=""
MODEL_CHOICE=""
RUN_ALL=false
DRY_RUN=false
CONCURRENCY="1,4,8,16"
SSH_KEY=""
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
COMFY_ITERATIONS=10
CONTEXT_LENGTHS=""  # e.g. "4096,32768,131072" — empty = use INPUT_TOKENS only

# ============================================
# Load Config File (if exists)
# ============================================
if [ -f "$CONFIG_FILE" ]; then
    # Validate config contains only comments, blank lines, and KEY=VALUE
    if grep -qvE '^\s*$|^\s*#|^[A-Z_][A-Z0-9_]*=' "$CONFIG_FILE"; then
        echo -e "${RED}✗ Config file contains unexpected content: $CONFIG_FILE${NC}"
        echo "  Only KEY=VALUE assignments, comments (#), and blank lines are allowed."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ============================================
# Parse Arguments
# ============================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift ;;
        --cache-proxy) CACHE_PROXY="$2"; shift ;;
        --pack) PACK="$2"; shift ;;
        --model) MODEL_CHOICE="$2"; shift ;;
        --run-all) RUN_ALL=true ;;
        --dry-run) DRY_RUN=true ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        --repo) APP_PACK_REPO="$2"; shift ;;
        --branch) APP_PACK_BRANCH="$2"; shift ;;
        --input-tokens) INPUT_TOKENS="$2"; shift ;;
        --output-tokens) OUTPUT_TOKENS="$2"; shift ;;
        --num-prompts) NUM_PROMPTS="$2"; shift ;;
        --ssh-key) SSH_KEY="$2"; shift ;;
        --comfy-iterations) COMFY_ITERATIONS="$2"; shift ;;
        --context-lengths) CONTEXT_LENGTHS="$2"; shift ;;
        -h|--help)
            echo -e "${BLUE}Puget Systems AI App Pack — Automated Benchmark Suite${NC}"
            echo ""
            echo "Usage:"
            echo "  ./run_benchmarks.sh --host USER@IP                   Interactive mode on remote server"
            echo "  ./run_benchmarks.sh --host USER@IP --run-all         Run full test matrix on remote server"
            echo ""
            echo "Options:"
            echo "  --host USER@IP       (Required) SSH target for server-side operations"
            echo "  --cache-proxy URL    Squid cache proxy for model downloads"
            echo "  --pack NAME          App Pack: team_llm, personal_llm, comfy_ui"
            echo "  --model CHOICE       Model menu number (1-9) or model ID string"
            echo "  --run-all            Run all VRAM-appropriate models automatically"
            echo "  --dry-run            Validate setup without launching containers"
            echo "  --concurrency LIST   Concurrency levels (default: 1,4,8,16)"
            echo "  --repo URL           App Pack git repository URL or local path"
            echo "  --branch NAME        App Pack git branch (default: main)"
            echo "  --ssh-key PATH       Path to SSH private key"
            echo "  --comfy-iterations N Number of images per ComfyUI benchmark run (default: 10)"
            echo "  --context-lengths L  Comma-separated input token sizes to benchmark (e.g. 4096,32768,131072)"
            exit 0
            ;;
        *) echo -e "${RED}Unknown parameter: $1. Use --help for usage.${NC}"; exit 1 ;;
    esac
    shift
done

if [ -z "$HOST" ]; then
    echo -e "${RED}✗ Error: --host USER@IP is required.${NC}"
    echo "  The orchestrator runs on your local machine and uses SSH to manage App Packs on the inference server."
    exit 1
fi

# Extract IP/hostname from USER@IP format
REMOTE_IP="${HOST#*@}"
BENCH_URL_BASE="http://${REMOTE_IP}"

# ============================================
# Command Execution Helpers
# ============================================
declare -a SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

target_cmd() {
    ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

run_genai_perf_client() {
    local endpoint="$1"
    local url="$2"
    local model="$3"
    local concurrency="$4"
    local results_dir="$5"

    echo -e "  ${BLUE}Running genai-perf benchmark locally pointed at ${url}...${NC}"

    local ctx_arg=""
    if [ -n "${CONTEXT_LENGTHS:-}" ]; then
        ctx_arg="--context-lengths ${CONTEXT_LENGTHS}"
    fi

    (
        cd "$SCRIPT_DIR/llm_tests"
        # shellcheck disable=SC2086
        ./run_genai_perf.sh \
            --endpoint "$endpoint" \
            --url "$url" \
            --model "$model" \
            --concurrency "$concurrency" \
            --input-tokens "$INPUT_TOKENS" \
            --output-tokens "$OUTPUT_TOKENS" \
            --num-prompts "$NUM_PROMPTS" \
            --results-dir "$results_dir" \
            $ctx_arg
    )
}

echo -e "${BLUE}==============================================================${NC}"
echo -e "${BLUE}   Puget Systems AI App Pack — Automated Benchmark Suite${NC}"
echo -e "${BLUE}==============================================================${NC}"
echo ""

# Test SSH connection
echo -e "${YELLOW}[0/6] Testing SSH connection to $HOST...${NC}"
if ! target_cmd "echo 'SSH connection successful'" >/dev/null; then
    echo -e "${RED}✗ SSH connection failed. Make sure you have key-based auth set up:${NC}"
    echo "   ssh-copy-id $HOST"
    exit 1
fi
echo -e "${GREEN}✓ Connected to $HOST.${NC}"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}⚠  DRY RUN MODE — no containers will be launched${NC}"
    echo ""
fi

# ============================================
# 0.5. Remote Preflight — Docker & NVIDIA Provisioning
# ============================================
# Check if Docker and nvidia-smi are both available remotely
NEED_PREFLIGHT=false
if ! target_cmd "command -v docker > /dev/null 2>&1"; then
    echo ""
    echo -e "${YELLOW}[0.5/6] Docker not found on remote server — running preflight provisioning...${NC}"
    echo -e "${YELLOW}  This will install Docker CE, NVIDIA drivers, and Container Toolkit.${NC}"
    NEED_PREFLIGHT=true
elif ! target_cmd "command -v nvidia-smi > /dev/null 2>&1"; then
    echo ""
    echo -e "${YELLOW}[0.5/6] NVIDIA drivers not found on remote server — running preflight...${NC}"
    NEED_PREFLIGHT=true
else
    echo -e "${GREEN}✓ Docker and NVIDIA drivers detected on remote server.${NC}"
fi

if [ "$NEED_PREFLIGHT" = true ]; then
    echo ""

    PREFLIGHT_SCRIPT="$SCRIPT_DIR/scripts/remote_preflight.sh"
    if [ ! -f "$PREFLIGHT_SCRIPT" ]; then
        echo -e "${RED}✗ Preflight script not found at $PREFLIGHT_SCRIPT${NC}"
        exit 1
    fi

    # Ask for sudo password locally (only once)
    read -s -p "  Enter sudo password for remote server ($HOST): " REMOTE_SUDO_PASS
    echo ""

    # Pass the password via heredoc stdin to avoid exposure in ps output
    run_preflight() {
        ssh "${SSH_OPTS[@]}" "$HOST" "bash -s" <<PREFLIGHT_STDIN
export SUDO_PASS='$(printf '%s' "$REMOTE_SUDO_PASS" | sed "s/'/'\\\\''/g")'
$(cat "$PREFLIGHT_SCRIPT")
PREFLIGHT_STDIN
    }

    # Helper to reboot and wait for server to come back
    reboot_and_wait() {
        echo ""
        echo -e "${YELLOW}NVIDIA drivers were installed. Rebooting remote server...${NC}"
        ssh "${SSH_OPTS[@]}" "$HOST" "sudo -S reboot" <<< "$REMOTE_SUDO_PASS" 2>/dev/null || true

        echo -e "${YELLOW}  Waiting for server to go down...${NC}"
        sleep 10

        echo -e "${YELLOW}  Waiting for server to come back (up to 3 minutes)...${NC}"
        local timeout=180 elapsed=0
        while [ $elapsed -lt $timeout ]; do
            if target_cmd "echo 'back'" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Server is back online.${NC}"
                return 0
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done

        echo -e "${RED}✗ Server did not come back after reboot within ${timeout}s.${NC}"
        echo "  Check the server console and try again."
        return 1
    }

    PREFLIGHT_EXIT=0
    run_preflight || PREFLIGHT_EXIT=$?

    if [ "$PREFLIGHT_EXIT" -eq 100 ]; then
        reboot_and_wait || exit 1

        # Wait for services to stabilize
        sleep 5

        # Re-run preflight to verify everything and configure Docker runtime
        echo ""
        echo -e "${YELLOW}  Re-running preflight to verify post-reboot state...${NC}"
        PREFLIGHT_EXIT=0
        run_preflight || PREFLIGHT_EXIT=$?

        if [ "$PREFLIGHT_EXIT" -ne 0 ]; then
            echo -e "${RED}✗ Post-reboot preflight verification failed (exit $PREFLIGHT_EXIT).${NC}"
            exit 1
        fi
    elif [ "$PREFLIGHT_EXIT" -ne 0 ]; then
        echo -e "${RED}✗ Remote preflight failed (exit $PREFLIGHT_EXIT). Cannot continue.${NC}"
        exit 1
    fi

    # Clear the sudo password from memory
    unset REMOTE_SUDO_PASS

    echo ""
    echo -e "${GREEN}✓ Remote server provisioned and ready.${NC}"
fi



# ============================================
# 1. Acquire App Pack Repository (Remote)
# ============================================
echo ""
echo -e "${YELLOW}[1/6] Acquiring App Pack repository on remote server...${NC}"

REMOTE_TEMP_DIR=$(target_cmd "mktemp -d")
cleanup() {
    echo ""
    echo -e "${DIM}Cleaning up remote temp directory...${NC}"
    target_cmd "rm -rf $REMOTE_TEMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$APP_PACK_REPO" == http* || "$APP_PACK_REPO" == git@* ]]; then
    echo -e "  Cloning ${BLUE}${APP_PACK_REPO}${NC} (branch: ${GREEN}${APP_PACK_BRANCH}${NC})..."
    # Ensure git is installed remotely
    if ! target_cmd "command -v git >/dev/null"; then
        echo -e "${RED}✗ git is not installed on the remote server.${NC}"
        exit 1
    fi
    if ! target_cmd "git clone --depth 1 --branch \"$APP_PACK_BRANCH\" \"$APP_PACK_REPO\" \"$REMOTE_TEMP_DIR/app-pack\" 2>&1 | tail -1"; then
        echo -e "${RED}✗ Failed to clone App Pack repository on remote server.${NC}"
        exit 1
    fi
elif [ -d "$APP_PACK_REPO" ]; then
    echo -e "  Syncing local repository ${BLUE}${APP_PACK_REPO}${NC} to remote server..."
    if ! rsync -a -e "ssh ${SSH_OPTS[*]}" --exclude=".git" "$APP_PACK_REPO/" "$HOST:$REMOTE_TEMP_DIR/app-pack/"; then
        echo -e "${RED}✗ Failed to rsync local repository to remote server.${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ APP_PACK_REPO is not a valid URL or local directory: ${APP_PACK_REPO}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository deployed to $REMOTE_TEMP_DIR/app-pack.${NC}"

PACK_ROOT="$REMOTE_TEMP_DIR/app-pack"

# ============================================
# 2. Integrity Check (MD5) - Remote
# ============================================
echo ""
echo -e "${YELLOW}[2/6] Verifying installer integrity on remote server...${NC}"

CHECKSUM_FILE="$PACK_ROOT/install.sh.md5"
if target_cmd "[ -f \"$CHECKSUM_FILE\" ]"; then
    EXPECTED_HASH=$(target_cmd "awk '{print \$1}' \"$CHECKSUM_FILE\"")
    # Determine hashing tool
    if target_cmd "command -v md5sum >/dev/null"; then
        ACTUAL_HASH=$(target_cmd "md5sum \"$PACK_ROOT/install.sh\" | awk '{print \$1}'")
    elif target_cmd "command -v md5 >/dev/null"; then
        ACTUAL_HASH=$(target_cmd "md5 -q \"$PACK_ROOT/install.sh\"")
    else
        echo -e "${YELLOW}⚠ No md5 tool found on remote server — skipping integrity check.${NC}"
        ACTUAL_HASH="$EXPECTED_HASH"
    fi

    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        echo -e "${RED}✗ Integrity check FAILED.${NC}"
        echo -e "  Expected MD5: ${EXPECTED_HASH}"
        echo -e "  Got MD5:      ${ACTUAL_HASH}"
        exit 1
    fi
    echo -e "${GREEN}✓ Installer integrity verified (MD5).${NC}"
else
    echo -e "${YELLOW}⚠ No checksum file found — skipping integrity check.${NC}"
fi

# ============================================
# 3. Detect Hardware (Remote via helper script)
# ============================================
echo ""
echo -e "${YELLOW}[3/6] Detecting hardware on remote server...${NC}"

# We execute a small inline script remotely that sources gpu_detect.sh and prints key variables back to us
GPU_INFO=$(target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\" && if detect_gpus; then echo \"OK|\$GPU_COUNT|\$TOTAL_VRAM|\$GPU_NAME|\$IS_BLACKWELL|\$COMPUTE_CAP\"; else echo \"FAIL\"; fi'")

if [[ "$GPU_INFO" == "FAIL" || -z "$GPU_INFO" ]]; then
    echo -e "${RED}✗ nvidia-smi not found or failed on remote server. GPU benchmarks require NVIDIA drivers.${NC}"
    exit 1
fi

IFS='|' read -r status GPU_COUNT TOTAL_VRAM GPU_NAME IS_BLACKWELL COMPUTE_CAP <<< "$GPU_INFO"

echo -e "${GREEN}✓ Found ${GPU_COUNT}x ${GPU_NAME} (${TOTAL_VRAM} GB total)${NC}"
if [ "$IS_BLACKWELL" = "true" ]; then
    echo -e "${GREEN}  Blackwell GPU detected (compute ${COMPUTE_CAP}) → using CUDA 13.0 paths${NC}"
fi

HF_MIRROR=""
if [ -n "$CACHE_PROXY" ]; then
    echo -e "${GREEN}✓ Cache Proxy: ${CACHE_PROXY}${NC}"
    # Derive HF mirror URL from proxy host (port 8090 = puget_hf_mirror)
    _PROXY_HOST=$(echo "$CACHE_PROXY" | sed 's|http://||;s|:.*||')
    HF_MIRROR="http://${_PROXY_HOST}:8090"
    # Verify the mirror is reachable
    if target_cmd "curl -sf --max-time 3 '${HF_MIRROR}/api/whoami' > /dev/null 2>&1"; then
        echo -e "${GREEN}✓ HF Mirror: ${HF_MIRROR} (model downloads will be cached)${NC}"
    else
        HF_MIRROR=""
        echo -e "${YELLOW}⚠ HF Mirror not reachable at ${_PROXY_HOST}:8090 — direct downloads${NC}"
    fi
fi

# Persistent model cache on remote host — survives across benchmark runs
MODEL_CACHE_DIR="/opt/puget-model-cache"
target_cmd "sudo mkdir -p '$MODEL_CACHE_DIR' && sudo chmod 775 '$MODEL_CACHE_DIR'" 2>/dev/null || \
    target_cmd "mkdir -p '$MODEL_CACHE_DIR'" 2>/dev/null || true

# System Specs Collection
TARGET_HOSTNAME=$(target_cmd "hostname -s 2>/dev/null || hostname")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MASTER_RESULTS_DIR="$SCRIPT_DIR/results/${TARGET_HOSTNAME}_${TIMESTAMP}"
mkdir -p "$MASTER_RESULTS_DIR"

SPEC_FILE="$MASTER_RESULTS_DIR/system_specs.txt"
source "$SCRIPT_DIR/scripts/collect_specs.sh"
collect_system_specs "target_cmd" "$SPEC_FILE" "$TARGET_HOSTNAME"

echo -e "${GREEN}✓ System specs saved to $SPEC_FILE.${NC}"

# ============================================
# 4. Build Test Matrix
# ============================================
echo ""
echo -e "${YELLOW}[4/6] Configuring test matrix...${NC}"

declare -a TEST_MATRIX=()

# Local functions to abstract the config generation that normally happens inside install.sh
# We can't interactively prompt the user from a remote bash session easily, so we parse options locally.
get_vllm_model_info() {
    local choice="$1"
    # Execute vllm_model_select.sh functions remotely and capture variables
    local remote_out
    remote_out=$(target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\"; detect_gpus >/dev/null; source \"$PACK_ROOT/scripts/lib/vllm_model_select.sh\"; if select_vllm_model \"$choice\" >/dev/null 2>&1; then echo \"OK|\$VLLM_MODEL_ID|\$VLLM_IMAGE|\$VLLM_GPU_COUNT|\$VLLM_GPU_MEM_UTIL|\$VLLM_DTYPE|\$VLLM_MAX_CTX|\$VLLM_REASONING_ARGS\"; else echo \"FAIL\"; fi'")
    
    if [[ "$remote_out" == FAIL* || -z "$remote_out" ]]; then
        return 1
    fi
    echo "$remote_out"
    return 0
}

define_run_all_matrix() {
    # ── Team LLM (vLLM) — mirrors app-pack vllm_model_select.sh choices 1-9 ───
    # Choice 1: Qwen 3.6 35B MoE AWQ — always available (22 GB)
    TEST_MATRIX+=("team_llm|1|Qwen3.6-35B-A3B-AWQ|22||$CONCURRENCY")

    # Choice 2: Qwen 3.5 35B MoE AWQ (22 GB)
    if [ "$TOTAL_VRAM" -ge 22 ]; then
        TEST_MATRIX+=("team_llm|2|Qwen3.5-35B-A3B-AWQ|22||$CONCURRENCY")
    fi

    # Choice 3: Qwen 3.5 122B MoE AWQ (80 GB)
    if [ "$TOTAL_VRAM" -ge 80 ]; then
        TEST_MATRIX+=("team_llm|3|Qwen3.5-122B-A10B-AWQ|80||$CONCURRENCY")
    fi

    # Choice 4: DeepSeek R1 70B AWQ (40 GB)
    if [ "$TOTAL_VRAM" -ge 40 ]; then
        TEST_MATRIX+=("team_llm|4|DeepSeek-R1-70B-AWQ|40||$CONCURRENCY")
    fi

    # Choice 5: Nemotron 3 Nano 30B NVFP4 (20 GB)
    TEST_MATRIX+=("team_llm|5|Nemotron3-Nano-30B-NVFP4|20||$CONCURRENCY")

    # Choice 6: Nemotron 3 Super 120B NVFP4 (80 GB)
    if [ "$TOTAL_VRAM" -ge 80 ]; then
        TEST_MATRIX+=("team_llm|6|Nemotron3-Super-120B-NVFP4|80||$CONCURRENCY")
    fi

    # Choice 7: Gemma 4 26B MoE AWQ (20 GB)
    if [ "$TOTAL_VRAM" -ge 20 ]; then
        TEST_MATRIX+=("team_llm|7|Gemma4-26B-A4B-AWQ|20||$CONCURRENCY")
    fi

    # Choice 8: GPT-OSS 20B MXFP4 (16 GB)
    TEST_MATRIX+=("team_llm|8|GPT-OSS-20B-MXFP4|16||$CONCURRENCY")

    # Choice 9: GPT-OSS 120B MXFP4 (80 GB)
    if [ "$TOTAL_VRAM" -ge 80 ]; then
        TEST_MATRIX+=("team_llm|9|GPT-OSS-120B-MXFP4|80||$CONCURRENCY")
    fi

    # ── Personal LLM (Ollama) — mirrors app-pack ollama_model_select.sh ─────
    if [ "$TOTAL_VRAM" -ge 24 ]; then
        TEST_MATRIX+=("personal_llm|1|qwen3.6:35b|24|qwen3.6:35b|1")
    fi
    if [ "$TOTAL_VRAM" -ge 42 ]; then
        TEST_MATRIX+=("personal_llm|2|deepseek-r1:70b|42|deepseek-r1:70b|1")
    fi
    if [ "$TOTAL_VRAM" -ge 63 ]; then
        TEST_MATRIX+=("personal_llm|3|llama4:scout|63|llama4:scout|1")
    fi
    if [ "$TOTAL_VRAM" -ge 24 ]; then
        TEST_MATRIX+=("personal_llm|4|nemotron-3-nano:30b|24|nemotron-3-nano:30b|1")
    fi
    if [ "$TOTAL_VRAM" -ge 96 ]; then
        TEST_MATRIX+=("personal_llm|5|nemotron-3-super|96|nemotron-3-super|1")
    fi
    if [ "$TOTAL_VRAM" -ge 20 ]; then
        TEST_MATRIX+=("personal_llm|6|gemma4:31b|20|gemma4:31b|1")
    fi

    # ── ComfyUI image generation ──────────────────────────────────────
    if [ "$TOTAL_VRAM" -ge 16 ]; then
        TEST_MATRIX+=("comfy_ui|z_image_turbo|Z-Image Turbo|16||1")
    fi
    if [ "$TOTAL_VRAM" -ge 40 ]; then
        TEST_MATRIX+=("comfy_ui|flux2_dev|Flux.2 Dev FP8|40||1")
    fi
}

run_comfyui_bench_client() {
    local workflow_name="$1"
    local url="$2"
    local results_dir="$3"

    local workflow_file="$SCRIPT_DIR/comfyui_tests/workflows/${workflow_name}_txt2img_api.json"
    if [ ! -f "$workflow_file" ]; then
        echo -e "  ${RED}✗ Workflow JSON not found: $workflow_file${NC}"
        return 1
    fi

    echo -e "  ${BLUE}Running ComfyUI benchmark locally pointed at ${url}...${NC}"
    chmod +x "$SCRIPT_DIR/comfyui_tests/run_comfyui_bench.sh"
    (
        cd "$SCRIPT_DIR/comfyui_tests"
        ./run_comfyui_bench.sh \
            --url "$url" \
            --workflow "$workflow_file" \
            --iterations "$COMFY_ITERATIONS" \
            --results-dir "$results_dir"
    )
}

download_if_missing() {
    local comfy_dir="$1"
    local dest_dir="$2"
    local url="$3"
    local filename
    filename=$(basename "$url")
    # Rewrite URL to use HF mirror if available
    local dl_url="$url"
    if [ -n "${HF_MIRROR:-}" ]; then
        dl_url=$(echo "$url" | sed "s|https://huggingface.co|${HF_MIRROR}|")
    fi
    target_cmd "bash -c '
        MODEL_CACHE_DIR=${MODEL_CACHE_DIR:-/opt/puget-model-cache}
        dest=\"$comfy_dir/$dest_dir/$filename\"
        cache=\"\$MODEL_CACHE_DIR/$dest_dir/$filename\"
        # Already in work dir
        if [ -f \"\$dest\" ]; then
            echo \"  ✓ $filename (ready)\"; exit 0
        fi
        # Pull from persistent cache
        if [ -f \"\$cache\" ]; then
            echo \"  ✓ $filename (from model cache)\"
            mkdir -p \"$comfy_dir/$dest_dir\"
            cp \"\$cache\" \"\$dest\"
            exit 0
        fi
        # Download fresh
        echo \"  Downloading $filename...\"
        mkdir -p \"\$MODEL_CACHE_DIR/$dest_dir\"
        wget -q --show-progress -O \"\$cache\" \"$dl_url\" 2>\&1
        wget_rc=\$?
        if [ \$wget_rc -eq 0 ]; then
            cp \"\$cache\" \"\$dest\"
        else
            rm -f \"\$cache\"
            echo \"  ✗ Download failed: $filename\"
            exit 1
        fi'"
}

show_ollama_model_menu() {
    if [ "$TOTAL_VRAM" -ge 24 ]; then
        echo "  1) Qwen 3.6 (35B MoE)    - Agentic coding, 256K ctx, thinking preservation (~24 GB) [New]"
    else
        echo -e "  1) Qwen 3.6 (35B MoE)    - ${RED}Requires ~24 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    if [ "$TOTAL_VRAM" -ge 42 ]; then
        echo "  2) DeepSeek R1 (70B)     - Flagship Reasoning, Dual GPU (~42 GB)"
    else
        echo -e "  2) DeepSeek R1 (70B)     - ${RED}Requires ~42 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    if [ "$TOTAL_VRAM" -ge 63 ]; then
        echo "  3) Llama 4 Scout         - Multimodal (text+image), Dual GPU (~63 GB)"
    else
        echo -e "  3) Llama 4 Scout         - ${RED}Requires ~63 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    if [ "$TOTAL_VRAM" -ge 24 ]; then
        echo "  4) Nemotron 3 Nano (30B) - NVIDIA MoE Reasoning, Single GPU (~24 GB)"
    else
        echo -e "  4) Nemotron 3 Nano (30B) - ${RED}Requires ~24 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    if [ "$TOTAL_VRAM" -ge 96 ]; then
        echo "  5) Nemotron 3 Super      - NVIDIA Flagship MoE, Multi-GPU (~96 GB)"
    else
        echo -e "  5) Nemotron 3 Super      - ${RED}Requires ~96 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    if [ "$TOTAL_VRAM" -ge 20 ]; then
        echo "  6) Gemma 4 (31B)         - Google Dense Instruct, Single GPU (~20 GB)"
    else
        echo -e "  6) Gemma 4 (31B)         - ${RED}Requires ~20 GB VRAM (you have ${TOTAL_VRAM} GB)${NC}"
    fi
    echo "  7) Custom tag            - Enter an Ollama model tag"
}

select_ollama_model() {
    local choice="$1"
    OLLAMA_MODEL_TAG=""
    OLLAMA_MODEL_VRAM_GB=0
    case $choice in
        1) OLLAMA_MODEL_TAG="qwen3.6:35b";        OLLAMA_MODEL_VRAM_GB=24 ;;
        2) OLLAMA_MODEL_TAG="deepseek-r1:70b";    OLLAMA_MODEL_VRAM_GB=42 ;;
        3) OLLAMA_MODEL_TAG="llama4:scout";        OLLAMA_MODEL_VRAM_GB=63 ;;
        4) OLLAMA_MODEL_TAG="nemotron-3-nano:30b"; OLLAMA_MODEL_VRAM_GB=24 ;;
        5) OLLAMA_MODEL_TAG="nemotron-3-super";    OLLAMA_MODEL_VRAM_GB=96 ;;
        6) OLLAMA_MODEL_TAG="gemma4:31b";          OLLAMA_MODEL_VRAM_GB=20 ;;
        7)
            read -p "  Enter Ollama model tag: " OLLAMA_MODEL_TAG
            OLLAMA_MODEL_VRAM_GB=0
            ;;
        *) return 1 ;;
    esac
    return 0
}

# Fetch vllm menu output from remote 
show_vllm_menu_remote() {
    target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\" >/dev/null 2>&1; detect_gpus >/dev/null 2>&1; source \"$PACK_ROOT/scripts/lib/vllm_model_select.sh\" >/dev/null 2>&1; show_vllm_model_menu'"
}

if [ "$RUN_ALL" = true ]; then
    echo -e "  Mode: ${GREEN}Run ALL${NC} (automatic VRAM-gated matrix)"
    define_run_all_matrix
    echo ""
    echo "  Test matrix (${#TEST_MATRIX[@]} benchmarks):"
    for entry in "${TEST_MATRIX[@]}"; do
        IFS='|' read -r e_pack e_choice e_name e_vram e_tag e_conc <<< "$entry"
        echo -e "    • ${GREEN}${e_pack}${NC} → ${e_name}"
    done
elif [ -n "$PACK" ]; then
    echo -e "  Mode: ${GREEN}Non-interactive${NC} (--pack ${PACK}, --model ${MODEL_CHOICE})"
    
    if [ "$PACK" = "team_llm" ]; then
        if [ -z "$MODEL_CHOICE" ]; then
            echo -e "${RED}✗ --model is required with --pack team_llm${NC}"
            exit 1
        fi
        TEST_MATRIX+=("team_llm|${MODEL_CHOICE}|${MODEL_CHOICE}|0||${CONCURRENCY}")
        
    elif [ "$PACK" = "personal_llm" ]; then
        if [ -z "$MODEL_CHOICE" ]; then
            echo -e "${RED}✗ --model is required with --pack personal_llm${NC}"
            exit 1
        fi
        if [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]]; then
            select_ollama_model "$MODEL_CHOICE"
            TEST_MATRIX+=("personal_llm|${MODEL_CHOICE}|${OLLAMA_MODEL_TAG}|0|${OLLAMA_MODEL_TAG}|1")
        else
            TEST_MATRIX+=("personal_llm|0|${MODEL_CHOICE}|0|${MODEL_CHOICE}|1")
        fi
    elif [ "$PACK" = "comfy_ui" ]; then
        # MODEL_CHOICE for comfy_ui is the workflow name
        case "${MODEL_CHOICE:-z_image_turbo}" in
            z_image_turbo|1) TEST_MATRIX+=("comfy_ui|z_image_turbo|Z-Image Turbo|16||1") ;;
            flux2_dev|2)     TEST_MATRIX+=("comfy_ui|flux2_dev|Flux.2 Dev FP8|40||1") ;;
            flux2_dev_multigpu|3) TEST_MATRIX+=("comfy_ui|flux2_dev_multigpu|Flux.2 Dev FP8 MultiGPU|40||1") ;;
            flux2_dev_distorch2|4) TEST_MATRIX+=("comfy_ui|flux2_dev_distorch2|Flux.2 Dev FP8 DisTorch2|40||1") ;;
            flux2_dev_2k|5) TEST_MATRIX+=("comfy_ui|flux2_dev_2k|Flux.2 Dev FP8 2K|40||1") ;;
            flux2_dev_multigpu_2k|6) TEST_MATRIX+=("comfy_ui|flux2_dev_multigpu_2k|Flux.2 Dev FP8 MultiGPU 2K|40||1") ;;
            flux2_dev_distorch2_2k|7) TEST_MATRIX+=("comfy_ui|flux2_dev_distorch2_2k|Flux.2 Dev FP8 DisTorch2 2K|40||1") ;;
            *)
                echo -e "${RED}✗ Unknown comfy_ui model: ${MODEL_CHOICE}${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}✗ Unknown pack: ${PACK}.${NC}"; exit 1
    fi
else
    # Interactive Flow on local Mac
    echo -e "  Mode: ${GREEN}Interactive${NC}"
    echo ""
    echo "  Select an App Pack to benchmark:"
    echo "    1) Team LLM (vLLM)       — Production inference"
    echo "    2) Personal LLM (Ollama) — Single-user inference"
    echo "    3) ComfyUI (Image Gen)   — Z-Image Turbo / Flux.2 Dev"
    echo "    4) Run ALL               — Full test matrix"
    echo ""
    read -p "  Select [1-4]: " PACK_CHOICE

    case $PACK_CHOICE in
        1)
            PACK="team_llm"
            echo ""
            echo "  Select a model for vLLM:"
            echo ""
            show_vllm_menu_remote
            echo ""
            read -p "  Select [1-11]: " MODEL_CHOICE
            if [[ "$MODEL_CHOICE" =~ ^(10|11)$ ]]; then
                if [ "$MODEL_CHOICE" = "10" ]; then
                    read -p "  Enter HuggingFace model ID: " CUSTOM_MODEL
                    TEST_MATRIX+=("team_llm|custom|${CUSTOM_MODEL}|0||${CONCURRENCY}")
                else
                    echo "Exiting."; exit 0
                fi
            else
                TEST_MATRIX+=("team_llm|${MODEL_CHOICE}|Menu_Choice_${MODEL_CHOICE}|0||${CONCURRENCY}")
            fi
            ;;
        2)
            PACK="personal_llm"
            echo ""
            echo "  Select a model for Ollama:"
            echo ""
            show_ollama_model_menu
            echo ""
            read -p "  Select [1-7]: " MODEL_CHOICE
            if select_ollama_model "$MODEL_CHOICE"; then
                TEST_MATRIX+=("personal_llm|${MODEL_CHOICE}|${OLLAMA_MODEL_TAG}|0|${OLLAMA_MODEL_TAG}|1")
            else
                echo -e "${RED}✗ Invalid selection.${NC}"; exit 1
            fi
            ;;
        3)
            PACK="comfy_ui"
            echo ""
            echo "  Select a model for ComfyUI:"
            echo "    1) Z-Image Turbo (BF16) — Fast, high quality (~16 GB VRAM) [Recommended]"
            if [ "$TOTAL_VRAM" -ge 40 ]; then
                echo "    2) Flux.2 Dev (FP8)     — Flagship image gen (~40 GB VRAM)"
            else
                echo -e "    2) Flux.2 Dev (FP8)     — ${RED}Requires ~40 GB VRAM${NC}"
            fi
            echo ""
            read -p "  Select [1-2]: " COMFY_CHOICE
            case $COMFY_CHOICE in
                1) TEST_MATRIX+=("comfy_ui|z_image_turbo|Z-Image Turbo|16||1") ;;
                2)
                    if [ "$TOTAL_VRAM" -lt 40 ]; then
                        echo -e "${RED}✗ Insufficient VRAM for Flux.2 Dev (need ~40 GB, have ${TOTAL_VRAM} GB).${NC}"
                        exit 1
                    fi
                    TEST_MATRIX+=("comfy_ui|flux2_dev|Flux.2 Dev FP8|40||1")
                    ;;
                *) echo -e "${RED}✗ Invalid selection.${NC}"; exit 1 ;;
            esac
            ;;
        4)
            RUN_ALL=true
            define_run_all_matrix
            ;;
        *) echo -e "${RED}Invalid selection.${NC}"; exit 1 ;;
    esac
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${GREEN}  DRY RUN COMPLETE — validation passed${NC}"
    echo -e "${GREEN}==============================================================${NC}"
    echo "  Target Host:     $HOST"
    echo "  App Pack repo:   ✓ Cloned and verified to $REMOTE_TEMP_DIR"
    echo "  GPU detection:   ✓ ${GPU_COUNT}x ${GPU_NAME} (${TOTAL_VRAM} GB)"
    echo "  Cache proxy:     ${CACHE_PROXY:-not configured}"
    echo "  Test matrix:     ${#TEST_MATRIX[@]} benchmark(s)"
    echo "  Results dir:     $MASTER_RESULTS_DIR"
    rm -rf "$MASTER_RESULTS_DIR"
    exit 0
fi

# ============================================
# 5. Execute Benchmarks
# ============================================
echo ""
# Ensure run_genai_perf.sh is executable once
chmod +x "$SCRIPT_DIR/llm_tests/run_genai_perf.sh"

echo -e "${YELLOW}[5/6] Running benchmarks...${NC}"
echo ""

BENCH_COUNT=0
BENCH_TOTAL=${#TEST_MATRIX[@]}
FAILED_BENCHMARKS=()

for entry in "${TEST_MATRIX[@]}"; do
    IFS='|' read -r BENCH_PACK BENCH_CHOICE BENCH_MODEL BENCH_MIN_VRAM BENCH_OLLAMA_TAG BENCH_CONCURRENCY <<< "$entry"
    BENCH_COUNT=$((BENCH_COUNT + 1))

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Benchmark ${BENCH_COUNT}/${BENCH_TOTAL}: ${BENCH_PACK} → ${BENCH_MODEL}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    SAFE_MODEL_NAME=$(echo "$BENCH_MODEL" | tr '/:' '_')
    BENCH_RESULTS_DIR="$MASTER_RESULTS_DIR/${BENCH_PACK}_${SAFE_MODEL_NAME}"
    mkdir -p "$BENCH_RESULTS_DIR"

    if [ "$BENCH_PACK" != "comfy_ui" ]; then
        WORK_DIR="$REMOTE_TEMP_DIR/bench_${BENCH_PACK}_${SAFE_MODEL_NAME}"
        target_cmd "cp -r \"$PACK_ROOT/packs/$BENCH_PACK\" \"$WORK_DIR\""
        target_cmd "mkdir -p \"$WORK_DIR/scripts/lib\" && cp \"$PACK_ROOT/scripts/lib/\"*.sh \"$WORK_DIR/scripts/lib/\""
    fi

    if [ "$BENCH_PACK" = "team_llm" ]; then
        if [[ "$BENCH_CHOICE" == "custom" || ! "$BENCH_CHOICE" =~ ^[0-9]+$ ]]; then
            # Custom model
            target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
MODEL_ID=${BENCH_MODEL}
VLLM_IMAGE=latest
GPU_COUNT=${GPU_COUNT}
GPU_MEMORY_UTILIZATION=0.90
DTYPE=auto
REASONING_ARGS=
TOOL_CALL_ARGS=
EXTRA_VLLM_ARGS=
MAX_CONTEXT=
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
HF_ENDPOINT=${HF_MIRROR}
ENVEOF
        else
            vllm_info=$(get_vllm_model_info "$BENCH_CHOICE") || { echo -e "${RED}✗ Required ${BENCH_MIN_VRAM}GB VRAM for choice $BENCH_CHOICE. Skip.${NC}"; continue; }
            IFS='|' read -r status m_id m_img m_gpus m_mem m_dtype m_ctx m_reason <<< "$vllm_info"
            BENCH_MODEL="$m_id" # update to true ID
            target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
MODEL_ID=${m_id}
VLLM_IMAGE=${m_img}
GPU_COUNT=${m_gpus}
GPU_MEMORY_UTILIZATION=${m_mem}
DTYPE=${m_dtype}
MAX_CONTEXT=${m_ctx}
REASONING_ARGS=${m_reason}
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
HF_ENDPOINT=${HF_MIRROR}
ENVEOF
        fi

        echo -e "  ${BLUE}Starting vLLM on remote server...${NC}"
        target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null; docker compose up -d"
        echo ""

        echo -e "  ${YELLOW}Waiting for model to load by invoking vllm_monitor remotely...${NC}"
        target_cmd "bash -c 'source \"$WORK_DIR/scripts/lib/vllm_monitor.sh\" && wait_for_vllm \"puget_vllm\" \"0\"'"

        if ! target_cmd "curl -s --max-time 5 http://localhost:8000/v1/models > /dev/null 2>&1"; then
            echo -e "  ${RED}✗ vLLM API not responding. Skipping.${NC}"
            target_cmd "cd \"$WORK_DIR\" && docker compose logs --tail 20"
            target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null"
            FAILED_BENCHMARKS+=("$BENCH_MODEL (vLLM failed)")
            continue
        fi

        API_MODEL=$(target_cmd "curl -s http://localhost:8000/v1/models 2>/dev/null | grep -o '\"id\":\"[^\"]*' | head -n 1 | cut -d'\"' -f4" || echo "$BENCH_MODEL")

        echo ""
        if ! run_genai_perf_client "vllm" "${BENCH_URL_BASE}:8000" "$API_MODEL" "$BENCH_CONCURRENCY" "$BENCH_RESULTS_DIR"; then
            echo -e "  ${RED}✗ genai-perf failed for ${BENCH_MODEL}${NC}"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (genai-perf failed)")
        fi

        target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null"

    elif [ "$BENCH_PACK" = "personal_llm" ]; then
        target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
PUGET_APP_NAME=puget-bench-ollama
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
ENVEOF

        echo -e "  ${BLUE}Starting Ollama on remote server...${NC}"
        target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null; docker compose up -d"

        echo -e "  ${YELLOW}Waiting for Ollama API...${NC}"
        # Remote wait loop - ensure bash is used on remote for brace expansion
        if ! target_cmd "bash -c 'for i in {1..60}; do curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'"; then
             echo -e "  ${RED}✗ Ollama API not responding. Skipping.${NC}"
             target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null"
             FAILED_BENCHMARKS+=("$BENCH_OLLAMA_TAG (Ollama failed)")
             continue
        fi

        echo -e "  ${BLUE}Pulling remote model: ${BENCH_OLLAMA_TAG}...${NC}"
        if ! target_cmd "docker exec puget_ollama ollama pull \"$BENCH_OLLAMA_TAG\""; then
             echo -e "  ${RED}✗ Failed to pull remote model. Skipping.${NC}"
             target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null"
             FAILED_BENCHMARKS+=("$BENCH_OLLAMA_TAG (pull failed)")
             continue
        fi

        echo ""
        if ! run_genai_perf_client "ollama" "${BENCH_URL_BASE}:11434" "$BENCH_OLLAMA_TAG" "$BENCH_CONCURRENCY" "$BENCH_RESULTS_DIR"; then
             echo -e "  ${RED}✗ genai-perf failed for ${BENCH_OLLAMA_TAG}${NC}"
             FAILED_BENCHMARKS+=("${BENCH_OLLAMA_TAG} (genai-perf failed)")
        fi

        target_cmd "cd \"$WORK_DIR\" && docker compose down 2>/dev/null"

    elif [ "$BENCH_PACK" = "comfy_ui" ]; then
        # ── ComfyUI: pre-download models, build, launch, benchmark, teardown ──

        # Map workflow name → model files (mirrors init.sh EXTRA_DOWNLOADS logic)
        COMFY_WORK_DIR="$REMOTE_TEMP_DIR/bench_comfy_ui_${BENCH_CHOICE}"
        target_cmd "cp -r \"$PACK_ROOT/packs/comfy_ui\" \"$COMFY_WORK_DIR\""
        target_cmd "mkdir -p \"$COMFY_WORK_DIR/scripts/lib\" && cp \"$PACK_ROOT/scripts/lib/\"*.sh \"$COMFY_WORK_DIR/scripts/lib/\""

        # Create model subdirectories
        for model_dir in models/diffusion_models models/vae models/text_encoders models/loras models/checkpoints; do
            target_cmd "mkdir -p \"$COMFY_WORK_DIR/$model_dir\""
        done

        echo -e "  ${BLUE}Pre-downloading models for ${BENCH_MODEL}...${NC}"

        case "$BENCH_CHOICE" in
            z_image_turbo)
                download_if_missing "$COMFY_WORK_DIR" "models/diffusion_models" \
                    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors"
                download_if_missing "$COMFY_WORK_DIR" "models/vae" \
                    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors"
                download_if_missing "$COMFY_WORK_DIR" "models/text_encoders" \
                    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
                ;;
            flux2_dev|flux2_dev_multigpu|flux2_dev_distorch2|flux2_dev_2k|flux2_dev_multigpu_2k|flux2_dev_distorch2_2k)
                # Choose text encoder based on per-GPU VRAM (ComfyUI uses single GPU)
                PER_GPU_VRAM=$((TOTAL_VRAM / GPU_COUNT))
                if [ "$PER_GPU_VRAM" -ge 48 ]; then
                    FLUX2_TEXT_ENC="mistral_3_small_flux2_bf16.safetensors"
                else
                    FLUX2_TEXT_ENC="mistral_3_small_flux2_fp8.safetensors"
                    echo -e "  ${YELLOW}Note: Using FP8 text encoder (${PER_GPU_VRAM} GB per-GPU VRAM).${NC}"
                fi
                download_if_missing "$COMFY_WORK_DIR" "models/diffusion_models" \
                    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/diffusion_models/flux2_dev_fp8mixed.safetensors"
                download_if_missing "$COMFY_WORK_DIR" "models/vae" \
                    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
                download_if_missing "$COMFY_WORK_DIR" "models/text_encoders" \
                    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/text_encoders/${FLUX2_TEXT_ENC}"
                download_if_missing "$COMFY_WORK_DIR" "models/loras" \
                    "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/loras/Flux_2-Turbo-LoRA_comfyui.safetensors"
                ;;
            *)
                echo -e "  ${RED}✗ Unknown comfy_ui workflow: ${BENCH_CHOICE}. Skipping.${NC}"
                FAILED_BENCHMARKS+=("$BENCH_MODEL (unknown workflow)")
                continue
                ;;
        esac

        # Install ComfyUI-MultiGPU extension if needed for multi-GPU workflows
        case "$BENCH_CHOICE" in
            *multigpu*|*distorch2*)
                if ! target_cmd "test -d '$COMFY_WORK_DIR/custom_nodes/ComfyUI-MultiGPU'"; then
                    echo -e "  ${BLUE}Installing ComfyUI-MultiGPU custom node...${NC}"
                    target_cmd "git clone --depth 1 https://github.com/pollockjj/ComfyUI-MultiGPU.git '$COMFY_WORK_DIR/custom_nodes/ComfyUI-MultiGPU'"
                    target_cmd "chmod -R 775 '$COMFY_WORK_DIR/custom_nodes/ComfyUI-MultiGPU'"
                    echo -e "  ${GREEN}✓ ComfyUI-MultiGPU installed.${NC}"
                fi
                ;;
        esac

        # Workaround: numpy 2.4.x has a "cannot load module more than once" bug on Python 3.12
        # Pin numpy<2.4 in the Dockerfile before PyTorch install picks up an incompatible version
        target_cmd "grep -q 'numpy<2.4' \"$COMFY_WORK_DIR/Dockerfile\" || sed -i '/^RUN pip install.*torch.*torchvision/i RUN pip install --no-cache-dir \"numpy<2.4\"' \"$COMFY_WORK_DIR/Dockerfile\""

        # Build container (smart_build skips if fingerprint unchanged)
        echo -e "  ${BLUE}Building ComfyUI container on remote server (smart build)...${NC}"
        target_cmd "bash -c 'source \"$COMFY_WORK_DIR/scripts/lib/smart_build.sh\" && cd \"$COMFY_WORK_DIR\" && smart_build'"

        # Launch
        echo -e "  ${BLUE}Starting ComfyUI on remote server...${NC}"
        # Fix ownership on volume-mount dirs (container runs as UID 999, GID 1500)
        target_cmd "mkdir -p \"$COMFY_WORK_DIR/output\" \"$COMFY_WORK_DIR/input\" \"$COMFY_WORK_DIR/custom_nodes\""
        target_cmd "chmod -R 775 \"$COMFY_WORK_DIR/output\" \"$COMFY_WORK_DIR/input\" 2>/dev/null || true"
        target_cmd "cd \"$COMFY_WORK_DIR\" && docker compose down 2>/dev/null; docker compose up -d"

        # Wait for API (port 8188)
        echo -e "  ${YELLOW}Waiting for ComfyUI API on port 8188...${NC}"
        if ! target_cmd "bash -c 'for i in {1..60}; do curl -s --max-time 3 http://localhost:8188/api/system_stats >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1'"; then
            echo -e "  ${RED}✗ ComfyUI API not responding after 300s. Skipping.${NC}"
            target_cmd "cd \"$COMFY_WORK_DIR\" && docker compose logs --tail 20"
            target_cmd "cd \"$COMFY_WORK_DIR\" && docker compose down 2>/dev/null"
            FAILED_BENCHMARKS+=("$BENCH_MODEL (ComfyUI failed to start)")
            continue
        fi
        echo -e "  ${GREEN}✓ ComfyUI API ready.${NC}"

        echo ""
        if ! run_comfyui_bench_client "$BENCH_CHOICE" "${BENCH_URL_BASE}:8188" "$BENCH_RESULTS_DIR"; then
            echo -e "  ${RED}✗ ComfyUI benchmark failed for ${BENCH_MODEL}${NC}"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (benchmark failed)")
        fi

        target_cmd "cd \"$COMFY_WORK_DIR\" && docker compose down 2>/dev/null"
    fi
done

# ============================================
# 6. Generate Consolidated Report
# ============================================
echo -e "${YELLOW}[6/6] Generating consolidated report...${NC}"
SUMMARY_SCRIPT="$SCRIPT_DIR/llm_tests/generate_summary.py"
if [ -f "$SUMMARY_SCRIPT" ]; then
    python3 "$SUMMARY_SCRIPT" "$MASTER_RESULTS_DIR" "$SPEC_FILE" || true
fi

echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}  Benchmarks Complete!${NC}"
echo -e "${GREEN}==============================================================${NC}"
echo "  Results: $MASTER_RESULTS_DIR"

if [ ${#FAILED_BENCHMARKS[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}The following benchmarks FAILED:${NC}"
    for fail in "${FAILED_BENCHMARKS[@]}"; do
        echo -e "  ${RED}• $fail${NC}"
    done
    echo ""
fi