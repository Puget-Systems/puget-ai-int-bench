# Puget Systems AI App Pack — Internal Benchmark Suite

![Version](https://img.shields.io/github/v/tag/Puget-Systems/puget-ai-int-bench?label=version&sort=semver)

Fully automated performance benchmarking for [Puget Docker App Packs](https://github.com/Puget-Systems/puget-docker-app-packs). Downloads, installs, launches, benchmarks, and tears down App Packs automatically — no pre-configuration required.

## What This Tests

- **Team LLM** (vLLM) — multi-user serving via the `team_llm` app pack
- **Personal LLM** (Ollama) — single-user inference via the `personal_llm` app pack
- **ComfyUI** — image generation throughput and latency (Z-Image Turbo, Flux.2 Dev single/multi-GPU/DisTorch2)

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker** | With the NVIDIA Container Toolkit, on the GPU box |
| **GPU + Drivers** | `nvidia-smi` (NVIDIA), `rocm-smi` (AMD), or `clinfo` (Intel) must work on the box |
| **Git** | For cloning the App Pack repository |
| **Python 3** | For the summary report + ComfyUI benchmark client |

Run `./run_benchmarks.sh --doctor` on the box to confirm all of the above at once. (Remote `--host` mode additionally needs SSH access from wherever you launch it.)

## Quick Start

### On-Box Mode (Recommended)

Run the bench **directly on the GPU box** — copy the repo over (or clone it there) and run, no flags needed. genai-perf runs natively on the box alongside the server, so there's no SSH tunnel and concurrency scales cleanly. The lab cache is auto-detected.

```bash
# On the GPU box:
git clone git@github.com:Puget-Systems/puget-ai-int-bench.git
cd puget-ai-int-bench

# 1) Confirm the box is ready (Docker, GPU, disk, cache, port) — runs no benchmark
./run_benchmarks.sh --doctor

# 2) Interactive: pick a pack + model
./run_benchmarks.sh

# 2b) Or run the full VRAM-gated matrix unattended
./run_benchmarks.sh --run-all
```

The script will:
1. **Clone** the App Pack repository to a temp directory (verified against `checksums.md5`)
2. **Detect** your GPU hardware (vendor, model, VRAM, compute capability, NVLink/PCIe)
3. **Auto-use** the lab cache (Olah HF mirror + Squid) when reachable
4. **Prompt** you to select an App Pack and model/workflow (or use `--run-all`)
5. **Launch** the App Pack via `docker compose` and **wait** for load (bounded by `MODEL_LOAD_TIMEOUT`)
6. **Run** benchmarks (genai-perf for LLMs, ComfyUI REST/WebSocket client for image gen) with GPU power monitoring
7. **Tear down** the App Pack and free the GPUs
8. **Generate** a PASS/FAIL/SKIP summary report (text + Markdown)

### Non-Interactive Mode

```bash
# Benchmark a specific pack + model (on-box)
./run_benchmarks.sh --pack team_llm --model 1            # menu choice 1
./run_benchmarks.sh --pack team_llm --model Qwen/Qwen3-8B --gpu-count 1   # custom HF id, force TP=1
./run_benchmarks.sh --pack comfy_ui --comfy-iterations 10

# Validate setup without launching containers
./run_benchmarks.sh --run-all --dry-run
```

### Remote Mode (optional)

To orchestrate a *separate* box over SSH instead of running on it, add `--host USER@IP`. Note: genai-perf then runs on the GPU box natively (pushed over SSH), not tunneled — concurrency above ~10 over an SSH tunnel was unreliable, which is why on-box is preferred.

```bash
./run_benchmarks.sh --host USER@IP --run-all
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--host USER@IP` | *(on-box)* | SSH target. Omit (or `--host local`) to run on this machine. |
| `--doctor` | `false` | Read-only readiness check (Docker, GPU, disk, cache, port), then exit |
| `--gpu-count N` | *(auto)* | Force GPU count for custom models (e.g. `1` = single-GPU TP=1) |
| `--cache-proxy URL` | *(auto)* | Override the cache host. The lab cache (HF mirror :8090 + Squid :3128) is auto-detected; only needed to point elsewhere. |
| `--pack NAME` | *(interactive)* | `team_llm`, `personal_llm`, or `comfy_ui` |
| `--model CHOICE` | *(interactive)* | Model menu number, model ID/tag, or ComfyUI workflow name |
| `--run-all` | `false` | Run full VRAM-gated test matrix |
| `--dry-run` | `false` | Validate setup without launching containers |
| `--concurrency LIST` | `1,4,8,16` | Comma-separated concurrency levels (LLM only) |
| `--context-lengths LIST` | *(none)* | Comma-separated input token sizes to sweep (e.g. `4096,32768,131072`) |
| `--branch NAME` | `main` | App Pack git branch to clone |
| `--input-tokens N` | `500` | Default input token count (overridden by `--context-lengths`) |
| `--output-tokens N` | `500` | Max generation length (LLM only) |
| `--num-prompts N` | `50` | Prompts per concurrency level (LLM only) |
| `--comfy-iterations N` | `10` | Number of images per ComfyUI benchmark run |
| `--ssh-key PATH` | *(none)* | Path to SSH private key |

### Config File

Persist defaults in `~/.config/puget-bench/bench.conf`:

```bash
CACHE_PROXY=http://CACHE_PROXY_IP:3128
APP_PACK_BRANCH=main
CONCURRENCY=1,4,8,16
CONTEXT_LENGTHS=4096,32768,131072
```

See [bench.conf.example](bench.conf.example) for the template.

## Model Caching

The benchmark suite uses a three-tier caching strategy to avoid re-downloading multi-GB model weights:

1. **Work directory** — if the model is already in the benchmark work dir, use it
2. **Persistent cache** (`/opt/puget-model-cache`, or `~/puget-model-cache` without sudo) — survives across runs on the same host
3. **Fresh download** — from the lab HF mirror when reachable, else direct from HuggingFace

Infrastructure caching is **auto-detected** — no flags needed on the lab network:

- **Olah HF Mirror** (port 8090): caches HuggingFace model weights. The bench probes it and sets `HF_ENDPOINT` automatically when it answers.
- **Squid HTTP Proxy** (port 3128): generic HTTP / Docker layer caching, auto-detected the same way.
- Both run on the DGX Spark, provisioned via [puget-hypervisor-devops](https://github.com/Puget-Systems/puget-hypervisor-devops) Terraform (`olah_mirror` + `docker_cache_proxy`). Override the host with `PUGET_CACHE_HOST=<host>` or `--cache-proxy`; off-network the bench silently falls back to direct downloads.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  run_benchmarks.sh  (runs ON the GPU box in on-box mode;                 │
│                      orchestrates over SSH in --host mode)               │
│                                                                         │
│  1. git clone puget-docker-app-pack → /tmp (verified vs checksums.md5)  │
│  2. Detect GPU (vendor, VRAM, compute cap, NVLink/PCIe)                 │
│  3. Auto-detect lab cache (Olah HF mirror :8090, Squid :3128)          │
│  4. For each (pack, model) in test matrix:                              │
│                                                                         │
│     LLM packs (team_llm / personal_llm):                               │
│     ┌────────────────────────────────────────────────────────┐          │
│     │  Write .env (+ NCCL_P2P_DISABLE on PCIe multi-GPU)     │          │
│     │  docker compose up -d inference                        │          │
│     │  Wait for API health (vllm_monitor, MODEL_LOAD_TIMEOUT)│          │
│     │  genai-perf runs on the box → localhost:8000          │ ← on-box │
│     │  GPU power sampled throughout (vendor-specific)        │          │
│     │  docker compose down + reap workers, wait GPU-free     │          │
│     └────────────────────────────────────────────────────────┘          │
│                                                                         │
│     ComfyUI pack (comfy_ui):                                           │
│     ┌────────────────────────────────────────────────────────┐          │
│     │  Pre-download models, build + up -d (smart_build.sh)  │          │
│     │  Python bench client (REST + WebSocket) → localhost   │          │
│     │  docker compose down                                  │          │
│     └────────────────────────────────────────────────────────┘          │
│                                                                         │
│  5. generate_summary.py → summary.txt + summary.md                     │
└─────────────────────────────────────────────────────────────────────────┘
```

> **Note:** genai-perf runs **on the GPU box**, co-located with the inference server (reaching it at `localhost:8000`). Earlier versions tunneled genai-perf from a Mac over an SSH port-forward, but that throttled at concurrency above ~10; running on-box removes the tunnel and lets concurrency scale. The single SSH seam (`--host` mode) only orchestrates — the benchmark client still executes on the box.

## Benchmark Parameters

| Parameter | Default | Description |
|---|---|---|
| Input tokens | 500 | Synthetic prompt length |
| Output tokens | 500 | Max generation length |
| Num prompts | 50 | Prompts per concurrency level |
| Measurement interval | 120s | Duration of each measurement window |

## Repository Structure

```
puget-ai-int-bench/
├── run_benchmarks.sh              # Main automated orchestrator
├── bench.conf.example             # Configuration file template
├── scripts/
│   ├── remote_preflight.sh        # Auto-provisions Docker + NVIDIA drivers
│   └── collect_specs.sh           # Shared system specs collection helper
├── llm_tests/
│   ├── run_genai_perf.sh          # genai-perf Docker runner
│   └── generate_summary.py        # Summary report generator (txt + md)
├── comfyui_tests/
│   ├── run_comfyui_bench.sh       # Shell wrapper (venv setup, invokes Python)
│   ├── run_comfyui_bench.py       # Headless ComfyUI benchmark (REST + WebSocket)
│   ├── requirements.txt           # Python deps (requests, websockets)
│   └── workflows/                 # API-format workflow JSONs
│       ├── z_image_turbo_txt2img_api.json
│       ├── flux2_dev_txt2img_api.json
│       ├── flux2_dev_multigpu_txt2img_api.json
│       ├── flux2_dev_distorch2_txt2img_api.json
│       └── ..._2k_*.json          # 2048×2048 resolution variants
├── docs/
│   └── glossary.md                # Benchmark metrics glossary
├── archive/                        # Deprecated scripts kept for reference
├── findings/                       # Synthesized reports & analysis
└── results/                        # Raw benchmark data (per-run)
```

## "Run ALL" Default Matrix

When `--run-all` is specified, the following models are tested (filtered by available VRAM). Model choices map 1:1 to the app-pack menus.

### Team LLM (vLLM)

| # | Model | HF ID | Min VRAM | Notes |
|---|---|---|---|---|
| 1 | Qwen 3 (8B) | `Qwen/Qwen3-8B` | 16 GB | Fast, single GPU, always runs |
| 2 | Qwen 3 (32B FP8) | `Qwen/Qwen3-32B-FP8` | 40 GB | Near-lossless quality |
| 3 | Qwen 3.5 35B MoE AWQ | `cyankiwi/Qwen3.5-35B-A3B-AWQ-4bit` | 22 GB | 256K ctx |
| 4 | Qwen 3.5 122B MoE AWQ | `cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit` | 80 GB | Flagship, 128K ctx |
| 5 | DeepSeek R1 70B AWQ | `Valdemardi/DeepSeek-R1-Distill-Llama-70B-AWQ` | 40 GB | Reasoning specialist |
| 6 | Nemotron 3 Nano 30B | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4` | 20 GB | NVFP4, always runs |
| 7 | Nemotron 3 Super 120B | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 80 GB | NVFP4 flagship |
| 8 | Gemma 4 26B MoE AWQ | `cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit` | 20 GB | Google MoE, auto-skipped |


### Personal LLM (Ollama)

| # | Model | Tag | Min VRAM | Notes |
|---|---|---|---|---|
| 1 | Qwen 3 (8B) | `qwen3:8b` | 5 GB | Fast, Low VRAM, always runs |
| 2 | Qwen 3 (32B) | `qwen3:32b` | 20 GB | Best Quality, Single GPU |
| 3 | DeepSeek R1 (70B) | `deepseek-r1:70b` | 42 GB | Flagship Reasoning, Dual GPU |
| 4 | Llama 4 Scout | `llama4:scout` | 63 GB | Multimodal (text+image), Dual GPU |
| 5 | Nemotron 3 Nano (30B) | `nemotron-3-nano:30b` | 24 GB | NVIDIA MoE Reasoning, Single GPU |
| 6 | Nemotron 3 Super | `nemotron-3-super` | 96 GB | NVIDIA Flagship MoE, Multi-GPU |
| 7 | Gemma 4 (31B) | `gemma4:31b` | 20 GB | Google, Dense Instruct, Single GPU |


### ComfyUI (Image Gen)

| Workflow | Min VRAM | Notes |
|---|---|---|
| Z-Image Turbo (BF16) | 16 GB | Fast, high quality |
| Flux.2 Dev (FP8) | 40 GB | Flagship image gen |

## Documentation

- **[Benchmark Glossary](docs/glossary.md)** — What each metric means and how to interpret results
- **[Findings & Analysis](findings/)** — Detailed results and hardware-specific reports

## Tested Hardware

| System | GPU | Memory | Status |
|---|---|---|---|
| 4× RTX PRO 6000 Blackwell | 4× RTX PRO 6000 (96 GB each) | 754 GB | ✅ Ollama, ✅ vLLM (1,234 tok/s @ c16) |
| DGX Spark (GB10) | NVIDIA GB10 (unified) | 128 GB LPDDR5X | ✅ Ollama, ⚠️ vLLM (C4+ crash) |
| 2× RTX 5090 (KVM VM) | 2× RTX 5090 (32 GB each) | 64 GB | ✅ Ollama, ✅ vLLM |

See [`findings/`](findings/) for detailed results and analysis.

## Known Issues

- **Gemma 4 + vLLM:** Blocked upstream — vLLM does not yet support packed MoE expert weights. Auto-skipped by the orchestrator. Use the Ollama `gemma4:31b` variant instead.
- **vLLM + GB10:** NVFP4 MoE kernels crash at concurrency > 1 on sm_120 architecture. Use Ollama as a workaround.
- **Ollama silent CPU fallback:** If Docker loses GPU context (e.g., after VM suspend/resume), Ollama falls back to CPU without warning. Fix: `docker compose down && docker compose up -d`.
- **Triton SDK on GB10:** Emits a harmless "unsupported GPU" warning. Benchmarks work fine — genai-perf only uses CPU for HTTP request generation.
- **Multi-GPU without NVLink:** On PCIe-only multi-GPU boxes (e.g. 2× RTX PRO 6000), NCCL P2P over PCIe can deadlock during init. The bench auto-detects the interconnect and sets `NCCL_P2P_DISABLE=1` when there's no NVLink.

## License

MIT — See [LICENSE](LICENSE)

## Changelog

### v1.5.0

- **On-box mode is the primary path** — run `run_benchmarks.sh` directly on the GPU box (no `--host`). genai-perf executes on the box at `localhost:8000` instead of over an SSH tunnel, fixing concurrency throttling above ~10. `--host` still works for SSH orchestration.
- **`--doctor` readiness check** — verify Docker, GPU + interconnect, disk, port 8000, lab cache, and HF token without running a benchmark.
- **Automatic lab-cache discovery** — the Olah HF mirror (:8090) and Squid proxy (:3128) on the DGX Spark are auto-detected and used when reachable; no `--cache-proxy` needed. Override with `PUGET_CACHE_HOST` / `--cache-proxy`.
- **NVIDIA support hardening** — vendor auto-default, `nvidia-smi` power monitoring, NVLink/PCIe detection driving `NCCL_P2P_DISABLE`, and integrity verified against the `checksums.md5` manifest (matching `setup.sh`).
- **Robustness** — `MODEL_LOAD_TIMEOUT` bounds hung loads; the failure path now tears down + frees the GPU before continuing; power monitoring is non-fatal; bare-metal platform reporting fixed.
- **Cleanup** — one-off driver scripts moved to `archive/`; `run_benchmarks.sh` is the single entry point. Default App Pack branch is `main`.

### v1.4.0

- **Local genai-perf execution via SSH tunnel** — genai-perf now runs locally on macOS inside a Triton SDK container, connecting to the remote inference server via a dynamic SSH port-forward (`localhost:RANDOM → remote:8000`). This keeps the GPU node's resources fully dedicated to inference and bypasses macOS Docker's VPN network namespace isolation.
- **Docker Desktop required** — the Mac orchestrator now needs Docker Desktop running locally for genai-perf and ComfyUI benchmark containers.
- **HF Mirror detection fix** — the mirror health check no longer uses `curl -f`, which was incorrectly failing on a valid `401 Unauthorized` response from the HuggingFace mirror proxy.
- **Gemma 4 / vLLM auto-skip** — `Gemma4-26B-A4B-AWQ` is automatically skipped with a diagnostic message, pending upstream vLLM support for packed MoE expert weights.
- **Mandatory Ollama pre-loading** — uses `/api/generate` with `keep_alive` to force model load before benchmarking, preventing timeout failures.
- **Automated `docker compose pull`** — Ollama images are pulled before each run to prevent HTTP 412 manifest versioning errors.

### v1.3.0

- **Models now sourced from app-pack** — menus and `--run-all` matrix updated to exactly mirror `vllm_model_select.sh` and `ollama_model_select.sh` from `puget-docker-app-pack`; no more stale/guessed model lists
- **vLLM models (9 entries):** Qwen 3.6 35B, Qwen 3.5 35B + 122B, DeepSeek R1 70B, Nemotron 3 Nano + Super (NVFP4), Gemma 4 26B, GPT-OSS 20B + 120B (MXFP4)
- **Ollama models (6 entries):** Qwen 3.6 35B, DeepSeek R1 70B, Llama 4 Scout, Nemotron 3 Nano + Super, Gemma 4 31B
- **Context window sweeps** — `--context-lengths 4096,32768,131072` benchmarks each size in a separate pass; results saved per `ctx{N}_concurrency_{C}` subdirectory
- **Cache fully wired for all packs** — `HF_ENDPOINT`, `HTTP_PROXY`, `HTTPS_PROXY` now injected into vLLM and Ollama `.env` files so the Squid proxy and HF mirror are actually used by the model containers
- **Triton SDK image** updated to `25.04-py3-sdk`; `--sdk-image` override flag added to `run_genai_perf.sh`
- **VRAM gates** match app-pack exactly; interactive prompt counts updated to 1-11 (vLLM) and 1-7 (Ollama)

### v1.2.0

- **ComfyUI benchmark support** — full lifecycle: model pre-download, container build, headless benchmark via REST + WebSocket, teardown
- **7 workflow variants** — Z-Image Turbo, Flux.2 Dev × {single, MultiGPU, DisTorch2} × {1K, 2K} resolutions
- **Python benchmark client** — per-iteration timing, random seed injection, CSV + JSON output, VRAM snapshots
- **3-tier model caching** — work dir → `/opt/puget-model-cache` → fresh download (with HF mirror support)
- **HF mirror auto-detection** — derives mirror URL from `--cache-proxy` host on port 8090
- **`--comfy-iterations`** — configurable number of images per benchmark run (default: 10)
- **Security hardening** — tightened `chmod 775` (was 777), fixed wget pipeline exit-code masking, idempotent Dockerfile patching
- **Code quality** — hoisted `download_if_missing()` out of loop, skipped duplicate pack copies, added `requirements.txt`

### v1.1.0

- **Automated orchestration** — end-to-end provisioning, deployment, benchmarking, and teardown
- **Multi-model test matrix** — `--run-all` runs all VRAM-appropriate models automatically
- **Remote preflight** — auto-installs Docker, NVIDIA drivers, and Container Toolkit
- **Config file** — persist defaults in `~/.config/puget-bench/bench.conf`
- **Dual report output** — `summary.txt` (terminal) + `summary.md` (Markdown)
- **Benchmark glossary** — `docs/glossary.md` explains all metrics
- **Security** — sudo credentials passed via stdin, config file validated before sourcing
- **Archived** legacy SSH-based remote workflow

### v1.0.0

- Initial SSH-based remote benchmarking workflow
- genai-perf integration with Ollama and vLLM detection
- System specs collection and summary report generation