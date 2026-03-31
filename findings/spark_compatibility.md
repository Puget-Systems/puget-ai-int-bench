# Puget AI App Pack — DGX Spark Compatibility Report

**Date:** March 30, 2026
**Hardware:** NVIDIA DGX Spark (`spark-5743`)
**Goal:** Validate Puget Docker App Packs on the GB10 unified memory architecture

---

## Summary

The DGX Spark uses NVIDIA's GB10 chip with a **unified memory architecture** — 
the CPU and GPU share a single 128 GB memory pool. This is fundamentally different
from discrete GPU systems (RTX 5090, A100, H100) where the GPU has its own dedicated 
VRAM. This difference triggers several compatibility issues in our App Pack stack.

---

## Compatibility Matrix

| App Pack | Status | Notes |
|---|---|---|
| **Personal LLM** (Ollama) | ✅ **Works** | Full GPU acceleration, 38+ tok/s on Nemotron Nano 30B |
| **Team LLM** (vLLM) | ⚠️ **Partial** | C1 works (33 tok/s), crashes at C4+ (NVFP4 kernel bug) |
| **ComfyUI** | 🔲 **Untested** | Planned for Phase 3 |
| **Docker Base** | ✅ **Works** | No GPU dependency |

---

## Issues & Fixes

### 1. `gpu_detect.sh` — VRAM Detection Failure

**Problem:** `nvidia-smi --query-gpu=memory.total` returns `[N/A]` on GB10 because
there is no discrete VRAM — the GPU uses unified system memory.

**Impact:** The installer's GPU detection (`detect_gpus` function) failed to determine
available VRAM, which gates model selection menus.

**Fix applied in `scripts/lib/gpu_detect.sh`:**

```bash
# Fallback for unified memory (GB10 / DGX Spark)
if [[ "$VRAM_MB" == "[N/A]" ]] || [[ -z "$VRAM_MB" ]]; then
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    VRAM_MB=$((TOTAL_MEM_KB / 1024))
fi
```

**Rationale:** On unified memory, all system RAM is GPU-accessible, so total system
memory is the correct value for VRAM gating decisions.

---

### 2. vLLM NVFP4 Kernel Crash (sm_120)

**Problem:** vLLM's nightly cu130 build crashes with `EngineDeadError` when serving
more than 1 concurrent request using the NVFP4 quantized Nemotron Nano model.

**Error trace:**
```
(EngineCore pid=209) For debugging consider passing CUDA_LAUNCH_BLOCKING=1
(EngineCore pid=209) Compile with `TORCH_USE_CUDA_DSA` to enable device-side assertions.
...
vllm.v1.engine.exceptions.EngineDeadError: EngineCore encountered an issue.
```

**Root cause:** The NVFP4 MoE kernels are not yet stable on sm_120 (GB10) architecture.
vLLM's `enforce_eager=True` workaround (which disables CUDA Graphs) doesn't fully
resolve the issue.

**Status:** Upstream bug. vLLM's GB10 support is experimental. Wait for stable vLLM
release with sm_120 validation.

**Workaround:** Use Ollama with Q4_K_M quantization, which is both faster and stable.

---

### 3. Triton SDK Container Warning

**Problem:** The genai-perf SDK container emits:
```
WARNING: Detected NVIDIA GB10 GPU, which is not yet supported in this version of the container
ERROR: No supported GPU(s) detected to run this container
```

**Impact:** None — genai-perf only uses CPU for HTTP request generation. The warning
is about local GPU compute capabilities, which are not needed for benchmarking.

**Workaround:** Set `NVIDIA_DISABLE_REQUIRE=1` in the Docker environment to suppress
the hard-fail check. Already implemented in `run_genai_perf.sh`.

---

### 4. Ollama Silent CPU Fallback (All Platforms — Critical)

**Problem:** If the NVIDIA Container Toolkit loses GPU context (e.g., after a VM
sleep/resume cycle, driver update, or system hibernation), Ollama **silently falls
back to CPU-only inference** with no user-facing error.

**Symptom:** Generation feels "slow" — ~5-10 tok/s instead of 100+ tok/s. The only
indicator is deep in the container logs:

```
ggml_cuda_init: failed to initialize CUDA: no CUDA-capable device is detected
offloading 0 repeating layers to GPU
offloaded 0/53 layers to GPU
```

**Impact:** Critical for customer experience. Users will think the hardware is slow
rather than diagnosing a container GPU passthrough issue.

**Fix:** Restart the container stack to re-establish CUDA device injection:
```bash
cd ~/personal_llm && docker compose down && docker compose up -d
```

**Recommendation for App Pack:** Add a GPU health check probe to the compose file
or `init.sh` that verifies `nvidia-smi` works inside the container on startup and
warns the user if GPU acceleration is unavailable.

---

### 5. Ollama ARM64 Compatibility

**Status:** ✅ Works out of the box.

Ollama's official `ollama/ollama:latest` Docker image includes ARM64 (aarch64) support.
The GB10's ARM Cortex-X925/A725 cores are fully supported. GPU acceleration via CUDA
on the unified memory works correctly.

---

## Architecture Notes for Developers

### Unified Memory Implications

1. **No VRAM OOM in the traditional sense.** The GPU can address all 128 GB of system
   memory. Instead of OOM, you'll see system-level memory pressure (swap thrashing).

2. **Memory contention.** Running both the inference server AND the benchmark client
   on the Spark causes them to compete for the same physical memory. Use the 
   split-architecture approach: run benchmarks from a separate machine.

3. **nvidia-smi reports `[N/A]` for memory.** All memory queries that assume discrete 
   VRAM will fail. Use `/proc/meminfo` as fallback.

4. **No multi-GPU tensor parallel.** There is only one GPU. Models that require TP>1
   (e.g., our default 2-GPU Nemotron config on 5090 systems) must be reconfigured 
   for TP=1.

### Recommended Spark Configuration

```env
# .env for team_llm on DGX Spark
MODEL_ID=nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4
GPU_COUNT=1
GPU_MEMORY_UTILIZATION=0.90
EXTRA_VLLM_ARGS=--enforce-eager
```

Or for personal_llm (recommended):
```bash
# After `docker compose up -d inference`:
docker compose exec inference ollama pull nemotron-3-nano:30b
```
