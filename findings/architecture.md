# Puget AI Benchmark Infrastructure — Architecture Notes

**Date:** March 30, 2026
**Repo:** `puget-ai-internal-bench`

---

## Overview

The benchmarking suite is designed to validate Puget Systems' Docker-based AI App 
Packs (Team LLM, Personal LLM, ComfyUI) across different hardware configurations.
It produces standardized performance data for internal sales documentation and 
engineering validation.

---

## Architecture: Split Execution Model

```
┌─────────────────┐         SSH (specs + detection)        ┌─────────────────────┐
│  Bench Machine   │ ─────────────────────────────────────▸ │  Inference Server   │
│  (Mac / any x86) │                                       │  (DGX Spark / GPU)  │
│                  │         HTTP (inference API)           │                     │
│  genai-perf      │ ◂─────────────────────────────────── │  vLLM / Ollama      │
│  (Docker)        │  :8000 (vLLM) or :11434 (Ollama)     │  (Docker)           │
└─────────────────┘                                       └─────────────────────┘
```

**Why split?** Running the benchmark client on the same machine as the inference
server causes resource contention — especially on unified memory systems like the
DGX Spark where both processes compete for the same physical memory pool.

---

## Script Flow

### `run_benchmarks.sh` (Orchestrator)

```
1. Parse args (--host USER@IP or --local)
2. SSH → Collect system specs (lscpu, free, nvidia-smi, /etc/os-release)
3. SSH → Detect active app packs (curl ports 11434, 8000)
4. For each detected pack:
   a. Discover model name via API
   b. Run genai-perf Docker container LOCALLY, pointed at remote IP
5. Generate summary report (Python)
```

### `llm_tests/run_genai_perf.sh` (Benchmark Runner)

- Runs the `nvcr.io/nvidia/tritonserver:24.08-py3-sdk` container
- Uses `--net=host` for direct network access
- Sets `NVIDIA_DISABLE_REQUIRE=1` to bypass GPU checks (bench is CPU-only HTTP perf)
- Loops through concurrency levels, generating separate result directories

### `llm_tests/generate_summary.py` (Report Generator)

- Parses genai-perf CSV exports
- Produces human-readable summary table
- Includes system specs from the collected spec file

---

## Key Design Decisions

### 1. Why Docker for genai-perf?

genai-perf requires Linux + specific Python/protobuf dependencies. Running via the
official Triton SDK Docker image ensures reproducibility across bench machines
(Mac, Linux workstations, etc.) without polluting the host.

### 2. Why `--stability-percentage 999`?

Forces genai-perf to run a single measurement pass rather than iterating until
statistical stability. For our purposes, a single 120-second measurement window
is more useful than averaged micro-benchmarks, as it captures real-world variance
including model warm-up effects.

### 3. Why separate Ollama concurrency from vLLM?

The orchestrator defaults Ollama to C1 because Ollama's default configuration
serializes requests — concurrent requests queue rather than batch. Higher
concurrency tests are valid but the throughput scaling behavior is different
from vLLM's continuous batching. We run them separately to avoid conflating
the results.

---

## File Structure

```
puget-ai-internal-bench/
├── run_benchmarks.sh          # Main orchestrator
├── llm_tests/
│   ├── run_genai_perf.sh      # genai-perf runner (Docker)
│   └── generate_summary.py   # Summary report generator
├── findings/                  # Synthesized results & reports
│   ├── benchmark_results_2026-03-30.md
│   ├── spark_compatibility.md
│   └── architecture.md        # (this file)
└── results/                   # Raw benchmark data
    ├── spark-5743_20260330_*/  # Per-run directories
    └── ...
```

---

## Adding New Hardware / App Packs

### New Hardware Target

1. Ensure SSH key auth: `ssh-copy-id user@new-host`
2. Install the Docker App Pack on the target
3. Run: `./run_benchmarks.sh --host user@new-host`
4. Results appear in `results/{hostname}_{timestamp}/`

### New App Pack

1. Add detection logic in `run_benchmarks.sh` (curl the API port)
2. Add a new handler block that invokes `run_genai_perf.sh` with the right `--endpoint`
3. For non-OpenAI-compatible APIs, a new benchmark script may be needed (e.g., ComfyUI)
