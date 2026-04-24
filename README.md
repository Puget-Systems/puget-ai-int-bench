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
| **Docker** | With NVIDIA Container Toolkit |
| **NVIDIA GPU + Drivers** | `nvidia-smi` must work |
| **Git** | For cloning the App Pack repository |
| **Python 3** | For summary report + ComfyUI benchmark client |

## Quick Start

### Interactive Mode (Recommended)

```bash
# Clone this repo
git clone git@github.com:Puget-Systems/puget-ai-int-bench.git
cd puget-ai-int-bench

# Run the benchmark suite targeting a remote server (interactive prompts)
./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP

# With cache proxy for faster model downloads
./run_benchmarks.sh --host USER@IP --cache-proxy http://CACHE_PROXY_IP:3128
```

The script will:
1. **Clone** the App Pack repository to a temp directory (with MD5 integrity check)
2. **Detect** your GPU hardware (model, VRAM, compute capability)
3. **Prompt** you to select an App Pack and model/workflow
4. **Pre-download** model weights (with persistent caching + optional HF mirror)
5. **Launch** the App Pack via `docker compose`
6. **Wait** for the model to download and load (with progress monitoring)
7. **Run** benchmarks (genai-perf for LLMs, or ComfyUI REST/WebSocket client for image gen)
8. **Tear down** the App Pack
9. **Generate** a summary report (text + Markdown)

### Non-Interactive Mode

```bash
# Benchmark a specific pack + model
./run_benchmarks.sh --host USER@IP --pack team_llm --model 1        # Qwen3-8B
./run_benchmarks.sh --host USER@IP --pack personal_llm --model 2     # qwen3:32b

# ComfyUI benchmarks
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model z_image_turbo
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev_multigpu
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev_distorch2
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev_2k          # 2K resolution variants
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev_multigpu_2k
./run_benchmarks.sh --host USER@IP --pack comfy_ui --model flux2_dev_distorch2_2k

# Run ALL VRAM-appropriate models automatically
./run_benchmarks.sh --host USER@IP --run-all

# Validate setup without launching containers
./run_benchmarks.sh --host USER@IP --dry-run
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--host USER@IP` | *(required)* | SSH target for the remote inference server |
| `--cache-proxy URL` | *(none)* | Squid cache proxy for model downloads |
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
2. **Persistent cache** (`/opt/puget-model-cache`) — survives across benchmark runs on the same host
3. **Fresh download** — from HuggingFace (or HF mirror if `--cache-proxy` is set)

Additional infrastructure caching:

- **Squid HTTP Proxy**: Caches HuggingFace model downloads on the LAN. Set `--cache-proxy` or `CACHE_PROXY` in your config.
- **HF Mirror** (port 8090): Auto-detected from the cache proxy host. Rewrites HuggingFace URLs to the local mirror.
- **NFS Model Server**: GPU VMs can mount shared model storage from the cache-proxy VM.
- Both are provisioned via [puget-hypervisor-devops](https://github.com/Puget-Systems/puget-hypervisor-devops) Terraform.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  run_benchmarks.sh                                                   │
│                                                                      │
│  1. git clone puget-docker-app-pack → /tmp (MD5 verified)           │
│  2. Source shared libs (gpu_detect, vllm_model_select, etc.)        │
│  3. For each (pack, model) in test matrix:                           │
│                                                                      │
│     LLM packs (team_llm / personal_llm):                            │
│     ┌──────────────────────────────────────────┐                     │
│     │  Write .env (model, cache proxy)         │                     │
│     │  docker compose up -d                    │                     │
│     │  Wait for API health                     │ ← vllm_monitor.sh  │
│     │  genai-perf benchmark                    │ ← run_genai_perf.sh│
│     │  docker compose down                     │                     │
│     └──────────────────────────────────────────┘                     │
│                                                                      │
│     ComfyUI pack (comfy_ui):                                        │
│     ┌──────────────────────────────────────────┐                     │
│     │  Pre-download models (3-tier cache)       │                     │
│     │  Install MultiGPU extension (if needed)  │                     │
│     │  docker compose build + up -d            │ ← smart_build.sh   │
│     │  Wait for API (:8188)                    │                     │
│     │  Python bench client (REST + WebSocket)  │ ← run_comfyui_bench│
│     │  docker compose down                     │                     │
│     └──────────────────────────────────────────┘                     │
│                                                                      │
│  4. generate_summary.py → summary.txt + summary.md                  │
└──────────────────────────────────────────────────────────────────────┘
```

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
| 1 | Qwen 3.6 35B MoE AWQ | `cyankiwi/Qwen3.6-35B-A3B-AWQ-4bit` | 22 GB | 128K ctx, always runs |
| 2 | Qwen 3.5 35B MoE AWQ | `cyankiwi/Qwen3.5-35B-A3B-AWQ-4bit` | 22 GB | 256K ctx |
| 3 | Qwen 3.5 122B MoE AWQ | `cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit` | 80 GB | 128K ctx |
| 4 | DeepSeek R1 70B AWQ | `Valdemardi/DeepSeek-R1-Distill-Llama-70B-AWQ` | 40 GB | Reasoning specialist |
| 5 | Nemotron 3 Nano 30B | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4` | 20 GB | NVFP4, always runs |
| 6 | Nemotron 3 Super 120B | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | 80 GB | NVFP4 flagship |
| 7 | Gemma 4 26B MoE AWQ | `cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit` | 20 GB | Google MoE |
| 8 | GPT-OSS 20B MXFP4 | `openai/gpt-oss-20b` | 16 GB | OpenAI open-weight, always runs |
| 9 | GPT-OSS 120B MXFP4 | `openai/gpt-oss-120b` | 80 GB | OpenAI flagship open-weight |

### Personal LLM (Ollama)

| # | Model | Tag | Min VRAM | Notes |
|---|---|---|---|---|
| 1 | Qwen 3.6 35B MoE | `qwen3.6:35b` | 24 GB | Agentic coding, 256K ctx |
| 2 | DeepSeek R1 70B | `deepseek-r1:70b` | 42 GB | Flagship reasoning |
| 3 | Llama 4 Scout | `llama4:scout` | 63 GB | Multimodal (text+image) |
| 4 | Nemotron 3 Nano 30B | `nemotron-3-nano:30b` | 24 GB | NVIDIA MoE reasoning |
| 5 | Nemotron 3 Super | `nemotron-3-super` | 96 GB | NVIDIA flagship MoE |
| 6 | Gemma 4 31B | `gemma4:31b` | 20 GB | Google dense instruct |

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

- **vLLM + GB10:** NVFP4 MoE kernels crash at concurrency > 1 on sm_120 architecture. Use Ollama as a workaround.
- **Ollama silent CPU fallback:** If Docker loses GPU context (e.g., after VM suspend/resume), Ollama falls back to CPU without warning. Fix: `docker compose down && docker compose up -d`.
- **Triton SDK on GB10:** Emits a harmless "unsupported GPU" warning. Benchmarks work fine — genai-perf only uses CPU for HTTP request generation.

## License

MIT — See [LICENSE](LICENSE)

## Changelog

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