# Puget Systems AI App Pack — Internal Benchmark Suite

![Version](https://img.shields.io/github/v/tag/Puget-Systems/puget-ai-int-bench?label=version&sort=semver)

Fully automated performance benchmarking for [Puget Docker App Packs](https://github.com/Puget-Systems/puget-docker-app-packs). Downloads, installs, launches, benchmarks, and tears down App Packs automatically — no pre-configuration required.

## What This Tests

- **Team LLM** (vLLM) — multi-user serving via the `team_llm` app pack
- **Personal LLM** (Ollama) — single-user inference via the `personal_llm` app pack
- **ComfyUI** — image generation latency *(planned)*

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker** | With NVIDIA Container Toolkit |
| **NVIDIA GPU + Drivers** | `nvidia-smi` must work |
| **Git** | For cloning the App Pack repository |
| **Python 3** | For summary report generation |

## Quick Start

### Interactive Mode (Recommended)

```bash
# Clone this repo
git clone git@github.com:Puget-Systems/puget-ai-int-bench.git
cd puget-ai-int-bench

# Run the benchmark suite targeting a remote server (interactive prompts)
./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP

# With cache proxy for faster model downloads
./run_benchmarks.sh --host USER@IP --cache-proxy http://172.19.168.179:3128
```

The script will:
1. **Clone** the App Pack repository to a temp directory (with MD5 integrity check)
2. **Detect** your GPU hardware (model, VRAM, compute capability)
3. **Prompt** you to select an App Pack and model
4. **Launch** the App Pack via `docker compose`
5. **Wait** for the model to download and load (with progress monitoring)
6. **Run** genai-perf benchmarks at specified concurrency levels
7. **Tear down** the App Pack
8. **Generate** a summary report (text + Markdown)

### Non-Interactive Mode

```bash
# Benchmark a specific pack + model
./run_benchmarks.sh --host USER@IP --pack team_llm --model 1        # Qwen3-8B
./run_benchmarks.sh --host USER@IP --pack personal_llm --model 2     # qwen3:32b

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
| `--pack NAME` | *(interactive)* | `team_llm` or `personal_llm` |
| `--model CHOICE` | *(interactive)* | Model menu number (1-9) or model ID/tag |
| `--run-all` | `false` | Run full VRAM-gated test matrix |
| `--dry-run` | `false` | Validate setup without launching containers |
| `--concurrency LIST` | `1,4,8,16` | Comma-separated concurrency levels |
| `--branch NAME` | `main` | App Pack git branch to clone |
| `--input-tokens N` | `500` | Synthetic prompt length |
| `--output-tokens N` | `500` | Max generation length |
| `--num-prompts N` | `50` | Prompts per concurrency level |
| `--ssh-key PATH` | *(none)* | Path to SSH private key |

### Config File

Persist defaults in `~/.config/puget-bench/bench.conf`:

```bash
CACHE_PROXY=http://172.19.168.179:3128
APP_PACK_BRANCH=main
CONCURRENCY=1,4,8,16
```

See [bench.conf.example](bench.conf.example) for the template.

## Model Caching

The benchmark suite integrates with the existing Puget infrastructure cache:

- **Squid HTTP Proxy**: Caches HuggingFace model downloads on the LAN. Set `--cache-proxy` or `CACHE_PROXY` in your config.
- **NFS Model Server**: GPU VMs can mount shared model storage from the cache-proxy VM.
- Both are provisioned via [puget-hypervisor-devops](https://github.com/Puget-Systems/puget-hypervisor-devops) Terraform.

First download of a model goes through the proxy and is cached. Subsequent downloads (even on different machines on the same LAN) hit the cache.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  run_benchmarks.sh                                               │
│                                                                  │
│  1. git clone puget-docker-app-pack → /tmp (MD5 verified)       │
│  2. Source shared libs (gpu_detect, vllm_model_select, etc.)    │
│  3. For each (pack, model) in test matrix:                       │
│     ┌─────────────────────────────────────┐                      │
│     │  Write .env (model, cache proxy)    │                      │
│     │  docker compose up -d               │                      │
│     │  Wait for API health                │  ← vllm_monitor.sh  │
│     │  genai-perf benchmark               │  ← run_genai_perf.sh│
│     │  docker compose down                │                      │
│     └─────────────────────────────────────┘                      │
│  4. generate_summary.py → summary.txt + summary.md              │
└──────────────────────────────────────────────────────────────────┘
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
├── docs/
│   └── glossary.md                # Benchmark metrics glossary
├── archive/                        # Deprecated scripts kept for reference
├── comfyui_tests/                  # (Planned) ComfyUI latency benchmarks
├── findings/                       # Synthesized reports & analysis
└── results/                        # Raw benchmark data (per-run)
```

## "Run ALL" Default Matrix

When `--run-all` is specified, the following models are tested (filtered by available VRAM):

| Pack | Model | Min VRAM | Concurrency |
|---|---|---|---|
| Team LLM (vLLM) | Qwen/Qwen3-8B | 16 GB | 1 |
| Team LLM (vLLM) | Qwen/Qwen3-32B-FP8 | 40 GB | 1,4,8,16 |
| Personal LLM (Ollama) | qwen3:8b | 8 GB | 1 |
| Personal LLM (Ollama) | qwen3:32b | 32 GB | 1 |

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