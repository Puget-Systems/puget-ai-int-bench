# Puget Systems AI Internal Benchmarks

Automated benchmarking suite for Puget Systems Docker App Packs (Personal LLM, Team LLM, and ComfyUI). Run benchmarks **remotely from any machine** — the suite SSHes into the inference server, collects hardware specs, runs genai-perf, and copies results back.

## Quick Start

### 1. Set Up SSH Key Auth (One-Time)

The benchmark suite requires password-less SSH access to the inference server.

```bash
# If you don't already have an SSH key, generate one:
ssh-keygen -t ed25519 -C "puget-bench"

# Copy your public key to the inference server:
ssh-copy-id puget@172.19.168.179

# Verify it works (should connect without asking for a password):
ssh puget@172.19.168.179 "echo 'Key auth works!'"
```

### 2. Run Benchmarks

```bash
# Benchmark a remote inference server (primary use case)
./run_benchmarks.sh --host puget@172.19.168.179

# Custom concurrency levels
./run_benchmarks.sh --host puget@172.19.168.179 --concurrency "1,4,8,16,32"

# Use a specific SSH key
./run_benchmarks.sh --host puget@172.19.168.179 --ssh-key ~/.ssh/puget_bench

# Run locally on the inference server itself
./run_benchmarks.sh --local
```

### 3. Review Results

Results are saved to `results/<hostname>_<timestamp>/` containing:
- `system_specs.txt` — CPU, GPU, memory, OS, and VM/bare-metal detection
- `genai_perf_*/` — Per-concurrency-level benchmark data (JSON + CSV)

## Structure

| Path | Description |
|------|-------------|
| `run_benchmarks.sh` | Main orchestrator — handles SSH, spec collection, and result retrieval |
| `llm_tests/run_genai_perf.sh` | genai-perf runner (executes on the inference server) |
| `comfyui_tests/` | ComfyUI API benchmark scripts (coming soon) |
| `results/` | Output directory for benchmark results |

## How It Works

```
┌─────────────────┐        SSH        ┌──────────────────────────┐
│   Your Machine  │ ───────────────── │  Inference Server        │
│                 │                   │  (DGX Spark / VM / etc)  │
│ run_benchmarks  │  1. Collect specs │                          │
│     .sh         │  2. Detect packs  │  nvidia-smi / lscpu      │
│                 │  3. Run Docker    │  docker + genai-perf      │
│                 │  4. SCP results   │  vLLM / Ollama            │
│  results/       │ ◄──────────────── │  /tmp/puget_bench_*/      │
└─────────────────┘                   └──────────────────────────┘
```

## Notes

- **VM detection**: The spec file records whether the inference server is bare metal or a VM (via `systemd-detect-virt`), useful for comparing native vs virtualized performance.
- **Docker required**: The inference server must have Docker installed — genai-perf runs inside the `tritonserver:24.08-py3-sdk` container.
- **genai-perf container**: Does NOT need GPU access on the server — it's a CPU-side HTTP benchmarking client that sends requests to the LLM endpoint.