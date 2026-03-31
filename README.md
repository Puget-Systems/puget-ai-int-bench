# Puget Systems AI App Pack — Internal Benchmark Suite

Standardized performance benchmarking for [Puget Docker App Packs](https://github.com/Puget-Systems/puget-docker-app-packs) across different hardware configurations. Produces reproducible throughput and latency data for internal sales documentation and engineering validation.

## What This Tests

- **Personal LLM** (Ollama) — single-user inference via the `personal_llm` app pack
- **Team LLM** (vLLM) — multi-user serving via the `team_llm` app pack
- **ComfyUI** — image generation latency *(planned)*

## Prerequisites

| Requirement | Where | Notes |
|---|---|---|
| **Docker** | Bench machine (your laptop/workstation) | Runs the genai-perf container locally |
| **SSH key auth** | Bench machine → inference server | Passwordless access for spec collection |
| **App Pack installed** | Inference server | At least one of: Personal LLM (port 11434) or Team LLM (port 8000) |

> **Important:** The benchmark client (genai-perf) runs on *your* machine, not on the inference server. This avoids resource contention — especially critical on unified memory systems like the DGX Spark.

## Quick Start

### 1. Set Up SSH Access (One-Time)

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -C "puget-bench"

# Copy it to the inference server
ssh-copy-id USER@INFERENCE_SERVER_IP

# Verify
ssh USER@INFERENCE_SERVER_IP "hostname && nvidia-smi --query-gpu=name --format=csv,noheader"
```

### 2. Run the Benchmark

```bash
# Clone this repo
git clone git@github.com:Puget-Systems/puget-ai-int-bench.git
cd puget-ai-int-bench

# Benchmark a remote inference server
./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP

# With custom concurrency levels (default: 1,4,8,16)
./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP --concurrency "1,4,8"

# With a specific SSH key
./run_benchmarks.sh --host USER@INFERENCE_SERVER_IP --ssh-key ~/.ssh/my_key
```

The orchestrator will:
1. **SSH** into the server to collect system specs (CPU, GPU, memory, OS, VM detection)
2. **Detect** which app packs are running (Ollama on :11434, vLLM on :8000)
3. **Discover** the active model name via the API
4. **Run genai-perf** locally in a Docker container, pointed at the remote server
5. **Generate** a summary report with throughput and latency tables

### 3. Review Results

Results are saved to `results/<hostname>_<timestamp>/`:

```
results/spark-5743_20260330_153555/
├── system_specs.txt                    # Hardware + OS snapshot
├── summary.txt                         # Human-readable results table
├── concurrency_1/
│   ├── profile_export_genai_perf.csv   # Detailed metrics
│   ├── profile_export_genai_perf.json  # Machine-readable export
│   └── llm_inputs.json                 # Synthetic prompts used
└── concurrency_4/
    └── ...
```

## Architecture

```
┌──────────────────────┐                          ┌──────────────────────────┐
│  Bench Machine       │    SSH (specs only)       │  Inference Server        │
│  (Mac / Linux / WSL) │ ────────────────────────▸ │  (DGX Spark / GPU VM)    │
│                      │                           │                          │
│  genai-perf          │    HTTP (inference API)    │  Ollama (:11434)         │
│  (Docker container)  │ ◂──────────────────────── │  — or —                  │
│                      │                           │  vLLM   (:8000)          │
│  results/            │                           │                          │
└──────────────────────┘                           └──────────────────────────┘
```

**Why split?** Running the benchmark client on the same machine as the inference engine causes memory contention and unreliable results — especially on unified memory systems (DGX Spark) where the CPU and GPU share the same RAM.

## Benchmark Parameters

| Parameter | Default | Description |
|---|---|---|
| `--concurrency` | `1,4,8,16` | Comma-separated concurrency levels to test |
| Input tokens | 500 | Synthetic prompt length |
| Output tokens | 500 | Max generation length |
| Num prompts | 50 | Prompts per concurrency level |
| Measurement interval | 120s | Duration of each measurement window |

## Repository Structure

```
puget-ai-int-bench/
├── run_benchmarks.sh              # Main orchestrator
├── llm_tests/
│   ├── run_genai_perf.sh          # genai-perf Docker runner
│   └── generate_summary.py        # Summary report generator
├── comfyui_tests/                  # (Planned) ComfyUI latency benchmarks
├── findings/                       # Synthesized reports & analysis
│   ├── benchmark_results_*.md      # Performance data & comparisons
│   ├── spark_compatibility.md      # DGX Spark / GB10 compatibility notes
│   └── architecture.md             # Infrastructure design docs
└── results/                        # Raw benchmark data (per-run)
```

## Tested Hardware

| System | GPU | Memory | Status |
|---|---|---|---|
| DGX Spark (GB10) | NVIDIA GB10 (unified) | 128 GB LPDDR5X | ✅ Ollama, ⚠️ vLLM (C4+ crash) |
| 2× RTX 5090 (KVM VM) | 2× RTX 5090 (32 GB each) | 64 GB | ✅ Ollama, ✅ vLLM |

See [`findings/`](findings/) for detailed results and analysis.

## Adding a New Test Target

1. Install a Puget App Pack on the target system ([instructions](https://github.com/Puget-Systems/puget-docker-app-packs))
2. Set up SSH key auth from your bench machine
3. Run: `./run_benchmarks.sh --host USER@NEW_TARGET_IP`
4. Results appear in `results/<hostname>_<timestamp>/`

## Known Issues

- **vLLM + GB10:** NVFP4 MoE kernels crash at concurrency > 1 on sm_120 architecture. Use Ollama as a workaround.
- **Ollama silent CPU fallback:** If Docker loses GPU context (e.g., after VM suspend/resume), Ollama falls back to CPU without warning. Fix: `docker compose down && docker compose up -d`. See [findings/spark_compatibility.md](findings/spark_compatibility.md#4-ollama-silent-cpu-fallback-all-platforms--critical).
- **Triton SDK on GB10:** Emits a harmless "unsupported GPU" warning. Benchmarks work fine — genai-perf only uses CPU for HTTP request generation.

## License

MIT — See [LICENSE](LICENSE)