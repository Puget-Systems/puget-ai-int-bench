#!/bin/bash

# Puget Systems AI App Pack — Automated Benchmark Suite
#
# End-to-end benchmark orchestrator: detects hardware, downloads/launches an
# App Pack, benchmarks it (genai-perf, co-located on the GPU box for accurate
# TTFT), and tears it down. Runs ON the box by default (no SSH); --host targets
# a separate machine over SSH.
#
# Usage:
#   ./run_benchmarks.sh                                    # On-box, interactive (run at the hardware)
#   ./run_benchmarks.sh --run-all                          # On-box, full VRAM-gated matrix
#   ./run_benchmarks.sh --host USER@IP                     # Remote mode over SSH
#   ./run_benchmarks.sh --pack team_llm --model 2          # On-box, non-interactive

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
VERSION="1.6.1"
APP_PACK_REPO="https://github.com/Puget-Systems/puget-docker-app-packs.git"
APP_PACK_BRANCH="main"
# Lab cache host (DGX Spark): Olah HF mirror on :8090, Squid HTTP proxy on :3128
# (puget-hypervisor-devops/terraform). Internal DNS name assigned by IT; resolves to
# the Spark (currently 172.19.168.179) on-network. Auto-probed and used when reachable,
# silently skipped otherwise. Override per-run with --cache-proxy or CACHE_PROXY in bench.conf.
DEFAULT_CACHE_HOST="${PUGET_CACHE_HOST:-lab-cache.puget.systems}"
# Absolute backstop on the load wait. The real bound is stall-based (vllm_monitor
# fails after VLLM_STALL_SECONDS of no progress), which correctly distinguishes a
# slow-but-progressing cold load from a hang. This flat ceiling only catches the rare
# case where the monitor itself wedges, so keep it generous (2h) — a legitimate cold
# ~140 GB download + load can run well past the old 30-min value.
MODEL_LOAD_TIMEOUT="${MODEL_LOAD_TIMEOUT:-7200}"
VLLM_STALL_SECONDS="${VLLM_STALL_SECONDS:-600}"  # no-progress window passed to the monitor
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
DOCTOR=false
CONCURRENCY="1,4,8,16"
SSH_KEY=""
INPUT_TOKENS=500
OUTPUT_TOKENS=500
NUM_PROMPTS=50
MEASUREMENT_INTERVAL=30000
MEASUREMENT_INTERVAL_SET=false   # true once the user passes --measurement-interval
COMFY_ITERATIONS=10
CONTEXT_LENGTHS=""  # e.g. "4096,32768,131072" — empty = use INPUT_TOKENS only
SKIP_CHECKSUM=false
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}}"  # respect an inherited env token; else bench.conf / --hf-token / cache / prompt
HF_TOKEN_SOURCE=""  # where the token came from (for reporting)
SUDO_PASS=""        # Remote sudo password — load from bench.conf or --sudo-pass flag
NO_LOCAL_DOCKER=false  # Set by local preflight if Docker is unavailable
FRESH_CACHE=false      # If true, clear model caches before running (default: keep cache)
REQUEST_TIMEOUT=""     # Per-request timeout (seconds) for genai-perf — extend for thinking models
GPU_COUNT_OVERRIDE=""  # Force a specific GPU count for custom models (e.g. 1 = single-GPU TP=1)
DTYPE_OVERRIDE=""      # Force model dtype (e.g. float16 — Intel XPU vLLM cannot serve bfloat16)
MAX_MODEL_LEN=""       # Cap vLLM --max-model-len (KV-cache headroom for large-context models)
RESUME_DIR=""          # Prior results dir: skip (pack, model) entries that have a .done marker there
SKIP_DRIVER_CHECK=false  # Bypass the host-driver vs container-CUDA gate (debug only)
DOCKER_COMPOSE=""      # Resolved Compose command on the target ("docker compose" or "docker-compose")

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
        --doctor) DOCTOR=true ;;
        --concurrency) CONCURRENCY="$2"; shift ;;
        --repo) APP_PACK_REPO="$2"; shift ;;
        --branch) APP_PACK_BRANCH="$2"; shift ;;
        --input-tokens) INPUT_TOKENS="$2"; shift ;;
        --output-tokens) OUTPUT_TOKENS="$2"; shift ;;
        --num-prompts) NUM_PROMPTS="$2"; shift ;;
        --measurement-interval) MEASUREMENT_INTERVAL="$2"; MEASUREMENT_INTERVAL_SET=true; shift ;;
        --ssh-key) SSH_KEY="$2"; shift ;;
        --comfy-iterations) COMFY_ITERATIONS="$2"; shift ;;
        --context-lengths) CONTEXT_LENGTHS="$2"; shift ;;
        --skip-checksum) SKIP_CHECKSUM=true ;;
        --fresh-cache) FRESH_CACHE=true ;;
        --hf-token) HF_TOKEN="$2"; shift ;;
        --sudo-pass) SUDO_PASS="$2"; shift ;;
        --request-timeout) REQUEST_TIMEOUT="$2"; shift ;;
        --gpu-count) GPU_COUNT_OVERRIDE="$2"; shift ;;
        --dtype) DTYPE_OVERRIDE="$2"; shift ;;
        --max-model-len) MAX_MODEL_LEN="$2"; shift ;;
        --resume) RESUME_DIR="$2"; shift ;;
        --skip-driver-check) SKIP_DRIVER_CHECK=true ;;
        -v|--version) echo "run_benchmarks.sh — Puget AI App Pack bench v${VERSION}"; exit 0 ;;
        -h|--help)
            echo -e "${BLUE}Puget Systems AI App Pack — Automated Benchmark Suite v${VERSION}${NC}"
            echo ""
            echo "Usage:"
            echo "  ./run_benchmarks.sh                                  On-box mode — run on THIS machine (interactive)"
            echo "  ./run_benchmarks.sh --run-all                        On-box mode — full VRAM-gated matrix"
            echo "  ./run_benchmarks.sh --host USER@IP                   Remote mode — orchestrate a separate box over SSH"
            echo "  ./run_benchmarks.sh --doctor                         Readiness check only — verify the box can run, then exit"
            echo ""
            echo "Options:"
            echo "  --host USER@IP       Remote SSH target. Omit (or use --host local) to run on this machine."
            echo "  --cache-proxy URL    Override the cache host (Squid :3128 + HF mirror :8090)."
            echo "                       The lab cache is auto-detected when reachable; this is only"
            echo "                       needed to point at a different host."
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
            echo "  --fresh-cache        Clear model caches before running (default: keep cached models)"
            echo "  --resume DIR         Skip (pack, model) entries already completed in a prior results dir"
            echo "  --skip-driver-check  Bypass the host-driver vs container-CUDA compatibility gate"
            echo "  -v, --version        Print the bench suite version and exit"
            exit 0
            ;;
        *) echo -e "${RED}Unknown parameter: $1. Use --help for usage.${NC}"; exit 1 ;;
    esac
    shift
done

# On-box (local) mode runs everything on THIS machine with no SSH — the intended
# path for an integration specialist sitting at the hardware under test. Remote
# mode (--host USER@IP) still works for orchestrating a separate box.
LOCAL_MODE=false
case "$HOST" in
    ""|local|localhost|127.0.0.1) LOCAL_MODE=true ;;
esac

# Extract IP/hostname from USER@IP format (localhost in on-box mode)
if [ "$LOCAL_MODE" = true ]; then
    REMOTE_IP="localhost"
else
    REMOTE_IP="${HOST#*@}"
fi
BENCH_URL_BASE="http://${REMOTE_IP}"

# ============================================
# Command Execution Helpers
# ============================================
declare -a SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

# target_cmd runs a command on the target machine. In on-box (local) mode this
# is a local shell; in remote mode it is an SSH call. Callers pass a single
# command string and may pipe a heredoc on stdin — both forms preserve stdin.
target_cmd() {
    if [ "$LOCAL_MODE" = true ]; then
        bash -c "$*"
    else
        ssh "${SSH_OPTS[@]}" "$HOST" "$@"
    fi
}

# push_file SRC DEST — copy a local file to the target.
push_file() {
    if [ "$LOCAL_MODE" = true ]; then
        cp "$1" "$2"
    else
        scp "${SSH_OPTS[@]}" "$1" "$HOST:$2" >/dev/null 2>&1
    fi
}

# pull_dir SRC_DIR DEST_DIR — copy a results directory from the target back.
pull_dir() {
    mkdir -p "$2"
    if [ "$LOCAL_MODE" = true ]; then
        cp -a "$1/." "$2/" 2>/dev/null || true
    else
        rsync -a -e "ssh ${SSH_OPTS[*]}" "$HOST:$1/" "$2/" 2>/dev/null || true
    fi
}

# resolve_hf_token MODE — populate HF_TOKEN. Order: existing flag/env/bench.conf value,
# then the local huggingface-cli cache (~/.cache/huggingface/token etc.). In MODE=prompt
# with a TTY, prompt for one and offer to persist it to bench.conf. Resolution happens on
# the launching machine, so the token is forwarded to a remote box via the .env we write.
# MODE=quiet never prompts (used by --doctor). Safe in batch/nohup: the prompt is gated on
# an interactive stdin, so it no-ops there.
resolve_hf_token() {
    local mode="${1:-quiet}" f
    if [ -n "${HF_TOKEN:-}" ]; then
        [ -z "$HF_TOKEN_SOURCE" ] && HF_TOKEN_SOURCE="flag/env/config"
        return 0
    fi
    for f in "${HF_TOKEN_PATH:-}" "${HF_HOME:+$HF_HOME/token}" "$HOME/.cache/huggingface/token" "$HOME/.huggingface/token"; do
        if [ -n "$f" ] && [ -f "$f" ]; then
            HF_TOKEN=$(tr -d '[:space:]' < "$f" 2>/dev/null)
            if [ -n "$HF_TOKEN" ]; then HF_TOKEN_SOURCE="$f"; return 0; fi
        fi
    done
    if [ "$mode" = "prompt" ] && [ -t 0 ]; then
        echo -e "${YELLOW}No HuggingFace token found${NC} — gated models (some Llama/Gemma) need one for tokenizer/weight access."
        read -r -s -p "  Paste an HF token (or press Enter to skip gated models): " HF_TOKEN
        echo ""
        if [ -n "$HF_TOKEN" ]; then
            HF_TOKEN_SOURCE="prompt"
            local _save
            read -r -p "  Save it to ${CONFIG_FILE} for next time? [y/N] " _save
            if [[ "$_save" =~ ^[Yy]$ ]]; then
                mkdir -p "$CONFIG_DIR"
                [ -f "$CONFIG_FILE" ] && grep -v '^HF_TOKEN=' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
                echo "HF_TOKEN=${HF_TOKEN}" >> "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE" 2>/dev/null || true
                echo -e "  ${GREEN}✓ Saved to ${CONFIG_FILE}${NC}"
            fi
        fi
    fi
    [ -z "${HF_TOKEN:-}" ] && HF_TOKEN_SOURCE="none"
    return 0
}

# ── Driver ↔ container-CUDA compatibility gate ────────────────────────────
# Different models resolve to different container images (stable vs cu130-nightly),
# and those images need different minimum host drivers. The mapping lives in the
# app-pack (gpu_detect.sh min_driver_for_image); this local copy is the fallback
# for older app-pack branches that predate it. Keep the two in sync.
bench_min_driver_for_image() {
    case "$1" in
        *cu130*)            echo 580 ;;   # CUDA 13.0 (Blackwell nightly line)
        *cu128*|*cu129*)    echo 570 ;;
        vllm/vllm-openai:*) echo 570 ;;   # stable/latest/nightly are CUDA 12.8+ builds
        *) ;;                             # ROCm/XPU/unknown: no NVIDIA driver gate
    esac
}

# bench_driver_ok IMAGE — return 0 when the host driver can run IMAGE (or when
# either side is unknown; a missing data point must never block a benchmark —
# the container launch will surface a real mismatch, which we then classify).
# Sets BENCH_DRIVER_MIN for the caller's error message.
bench_driver_ok() {
    BENCH_DRIVER_MIN=$(bench_min_driver_for_image "$1")
    [ "$SKIP_DRIVER_CHECK" = true ] && return 0
    [ -z "$BENCH_DRIVER_MIN" ] && return 0
    [ "${GPU_VENDOR:-nvidia}" = "nvidia" ] || return 0
    local major="${DRIVER_VERSION:-}"; major="${major%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 0
    [ "$major" -ge "$BENCH_DRIVER_MIN" ]
}

# diagnose_failure WORK_DIR LABEL — dump the container log tail, then grep it for
# known failure signatures and print a plain-language diagnosis + fix. This is what
# an integration tech sees instead of 200 raw log lines with no interpretation.
diagnose_failure() {
    local work_dir="$1" label="${2:-server}" logs
    logs=$(target_cmd "cd \"$work_dir\" && ${DOCKER_COMPOSE} logs --tail 200 2>/dev/null" 2>/dev/null) || true
    echo "$logs" | tail -60
    echo ""
    echo -e "  ${YELLOW}── Diagnosis ─────────────────────────────────────────────${NC}"
    if echo "$logs" | grep -qiE 'no kernel image is available'; then
        echo -e "  ${RED}Driver/CUDA mismatch:${NC} the container's CUDA build has no kernels for this GPU"
        echo -e "  or the host driver is too old for the container's CUDA runtime."
        echo -e "  Fix: upgrade the NVIDIA driver (cu130 images need ≥580), or pick a model"
        echo -e "  that uses the stable image. Installed driver: ${DRIVER_VERSION:-unknown}."
    elif echo "$logs" | grep -qiE 'driver/library version mismatch'; then
        echo -e "  ${RED}Driver was updated but the old kernel module is still loaded.${NC}"
        echo -e "  Fix: reboot the box, then re-run."
    elif echo "$logs" | grep -qiE 'CUDA out of memory|HIP out of memory|max seq len.*KV cache|No available memory for the cache'; then
        echo -e "  ${RED}Out of GPU memory (weights + KV cache don't fit).${NC}"
        echo -e "  Fix: re-run with --max-model-len 32768 (or lower), or a smaller model."
    elif echo "$logs" | grep -qiE '401|403|gated|GatedRepo|Access to model.*restricted'; then
        echo -e "  ${RED}HuggingFace auth failure — this model is gated.${NC}"
        echo -e "  Fix: set a token with access (HF_TOKEN in ~/.config/puget-bench/bench.conf,"
        echo -e "  or huggingface-cli login), then re-run. Token status: ${HF_TOKEN_SOURCE:-none}."
    elif echo "$logs" | grep -qiE 'NCCL|P2P.*(hang|fail|timeout)'; then
        echo -e "  ${RED}NCCL / GPU peer-to-peer failure during multi-GPU init.${NC}"
        echo -e "  Fix: usually NCCL_P2P_DISABLE=1 (the bench sets this on PCIe-only boxes);"
        echo -e "  if it persists, re-run with --gpu-count 1 to isolate."
    elif echo "$logs" | grep -qiE 'model type .* not recognized|does not recognize this architecture|has no attribute'; then
        echo -e "  ${RED}The model architecture is newer than this container's vLLM/transformers.${NC}"
        echo -e "  Fix: the model likely needs the nightly image — check VLLM_IMAGE in the app-pack menu."
    elif echo "$logs" | grep -qiE 'UR_RESULT_ERROR_DEVICE_LOST|level_zero backend failed'; then
        echo -e "  ${RED}The GPU crashed/reset mid-run (Level Zero DEVICE_LOST).${NC}"
        echo -e "  The driver lost the device — usually a GPU hang or kernel driver crash, not a"
        echo -e "  config problem. Check ${BLUE}sudo dmesg | tail -30${NC} for i915/xe GPU reset messages;"
        echo -e "  a reboot is often needed before the GPU responds again. If it recurs on the"
        echo -e "  same model, try --gpu-count 1 (single-GPU) to rule out multi-GPU sync issues."
    elif echo "$logs" | grep -qiE 'shm_broadcast.*cancelled|RuntimeError: cancelled|Engine core initialization failed'; then
        echo -e "  ${RED}Engine-core init failed — the API server gave up waiting on its workers.${NC}"
        echo -e "  On multi-GPU boxes this is usually the tensor-parallel worker hanging or"
        echo -e "  dying during distributed init (seen on XPU TP≥2 and PCIe-P2P setups)."
        echo -e "  Isolate: re-run this model single-GPU —"
        echo -e "  ${BLUE}./run_benchmarks.sh --pack team_llm --model <HF-id> --gpu-count 1${NC}"
    elif echo "$logs" | grep -qiE 'Failed to infer device type|XPU device count is zero'; then
        echo -e "  ${RED}The container cannot see the GPU at all.${NC}"
        echo -e "  Device passthrough is missing/broken (e.g. /dev/dri not mapped, or the host"
        echo -e "  driver is down). Verify the GPU on the host (clinfo / rocm-smi / nvidia-smi),"
        echo -e "  then check the compose override maps the device into the container."
    else
        echo -e "  No known signature matched — see the full ${label} log above."
    fi
    echo -e "  ${YELLOW}──────────────────────────────────────────────────────────${NC}"
}

# run_doctor — read-only readiness check (invoked by --doctor; never runs a benchmark).
# Verifies a box can run the suite: Docker, GPU + interconnect, disk, port 8000, the
# lab cache, and HF token. Lets an integration specialist confirm readiness unaided.
run_doctor() {
    local fail=0 warn=0
    echo -e "${BLUE}==============================================================${NC}"
    echo -e "${BLUE}   Puget Systems AI Benchmark — Doctor (readiness check)${NC}"
    echo -e "${BLUE}==============================================================${NC}"
    echo -e "  Version: v${VERSION}"
    if [ "$LOCAL_MODE" = true ]; then
        echo -e "  Mode: ${GREEN}on-box${NC} (this machine)"
    else
        echo -e "  Mode: remote → ${HOST}"
        if target_cmd "true" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} SSH reachable"
        else
            echo -e "  ${RED}✗${NC} SSH to ${HOST} failed"; return 1
        fi
    fi
    echo ""

    # Docker
    if target_cmd "command -v docker >/dev/null 2>&1"; then
        if target_cmd "docker info >/dev/null 2>&1"; then
            echo -e "  ${GREEN}✓${NC} Docker: $(target_cmd "docker --version" 2>/dev/null)"
        else
            echo -e "  ${RED}✗${NC} Docker installed but daemon not running / no permission"; fail=$((fail+1))
        fi
    else
        echo -e "  ${RED}✗${NC} Docker not installed"; fail=$((fail+1))
    fi

    # Docker Compose (v2 plugin or v1 standalone) — the bench drives everything
    # through it, and Ubuntu's docker.io package omits the plugin.
    if detect_docker_compose; then
        echo -e "  ${GREEN}✓${NC} Docker Compose: ${DOCKER_COMPOSE}"
    else
        echo -e "  ${RED}✗${NC} Docker Compose missing (no 'docker compose' plugin or 'docker-compose')"
        echo -e "        Fix (Ubuntu): sudo apt-get install -y docker-compose-v2"; fail=$((fail+1))
    fi

    # GPU + interconnect
    if target_cmd "command -v nvidia-smi >/dev/null 2>&1"; then
        local g n nvl
        g=$(target_cmd "nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader" 2>/dev/null)
        n=$(echo "$g" | grep -c .)
        echo -e "  ${GREEN}✓${NC} NVIDIA GPUs: ${n}"
        echo "$g" | sed 's/^/        /'
        # Driver ↔ container-CUDA readiness: which model image lines can this driver run?
        local drv drv_major
        drv=$(echo "$g" | head -1 | awk -F', ' '{print $3}')
        drv_major="${drv%%.*}"
        if [[ "$drv_major" =~ ^[0-9]+$ ]]; then
            if [ "$drv_major" -ge 580 ]; then
                echo -e "  ${GREEN}✓${NC} Driver ${drv} — supports ALL model images (CUDA 12 stable + CUDA 13 cu130)"
            elif [ "$drv_major" -ge 570 ]; then
                echo -e "  ${YELLOW}⚠${NC} Driver ${drv} — CUDA-12 models OK, but cu130 models (Blackwell nightly"
                echo -e "      line: Qwen3.5/3.6, Nemotron NVFP4, Gemma4) need driver ≥580 and will be SKIPPED."
                echo -e "      Fix: upgrade the driver (app-pack setup.sh offers this) and reboot."; warn=$((warn+1))
            else
                echo -e "  ${YELLOW}⚠${NC} Driver ${drv} is older than 570 — current vLLM images (CUDA 12.8+) may fail."
                echo -e "      Fix: upgrade the driver (app-pack setup.sh offers this) and reboot."; warn=$((warn+1))
            fi
        fi
        if [ "${n:-0}" -gt 1 ]; then
            nvl=$(target_cmd "nvidia-smi topo -m 2>/dev/null | grep -E '^[[:space:]]*GPU[0-9]' | grep -oE 'NV[0-9]+' | head -1" 2>/dev/null)
            if [ -n "$nvl" ]; then
                echo -e "        Interconnect: NVLink (NCCL P2P stays on)"
            else
                echo -e "        Interconnect: PCIe (NCCL P2P will be auto-disabled)"
            fi
        fi
    elif target_cmd "command -v rocm-smi >/dev/null 2>&1"; then
        echo -e "  ${GREEN}✓${NC} AMD ROCm GPU(s) detected"
    elif target_cmd "command -v clinfo >/dev/null 2>&1 && clinfo 2>/dev/null | grep -qi intel"; then
        echo -e "  ${GREEN}✓${NC} Intel GPU(s) detected"
    else
        echo -e "  ${RED}✗${NC} No supported GPU detected (nvidia-smi / rocm-smi / clinfo)"; fail=$((fail+1))
    fi

    # Disk
    local disk
    disk=$(target_cmd "df -h \"\$HOME\" 2>/dev/null | tail -1 | awk '{print \$4\" free of \"\$2}'" 2>/dev/null)
    [ -n "$disk" ] && echo -e "  ${GREEN}✓${NC} Disk (\$HOME): ${disk}"

    # Port 8000
    if target_cmd "ss -ltn 2>/dev/null | grep -q ':8000 '"; then
        echo -e "  ${YELLOW}⚠${NC} Port 8000 in use — a prior server may still be running"; warn=$((warn+1))
    else
        echo -e "  ${GREEN}✓${NC} Port 8000 free"
    fi

    # Lab cache
    if target_cmd "curl -s --max-time 3 'http://${DEFAULT_CACHE_HOST}:8090/api/whoami' >/dev/null 2>&1"; then
        echo -e "  ${GREEN}✓${NC} HF mirror reachable (${DEFAULT_CACHE_HOST}:8090) — model downloads cached"
    else
        echo -e "  ${YELLOW}⚠${NC} HF mirror unreachable (${DEFAULT_CACHE_HOST}:8090) — direct downloads"; warn=$((warn+1))
    fi

    # HF token (gated models) — discover without prompting
    resolve_hf_token quiet
    if [ -n "${HF_TOKEN:-}" ]; then
        echo -e "  ${GREEN}✓${NC} HF token found (${HF_TOKEN_SOURCE}) — gated models OK"
    else
        echo -e "  ${YELLOW}⚠${NC} No HF token (checked env, bench.conf, ~/.cache/huggingface) — gated models will fail; run without --doctor to be prompted, or set HF_TOKEN in ${CONFIG_FILE}"; warn=$((warn+1))
    fi

    echo ""
    if [ "$fail" -gt 0 ]; then
        echo -e "  ${RED}✗ Not ready: ${fail} blocking issue(s), ${warn} warning(s).${NC}"
        return 1
    elif [ "$warn" -gt 0 ]; then
        echo -e "  ${YELLOW}✓ Ready with ${warn} warning(s) — benchmarks can run.${NC}"
        return 0
    fi
    echo -e "  ${GREEN}✓ All checks passed — ready to benchmark.${NC}"
    return 0
}

# detect_docker_compose — resolve a working Compose command ON THE TARGET into
# DOCKER_COMPOSE. Prefer the v2 plugin ("docker compose"); fall back to the v1
# standalone ("docker-compose"). Ubuntu's `docker.io` package ships the engine
# and the legacy image builder but NOT the compose plugin, so `docker compose`
# fails there — and it fails cryptically ("unknown shorthand flag: 'd' in -d",
# because docker reparses the args after not finding the plugin), only after the
# image has already built. Detecting up front lets us fail with a real fix.
# Returns 1 (and leaves DOCKER_COMPOSE empty) when neither is available.
detect_docker_compose() {
    if target_cmd "docker compose version >/dev/null 2>&1"; then
        DOCKER_COMPOSE="docker compose"
    elif target_cmd "docker-compose version >/dev/null 2>&1"; then
        DOCKER_COMPOSE="docker-compose"
    else
        DOCKER_COMPOSE=""
        return 1
    fi
    return 0
}

# ensure_vllm_image IMG — guarantee the vLLM container image exists on the target.
# Build-required puget-* images are built from their Dockerfile in $WORK_DIR (same
# as the App Pack installer does); everything else is pulled. Returns non-zero on
# failure so the caller can record a SKIP/FAIL and move on. This replaces the old
# hardcoded per-vendor pull that ignored the image the model menu actually selected.
ensure_vllm_image() {
    local img="$1"
    if [ -z "$img" ]; then
        echo -e "  ${RED}✗ No container image resolved for this model.${NC}"; return 1
    fi
    if target_cmd "docker image inspect '$img' >/dev/null 2>&1"; then
        echo -e "  ${GREEN}✓ Image present: ${img}${NC}"; return 0
    fi
    case "$img" in
        puget-vllm-xpu*)
            echo -e "  ${BLUE}Building ${img} from Dockerfile.xpu (first run; a few minutes)...${NC}"
            if ! target_cmd "cd \"$WORK_DIR\" && docker build -t '$img' -f Dockerfile.xpu ."; then
                echo -e "  ${RED}✗ Failed to build ${img}.${NC}"; return 1
            fi ;;
        puget-*)
            echo -e "  ${RED}✗ Build-required image with no known Dockerfile mapping: ${img}${NC}"; return 1 ;;
        *)
            echo -e "  ${BLUE}Pulling ${img} (first run only)...${NC}"
            if ! target_cmd "docker pull '$img'"; then
                echo -e "  ${RED}✗ Failed to pull ${img}.${NC}"; return 1
            fi ;;
    esac
    return 0
}

# reap_workers_and_wait_gpu — a plain `docker compose down` can leave orphaned
# vLLM worker processes behind (the spawn multiproc method detaches EngineCore /
# TP workers) that keep holding GPU memory and port 8000, wedging the next model.
# Kill any strays, free the port, and wait until the GPUs report idle. Vendor-
# neutral: precise compute-process check on NVIDIA, vLLM-process proxy elsewhere.
reap_workers_and_wait_gpu() {
    target_cmd "pkill -9 -f 'vllm.entrypoints' 2>/dev/null; pkill -9 -f 'multiprocessing.spawn' 2>/dev/null; fuser -k 8000/tcp 2>/dev/null; true" 2>/dev/null || true
    local waited=0 max=90
    while [ "$waited" -lt "$max" ]; do
        if target_cmd "
            if command -v nvidia-smi >/dev/null 2>&1; then
                [ -z \"\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)\" ]
            else
                # Non-NVIDIA: match only the actual vLLM server, not the bench's own
                # processes/paths that merely contain the string 'vllm'.
                ! pgrep -f 'vllm\\.entrypoints' >/dev/null 2>&1
            fi
        " 2>/dev/null; then
            [ "$waited" -gt 0 ] && echo -e "  ${GREEN}✓ GPUs free.${NC}"
            return 0
        fi
        sleep 3; waited=$((waited + 3))
    done
    echo -e "  ${YELLOW}⚠ GPUs still showing activity after ${max}s — continuing.${NC}"
    return 0
}

# ============================================
# GPU Power Monitoring
# ============================================
# Uses sysfs hwmon (amdgpu / Intel xe|i915) or nvidia-smi to poll GPU power
# draw during benchmarks. Writes timestamped readings to a temp file on the
# remote host.

POWER_MONITOR_LOG="/tmp/puget_bench_power.csv"

start_power_monitor() {
    local interval="${1:-2}"  # polling interval in seconds

    # Kill any stale monitor from a previous run
    target_cmd "kill \$(cat /tmp/puget_bench_power.pid 2>/dev/null) 2>/dev/null; rm -f $POWER_MONITOR_LOG /tmp/puget_bench_power.pid" 2>/dev/null || true

    if [ "$GPU_VENDOR" = "amd" ]; then
        # AMD: read power from sysfs hwmon (power1_average is in microwatts)
        target_cmd "nohup bash -c '
            echo \"timestamp_s,total_gpu_watts\" > $POWER_MONITOR_LOG
            while true; do
                total_uw=0
                for f in /sys/class/hwmon/hwmon*/power1_average; do
                    name=\$(cat \$(dirname \$f)/name 2>/dev/null)
                    if [ \"\$name\" = \"amdgpu\" ]; then
                        uw=\$(cat \$f 2>/dev/null || echo 0)
                        total_uw=\$((total_uw + uw))
                    fi
                done
                watts=\$(echo \"scale=1; \$total_uw / 1000000\" | bc)
                echo \"\$(date +%s),\$watts\" >> $POWER_MONITOR_LOG
                sleep $interval
            done
        ' > /dev/null 2>&1 & echo \$! > /tmp/puget_bench_power.pid" 2>/dev/null
    elif [ "$GPU_VENDOR" = "intel" ]; then
        # Intel XPU (Arc / Battlemage): read power from sysfs hwmon exposed by the
        # xe (or legacy i915) driver. power1_average is in microwatts. Falls back to
        # an energy1_input delta when an average reading is unavailable.
        target_cmd "nohup bash -c '
            echo \"timestamp_s,total_gpu_watts\" > $POWER_MONITOR_LOG
            declare -A prev_uj
            prev_t=\$(date +%s%N)
            while true; do
                total_uw=0
                now_t=\$(date +%s%N)
                for d in /sys/class/hwmon/hwmon*; do
                    name=\$(cat \$d/name 2>/dev/null)
                    if [ \"\$name\" = \"xe\" ] || [ \"\$name\" = \"i915\" ]; then
                        if [ -r \"\$d/power1_average\" ]; then
                            uw=\$(cat \$d/power1_average 2>/dev/null || echo 0)
                            total_uw=\$((total_uw + uw))
                        elif [ -r \"\$d/energy1_input\" ]; then
                            uj=\$(cat \$d/energy1_input 2>/dev/null || echo 0)
                            if [ -n \"\${prev_uj[\$d]:-}\" ]; then
                                d_uj=\$((uj - prev_uj[\$d]))
                                d_ns=\$((now_t - prev_t))
                                [ \$d_ns -gt 0 ] && total_uw=\$((total_uw + d_uj * 1000000000 / d_ns))
                            fi
                            prev_uj[\$d]=\$uj
                        fi
                    fi
                done
                prev_t=\$now_t
                watts=\$(echo \"scale=1; \$total_uw / 1000000\" | bc)
                echo \"\$(date +%s),\$watts\" >> $POWER_MONITOR_LOG
                sleep $interval
            done
        ' > /dev/null 2>&1 & echo \$! > /tmp/puget_bench_power.pid" 2>/dev/null
    elif [ "$GPU_VENDOR" = "nvidia" ]; then
        # NVIDIA: sum power.draw (watts) across all GPUs via nvidia-smi.
        target_cmd "nohup bash -c '
            echo \"timestamp_s,total_gpu_watts\" > $POWER_MONITOR_LOG
            while true; do
                total=0
                for p in \$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null); do
                    total=\$(echo \"\$total + \$p\" | bc 2>/dev/null || echo \"\$total\")
                done
                echo \"\$(date +%s),\$total\" >> $POWER_MONITOR_LOG
                sleep $interval
            done
        ' > /dev/null 2>&1 & echo \$! > /tmp/puget_bench_power.pid" 2>/dev/null
    else
        # Power monitoring is optional telemetry — never fatal to the benchmark.
        echo -e "  ${YELLOW}⚠ Power monitoring not supported for GPU vendor: ${GPU_VENDOR:-unknown}${NC}"
        return 0
    fi

    echo -e "  ${BLUE}⚡ GPU power monitor started (polling every ${interval}s)${NC}"
}

stop_power_monitor() {
    local results_dir="${1:-.}"

    # Kill the background monitor
    target_cmd "kill \$(cat /tmp/puget_bench_power.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/puget_bench_power.pid" 2>/dev/null || true

    # Retrieve and process readings
    local readings
    readings=$(target_cmd "cat $POWER_MONITOR_LOG 2>/dev/null" 2>/dev/null) || true

    if [ -z "$readings" ] || [ "$(echo "$readings" | wc -l)" -le 2 ]; then
        echo -e "  ${YELLOW}⚠ No power data collected${NC}"
        LAST_AVG_GPU_WATTS=""
        LAST_PEAK_GPU_WATTS=""
        return 1
    fi

    # Calculate average and peak from CSV (skip header)
    local stats
    stats=$(echo "$readings" | tail -n +2 | awk -F',' '
        NR==1 { min=$2; max=$2 }
        { sum+=$2; count++; if($2>max) max=$2; if($2<min) min=$2 }
        END {
            if(count>0) printf "%.1f,%.1f,%.1f,%d", sum/count, max, min, count
            else print "0,0,0,0"
        }
    ')

    IFS=',' read -r avg_w peak_w min_w sample_count <<< "$stats"
    LAST_AVG_GPU_WATTS="$avg_w"
    LAST_PEAK_GPU_WATTS="$peak_w"

    echo -e "  ${GREEN}⚡ GPU Power: avg=${avg_w}W  peak=${peak_w}W  min=${min_w}W  (${sample_count} samples)${NC}"

    # Save power report alongside benchmark results
    if [ -d "$results_dir" ]; then
        cat > "$results_dir/power_report.txt" <<EOF
GPU Power Report
================
Average GPU Power: ${avg_w}W
Peak GPU Power:    ${peak_w}W
Min GPU Power:     ${min_w}W
Samples:           ${sample_count}
Interval:          2s

Raw Data:
$readings
EOF
        echo -e "  ${BLUE}  Power report saved to ${results_dir}/power_report.txt${NC}"
    fi

    # Clean up remote log
    target_cmd "rm -f $POWER_MONITOR_LOG" 2>/dev/null || true
}

run_genai_perf_client() {
    local endpoint="$1"
    local url="$2"
    local model="$3"
    local concurrency="$4"
    local results_dir="$5"

    local port
    port=$(echo "$url" | grep -o ':[0-9]*$' | tr -d ':')

    # Run the genai-perf client ON THE REMOTE host (native Linux networking),
    # not locally through an SSH tunnel. Docker Desktop's host.docker.internal
    # gateway corrupts requests at high concurrency (HTTP 400s ≥ ~32 concurrent),
    # while the remote container talking to localhost:$port is rock solid.
    # Results are written to a remote dir and rsync'd back to $results_dir.
    local safe_tag
    safe_tag=$(echo "${model}_${concurrency}" | tr '/:, ' '____')
    local remote_res="$REMOTE_TEMP_DIR/genai_${safe_tag}"
    target_cmd "rm -rf '$remote_res'; mkdir -p '$remote_res'"

    # Ship the genai-perf runner to the target (single source of truth)
    push_file "$SCRIPT_DIR/llm_tests/run_genai_perf.sh" "$REMOTE_TEMP_DIR/run_genai_perf.sh"

    local ctx_arg=""
    if [ -n "${CONTEXT_LENGTHS:-}" ]; then
        ctx_arg="--context-lengths ${CONTEXT_LENGTHS}"
    fi

    echo -e "  ${BLUE}Running genai-perf on the target (native net) → localhost:${port}...${NC}"

    local rt_arg=""
    if [ -n "${REQUEST_TIMEOUT:-}" ]; then
        rt_arg="--request-timeout ${REQUEST_TIMEOUT}"
    fi

    local exit_code=0
    # HF_TOKEN/HF_ENDPOINT are exported into the shell so run_genai_perf.sh can
    # forward them into the SDK container for tokenizer downloads. Only set
    # HF_ENDPOINT when a mirror exists — exporting it empty makes transformers use
    # "" as the endpoint and the tokenizer download fails ("Unrecognized model").
    local hf_env="HF_TOKEN='${HF_TOKEN}' HUGGINGFACE_HUB_TOKEN='${HF_TOKEN}'"
    [ -n "${HF_ENDPOINT_EFFECTIVE:-}" ] && hf_env="$hf_env HF_ENDPOINT='${HF_ENDPOINT_EFFECTIVE}'"
    target_cmd "export $hf_env; bash '$REMOTE_TEMP_DIR/run_genai_perf.sh' \
        --endpoint '$endpoint' \
        --url 'http://localhost:$port' \
        --model '$model' \
        --concurrency '$concurrency' \
        --input-tokens '$INPUT_TOKENS' \
        --output-tokens '$OUTPUT_TOKENS' \
        --num-prompts '$NUM_PROMPTS' \
        --results-dir '$remote_res' \
        --measurement-interval '${EFF_INTERVAL:-$MEASUREMENT_INTERVAL}' \
        $rt_arg $ctx_arg" || exit_code=$?

    # Pull results back to the master results dir
    pull_dir "$remote_res" "$results_dir"

    return $exit_code
}

# Readiness check only — verify the box can run, then exit (no benchmarks).
if [ "$DOCTOR" = true ]; then
    run_doctor
    exit $?
fi

echo -e "${BLUE}==============================================================${NC}"
echo -e "${BLUE}   Puget Systems AI App Pack — Automated Benchmark Suite${NC}"
echo -e "${BLUE}==============================================================${NC}"
echo ""

# Resolve the HF token up front (flag/env/bench.conf → local HF cache → prompt) so
# gated models work and the token is forwarded to the target via the .env we write.
resolve_hf_token prompt
if [ -n "${HF_TOKEN:-}" ]; then
    echo -e "${GREEN}✓ HuggingFace token: using ${HF_TOKEN_SOURCE}${NC}"
else
    echo -e "${YELLOW}⚠ No HuggingFace token — gated models (some Llama/Gemma) will be skipped/fail.${NC}"
fi
echo ""

# Connect to the target (skip SSH entirely in on-box mode)
if [ "$LOCAL_MODE" = true ]; then
    echo -e "${YELLOW}[0/6] On-box mode — running locally on this machine (no SSH).${NC}"
    echo -e "${GREEN}✓ Target: $(hostname).${NC}"
else
    echo -e "${YELLOW}[0/6] Testing SSH connection to $HOST...${NC}"
    if ! target_cmd "echo 'SSH connection successful'" >/dev/null; then
        echo -e "${RED}✗ SSH connection failed. Make sure you have key-based auth set up:${NC}"
        echo "   ssh-copy-id $HOST"
        exit 1
    fi
    echo -e "${GREEN}✓ Connected to $HOST.${NC}"
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}⚠  DRY RUN MODE — no containers will be launched${NC}"
    echo ""
fi

# ============================================
# 0.25. Local Preflight — Docker (needed for genai-perf)
# ============================================
# genai-perf now runs on the TARGET (the GPU box) via target_cmd, so in on-box
# mode the box's Docker is verified by the preflight below — skip this client-side
# check. It only matters in remote mode where the orchestrator is a separate box.
if [ "$LOCAL_MODE" = false ] && ! command -v docker &>/dev/null; then
    echo ""
    echo -e "${YELLOW}[0.25/6] Local Docker check...${NC}"
    echo -e "${RED}✗ Docker is not installed on this machine.${NC}"
    echo ""
    echo "  LLM benchmarks (team_llm / personal_llm) require Docker locally"
    echo "  to run the genai-perf benchmark client."
    echo ""

    LOCAL_OS="$(uname -s)"
    case "$LOCAL_OS" in
        Darwin)
            echo "  Install Docker Desktop for macOS:"
            echo "    https://docs.docker.com/desktop/setup/install/mac-install/"
            echo ""
            echo "  Or via Homebrew:"
            echo "    brew install --cask docker"
            echo ""
            echo "  After installing, launch Docker Desktop and wait for it to start."
            ;;
        Linux)
            # Detect WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "  You appear to be running WSL. Install Docker Desktop for Windows"
                echo "  with WSL2 backend enabled:"
                echo "    https://docs.docker.com/desktop/setup/install/windows-install/"
                echo ""
                echo "  Make sure 'Use the WSL 2 based engine' is checked in Docker Desktop"
                echo "  settings, and your distro is enabled under Resources → WSL Integration."
            else
                echo "  Install Docker on Linux:"
                echo ""
                read -p "  Would you like to install Docker CE now? [y/N] " INSTALL_DOCKER
                if [[ "$INSTALL_DOCKER" =~ ^[Yy] ]]; then
                    echo ""
                    echo -e "${BLUE}  Installing Docker CE...${NC}"
                    sudo apt-get update -y
                    sudo apt-get install -y ca-certificates curl gnupg
                    sudo install -m 0755 -d /etc/apt/keyrings
                    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
                    sudo chmod a+r /etc/apt/keyrings/docker.gpg
                    echo \
                      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    sudo apt-get update -y
                    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                    sudo usermod -aG docker "$USER"
                    echo ""
                    echo -e "${GREEN}  ✓ Docker CE installed.${NC}"
                    echo -e "${YELLOW}  Note: You may need to log out and back in for group permissions.${NC}"
                    echo -e "${YELLOW}  Alternatively, run: sg docker -c './run_benchmarks.sh ...'${NC}"
                else
                    echo ""
                    echo "  To install manually:"
                    echo "    https://docs.docker.com/engine/install/ubuntu/"
                fi
            fi
            ;;
        *)
            echo "  Install Docker for your platform:"
            echo "    https://docs.docker.com/get-docker/"
            ;;
    esac

    # Re-check after potential install
    if ! command -v docker &>/dev/null; then
        echo ""
        echo -e "${RED}  Docker is still not available. LLM benchmarks will fail.${NC}"
        echo -e "${YELLOW}  You can still run ComfyUI-only benchmarks without Docker.${NC}"
        echo ""
        read -p "  Continue anyway? (ComfyUI benchmarks will still work) [y/N] " CONTINUE_NO_DOCKER
        if [[ ! "$CONTINUE_NO_DOCKER" =~ ^[Yy] ]]; then
            exit 1
        fi
        echo ""
        echo -e "${YELLOW}⚠  Continuing without local Docker — LLM benchmarks will be skipped.${NC}"
        NO_LOCAL_DOCKER=true
    else
        echo ""
        echo -e "${GREEN}✓ Docker is now available locally.${NC}"
        NO_LOCAL_DOCKER=false
    fi
else
    echo -e "${GREEN}✓ Docker detected locally ($(docker --version 2>/dev/null | head -1)).${NC}"
    NO_LOCAL_DOCKER=false
fi

# ============================================
# 0.5. Remote Preflight — Docker & GPU Provisioning
# ============================================
# Check if Docker and GPU drivers (NVIDIA or Intel) are available remotely
NEED_PREFLIGHT=false
if ! target_cmd "command -v docker > /dev/null 2>&1"; then
    echo ""
    echo -e "${YELLOW}[0.5/6] Docker not found on target machine — running preflight provisioning...${NC}"
    echo -e "${YELLOW}  This will install Docker CE and GPU drivers.${NC}"
    NEED_PREFLIGHT=true
elif ! target_cmd "command -v nvidia-smi > /dev/null 2>&1" && ! target_cmd "ls /dev/dri/renderD* > /dev/null 2>&1"; then
    echo ""
    echo -e "${YELLOW}[0.5/6] No GPU drivers found on target machine — running preflight...${NC}"
    NEED_PREFLIGHT=true
else
    echo -e "${GREEN}✓ Docker and GPU drivers detected on target machine.${NC}"
fi

if [ "$NEED_PREFLIGHT" = true ]; then
    echo ""

    if [ "$LOCAL_MODE" = true ]; then
        echo -e "${RED}✗ Docker and/or GPU drivers are missing on this machine.${NC}"
        echo "  In on-box mode, install them first — the App Pack installer handles this:"
        echo "    curl -fsSL https://raw.githubusercontent.com/Puget-Systems/puget-docker-app-packs/main/setup.sh -o setup.sh && bash setup.sh"
        echo "  (Or pass --host USER@IP to provision a remote box over SSH.)"
        exit 1
    fi

    PREFLIGHT_SCRIPT="$SCRIPT_DIR/scripts/remote_preflight.sh"
    if [ ! -f "$PREFLIGHT_SCRIPT" ]; then
        echo -e "${RED}✗ Preflight script not found at $PREFLIGHT_SCRIPT${NC}"
        exit 1
    fi

    # Use SUDO_PASS from bench.conf / --sudo-pass flag, or prompt interactively
    if [ -n "$SUDO_PASS" ]; then
        REMOTE_SUDO_PASS="$SUDO_PASS"
        echo -e "  ${GREEN}Using sudo password from config.${NC}"
    else
        read -s -p "  Enter sudo password for target machine ($HOST): " REMOTE_SUDO_PASS
        echo ""
    fi

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
        echo -e "${YELLOW}NVIDIA drivers were installed. Rebooting target machine...${NC}"
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

# Resolve the Compose command up front (before any expensive build/clone) so a
# box missing the Compose v2 plugin fails here with a fix, not mid-run.
if ! detect_docker_compose; then
    echo ""
    echo -e "${RED}✗ Docker Compose is not available on the target.${NC}"
    echo -e "  The engine is installed but neither ${BLUE}docker compose${NC} (v2 plugin) nor"
    echo -e "  ${BLUE}docker-compose${NC} (v1) works. Ubuntu's ${YELLOW}docker.io${NC} package omits the plugin."
    echo -e "  Fix (Ubuntu): ${GREEN}sudo apt-get install -y docker-compose-v2${NC}"
    echo -e "  or install Docker's official packages (docker-ce + docker-compose-plugin):"
    echo -e "  ${GREEN}https://docs.docker.com/engine/install/ubuntu/${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Compose command: ${DOCKER_COMPOSE}${NC}"

# ============================================
# 1. Acquire App Pack Repository (Remote)
# ============================================
echo ""
echo -e "${YELLOW}[1/6] Acquiring App Pack repository on target machine...${NC}"

REMOTE_TEMP_DIR=$(target_cmd "mktemp -d")
# Remove the per-run temp tree on exit. Model weights are NOT lost: vLLM/Ollama
# weights live in shared docker volumes and ComfyUI weights in MODEL_CACHE_DIR —
# the temp dir only holds pack copies and scratch. Leaving it (the old behavior)
# leaked multi-GB dirs into /tmp until the disk filled.
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up remote temp directory...${NC}"
    target_cmd "rm -rf \"$REMOTE_TEMP_DIR\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$APP_PACK_REPO" == http* || "$APP_PACK_REPO" == git@* ]]; then
    echo -e "  Cloning ${BLUE}${APP_PACK_REPO}${NC} (branch: ${GREEN}${APP_PACK_BRANCH}${NC})..."
    # Ensure git is installed remotely
    if ! target_cmd "command -v git >/dev/null"; then
        echo -e "${RED}✗ git is not installed on the target machine.${NC}"
        exit 1
    fi
    if ! target_cmd "git clone --depth 1 --branch \"$APP_PACK_BRANCH\" \"$APP_PACK_REPO\" \"$REMOTE_TEMP_DIR/app-pack\" 2>&1 | tail -1"; then
        echo -e "${RED}✗ Failed to clone App Pack repository on target machine.${NC}"
        exit 1
    fi
elif [ -d "$APP_PACK_REPO" ]; then
    echo -e "  Deploying local repository ${BLUE}${APP_PACK_REPO}${NC}..."
    if [ "$LOCAL_MODE" = true ]; then
        if ! rsync -a --exclude=".git" "$APP_PACK_REPO/" "$REMOTE_TEMP_DIR/app-pack/"; then
            echo -e "${RED}✗ Failed to copy local repository.${NC}"
            exit 1
        fi
    else
        if ! rsync -a -e "ssh ${SSH_OPTS[*]}" --exclude=".git" "$APP_PACK_REPO/" "$HOST:$REMOTE_TEMP_DIR/app-pack/"; then
            echo -e "${RED}✗ Failed to rsync local repository to target machine.${NC}"
            exit 1
        fi
    fi
else
    echo -e "${RED}✗ APP_PACK_REPO is not a valid URL or local directory: ${APP_PACK_REPO}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository deployed to $REMOTE_TEMP_DIR/app-pack.${NC}"

PACK_ROOT="$REMOTE_TEMP_DIR/app-pack"

# Temporary fix for Gemma 4 Dockerfile missing git (only present on some branches)
target_cmd "[ -f \"$PACK_ROOT/packs/team_llm/Dockerfile.gemma4\" ] && sed -i '/RUN pip install --no-cache-dir/i RUN apt-get update && apt-get install -y git' \"$PACK_ROOT/packs/team_llm/Dockerfile.gemma4\" || true"

# ============================================
# 2. Integrity Check (MD5) - Remote
# ============================================
echo ""
echo -e "${YELLOW}[2/6] Verifying installer integrity on target machine...${NC}"

# Mirror setup.sh: prefer the multi-file checksums.md5 manifest, fall back to
# the legacy single-file install.sh.md5. (Verifying only the legacy file would
# fail whenever it drifts from install.sh even though setup.sh — and therefore
# real installs — pass via the manifest.)
CHECKSUM_MANIFEST="$PACK_ROOT/checksums.md5"
LEGACY_CHECKSUM="$PACK_ROOT/install.sh.md5"
if [ "$SKIP_CHECKSUM" = true ]; then
    echo -e "${YELLOW}⚠ Skipping integrity check (--skip-checksum).${NC}"
elif ! target_cmd "command -v md5sum >/dev/null"; then
    echo -e "${YELLOW}⚠ No md5sum on target machine — skipping integrity check.${NC}"
elif target_cmd "[ -f \"$CHECKSUM_MANIFEST\" ]"; then
    # Verify every shipped script against the manifest (md5sum -c resolves paths
    # relative to the manifest's directory).
    if target_cmd "cd \"$PACK_ROOT\" && md5sum -c --quiet checksums.md5 >/dev/null 2>&1"; then
        N_FILES=$(target_cmd "grep -c . \"$CHECKSUM_MANIFEST\"")
        echo -e "${GREEN}✓ All scripts verified (${N_FILES} files via checksums.md5).${NC}"
    else
        echo -e "${RED}✗ Integrity check FAILED.${NC}"
        target_cmd "cd \"$PACK_ROOT\" && md5sum -c checksums.md5 2>&1 | grep -v ': OK$'" || true
        echo -e "  One or more shipped scripts may be corrupted or tampered with."
        echo -e "  If you just edited scripts, run: ${BLUE}scripts/update_checksum.sh${NC}"
        exit 1
    fi
elif target_cmd "[ -f \"$LEGACY_CHECKSUM\" ]"; then
    # Backwards compatibility: single-file install.sh.md5
    EXPECTED_HASH=$(target_cmd "awk '{print \$1}' \"$LEGACY_CHECKSUM\"")
    ACTUAL_HASH=$(target_cmd "md5sum \"$PACK_ROOT/install.sh\" | awk '{print \$1}'")
    if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        echo -e "${RED}✗ Integrity check FAILED.${NC}"
        echo -e "  Expected MD5: ${EXPECTED_HASH}"
        echo -e "  Got MD5:      ${ACTUAL_HASH}"
        exit 1
    fi
    echo -e "${GREEN}✓ Installer integrity verified (legacy install.sh.md5).${NC}"
else
    echo -e "${YELLOW}⚠ No checksum file found — skipping integrity check.${NC}"
fi

# ============================================
# 3. Detect Hardware (Remote via helper script)
# ============================================
echo ""
echo -e "${YELLOW}[3/6] Detecting hardware on target machine...${NC}"

# We execute a small inline script remotely that sources gpu_detect.sh and prints key variables back to us
GPU_INFO=$(target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\" && if detect_gpus; then echo \"OK|\$GPU_VENDOR|\$GPU_COUNT|\$TOTAL_VRAM|\$GPU_NAME|\$IS_BLACKWELL|\$COMPUTE_CAP|\$VRAM_GB|\${DRIVER_VERSION:-}\"; else echo \"FAIL\"; fi'")

if [[ "$GPU_INFO" == "FAIL" || -z "$GPU_INFO" ]]; then
    echo -e "${RED}✗ No GPUs detected on target machine. GPU benchmarks require NVIDIA, Intel, or AMD GPU drivers.${NC}"
    exit 1
fi

IFS='|' read -r status GPU_VENDOR GPU_COUNT TOTAL_VRAM GPU_NAME IS_BLACKWELL COMPUTE_CAP VRAM_GB DRIVER_VERSION <<< "$GPU_INFO"

# Older app-pack branches predate DRIVER_VERSION in gpu_detect.sh — query it
# directly so the driver↔CUDA gate still works against them.
if [ -z "${DRIVER_VERSION:-}" ]; then
    DRIVER_VERSION=$(target_cmd "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1" 2>/dev/null) || true
fi

# The NVIDIA (main) app-pack branch's gpu_detect.sh detects via nvidia-smi but
# does not emit a vendor string. If detection succeeded with no vendor, it's
# NVIDIA — default it so power monitoring and vendor-specific paths work.
if [ -z "${GPU_VENDOR:-}" ] && [ "${GPU_COUNT:-0}" -gt 0 ]; then
    GPU_VENDOR="nvidia"
fi

echo -e "${GREEN}✓ Found ${GPU_COUNT}x ${GPU_NAME} (${TOTAL_VRAM} GB total) [vendor: ${GPU_VENDOR}]${NC}"
[ -n "${DRIVER_VERSION:-}" ] && echo -e "${GREEN}✓ GPU driver: ${DRIVER_VERSION}${NC}"
if [ "$GPU_VENDOR" = "amd" ]; then
    echo -e "${GREEN}  AMD GPU detected → using ROCm container paths${NC}"
elif [ "$GPU_VENDOR" = "intel" ]; then
    echo -e "${GREEN}  Intel XPU detected → using XPU container paths${NC}"
elif [ "$IS_BLACKWELL" = "true" ]; then
    echo -e "${GREEN}  Blackwell GPU detected (compute ${COMPUTE_CAP}) → using CUDA 13.0 paths${NC}"
fi

# Cache auto-discovery. Pick the cache host: explicit --cache-proxy wins, else the
# baked lab default (DGX Spark). Then probe the Olah HF mirror (:8090) and the Squid
# HTTP proxy (:3128) independently — each is used only if it actually answers, so the
# bench transparently uses the lab cache on-network and falls back to direct downloads
# anywhere else. The HF mirror is the big win (it caches multi-GB model weights).
HF_MIRROR=""
if [ -n "$CACHE_PROXY" ]; then
    _CACHE_HOST=$(echo "$CACHE_PROXY" | sed 's|http://||;s|:.*||')
    _SQUID_URL="$CACHE_PROXY"
    _CACHE_EXPLICIT=true
else
    _CACHE_HOST="$DEFAULT_CACHE_HOST"
    _SQUID_URL="http://${DEFAULT_CACHE_HOST}:3128"
    _CACHE_EXPLICIT=false
fi
CACHE_PROXY=""   # set below only if the proxy actually answers

if [ -n "$_CACHE_HOST" ]; then
    # Olah HF mirror (:8090) — caches HuggingFace model weight downloads.
    if target_cmd "curl -s --max-time 3 'http://${_CACHE_HOST}:8090/api/whoami' > /dev/null 2>&1"; then
        HF_MIRROR="http://${_CACHE_HOST}:8090"
        echo -e "${GREEN}✓ HF Mirror: ${HF_MIRROR} (model downloads cached)${NC}"
    fi
    # Squid forward proxy — generic HTTP / Docker layer caching.
    _SQ_HOST=$(echo "$_SQUID_URL" | sed 's|http://||;s|:.*||')
    _SQ_PORT=$(echo "$_SQUID_URL" | sed 's|.*:||')
    if target_cmd "nc -z -w 2 '${_SQ_HOST}' '${_SQ_PORT}' 2>/dev/null || curl -sf --max-time 3 --proxy '' '${_SQUID_URL}' > /dev/null 2>&1"; then
        CACHE_PROXY="$_SQUID_URL"
        echo -e "${GREEN}✓ Cache Proxy: ${CACHE_PROXY}${NC}"
    fi
    if [ -z "$HF_MIRROR" ] && [ -z "$CACHE_PROXY" ]; then
        if [ "$_CACHE_EXPLICIT" = true ]; then
            echo -e "${YELLOW}⚠ Cache host ${_CACHE_HOST} unreachable — direct downloads this run${NC}"
        else
            echo -e "${YELLOW}⚠ No lab cache reachable (${_CACHE_HOST}) — model downloads go DIRECT${NC}"
            echo -e "${YELLOW}  On the lab network this usually means the cache VM is down or the host"
            echo -e "  changed — check PUGET_CACHE_HOST / --cache-proxy. Off-network this is expected.${NC}"
        fi
        # A tech at the console should get a chance to fix the cache instead of
        # silently pulling 40-120 GB from the internet. Non-interactive runs
        # (nohup, CI) keep the old fall-through behavior.
        if [ -t 0 ] && [ "$DRY_RUN" = false ]; then
            read -r -p "  Continue with direct downloads? [Y/n] " _cache_go
            if [[ "$_cache_go" =~ ^[Nn]$ ]]; then
                echo "  Aborting — bring up the cache (or pass --cache-proxy) and re-run."
                exit 1
            fi
        fi
    fi
fi

# ── HF mirror vs gated-model auth ──────────────────────────────────────────
# History: gated models 401'd through the Olah mirror, and the old workaround
# was "token present → bypass the mirror entirely", which silently gave up
# weight caching whenever anyone had logged into huggingface-cli. Olah forwards
# the Authorization header upstream, so token+mirror normally work TOGETHER —
# probe it and only bypass when the mirror genuinely can't forward auth.
HF_ENDPOINT_EFFECTIVE="${HF_MIRROR}"
if [ -n "$HF_MIRROR" ] && [ -n "${HF_TOKEN:-}" ]; then
    _auth_code=$(target_cmd "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Authorization: Bearer ${HF_TOKEN}' '${HF_MIRROR}/api/whoami-v2'" 2>/dev/null) || _auth_code=""
    if [ "$_auth_code" = "200" ]; then
        echo -e "${GREEN}✓ HF mirror forwards auth — gated models download THROUGH the cache${NC}"
    else
        HF_ENDPOINT_EFFECTIVE=""
        echo -e "${YELLOW}⚠ HF mirror does not forward auth (HTTP ${_auth_code:-none}) — bypassing the"
        echo -e "  mirror so gated models can authenticate. Downloads are NOT cached this run.${NC}"
    fi
fi

# Persistent model cache on remote host — survives across benchmark runs
MODEL_CACHE_DIR="/opt/puget-model-cache"
if ! target_cmd "sudo mkdir -p '$MODEL_CACHE_DIR' && sudo chmod 775 '$MODEL_CACHE_DIR'" 2>/dev/null; then
    if ! target_cmd "mkdir -p '$MODEL_CACHE_DIR'" 2>/dev/null; then
        # Use the remote user's home directory (not local $HOME)
        REMOTE_HOME=$(target_cmd "echo \$HOME" 2>/dev/null)
        MODEL_CACHE_DIR="${REMOTE_HOME:-/tmp}/puget-model-cache"
        target_cmd "mkdir -p '$MODEL_CACHE_DIR'" 2>/dev/null || true
        echo -e "  ${YELLOW}Using fallback cache dir: $MODEL_CACHE_DIR (no sudo for /opt)${NC}"
    fi
fi

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
    # Execute vllm_model_select.sh functions remotely and capture ALL variables.
    # Redirect stdin from /dev/null: the "Custom" menu entry runs `read -p` for a
    # model ID, and with the prompt suppressed by >/dev/null that read would
    # silently consume the operator's terminal input and hang the enumeration
    # (looks like a frozen cursor after picking "Run ALL"). </dev/null makes the
    # Custom/Skip entries hit EOF and return non-zero (correctly excluded).
    local remote_out
    remote_out=$(target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\"; detect_gpus >/dev/null; source \"$PACK_ROOT/scripts/lib/vllm_model_select.sh\"; if select_vllm_model \"$choice\" >/dev/null 2>&1 </dev/null; then echo \"OK|\$VLLM_MODEL_ID|\$VLLM_IMAGE|\$VLLM_GPU_COUNT|\$VLLM_GPU_MEM_UTIL|\$VLLM_DTYPE|\$VLLM_MAX_CTX|\$VLLM_REASONING_ARGS|\$VLLM_EXTRA_ARGS|\$VLLM_TOOL_CALL_ARGS|\$VLLM_THINKING_ARGS|\$VLLM_MODEL_SIZE_GB\"; else echo \"FAIL\"; fi' </dev/null")
    
    if [[ "$remote_out" == FAIL* || -z "$remote_out" ]]; then
        return 1
    fi
    echo "$remote_out"
    return 0
}

# ── Model manifest (app-pack scripts/list_models.sh) ────────────────────────
# Versioned TSV of every model the app-pack menus offer on this hardware —
# the single source of truth for the personal_llm matrix and per-model driver
# requirements. Older app-pack branches don't ship it; callers must handle a
# non-zero return by falling back to the legacy enumeration.
MODEL_MANIFEST=""
MANIFEST_CONTRACT_SUPPORTED=1
load_model_manifest() {
    [ -n "$MODEL_MANIFEST" ] && return 0
    target_cmd "[ -f \"$PACK_ROOT/scripts/list_models.sh\" ]" 2>/dev/null || return 1
    MODEL_MANIFEST=$(target_cmd "bash \"$PACK_ROOT/scripts/list_models.sh\"" 2>/dev/null) || { MODEL_MANIFEST=""; return 1; }
    local ver
    ver=$(echo "$MODEL_MANIFEST" | head -1 | awk -F'\t' '$1=="#PUGET_MODEL_MANIFEST"{print $2}')
    if [ "${ver:-0}" -gt "$MANIFEST_CONTRACT_SUPPORTED" ] 2>/dev/null; then
        echo -e "${YELLOW}⚠ App-pack model manifest is contract v${ver}; this bench understands v${MANIFEST_CONTRACT_SUPPORTED}.${NC}"
        echo -e "${YELLOW}  Update the bench (git pull) — falling back to legacy model enumeration.${NC}"
        MODEL_MANIFEST=""
        return 1
    fi
    [ -z "$ver" ] && { MODEL_MANIFEST=""; return 1; }
    return 0
}

manifest_rows() {  # manifest_rows PACK — TSV rows for one pack
    echo "$MODEL_MANIFEST" | awk -F'\t' -v p="$1" '$1==p'
}

# get_ollama_model_info CHOICE — resolve a personal_llm menu number through the
# LIVE app-pack menu (single source of truth). Echoes "TAG|VRAM_GB".
get_ollama_model_info() {
    local choice="$1" out
    out=$(target_cmd "bash -c 'export PUGET_NONINTERACTIVE=1; source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\"; detect_gpus >/dev/null 2>&1; source \"$PACK_ROOT/scripts/lib/ollama_model_select.sh\"; if select_ollama_model \"$choice\" >/dev/null 2>&1 </dev/null; then echo \"OK|\$OLLAMA_MODEL_TAG|\$OLLAMA_MODEL_VRAM_GB\"; else echo FAIL; fi'" 2>/dev/null)
    [[ "$out" == OK* ]] || return 1
    echo "${out#OK|}"
    return 0
}

show_ollama_menu_remote() {
    target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\" >/dev/null 2>&1; detect_gpus >/dev/null 2>&1; source \"$PACK_ROOT/scripts/lib/ollama_model_select.sh\" >/dev/null 2>&1; show_ollama_model_menu'"
}

define_run_all_matrix() {
    # ── Team LLM (vLLM) — enumerate the LIVE app-pack menu (single source of
    #    truth). select_vllm_model VRAM-gates each choice; get_vllm_model_info
    #    returns non-zero for insufficient-VRAM / Custom / Skip / out-of-range, so
    #    we keep exactly the models the menu would actually offer on this hardware.
    # Ask the live menu how many entries it has (MENU_MAX) so adding/removing models
    # in the app-pack flows through automatically — don't hardcode the upper bound.
    local _c _menu_max
    echo -e "  ${BLUE}Enumerating available models for this hardware...${NC}"
    _menu_max=$(target_cmd "bash -c 'source \"$PACK_ROOT/scripts/lib/gpu_detect.sh\" >/dev/null 2>&1; detect_gpus >/dev/null 2>&1; source \"$PACK_ROOT/scripts/lib/vllm_model_select.sh\" >/dev/null 2>&1; show_vllm_model_menu >/dev/null 2>&1; echo \${MENU_MAX:-12}'" 2>/dev/null)
    [[ "$_menu_max" =~ ^[0-9]+$ ]] || _menu_max=12
    # Store the RESOLVED model id (field 2 of "OK|id|image|...") as the display
    # name — the menu number stays in the choice field for execution, but the
    # matrix listing, results dirs, and resume markers key off the real model.
    local _vinfo _vid
    for _c in $(seq 1 "$_menu_max"); do
        if _vinfo=$(get_vllm_model_info "$_c" 2>/dev/null); then
            _vid=$(echo "$_vinfo" | cut -d'|' -f2)
            TEST_MATRIX+=("team_llm|${_c}|${_vid:-menu_choice_${_c}}|0||$CONCURRENCY")
        fi
    done

    # ── Personal LLM — enumerate the LIVE app-pack manifest (single source of
    #    truth; already VRAM-gated by the same select_* functions the installer
    #    uses). Falls back to querying the menu directly on app-pack branches
    #    that predate scripts/list_models.sh.
    if load_model_manifest; then
        local _row_engine _row
        while IFS=$'\t' read -r _mp _row_engine _mc _mid _msize _mdrv _mimg _mgpus _mdt _mctx; do
            [ -z "${_mid:-}" ] && continue
            if [ "$_row_engine" = "ollama" ]; then
                TEST_MATRIX+=("personal_llm|${_mc}|${_mid}|${_msize}|${_mid}|1")
            else
                # AMD personal_llm now ships llama.cpp — the bench has no
                # llama.cpp client path yet, so surface that instead of
                # silently benchmarking an engine the pack no longer uses.
                echo -e "  ${YELLOW}⚠ personal_llm on ${GPU_VENDOR} uses ${_row_engine} — not yet benchable, skipping ${_mid}${NC}"
            fi
        done < <(manifest_rows personal_llm)
    else
        # Legacy fallback: enumerate the app-pack Ollama menu directly.
        local _oc _oinfo
        for _oc in $(seq 1 12); do
            if _oinfo=$(get_ollama_model_info "$_oc"); then
                IFS='|' read -r _otag _ovram <<< "$_oinfo"
                TEST_MATRIX+=("personal_llm|${_oc}|${_otag}|${_ovram}|${_otag}|1")
            fi
        done
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

# Ollama menus/selection come from the app-pack (show_ollama_menu_remote /
# get_ollama_model_info above) — the bench used to keep its own copies, which
# drifted into three inconsistent model lists. Do not re-add local lists here.

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
            if ! _oinfo=$(get_ollama_model_info "$MODEL_CHOICE"); then
                echo -e "${RED}✗ Ollama menu choice ${MODEL_CHOICE} is invalid or needs more VRAM on this box.${NC}"
                exit 1
            fi
            IFS='|' read -r OLLAMA_MODEL_TAG _ <<< "$_oinfo"
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
            # Don't hardcode menu numbering — it differs per vendor/branch. Accept
            # any number and let the app-pack menu validate it; anything that
            # doesn't resolve (Custom, Skip, invalid) falls through to custom entry.
            read -p "  Select a model number (or 'c' for a custom HF ID): " MODEL_CHOICE
            if [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]] && _vinfo=$(get_vllm_model_info "$MODEL_CHOICE" 2>/dev/null); then
                _vid=$(echo "$_vinfo" | cut -d'|' -f2)
                echo -e "  ${GREEN}✓ Selected: ${_vid}${NC}"
                TEST_MATRIX+=("team_llm|${MODEL_CHOICE}|${_vid:-menu_choice_${MODEL_CHOICE}}|0||${CONCURRENCY}")
            else
                read -p "  Enter HuggingFace model ID (owner/model): " CUSTOM_MODEL
                if [ -z "$CUSTOM_MODEL" ]; then echo "  No model selected. Exiting."; exit 0; fi
                TEST_MATRIX+=("team_llm|custom|${CUSTOM_MODEL}|0||${CONCURRENCY}")
            fi
            ;;
        2)
            PACK="personal_llm"
            echo ""
            echo "  Select a model for Ollama (live app-pack menu):"
            echo ""
            show_ollama_menu_remote
            echo ""
            read -p "  Select a model number (or enter an Ollama tag directly): " MODEL_CHOICE
            if [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]]; then
                if _oinfo=$(get_ollama_model_info "$MODEL_CHOICE"); then
                    IFS='|' read -r OLLAMA_MODEL_TAG _ <<< "$_oinfo"
                    TEST_MATRIX+=("personal_llm|${MODEL_CHOICE}|${OLLAMA_MODEL_TAG}|0|${OLLAMA_MODEL_TAG}|1")
                else
                    echo -e "${RED}✗ Invalid selection (or insufficient VRAM for that model).${NC}"; exit 1
                fi
            elif [ -n "$MODEL_CHOICE" ]; then
                TEST_MATRIX+=("personal_llm|0|${MODEL_CHOICE}|0|${MODEL_CHOICE}|1")
            else
                echo "  No model selected. Exiting."; exit 0
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
            echo ""
            echo "  Test matrix (${#TEST_MATRIX[@]} benchmarks):"
            for entry in ${TEST_MATRIX[@]+"${TEST_MATRIX[@]}"}; do
                IFS='|' read -r e_pack e_choice e_name e_vram e_tag e_conc <<< "$entry"
                echo -e "    • ${GREEN}${e_pack}${NC} → ${e_name}"
            done
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
FAILED_BENCHMARKS=()      # FAIL/SKIP entries, each "model (reason)"
PASSED_BENCHMARKS=()      # models that completed cleanly, each "pack|model"
SUITE_START_EPOCH=$(date +%s)
declare -a BENCH_TIMINGS=()

format_duration() {
    local secs=$1
    local h=$((secs / 3600))
    local m=$(( (secs % 3600) / 60 ))
    local s=$((secs % 60))
    if [ $h -gt 0 ]; then printf '%dh %02dm %02ds' $h $m $s
    elif [ $m -gt 0 ]; then printf '%dm %02ds' $m $s
    else printf '%ds' $s; fi
}

if [ "$FRESH_CACHE" = true ]; then
    echo -e "${YELLOW}Clearing shared benchmark caches (--fresh-cache)...${NC}"
    target_cmd "docker run --rm -v shared_vllm_cache:/cache alpine rm -rf /cache/hub/*" 2>/dev/null || true
    target_cmd "docker run --rm -v shared_ollama_data:/data alpine rm -rf /data/*" 2>/dev/null || true
    target_cmd "docker volume prune -f 2>/dev/null; docker image prune -f 2>/dev/null" || true
else
    echo -e "${GREEN}✓ Keeping model caches (use --fresh-cache to clear)${NC}"
    target_cmd "docker image prune -f 2>/dev/null" || true
fi

for entry in "${TEST_MATRIX[@]}"; do
    IFS='|' read -r BENCH_PACK BENCH_CHOICE BENCH_MODEL BENCH_MIN_VRAM BENCH_OLLAMA_TAG BENCH_CONCURRENCY <<< "$entry"
    BENCH_COUNT=$((BENCH_COUNT + 1))
    BENCH_OK=true   # set false on any non-fatal failure that still reaches loop end
    EFF_INTERVAL=""  # per-model measurement window override (thinking models)

    _BENCH_START=$(date +%s)

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Benchmark ${BENCH_COUNT}/${BENCH_TOTAL}: ${BENCH_PACK} → ${BENCH_MODEL}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Skip LLM benchmarks if local Docker is unavailable (genai-perf needs it)
    if [ "${NO_LOCAL_DOCKER:-false}" = true ] && [ "$BENCH_PACK" != "comfy_ui" ]; then
        echo -e "  ${YELLOW}⚠ Skipping ${BENCH_MODEL} — local Docker required for genai-perf client.${NC}"
        FAILED_BENCHMARKS+=("${BENCH_MODEL} (skipped — no local Docker)")
        _BENCH_ELAPSED=$(( $(date +%s) - _BENCH_START ))
        BENCH_TIMINGS+=("${BENCH_PACK}|${BENCH_MODEL}|${_BENCH_ELAPSED}")
        continue
    fi

    SAFE_MODEL_NAME=$(echo "$BENCH_MODEL" | tr '/:' '_')

    # --resume: skip entries that already completed in a prior results dir.
    # Markers are written per (pack, model) on PASS, so a --run-all that died at
    # model 6/10 can pick up where it left off instead of redoing everything.
    if [ -n "$RESUME_DIR" ] && [ -f "$RESUME_DIR/${BENCH_PACK}_${SAFE_MODEL_NAME}/.done" ]; then
        echo -e "  ${GREEN}✓ Already completed in ${RESUME_DIR} — skipping (remove the .done marker to redo).${NC}"
        PASSED_BENCHMARKS+=("${BENCH_PACK}|${BENCH_MODEL} (from resume)")
        continue
    fi

    # Pre-flight: forcibly remove any stale bench containers left by aborted prior
    # runs, reap orphaned vLLM workers, and wait for the GPUs to be free so the
    # next model starts from a clean slate (prevents OOM / port-in-use wedges).
    target_cmd "docker rm -f puget_vllm puget_team_brain puget_team_webui puget_ollama 2>/dev/null; docker network prune -f 2>/dev/null" || true
    reap_workers_and_wait_gpu

    BENCH_RESULTS_DIR="$MASTER_RESULTS_DIR/${BENCH_PACK}_${SAFE_MODEL_NAME}"
    mkdir -p "$BENCH_RESULTS_DIR"

    if [ "$BENCH_PACK" != "comfy_ui" ]; then
        WORK_DIR="$REMOTE_TEMP_DIR/bench_${BENCH_PACK}_${SAFE_MODEL_NAME}"
        target_cmd "cp -r \"$PACK_ROOT/packs/$BENCH_PACK\" \"$WORK_DIR\""
        target_cmd "mkdir -p \"$WORK_DIR/scripts/lib\" && cp \"$PACK_ROOT/scripts/lib/\"*.sh \"$WORK_DIR/scripts/lib/\""
    fi

    if [ "$BENCH_PACK" = "team_llm" ]; then
        # HF_ENDPOINT: the mirror, unless the auth-forwarding probe above showed the
        # mirror can't pass gated-repo credentials through (then it's blank = direct).
        hf_endpoint_val="${HF_ENDPOINT_EFFECTIVE}"
        BENCH_MODEL_SIZE_GB=0   # known weight size (GB) — drives the monitor's download % display
        if [[ "$BENCH_CHOICE" == "custom" || ! "$BENCH_CHOICE" =~ ^[0-9]+$ ]]; then
            # Custom model
            custom_image="latest"
            custom_mem_util="0.90"
            if [ "$GPU_VENDOR" = "amd" ]; then
                custom_image="vllm/vllm-openai-rocm:v0.20.2"
                if [[ "$BENCH_MODEL" =~ 3[Bb] ]]; then
                    custom_mem_util="0.50"
                elif [[ "$BENCH_MODEL" =~ 8[Bb] ]]; then
                    custom_mem_util="0.65"
                elif [ "$GPU_COUNT" -gt 1 ]; then
                    custom_mem_util="0.75"
                else
                    custom_mem_util="0.80"
                fi
            elif [ "$GPU_VENDOR" = "intel" ]; then
                custom_image="intel/llm-scaler-vllm:0.14.0-b8.2.1"
            elif [ "$IS_BLACKWELL" = "true" ]; then
                # Blackwell (sm_120) needs CUDA 13 kernels — the stable image lacks them.
                custom_image="vllm/vllm-openai:cu130-nightly"
            else
                custom_image="vllm/vllm-openai:latest"
            fi
            # Allow forcing a specific GPU count for custom models (e.g. single-GPU TP=1)
            custom_gpu_count="${GPU_COUNT_OVERRIDE:-$GPU_COUNT}"
            target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
MODEL_ID=${BENCH_MODEL}
VLLM_IMAGE=${custom_image}
GPU_COUNT=${custom_gpu_count}
GPU_MEMORY_UTILIZATION=${custom_mem_util}
DTYPE=${DTYPE_OVERRIDE:-auto}
REASONING_ARGS=
TOOL_CALL_ARGS=
EXTRA_VLLM_ARGS=--enforce-eager
MAX_CONTEXT=${MAX_MODEL_LEN}
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
HF_ENDPOINT=${hf_endpoint_val}
HF_TOKEN=${HF_TOKEN}
HUGGINGFACE_TOKEN=${HF_TOKEN}
ENVEOF
        else
            vllm_info=$(get_vllm_model_info "$BENCH_CHOICE") || { echo -e "${RED}✗ Required ${BENCH_MIN_VRAM}GB VRAM for choice $BENCH_CHOICE. Skip.${NC}"; continue; }
            IFS='|' read -r status m_id m_img m_gpus m_mem m_dtype m_ctx m_reason m_extra m_tool m_thinking m_size <<< "$vllm_info"
            [[ "${m_size:-}" =~ ^[0-9]+$ ]] && BENCH_MODEL_SIZE_GB="$m_size"
            BENCH_MODEL="$m_id" # update to true ID
            # Blackwell (sm_120) needs CUDA 13 kernels. Some menu models (DeepSeek 70B,
            # GPT-OSS) pin the stable v0.20.2 image which lacks them — force cu130-nightly.
            if [ "$IS_BLACKWELL" = "true" ]; then
                m_img="vllm/vllm-openai:cu130-nightly"
            fi
            target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
MODEL_ID=${m_id}
VLLM_IMAGE=${m_img}
GPU_COUNT=${m_gpus}
GPU_MEMORY_UTILIZATION=${m_mem}
DTYPE=${DTYPE_OVERRIDE:-${m_dtype}}
MAX_CONTEXT=${MAX_MODEL_LEN:-${m_ctx}}
REASONING_ARGS=
EXTRA_VLLM_ARGS=${m_extra}
TOOL_CALL_ARGS=${m_tool}
THINKING_ARGS=${m_thinking}
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
HF_ENDPOINT=${hf_endpoint_val}
HF_TOKEN=${HF_TOKEN}
HUGGINGFACE_TOKEN=${HF_TOKEN}
ENVEOF
        fi

        # Reasoning/thinking models emit a long internal phase before visible output;
        # at conc=1 a 30s window can capture 0 completed requests. If the user didn't
        # set --measurement-interval, widen it to 120s for these. (The --reasoning-parser
        # is intentionally NOT written to the bench .env — it splits reasoning out of the
        # response so genai-perf under-counts decode throughput; we measure raw tokens.)
        if [ "$MEASUREMENT_INTERVAL_SET" = false ]; then
            if [ -n "${m_thinking:-}" ] || [ -n "${m_reason:-}" ] || echo "$BENCH_MODEL" | grep -qiE 'qwen3|deepseek-r1|qwq|reason|think'; then
                EFF_INTERVAL=120000
                echo -e "  ${BLUE}ℹ Reasoning model detected → using a 120s measurement window${NC}"
            fi
        fi

        echo -e "  ${BLUE}Starting vLLM on target machine...${NC}"

        # Inject HF_TOKEN and shared model cache via compose override.
        # The app-pack compose creates a per-project vllm_cache volume; we override
        # it to use a single shared external volume so models download once.
        target_cmd "docker volume create shared_vllm_cache 2>/dev/null || true"
        _ENV=""
        if [ -n "$HF_TOKEN" ]; then
            _ENV+="      - HF_TOKEN=${HF_TOKEN}\n      - HUGGINGFACE_TOKEN=${HF_TOKEN}\n      - HUGGINGFACE_HUB_TOKEN=${HF_TOKEN}\n"
        fi
        # AMD ROCm: override NVIDIA deploy block, add device mappings
        if [ "$GPU_VENDOR" = "amd" ]; then
            _OVERRIDE="services:\n  inference:\n"
            _OVERRIDE+="    deploy: {}\n"
            _OVERRIDE+="    privileged: true\n"
            _OVERRIDE+="    devices:\n      - /dev/dri:/dev/dri\n      - /dev/kfd:/dev/kfd\n"
            _ENV+="      - VLLM_TARGET_DEVICE=rocm\n      - NCCL_P2P_DISABLE=1\n      - HIP_FORCE_DEV_KERNARG=1\n"
        elif [ "$GPU_VENDOR" = "intel" ]; then
            # Intel XPU: the LLM-Scaler image reaches the GPU through the DRI render
            # node. Without this device mapping the container sees zero XPU devices
            # and vLLM aborts at startup with "Failed to infer device type" /
            # "XPU device count is zero". Mirrors the app-pack's docker-compose.intel.yml
            # (which install.sh layers on, but the bench writes its own override).
            _OVERRIDE="services:\n  inference:\n"
            _OVERRIDE+="    deploy: {}\n"
            _OVERRIDE+="    devices:\n      - /dev/dri:/dev/dri\n"
        else
            _OVERRIDE="services:\n  inference:\n"
            # NVIDIA multi-GPU: choose the NCCL transport by interconnect.
            # With NVLink, P2P is fast and reliable — keep it on. Without NVLink
            # (PCIe-only, e.g. 2x RTX PRO 6000), P2P over PCIe can deadlock during
            # distributed init, so disable it and let NCCL stage via shared mem/host.
            # Detect NVLink via the topology matrix: NVLink-connected GPU pairs show
            # an "NV<n>" token; PCIe-only pairs show SYS/NODE/PHB/PXB/PIX.
            if [ "$GPU_VENDOR" = "nvidia" ] && [ "${GPU_COUNT:-1}" -gt 1 ]; then
                nvlink_present=$(target_cmd "nvidia-smi topo -m 2>/dev/null | grep -E '^[[:space:]]*GPU[0-9]' | grep -oE 'NV[0-9]+' | head -1" 2>/dev/null || echo "")
                if [ -n "$nvlink_present" ]; then
                    echo -e "  ${GREEN}NVIDIA multi-GPU: NVLink detected → keeping NCCL P2P enabled${NC}"
                else
                    echo -e "  ${YELLOW}NVIDIA multi-GPU: no NVLink (PCIe) → setting NCCL_P2P_DISABLE=1 to avoid P2P hang${NC}"
                    _ENV+="      - NCCL_P2P_DISABLE=1\n"
                fi
            fi
        fi

        if [ -n "$_ENV" ]; then
            _OVERRIDE+="    environment:\n${_ENV}"
        fi
        _OVERRIDE+="volumes:\n  vllm_cache:\n    external: true\n    name: shared_vllm_cache\n"
        target_cmd "printf '${_OVERRIDE}' > \"${WORK_DIR}/docker-compose.override.yml\""

        # AMD ROCm multi-GPU: use Pipeline Parallelism instead of Tensor Parallelism.
        # vLLM V1's RCCL all-reduce deadlocks on PCIe-connected AMD GPUs during TP.
        # PP splits layers across GPUs sequentially, avoiding collective ops.
        # Read GPU_COUNT from the .env (may differ from hardware count for TP=1 models).
        env_gpu_count=$(target_cmd "grep '^GPU_COUNT=' \"${WORK_DIR}/.env\"" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "1")
        if [ "$GPU_VENDOR" = "amd" ] && [ "${env_gpu_count:-1}" -gt 1 ]; then
            echo -e "  ${YELLOW}AMD multi-GPU: switching from TP=${env_gpu_count} to PP=${env_gpu_count} (avoids RCCL deadlock)${NC}"
            target_cmd "sed -i 's/^EXTRA_VLLM_ARGS=.*/&  --tensor-parallel-size 1 --pipeline-parallel-size ${env_gpu_count}/' \"${WORK_DIR}/.env\""
            # PP on AMD may leave less room for KV cache. Increase GPU utilization
            # and cap context length to avoid OOM on large models.
            target_cmd "sed -i 's/^GPU_MEM_UTIL=.*/GPU_MEM_UTIL=0.95/' \"${WORK_DIR}/.env\"" 2>/dev/null || true
            env_max_ctx=$(target_cmd "grep '^MAX_CONTEXT=' \"${WORK_DIR}/.env\"" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
            if [ "${env_max_ctx:-0}" -gt 16384 ]; then
                echo -e "  ${YELLOW}PP mode: capping MAX_CONTEXT from ${env_max_ctx} to 16384 (KV cache headroom)${NC}"
                target_cmd "sed -i 's/^MAX_CONTEXT=.*/MAX_CONTEXT=16384/' \"${WORK_DIR}/.env\""
            fi
        fi

        # Gemma4 AWQ packed-expert weights: skip only on the Intel XPU backend (B70),
        # where it is known-unsupported. On NVIDIA/AMD, attempt it — let it run (or
        # fail honestly) rather than pre-skipping. Gemma must not be skipped off B70.
        if [ "$GPU_VENDOR" = "intel" ] && echo "$BENCH_MODEL" | grep -qi "gemma.4"; then
            echo -e "  ${YELLOW}⚠ Gemma4 AWQ is unsupported on the Intel XPU vLLM backend (packed-expert weights).${NC}"
            echo -e "  ${YELLOW}  Skipping benchmark on this hardware.${NC}"
            echo "SKIPPED: Gemma4 AWQ — Intel XPU vLLM lacks packed-expert weight support" > "$BENCH_RESULTS_DIR/SKIPPED.txt"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (unsupported on Intel XPU — packed experts)")
            _BENCH_ELAPSED=$(( $(date +%s) - _BENCH_START ))
            BENCH_TIMINGS+=("${BENCH_PACK}|${BENCH_MODEL}|${_BENCH_ELAPSED}")
            echo -e "  ${GREEN}⏱  ${BENCH_PACK} → ${BENCH_MODEL}: $(format_duration $_BENCH_ELAPSED)${NC}"
            continue
        fi

        # Large models (~70B+) default to a very long context (often 131K) whose KV
        # cache won't fit after the weights are loaded, so vLLM crash-loops at startup
        # ("max seq len needs N GiB KV cache > available"). Cap MAX_CONTEXT (when the
        # app-pack left it unset) to a value that still covers this run's actual needs
        # — the benchmark workload (input+output, or the --context-lengths sweep) is
        # far smaller than 131K. Generalizes the old DeepSeek-70B-specific cap.
        if echo "$BENCH_MODEL" | grep -qiE '7[02]b|11[0-9]b|12[0-9]b|[0-9]{3}b'; then
            if ! target_cmd "grep -q '^MAX_CONTEXT=.' \"$WORK_DIR/.env\"" 2>/dev/null; then
                _need_ctx=$(( ${INPUT_TOKENS:-500} + ${OUTPUT_TOKENS:-500} ))
                if [ -n "${CONTEXT_LENGTHS:-}" ]; then
                    _max_cl=$(echo "$CONTEXT_LENGTHS" | tr ',' '\n' | sort -n | tail -1)
                    [ "${_max_cl:-0}" -gt "$_need_ctx" ] && _need_ctx=$_max_cl
                fi
                _cap=$(( _need_ctx + 4096 ))
                [ "$_cap" -lt 32768 ] && _cap=32768
                echo -e "  ${YELLOW}Large model: capping MAX_CONTEXT to ${_cap} (KV-cache headroom after weights)${NC}"
                target_cmd "sed -i 's|^MAX_CONTEXT=$|MAX_CONTEXT=${_cap}|' \"$WORK_DIR/.env\""
            fi
        fi

        # Ensure the container image the model menu selected is present on the
        # target — build puget-* images from their Dockerfile, pull the rest.
        # This honors VLLM_IMAGE from the .env we just wrote (the old code
        # hardcoded the base image and ignored the menu's choice).
        EFFECTIVE_IMG=$(target_cmd "grep -m1 '^VLLM_IMAGE=' \"$WORK_DIR/.env\" | cut -d= -f2-" 2>/dev/null)

        # Driver ↔ container-CUDA gate: fail here in 2 seconds with a clear message
        # instead of 10 minutes later with "no kernel image is available" in a log dump.
        if ! bench_driver_ok "$EFFECTIVE_IMG"; then
            echo -e "  ${YELLOW}⚠ SKIP: ${BENCH_MODEL} needs NVIDIA driver ≥${BENCH_DRIVER_MIN} for its container"
            echo -e "    image (${EFFECTIVE_IMG}); this box has ${DRIVER_VERSION:-unknown}."
            echo -e "    Fix: upgrade the driver (app-pack setup.sh offers this) and reboot,"
            echo -e "    or pick a model on the stable image. Override: --skip-driver-check.${NC}"
            echo "SKIPPED: driver ${DRIVER_VERSION:-unknown} < required ${BENCH_DRIVER_MIN} for ${EFFECTIVE_IMG}" > "$BENCH_RESULTS_DIR/SKIPPED.txt"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (skipped — driver ${DRIVER_VERSION:-?} < ${BENCH_DRIVER_MIN} for ${EFFECTIVE_IMG})")
            _BENCH_ELAPSED=$(( $(date +%s) - _BENCH_START ))
            BENCH_TIMINGS+=("${BENCH_PACK}|${BENCH_MODEL}|${_BENCH_ELAPSED}")
            continue
        fi

        if ! ensure_vllm_image "$EFFECTIVE_IMG"; then
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (image unavailable: ${EFFECTIVE_IMG:-none})")
            _BENCH_ELAPSED=$(( $(date +%s) - _BENCH_START ))
            BENCH_TIMINGS+=("${BENCH_PACK}|${BENCH_MODEL}|${_BENCH_ELAPSED}")
            continue
        fi

        # Only start the vLLM inference service. The team_llm pack also defines
        # 'ui' (open-webui) and 'brain' (autogen, slow build) services that the
        # benchmark never touches — starting them rebuilds the autogen image on
        # every model. genai-perf hits inference:8000 directly.
        target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null; ${DOCKER_COMPOSE} up -d inference"
        echo ""

        echo -e "  ${YELLOW}Waiting for model to load by invoking vllm_monitor remotely (timeout ${MODEL_LOAD_TIMEOUT}s)...${NC}"
        # Bound the wait: a hung server (NCCL deadlock, OOM stall) would otherwise make
        # the monitor loop forever. On timeout, fall through to the API check below.
        if ! target_cmd "timeout ${MODEL_LOAD_TIMEOUT} bash -c 'source \"$WORK_DIR/scripts/lib/vllm_monitor.sh\" && wait_for_vllm \"puget_vllm\" \"${BENCH_MODEL_SIZE_GB:-0}\" \"${VLLM_STALL_SECONDS}\"'"; then
            echo -e "  ${YELLOW}⚠ Model did not become ready within ${MODEL_LOAD_TIMEOUT}s (or monitor exited).${NC}"
        fi

        if ! target_cmd "curl -s --max-time 5 http://localhost:8000/v1/models > /dev/null 2>&1"; then
            echo -e "  ${RED}✗ vLLM API not responding. Skipping.${NC}"
            diagnose_failure "$WORK_DIR" "vLLM"
            FAILED_BENCHMARKS+=("$BENCH_MODEL (vLLM failed)")
            BENCH_OK=false
            # Tear down the failed/hung container and free the GPUs before the next
            # model — otherwise a stuck server holds VRAM into the following run.
            target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null" || true
            reap_workers_and_wait_gpu
            continue
        fi

        API_MODEL=$(target_cmd "curl -s http://localhost:8000/v1/models 2>/dev/null | grep -o '\"id\":\"[^\"]*' | head -n 1 | cut -d'\"' -f4" || echo "$BENCH_MODEL")

        echo -e "  ${YELLOW}Pre-warming model to trigger Triton JIT compile...${NC}"
        target_cmd "curl -s -X POST http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"$API_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Pre-warmup: Puget Systems.\"}], \"max_tokens\": 50}' >/dev/null" || true

        echo ""
        start_power_monitor 2 || true
        if ! run_genai_perf_client "vllm" "${BENCH_URL_BASE}:8000" "$API_MODEL" "$BENCH_CONCURRENCY" "$BENCH_RESULTS_DIR"; then
            echo -e "  ${RED}✗ genai-perf failed for ${BENCH_MODEL}${NC}"
            echo -e "  ${YELLOW}Capturing vLLM logs for debugging...${NC}"
            target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} logs --tail 200 > /tmp/vllm_error_${BENCH_MODEL//\//_}.log"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (genai-perf failed)")
            BENCH_OK=false
        fi
        stop_power_monitor "$BENCH_RESULTS_DIR"

        # Tear down this model and free the GPUs before the next one. Plain `down`
        # keeps the external shared_vllm_cache volume (model weights) intact.
        target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null" || true
        reap_workers_and_wait_gpu

        # Optionally prune model from shared cache to save disk
        if [ "$FRESH_CACHE" = true ]; then
            HF_CACHE_DIR="models--$(echo "$BENCH_MODEL" | sed 's/\//--/g')"
            echo -e "  ${BLUE}Pruning $BENCH_MODEL from shared vLLM cache...${NC}"
            target_cmd "docker run --rm -v shared_vllm_cache:/cache alpine rm -rf \"/cache/hub/$HF_CACHE_DIR\"" 2>/dev/null || true
        fi
        # Prune per-benchmark volumes (open_webui_data) and dangling images to reclaim disk
        target_cmd "docker volume prune -f 2>/dev/null; docker image prune -f 2>/dev/null" || true

    elif [ "$BENCH_PACK" = "personal_llm" ]; then
        # AMD ROCm: use the official Ollama ROCm image
        _OLLAMA_IMG=""
        if [ "$GPU_VENDOR" = "amd" ]; then
            _OLLAMA_IMG="OLLAMA_IMAGE=ollama/ollama:rocm"
        fi
        target_cmd "cat > \"$WORK_DIR/.env\"" <<ENVEOF
PUGET_APP_NAME=puget-bench-ollama
${_OLLAMA_IMG}
CACHE_PROXY=${CACHE_PROXY}
HTTP_PROXY=${CACHE_PROXY}
HTTPS_PROXY=${CACHE_PROXY}
HF_TOKEN=${HF_TOKEN}
ENVEOF

        echo -e "  ${BLUE}Starting Ollama on target machine...${NC}"
        # Share a single Ollama data volume across all personal_llm benchmarks
        target_cmd "docker volume create shared_ollama_data 2>/dev/null || true"
        _OL_OVERRIDE="services:\n  inference:\n"
        # AMD ROCm: override NVIDIA deploy block, add device mappings
        if [ "$GPU_VENDOR" = "amd" ]; then
            _OL_OVERRIDE+="    deploy: {}\n"
            _OL_OVERRIDE+="    devices:\n      - /dev/dri:/dev/dri\n      - /dev/kfd:/dev/kfd\n"
        fi
        _OL_OVERRIDE+="volumes:\n  ollama_data:\n    external: true\n    name: shared_ollama_data\n"
        target_cmd "printf '${_OL_OVERRIDE}' > \"${WORK_DIR}/docker-compose.override.yml\""
        # Pull the latest Ollama image before starting — prevents 412 manifest
        # errors when pulling newer models that require a newer Ollama version.
        echo -e "  ${BLUE}Pulling latest Ollama container image...${NC}"
        target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} pull" 2>/dev/null || true
        target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null; ${DOCKER_COMPOSE} up -d"

        echo -e "  ${YELLOW}Waiting for Ollama API...${NC}"
        # Remote wait loop - ensure bash is used on remote for brace expansion
        if ! target_cmd "bash -c 'for i in {1..60}; do curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'"; then
             echo -e "  ${RED}✗ Ollama API not responding. Skipping.${NC}"
             diagnose_failure "$WORK_DIR" "Ollama"
             target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null"
             FAILED_BENCHMARKS+=("$BENCH_OLLAMA_TAG (Ollama failed)")
             continue
        fi

        echo -e "  ${BLUE}Pulling remote model: ${BENCH_OLLAMA_TAG}...${NC}"
        if ! target_cmd "docker exec puget_ollama ollama pull \"$BENCH_OLLAMA_TAG\""; then
             echo -e "  ${RED}✗ Failed to pull remote model. Skipping.${NC}"
             target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null"
             FAILED_BENCHMARKS+=("$BENCH_OLLAMA_TAG (pull failed)")
             continue
        fi

        # Pre-load the model into GPU VRAM before benchmarking.
        # Large models (e.g. 35B) can take 30+ seconds to load on first request,
        # which causes perf_analyzer to time out. This warm-up call ensures the
        # model is fully loaded and ready for inference.
        echo -e "  ${BLUE}Pre-loading model into VRAM...${NC}"
        if ! target_cmd "curl -sf --max-time 120 http://localhost:11434/api/generate -d '{\"model\": \"${BENCH_OLLAMA_TAG}\", \"keep_alive\": \"30m\"}' > /dev/null 2>&1"; then
            echo -e "  ${YELLOW}⚠ Model pre-load timed out, continuing anyway...${NC}"
        fi
        echo -e "  ${GREEN}✓ Model loaded and ready${NC}"

        echo ""
        # Ollama model names (e.g. qwen3.6:35b) contain colons which are invalid
        # HuggingFace repo IDs. genai-perf tries to auto-download the tokenizer
        # from HF using the model name, which fails. We use the Ollama API model
        # name as-is for the benchmark, but skip tokenizer-based metrics.
        if ! run_genai_perf_client "ollama" "${BENCH_URL_BASE}:11434" "$BENCH_OLLAMA_TAG" "$BENCH_CONCURRENCY" "$BENCH_RESULTS_DIR"; then
             echo -e "  ${RED}✗ genai-perf failed for ${BENCH_OLLAMA_TAG}${NC}"
             target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} logs --tail 200 > /tmp/ollama_error_${BENCH_MODEL//\//_}.log"
             FAILED_BENCHMARKS+=("${BENCH_OLLAMA_TAG} (genai-perf failed)")
             BENCH_OK=false
        fi

        # Prune specific model from Ollama to save disk
        echo -e "  ${BLUE}Pruning $BENCH_OLLAMA_TAG from shared Ollama data...${NC}"
        target_cmd "docker exec puget_ollama ollama rm \"$BENCH_OLLAMA_TAG\"" 2>/dev/null || true

        target_cmd "cd \"$WORK_DIR\" && ${DOCKER_COMPOSE} down -v 2>/dev/null"
        target_cmd "docker volume prune -f 2>/dev/null; docker image prune -f 2>/dev/null" || true

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
                # The flux2 workflow JSON references the FP8 text encoder by name, so we
                # must download exactly that. The previous VRAM-gated choice fetched the
                # bf16 encoder on >=48 GB GPUs (Spark, RTX PRO 6000), which never matched
                # the workflow's CLIPLoader -> HTTP 400 "value not in list" at submission.
                FLUX2_TEXT_ENC="mistral_3_small_flux2_fp8.safetensors"
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

        # AMD ROCm: use Dockerfile.rocm and inject device mappings
        if [ "$GPU_VENDOR" = "amd" ]; then
            target_cmd "cat > \"$COMFY_WORK_DIR/.env\"" <<COMFYENV
DOCKERFILE=Dockerfile.rocm
COMFYENV
            _COMFY_OVERRIDE="services:\n  app:\n    deploy: {}\n    user: root\n    privileged: true\n    devices:\n      - /dev/dri:/dev/dri\n      - /dev/kfd:/dev/kfd\n    environment:\n      - CLI_ARGS=--listen 0.0.0.0 --preview-method auto\n"
            target_cmd "printf '${_COMFY_OVERRIDE}' > \"${COMFY_WORK_DIR}/docker-compose.override.yml\""
        # Intel XPU: build the XPU Dockerfile and pass the DRI render node, mirroring
        # the app-pack's comfy docker-compose.intel.yml (smart_build reads DOCKERFILE
        # from .env). Without /dev/dri the container can't see the Arc GPU.
        elif [ "$GPU_VENDOR" = "intel" ]; then
            target_cmd "cat > \"$COMFY_WORK_DIR/.env\"" <<COMFYENV
DOCKERFILE=Dockerfile.xpu
COMFYENV
            _COMFY_OVERRIDE="services:\n  app:\n    deploy: {}\n    user: root\n    devices:\n      - /dev/dri:/dev/dri\n    environment:\n      - CLI_ARGS=--listen 0.0.0.0 --preview-method auto\n"
            target_cmd "printf '${_COMFY_OVERRIDE}' > \"${COMFY_WORK_DIR}/docker-compose.override.yml\""
        fi

        # CUDA/torch wheel selection (mirrors comfy_ui/init.sh). cu128 ships FP8 kernels
        # for sm_120 only; GB10/DGX Spark is sm_121 and needs CUDA 13 + torch cu130 or FP8
        # workflows (Flux.2) fail. Select cu130 for sm_12x>=1, keep cu128 for sm_120/RTX.
        COMFY_BUILD_ENV=""
        if [ "$IS_BLACKWELL" = "true" ] && [ "${COMPUTE_CAP%.*}" = "12" ] && [ "${COMPUTE_CAP#*.}" != "0" ]; then
            COMFY_BUILD_ENV="export CUDA_VERSION=13.0.2 TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130; "
            echo -e "  ${GREEN}sm_${COMPUTE_CAP/./} detected → building ComfyUI on CUDA 13 / torch cu130 (FP8 support)${NC}"
        fi

        # Build container (smart_build skips if fingerprint unchanged)
        echo -e "  ${BLUE}Building ComfyUI container on target machine (smart build)...${NC}"
        target_cmd "${COMFY_BUILD_ENV}bash -c 'source \"$COMFY_WORK_DIR/scripts/lib/smart_build.sh\" && cd \"$COMFY_WORK_DIR\" && smart_build'"

        # Launch
        echo -e "  ${BLUE}Starting ComfyUI on target machine...${NC}"
        # Fix ownership on volume-mount dirs (container runs as UID 999, GID 1500)
        target_cmd "mkdir -p \"$COMFY_WORK_DIR/output\" \"$COMFY_WORK_DIR/input\" \"$COMFY_WORK_DIR/custom_nodes\""
        target_cmd "chmod -R 777 \"$COMFY_WORK_DIR/output\" \"$COMFY_WORK_DIR/input\" 2>/dev/null || true"
        target_cmd "cd \"$COMFY_WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null; ${DOCKER_COMPOSE} up -d"

        # Wait for API (port 8188)
        echo -e "  ${YELLOW}Waiting for ComfyUI API on port 8188...${NC}"
        if ! target_cmd "bash -c 'for i in {1..60}; do curl -s --max-time 3 http://localhost:8188/api/system_stats >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1'"; then
            echo -e "  ${RED}✗ ComfyUI API not responding after 300s. Skipping.${NC}"
            diagnose_failure "$COMFY_WORK_DIR" "ComfyUI"
            target_cmd "cd \"$COMFY_WORK_DIR\" && ${DOCKER_COMPOSE} down 2>/dev/null"
            FAILED_BENCHMARKS+=("$BENCH_MODEL (ComfyUI failed to start)")
            continue
        fi
        echo -e "  ${GREEN}✓ ComfyUI API ready.${NC}"

        echo ""
        if ! run_comfyui_bench_client "$BENCH_CHOICE" "${BENCH_URL_BASE}:8188" "$BENCH_RESULTS_DIR"; then
            echo -e "  ${RED}✗ ComfyUI benchmark failed for ${BENCH_MODEL}${NC}"
            FAILED_BENCHMARKS+=("${BENCH_MODEL} (benchmark failed)")
            BENCH_OK=false
        fi

        target_cmd "cd \"$COMFY_WORK_DIR\" && ${DOCKER_COMPOSE} down -v 2>/dev/null"
        # Prune ComfyUI models (they are stored in the work dir)
        echo -e "  ${BLUE}Pruning ComfyUI models for ${BENCH_CHOICE}...${NC}"
        target_cmd "rm -rf \"$COMFY_WORK_DIR\"" 2>/dev/null || true
        target_cmd "docker image prune -f 2>/dev/null" || true
    fi
    _BENCH_ELAPSED=$(( $(date +%s) - _BENCH_START ))
    BENCH_TIMINGS+=("${BENCH_PACK}|${BENCH_MODEL}|${_BENCH_ELAPSED}")
    if [ "$BENCH_OK" = true ]; then
        PASSED_BENCHMARKS+=("${BENCH_PACK}|${BENCH_MODEL}")
        # Completion marker consumed by --resume on a later run
        touch "$BENCH_RESULTS_DIR/.done" 2>/dev/null || true
    fi
    echo -e "  ${GREEN}⏱  ${BENCH_PACK} → ${BENCH_MODEL}: $(format_duration $_BENCH_ELAPSED)${NC}"
    echo ""
done

SUITE_ELAPSED=$(( $(date +%s) - SUITE_START_EPOCH ))

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
echo "  Total wall time: $(format_duration $SUITE_ELAPSED)"
echo ""
echo -e "${BLUE}  Per-benchmark timing:${NC}"
printf '  %-15s %-35s %s\n' 'Pack' 'Model' 'Time'
printf '  %-15s %-35s %s\n' '───────────────' '───────────────────────────────────' '──────────'
for _t in ${BENCH_TIMINGS[@]+"${BENCH_TIMINGS[@]}"}; do
    IFS='|' read -r _tp _tm _ts <<< "$_t"
    printf '  %-15s %-35s %s\n' "$_tp" "$_tm" "$(format_duration $_ts)"
done

# ── Per-model status: PASS / FAIL / SKIP ──────────────────────────────────
echo ""
echo -e "${BLUE}  Status:${NC}"
_fail_n=0; _skip_n=0
_pass_n=${#PASSED_BENCHMARKS[@]}
for p in ${PASSED_BENCHMARKS[@]+"${PASSED_BENCHMARKS[@]}"}; do
    IFS='|' read -r _pp _pm <<< "$p"
    printf '    %bPASS%b  %-13s %s\n' "$GREEN" "$NC" "$_pp" "$_pm"
done
for fail in ${FAILED_BENCHMARKS[@]+"${FAILED_BENCHMARKS[@]}"}; do
    if echo "$fail" | grep -qiE "skip|unsupported"; then
        _skip_n=$((_skip_n + 1))
        printf '    %bSKIP%b  %s\n' "$YELLOW" "$NC" "$fail"
    else
        _fail_n=$((_fail_n + 1))
        printf '    %bFAIL%b  %s\n' "$RED" "$NC" "$fail"
    fi
done
echo ""
echo -e "  ${GREEN}${_pass_n} passed${NC}, ${RED}${_fail_n} failed${NC}, ${YELLOW}${_skip_n} skipped${NC} of ${BENCH_TOTAL} planned."
echo ""