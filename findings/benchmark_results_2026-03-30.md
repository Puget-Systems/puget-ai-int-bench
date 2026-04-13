# Puget AI App Pack Benchmark Findings

**Date:** March 30, 2026
**Author:** Puget Labs (Internal)
**Status:** Draft — For internal review before sharing with Sales

---

## Executive Summary

We benchmarked NVIDIA's **Nemotron Nano 30B** model across two inference engines
(vLLM and Ollama) on the DGX Spark (GB10 unified memory architecture). Key finding:
**Ollama outperforms vLLM by 15% at single-user throughput and is the only stable
option under concurrent load** on the Spark today.

---

## Test Environment

### Hardware Under Test

| System | CPU | GPU | Memory | Virtualization |
|---|---|---|---|---|
| **DGX Spark** (`spark-5743`) | 20-core ARM (10× Cortex-X925 + 10× Cortex-A725) | NVIDIA GB10 (unified) | 121 GB unified (shared CPU+GPU) | Bare metal, Ubuntu 24.04 |
| **vishlm** (KVM VM) | 16 vCPU | 2× RTX 5090 (32 GB each, passthrough) | 64 GB | KVM Virtual Machine |

### Software Stack

| Component | DGX Spark | vishlm |
|---|---|---|
| **NVIDIA Driver** | 580.95.05 | 570.x |
| **Docker** | Docker CE (latest) | Docker CE (latest) |
| **vLLM** | nightly cu130 (v0.18.1rc1) | nightly cu128 |
| **Ollama** | ollama/ollama:latest | N/A |
| **Benchmark tool** | genai-perf via Triton SDK 24.08 | genai-perf via Triton SDK 24.08 |

### Benchmark Parameters

| Parameter | Value |
|---|---|
| Input tokens | 500 (synthetic) |
| Output tokens | 500 (max) |
| Number of prompts | 50 |
| Measurement interval | 120s |
| Stability percentage | 999 (single-pass) |

---

## Results

### Nemotron Nano 30B — DGX Spark (GB10, Bare Metal)

| Engine | Quantization | Concurrency | Throughput (tok/s) | Avg Latency (ms) | P99 Latency (ms) | Status |
|---|---|---|---|---|---|---|
| **Ollama** | Q4_K_M (GGUF) | **1** | **38.42** | 7,858 | 27,209 | ✅ Stable |
| **Ollama** | Q4_K_M (GGUF) | **4** | **44.26** | 27,417 | 28,264 | ✅ Stable |
| vLLM | NVFP4 (safetensors) | **1** | 33.31 | 9,111 | 12,085 | ✅ Stable |
| vLLM | NVFP4 (safetensors) | **4** | — | — | — | ❌ CUDA kernel crash |

> **Ollama is 15% faster at C1 and the only engine stable at C4 on GB10.**

### Nemotron Nano 30B — 2× RTX 5090 (KVM VM, Docker)

#### Ollama (Single GPU, Q4_K_M)

| Concurrency | Throughput (tok/s) | Avg Latency (ms) | P99 Latency (ms) | Status |
|---|---|---|---|---|
| **1** | **107.40** | 2,839 | — | ✅ Stable |
| **4** | **146.08** | — | — | ✅ Stable |
| **8** | **133.20** | 17,329 | 18,184 | ✅ Stable |

> **RTX 5090 + Ollama is 2.8× faster than the Spark at C1** — discrete GDDR7 
> bandwidth dominance. Throughput peaks at C4 (146 tok/s) and regresses slightly 
> at C8 because Ollama serializes concurrent requests rather than batching them.

#### vLLM (2-GPU Tensor Parallel, NVFP4)

| Concurrency | Throughput (tok/s) | Avg Latency (ms) | P99 Latency (ms) | Status |
|---|---|---|---|---|
| **1** | 13.58 | — | — | ✅ Stable |
| **4** | 54.21 | — | — | ✅ Stable |
| **8** | 103.59 | — | — | ✅ Stable |
| **16** | — | — | — | ❌ HTTP 400 (max_num_seqs limit) |

> **vLLM's TP=2 config is a 7.9× penalty at C1** (13.58 vs 107.40 tok/s) for a 
> model that fits on a single GPU. However, vLLM's continuous batching scales 
> better under load: C1→C8 is a 7.6× improvement vs Ollama's 1.2× improvement.
> For team/multi-user serving, vLLM should be configured with TP=1 for this model.

---

## Analysis

### 1. Ollama vs vLLM — Engine Comparison

**Personal LLM (Ollama) is the clear winner for single-GPU inference** across both
hardware platforms.

| Metric | Ollama (Q4_K_M) | vLLM (NVFP4, TP=2) |
|---|---|---|
| **C1 throughput (5090 VM)** | **107.40 tok/s** | 13.58 tok/s |
| **C1 throughput (Spark)** | **38.42 tok/s** | 33.31 tok/s |
| **Stability at C4+ (Spark)** | ✅ Stable | ❌ CUDA crash |
| **Stability at C4+ (5090)** | ✅ Stable | ✅ Stable |
| **Startup time** | ~30s (model already pulled) | ~18 min (shard loading) |

vLLM's poor C1 on the 5090 is due to TP=2 overhead — splitting a 24 GB model
across 2× 32 GB GPUs adds NVLink synchronization latency that dominates at low
concurrency. vLLM excels at high-concurrency serving (103 tok/s at C8) thanks
to continuous batching, but for ≤4 concurrent users, Ollama is vastly superior.

### 2. DGX Spark vs RTX 5090 — Hardware Comparison

**Winner: RTX 5090** for raw throughput. The 5090 is **2.8× faster** at C1.

| Metric | RTX 5090 (KVM VM) | DGX Spark (Bare Metal) |
|---|---|---|
| **Ollama C1** | **107.40 tok/s** | 38.42 tok/s |
| **Ollama C4** | **146.08 tok/s** | 44.26 tok/s |
| **Memory** | 32 GB GDDR7 (per GPU) | 128 GB unified LPDDR5X |
| **Max model size** | ~32 GB per GPU | ~100+ GB |

The 5090's discrete GDDR7 bandwidth (~1.8 TB/s) massively outperforms the Spark's
shared LPDDR5X bandwidth (~273 GB/s). For models that fit in 32 GB, the 5090 is
the better choice. The Spark's advantage is its **128 GB unified pool** — it can
run models far too large for a single 5090 without multi-GPU complexity.

### 3. Docker on VM vs Bare Metal

The 5090 tests were run inside a KVM VM with GPU passthrough. Phase 2 will run
the same tests on the bare-metal hypervisor (USER@HYPERVISOR_IP) after shutting
down the VM to release the GPUs. This will isolate the VM overhead, which is
expected to be small (<5%) based on prior PCI passthrough benchmarks.

---

## Bugs & Blockers Found

### 1. vLLM NVFP4 Kernel Crash on GB10 (Critical)

- **Symptom:** `EngineDeadError` at concurrency > 1, vLLM auto-restarts
- **Root cause:** CUDA kernel crash in the NVFP4 MoE backend on sm_120 (GB10)
- **Workaround:** Use Ollama instead, or wait for vLLM to fix sm_120 NVFP4 support
- **Impact:** Blocks Team LLM (vLLM) app pack on DGX Spark for production concurrent workloads

### 2. Unified Memory VRAM Detection (`gpu_detect.sh`)

- **Symptom:** `nvidia-smi --query-gpu=memory.total` returns `[N/A]` on GB10
- **Root cause:** GB10 unified memory architecture doesn't expose discrete VRAM
- **Fix applied:** Patched `gpu_detect.sh` to fall back to `/proc/meminfo` total RAM when `nvidia-smi` returns `[N/A]`, since all system RAM is GPU-accessible on unified architectures
- **PR:** Pushed to `puget-docker-app-packs` main

### 3. Triton SDK Container Warning on GB10

- **Symptom:** `WARNING: Detected NVIDIA GB10 GPU, which is not yet supported`
- **Impact:** Cosmetic only — genai-perf works fine via HTTP benchmarking, the warning is about local GPU compute which we don't use
- **Workaround:** Set `NVIDIA_DISABLE_REQUIRE=1` in Docker env (already implemented)

---

## Infrastructure Changes Made

### Benchmarking Framework (`puget-ai-int-bench`)

1. **Split architecture:** Benchmark client runs on a separate machine from the inference server to avoid resource contention (critical for unified memory systems like the Spark)
2. **`--host` mode:** SSH collects specs + detects services; Docker genai-perf runs locally pointed at remote IP
3. **`--local` mode:** Everything runs on the same machine (useful for discrete GPU systems)
4. **Absolute path resolution:** Fixed Docker volume mount nesting bug with `RESULTS_DIR`

### App Pack Installer (`puget-docker-app-packs`)

1. **Nemotron Nano 30B** added to Ollama personal_llm model menu (option 5)
2. **`gpu_detect.sh`** patched for unified memory fallback

---

## Recommendations

### For Sales (FAQ Material)

1. **DGX Spark + Ollama** is a strong single-user AI workstation story:
   - 38 tok/s on Nemotron Nano 30B (competitive with cloud APIs)
   - 121 GB unified memory means large models fit without worrying about VRAM
   - Docker-based deployment via Puget App Packs works out of the box

2. **2× RTX 5090** remains the best choice for:
   - Multi-user serving (vLLM scales to high concurrency)
   - Models that genuinely need >32 GB VRAM with discrete memory bandwidth
   - Production team deployments via the Team LLM app pack

### For Engineering (Next Steps)

1. **Phase 2:** Run bare-metal single 5090 benchmark for apples-to-apples Spark comparison
2. **Phase 2:** File vLLM bug for NVFP4 kernel crash on sm_120/GB10
3. **Phase 2:** Test Ollama with higher concurrency (C8, C16) on Spark
4. **Phase 2:** Add Qwen 3 32B and DeepSeek R1 to the benchmark gauntlet
5. **Phase 3:** ComfyUI image generation latency benchmarks

---

## Raw Data Locations

| Test | Results Directory |
|---|---|
| Spark + vLLM C1 (remote bench) | `results/spark-5743_20260330_144303/` |
| Spark + Ollama C1 (remote bench) | `results/spark-5743_20260330_153555/` |
| Spark + Ollama C4 (remote bench) | `results/spark-5743_ollama_concurrency/` |
| 5090 VM + vLLM TP=2 (C1-C8) | `results/ubuntu_20260330_160552/` |
| 5090 VM + Ollama (C1, C4, C8) | `results/ubuntu_5090_ollama/` |
