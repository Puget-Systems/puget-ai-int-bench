# AMD Radeon AI PRO R9700: Dual-GPU AI Inference Performance

**How do two AMD Radeon AI PRO R9700 GPUs perform for local LLM inference and image generation?**

---

## Introduction

In our [Intel Arc Pro B70 article](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/), we explored what a VRAM-first, multi-GPU inference workstation looks like when built around Intel's 32 GB cards. This article asks the same question of AMD's entry in that fight.

The Radeon AI PRO R9700 is the first RDNA 4 professional card positioned squarely at local AI inference. At 32 GB of GDDR6 VRAM per card and 640 GB/s of memory bandwidth, it occupies the same VRAM tier as the Arc Pro B70 - but with higher bandwidth and AMD's mature ROCm software stack backing it. At roughly $1,880 (configured pricing, July 2026; AMD's MSRP is $1,299), the R9700 substantially undercuts the NVIDIA RTX 5090 (~$4,130) while matching it on raw VRAM capacity. Two R9700 cards (~$3,760) deliver 64 GB of aggregate VRAM - the same total capacity as two RTX 5090s (~$8,260), at less than half the cost.

The question we set out to answer: **can two R9700 cards deliver production-quality local LLM inference and image generation - and how does AMD's approach stack up against the four-card B70 configuration we already tested?**

We installed two R9700 cards in a Puget Systems workstation and tested single-GPU baselines, dual-GPU pipeline parallelism, generative image workloads, and a 27B-parameter dense model that requires both cards to run. We also instrumented GPU power draw during every benchmark to calculate real-world cost-per-token - and compare it against today's frontier cloud APIs, where output pricing now ranges from $5/1M tokens (Claude Haiku 4.5) to $25/1M tokens (Claude Opus 4.8).

---

## Test Setup

| Component | Spec |
|-----------|------|
| **GPUs** | 2× AMD Radeon AI PRO R9700 (RDNA 4 / gfx1201) |
| **PCI Device ID** | `1002:7551` |
| **VRAM per GPU** | 32 GB GDDR6 |
| **Total VRAM** | 64 GB |
| **Compute Units** | 64 per GPU |
| **AI Accelerators** | 128 per GPU |
| **AI Performance** | 766 TOPS (INT8) / 1531 TOPS (INT4) per GPU |
| **Memory Bandwidth** | 640 GB/s per GPU |
| **Infinity Cache** | 64 MB per GPU |
| **TDP** | 300W per GPU |
| **Host System** | Puget Systems workstation, Intel® Xeon® 658X CPU (24 cores / 48 threads), 128 GB RAM |
| **OS** | Ubuntu 25.04 (Plucky Puffin) |
| **PCIe** | PCIe 5.0 x16, 2 slots |

**Inference Software:** All LLM benchmarks used `vllm/vllm-openai-rocm:v0.20.2` with unquantized FP16 weights. Multi-GPU models used Pipeline Parallelism (PP=2) instead of Tensor Parallelism to avoid RCCL all-reduce deadlocks on PCIe-connected AMD GPUs (see [Setup Notes](#setup-notes-for-practitioners)). Image generation used ComfyUI with `rocm/pytorch:latest` and the Z-Image Turbo model.

**Benchmark Tool:** NVIDIA GenAI-Perf with `--streaming` mode enabled for all LLM tests. Each test used 500 synthetic input tokens, 500 output tokens, and 50 prompts with a 30-second measurement interval for standard models. Thinking/reasoning models (Qwen3 8B) used a 120-second measurement interval and 20 prompts to properly capture the extended reasoning phase. Concurrency levels tested: 1, 4, and 8 simultaneous users.

**Power Monitoring:** GPU power draw was measured throughout each benchmark by polling the AMD kernel driver's `sysfs hwmon` interface (`power1_average`, reported in microwatts) every 2 seconds. This captures real power consumption under inference load, not just TDP ratings.

---

## What Models Fit?

Before looking at performance numbers, it's important to understand what models can run on this hardware. The ROCm-native vLLM container supports unquantized FP16 and GPTQ/AWQ quantized weights. All benchmarks in this article use full FP16 weights for a clean comparison against our [Intel Arc Pro B70 results](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/).

| Model | Type | Params | FP16 VRAM | Fits 1× R9700 (32 GB)? | Fits 2× R9700 (64 GB)? |
|-------|------|--------|-----------|------------------------|------------------------|
| **Qwen2.5 3B Instruct** | Dense | 3B | ~6 GB | ✅ Yes | ✅ Yes |
| **Qwen3 8B** | Dense (thinking) | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **Llama 3.1 8B Instruct** | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **DeepSeek R1 Distill 8B** | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **Qwen3.6-27B** | Dense | 27B | ~54 GB | ❌ No | ✅ **Tested** |
| **Qwen3.6-35B-A3B** | MoE | 35B (3B active) | ~70 GB | ❌ No | ❌ No |
| Gemma 4 31B | Dense | 31B | ~62 GB | ❌ No | ⚠️ Requires bfloat16 |
| Llama 4 Scout | MoE | 109B (17B active) | ~218 GB | ❌ No | ❌ No |
| DeepSeek V4 Flash | MoE | 284B (13B active) | ~568 GB | ❌ No | ❌ No |

A single R9700 comfortably runs everything up to 8B parameters. The 27B tier - currently the sweet spot for capable local inference - requires both cards working together. Models above 64 GB (35B MoE and up) would need additional cards or quantization. For context: the largest open-weight models (DeepSeek V4 Flash at 568 GB) remain firmly out of reach for any workstation-class hardware - those are datacenter territory.

---

## Single-GPU Performance

We started by establishing what a single R9700 can deliver. Each model was tested at concurrency levels 1, 4, and 8 to measure both interactive responsiveness and throughput under load.

### Summary: Single-GPU Results (Concurrency = 1)

| Model | Throughput (tok/s) | TTFT (ms) | ITL (ms) | Avg Latency |
|-------|-------------------|-----------|----------|-------------|
| **Qwen2.5 3B Instruct** | **81.1** | 76 ms | 12 ms | 4.1s |
| **DeepSeek R1 Distill 8B** | **61.3** | 167 ms | 16 ms | 12.8s |
| **Qwen3 8B** | **37.4** | 105 ms | 27 ms | 13.4s |
| **Llama 3.1 8B Instruct** | **31.9** | 142 ms | 31 ms | 8.7s |

*All tests: 500 input tokens, 500 output tokens, FP16, enforce-eager, single R9700, max-model-len 32768. Qwen3 8B used a 120-second measurement interval to accommodate its reasoning/thinking token generation.*

The data reveals a clear performance story:

- **3B models** hit 81.1 tok/s — output appears nearly instantaneous. The 76 ms TTFT is competitive with cloud API response times. At 12 ms ITL (Inter-Token Latency), each token arrives in real time with no perceptible stutter.

- **DeepSeek R1 8B** delivers 61.3 tok/s, the fastest 8B model we tested. Despite being a reasoning-distilled model, it significantly outpaces the Llama family on raw throughput. This is likely due to DeepSeek's architecture producing shorter, more efficient decode sequences for the benchmark prompts.

- **Qwen3 8B** delivers 37.4 tok/s — the second-fastest 8B model — with a 105 ms TTFT and smooth 27 ms ITL. As a thinking/reasoning model, Qwen3 generates internal reasoning tokens before producing visible output. This requires an extended measurement window (120s vs. the standard 30s) to capture properly. Once measured correctly, the model's throughput is excellent and competitive with non-reasoning models.

- **Llama 3.1 8B** hits 31.9 tok/s — usable for interactive chat. The 142 ms TTFT and 31 ms ITL mean responses start quickly and tokens arrive at a comfortable reading speed.

<details>
<summary><strong>Detailed Single-GPU Benchmark Tables</strong> (click to expand)</summary>

#### Qwen2.5 3B Instruct (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
|-------------|-------------------|---------------|--------------|-------------|-------------|
| 1 | **81.1** | 76 | 12 | 4.1s | 6.1s |
| 4 | **293** | 93 | 13 | 4.6s | 6.8s |
| 8 | **315** | 376 | 23 | 8.5s | 15.5s |

Throughput scales from 81 tok/s (single user) to 293 tok/s (4 users) - a 3.6× increase with only a 500 ms latency penalty. At 8 users the system plateaus at 315 tok/s as compute saturation sets in, with TTFT climbing to 376 ms and ITL roughly doubling.

#### Llama 3.1 8B Instruct (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
|-------------|-------------------|---------------|--------------|-------------|-------------|
| 1 | **31.9** | 142 | 31 | 8.7s | 15.5s |
| 4 | **114** | 167 | 32 | 11.3s | 16.6s |
| 8 | **170** | 323 | 43 | 15.0s | 22.0s |

Llama 3.1 scales from 31.9 tok/s to 114 tok/s at 4 users (3.57× throughput increase) while latency grows modestly from 8.7s to 11.3s. At 8 concurrent users, throughput reaches 170 tok/s - demonstrating that vLLM's continuous batching extracts strong parallelism from the R9700's compute units.

#### DeepSeek R1 Distill Llama 8B (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
|-------------|-------------------|---------------|--------------|-------------|-------------|
| 1 | **61.3** | 167 | 16 | 12.8s | 15.6s |
| 4 | **218** | 196 | 18 | 14.7s | 16.6s |
| 8 | **317** | 428 | 22 | 19.2s | 22.6s |

DeepSeek R1 8B is the throughput champion at 61.3 tok/s single-user. At 4 concurrent users, it delivers 218 tok/s with only 29 ms of additional TTFT penalty. The 16 ms ITL means token delivery is exceptionally smooth. At 8 users it reaches 317 tok/s - roughly matching the Qwen2.5 3B despite having nearly 3× more parameters.

#### Qwen3 8B (FP16, TP=1) - Thinking Model

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
|-------------|-------------------|---------------|--------------|-------------|-------------|
| 1 | **37.4** | 105 | 27 | 13.4s | 13.5s |
| 4 | **141** | 134 | 28 | 14.2s | 14.6s |
| 8 | **192** | 322 | 41 | 20.8s | 24.0s |

Qwen3 8B is a thinking/reasoning model that generates internal reasoning tokens before visible output. With the correct measurement configuration, Qwen3 8B proves to be highly capable: 37.4 tok/s at single-user, scaling to 192 tok/s at 8 concurrent users - a 5.1× throughput increase. The 105 ms TTFT and 27 ms ITL make it fully suitable for interactive use. Concurrency scaling is the best of any model tested, suggesting the R9700's compute units handle batched reasoning workloads particularly well.

> **A note on benchmarking reasoning models:** Qwen3 8B initially appeared to produce **0.0 tok/s** in our standard 30-second measurement window. The model's thinking phase - where it generates internal reasoning tokens before visible output - consumed the entire measurement interval, causing GenAI-Perf to report zero completed requests. Extending the measurement window to 120 seconds revealed the true throughput: 37.4 tok/s with a smooth 27 ms ITL. This is a cautionary example for anyone benchmarking thinking models: standard measurement configurations can fundamentally misrepresent their performance. We've published our extended-interval configuration alongside these results.

</details>

---

## Dual-GPU Performance (PP=2)

The R9700's real value proposition emerges when two cards work together. With 64 GB of aggregate VRAM, models up to 27B parameters in FP16 become accessible - models that simply cannot run on a single 32 GB card.

### Why Pipeline Parallelism?

On our test system, vLLM's Tensor Parallelism (TP) mode triggers RCCL all-reduce failures on PCIe-connected RDNA 4 GPUs. This is a known issue with RCCL's collective operations on this new GPU architecture (no XGMI/NVLink equivalent exists on these cards, and the current RCCL releases shipping in ROCm vLLM images do not yet launch collectives reliably on gfx1201). In our follow-up investigation, even with full PCIe peer-to-peer verified working at the platform level, stock ROCm vLLM images still failed TP=2 — this is a software maturity gap in the RCCL/RDNA 4 stack, not a configuration problem. Pipeline Parallelism (PP=2) avoids collectives entirely by splitting model layers sequentially across GPUs rather than sharding each layer. The tradeoff: PP introduces "pipeline bubbles" (idle time between pipeline stages) that slightly reduce throughput compared to ideal TP scaling. The benefit: it works reliably with zero stability issues.

Notably, the vLLM/RCCL limitation is not the end of the dual-GPU story on this hardware. llama.cpp's `--split-mode row` computes every token on both GPUs using HIP peer transfers — no RCCL collectives at all — and delivers tensor-parallel-style speedups today. We benchmarked it below. For teams that specifically want vLLM-style TP, the SGLang inference server with community RDNA 4 patches has a demonstrated same-hardware TP=2 concurrent-serving result (including AWQ int4 and FP8 support that ROCm vLLM currently lacks). We expect the RCCL gap to close as fixes land in released ROCm images.

### The Faster Dual-GPU Path: llama.cpp Row Split

While vLLM is limited to Pipeline Parallelism on this hardware, llama.cpp's ROCm backend offers a genuine both-GPUs-per-token mode. With `--split-mode row`, each layer's weights are split across both cards and every token's computation runs on both GPUs simultaneously — the same work distribution TP provides, implemented over direct HIP peer-to-peer copies instead of RCCL collectives.

We benchmarked the current `llama.cpp:server-rocm` build with Qwen2.5-32B-Instruct at Q4_K_M quantization (a 32B model in roughly 20 GB, split across both cards), using the same GenAI-Perf methodology as the rest of this article:

| Split mode | Concurrency | Aggregate tok/s | Per-user tok/s | ITL |
|---|---|---:|---:|---:|
| row | 1 | **23.0** | 23.0 | 44 ms |
| row | 4 | 36.0 | 12.0 | 85 ms |
| row | 8 | **60.0** | 9.8 | 102 ms |
| layer | 1 | 23.4 | 23.4 | 43 ms |
| layer | 4 | 40.2 | 11.4 | 89 ms |
| layer | 8 | 49.5 | 7.7 | 130 ms |

*Qwen2.5-32B-Instruct Q4_K_M, 500 input / 500 output tokens, streaming. Combined GPU power under row-split load: 453W average, 599W peak — both cards genuinely working. TTFT runs ~1s at concurrency 1 (32B prefill), higher than the smaller vLLM-served models elsewhere in this article. [†verify: rerun measured on our KVM-passthrough dev environment, validated within 3% of a bare-metal reference run — spot-check on bare metal before publication]*

Two results stand out. First, **23 tok/s single-user on a 32B-class model — more than double the 10.9 tok/s our vLLM PP=2 setup achieves on the FP16 27B**. The comparison isn't strictly apples-to-apples (Q4 quantized 32B vs. unquantized FP16 27B; quantization itself accounts for much of the bandwidth savings), but for teams who are comfortable with 4-bit weights, this is the fastest way to run big models on a pair of R9700s today. Second, concurrency scaling is real: 60 tok/s aggregate at 8 users in row mode. Earlier llama.cpp builds crashed under concurrent row-split decode on RDNA 4; the current build ran our full concurrent sweep without a single failure. Layer split is the more conservative choice and trades a little top-end aggregate throughput (49.5 vs 60 tok/s at 8 users) for slightly better mid-range behavior.

### 8B Models: PP=2 vs. Single-GPU

To quantify the PP overhead, we re-ran the 3B and 8B models across both GPUs:

| Model | Config | Throughput (tok/s) | TTFT (ms) | ITL (ms) | vs. TP=1 |
|-------|--------|-------------------|-----------|----------|----------|
| **Qwen2.5 3B** | TP=1 (1 GPU) | **81.1** | 76 | 12 | — |
| **Qwen2.5 3B** | PP=2 (2 GPUs) | 75.8 | 72 | 13 | −6.5% throughput |
| **Llama 3.1 8B** | TP=1 (1 GPU) | **31.9** | 142 | 31 | — |
| **Llama 3.1 8B** | PP=2 (2 GPUs) | 31.1 | 135 | 32 | −2.5% throughput |
| **DeepSeek R1 8B** | TP=1 (1 GPU) | **61.3** | 167 | 16 | — |
| **DeepSeek R1 8B** | PP=2 (2 GPUs) | 59.5 | 156 | 17 | −2.9% throughput |

*All results at Concurrency=1.*

The PP=2 throughput penalty ranges from 2.5% to 6.5% - a modest cost. Interestingly, TTFT actually *improves* slightly under PP=2 (76→72 ms for 3B, 142→135 ms for Llama 8B) because the prefill computation is distributed across two GPUs, reducing the initial prompt processing time. For models that fit on a single card, TP=1 remains the better choice for raw throughput. PP=2 is the right configuration for models that need the combined VRAM.

### Qwen3.6-27B Dense: Where Dual-GPU Earns Its Keep

The Qwen3.6-27B is a 27 billion parameter dense model requiring approximately 54 GB in FP16. It simply cannot run on a single R9700. Across two cards with PP=2, it runs with approximately 10 GB of VRAM headroom.

| Test | Throughput (tok/s) | TTFT (ms) | ITL (ms) | Avg Latency |
|------|-------------------|-----------|----------|-------------|
| Single-User (Concurrency=1) | **10.9** | 363 | 91 | 18.5s |

*Benchmark: 500 input tokens, 200 output tokens², FP16, PP=2 across 2× R9700, max-model-len 16384, gpu-memory-utilization 0.95, 120-second measurement interval, 10 prompts.*

*² Output tokens reduced to 200 and measurement interval extended to 120s to accommodate the model's reasoning overhead within the genai-perf measurement window.*

At 10.9 tok/s for a single user, this is approximately 650 words per minute of generated text - fast enough for interactive use, though noticeably slower than the 8B-class models. The 363 ms TTFT means the model begins responding in under half a second, which is excellent for a model of this size.

The 91 ms ITL translates to approximately 11 tokens arriving per second from the user's perspective. While this is slower than the 8B models' 16–31 ms ITL, it is still smooth enough that output appears as a continuous stream rather than choppy bursts.

For context: Qwen3.6-27B is one of the most capable open-weight dense models available as of mid-2026. Being able to run it locally in full FP16 precision on roughly $3,800 worth of GPU hardware, without any quantization compromises, is a meaningful capability.

---

## Scaling Summary

| Model | Architecture | 1× R9700 (TP=1) | 2× R9700 (PP=2) | Notes |
|-------|-------------|------------------|------------------|-------|
| Qwen2.5 3B | Dense | **81.1 tok/s** | 75.8 tok/s (−6.5%) | Single GPU preferred |
| Llama 3.1 8B | Dense | **31.9 tok/s** | 31.1 tok/s (−2.5%) | Single GPU preferred |
| DeepSeek R1 8B | Dense | **61.3 tok/s** | 59.5 tok/s (−2.9%) | Single GPU preferred |
| Qwen3 8B | Dense (thinking) | **37.4 tok/s** | — | Reasoning model; 105 ms TTFT, 27 ms ITL |
| **Qwen3.6-27B** | **Dense** | ❌ Does not fit (54 GB) | **10.9 tok/s** | **Dual-GPU required** |

*All single-user numbers at Concurrency=1.*

The results tell a clear story across two tiers:

1. **8B models and smaller** run best on a single R9700. The PP=2 overhead (2.5–6.5%) makes dual-GPU sharding counterproductive for models that already fit in 32 GB. DeepSeek R1 8B is the standout performer at 61.3 tok/s, followed by Qwen3 8B at 37.4 tok/s and Llama 3.1 8B at 31.9 tok/s. Notably, Qwen3 8B - a thinking/reasoning model - delivers excellent throughput with the best concurrency scaling of any model tested (5.1× at 8 users).

2. **27B dense models** require dual-GPU. The Qwen3.6-27B runs at 10.9 tok/s with a 363 ms TTFT - usable for interactive chat and production inference. This model class is inaccessible on any single 32 GB card without quantization.

---

## Cost of Inference: Local vs. Cloud

With throughput numbers established, the next question is practical: **what does it actually cost to run these models locally - and how does that compare to just calling a cloud API?** Frontier API pricing has climbed significantly: Claude Opus 4.8 now costs $25 per million output tokens, Gemini 2.5 Pro charges $10/1M, and even the budget-tier Claude Haiku 4.5 runs $5/1M. To answer this question with real data, we instrumented the benchmark suite with GPU power monitoring, polling the AMD kernel driver's `power1_average` sensor every 2 seconds throughout each test.

### Measured GPU Power Under Load

| Model | Config | GPUs Active | Avg GPU Power | Peak GPU Power |
|-------|--------|:-----------:|:-------------:|:--------------:|
| Qwen2.5 3B | TP=1 | 1 | **222W** | 254W |
| Qwen3 8B | TP=1 | 1 | **260W** | 299W |
| DeepSeek R1 8B | TP=1 | 1 | **254W** | 301W |
| Llama 3.1 8B | TP=1 | 1 | **151W** | 297W |
| Qwen3.6-27B | PP=2 | 2 | **325W** | 358W |

*GPU-only power from the AMD kernel driver (`sysfs hwmon`). Total system wall power includes CPU, RAM, and PSU overhead - add ~300W for the Xeon workstation.*

Two things stand out. First, no single-GPU workload comes close to the R9700's 300W TDP - average draw ranges from 151W (Llama 3.1 8B) to 260W (Qwen3 8B). Second, Llama 3.1 draws substantially less power than the other 8B models, suggesting its architecture is less compute-bound on RDNA 4.

### Cost Per Million Output Tokens

Using $0.12/kWh (US average) and estimated total system power (GPU average + 300W system overhead):

| Model | tok/s | GPU W | System W | $/1M tokens | vs. Haiku 4.5 ($5) | vs. Gemini 2.5 Pro ($10) | vs. Opus 4.8 ($25) |
|-------|------:|------:|---------:|------------:|-------------------:|------------------------:|-------------------:|
| Qwen2.5 3B | 81.0 | 222 | 522 | **$0.21** | 23× cheaper | 47× cheaper | 119× cheaper |
| DeepSeek R1 8B | 61.1 | 254 | 554 | **$0.30** | 16× cheaper | 33× cheaper | 83× cheaper |
| Qwen3 8B | 37.3 | 260 | 560 | **$0.50** | 10× cheaper | 20× cheaper | 50× cheaper |
| Llama 3.1 8B | 32.0 | 151 | 451 | **$0.47** | 10× cheaper | 21× cheaper | 53× cheaper |
| Qwen3.6-27B | 10.9 | 325 | 625 | **$1.91** | 2.6× cheaper | 5.2× cheaper | 13× cheaper |

*Cloud pricing as of June 2026: Claude Opus 4.8 ($25/1M output), Gemini 2.5 Pro ($10/1M output), Claude Haiku 4.5 ($5/1M output). Local costs are electricity only.*

Even the most expensive local configuration - the 27B model on two GPUs - costs $1.91 per million output tokens, roughly **2.6× cheaper than the least expensive frontier API** (Claude Haiku 4.5 at $5/1M). The 8B models range from $0.21–$0.50 per million tokens, making them **10–119× cheaper** than cloud APIs depending on which model you compare against.

### Multi-User Economics

The cost advantage widens dramatically under concurrent load. Because throughput scales faster than power consumption (the GPU is already drawing power whether it's running one request or eight), cost-per-token drops at higher concurrency:

| Model | Conc=1 | Conc=4 | Conc=8 |
|-------|-------:|-------:|-------:|
| Qwen2.5 3B | $0.21/1M | $0.06/1M | $0.06/1M |
| DeepSeek R1 8B | $0.30/1M | $0.08/1M | $0.06/1M |
| Qwen3 8B | $0.50/1M | $0.13/1M | $0.10/1M |

At concurrency=8, every 8B model costs **under $0.10 per million output tokens** - roughly 50–250× cheaper than frontier cloud APIs.

### Total Cost of Ownership

Beyond electricity, the hardware itself has a cost. Amortized over a 3-year workstation lifecycle at 8 hours/day, 5 days/week:

| Component | Cost (configured, July 2026) | Amortized $/hour |
|-----------|-----:|:-----------------:|
| 2× R9700 GPUs | ~$3,760 | $0.31/hr |
| Full Workstation | ~$7,600 | $0.61/hr |

At DeepSeek R1 8B's throughput (61.1 tok/s single-user), the workstation generates **220K tokens/hour**. Including both amortized hardware and electricity:

- **Total cost: ~$3.05 per million output tokens** (electricity + hardware amortization)
- That's **1.6× cheaper than Claude Haiku 4.5**, **3.3× cheaper than Gemini 2.5 Pro**, and **8× cheaper than Claude Opus 4.8**
- At 8 concurrent users (317 tok/s → 1.14M tokens/hour), the all-in cost drops to **~$0.60 per million tokens** — 8× cheaper than Haiku 4.5 and over 40× cheaper than Opus 4.8

The cost advantage is significant even when accounting for full hardware amortization - and the gap widens at higher utilization rates, where hardware costs are spread across more tokens while throughput multiplies.

---

## Image Generation: ComfyUI + Z-Image Turbo

We tested the R9700 for generative image workloads using ComfyUI with Z-Image Turbo, a distilled diffusion model designed for fast 4-step generation at 1024×1024.

ComfyUI detected the R9700 as a HIP device via `rocm/pytorch:latest` with no patches required. The entire pipeline fit comfortably within the card's 32 GB VRAM.

### Results

**Prompt:** *"A majestic snow-capped mountain peak at golden hour, reflected perfectly in a crystal-clear alpine lake surrounded by wildflowers, professional landscape photography, 8k resolution"*

| Metric | Value |
|--------|-------|
| **Iterations** | 10/10 passed (0 failures) |
| **Cold Start (iter 1)** | 11.9s (model loading + HIP JIT) |
| **Steady State (iter 2–10)** | 3.5s average |
| **Mean (all 10)** | 4.3s |
| **p50** | 3.5s |
| **Throughput** | 13.85 images/min |
| **VRAM Peak** | 19.8 GB |
| **VRAM Available** | 31.9 GB |

The steady-state number is what matters: after the first cold-start iteration, the R9700 generates 1024×1024 images in 3.5 seconds consistently. The VRAM peak of 19.8 GB leaves over 12 GB of headroom for larger models, higher resolutions, or multi-model pipelines. Zero failures across 10 consecutive runs confirms stable HIP inference.

### Sample Output

These images were generated on the R9700 using Z-Image Turbo with the benchmark prompt above. Each took under 4 seconds at steady state:

![Sample 1: Generated on AMD R9700 via Z-Image Turbo](images/z_image_sample_1.png)

![Sample 2: Generated on AMD R9700 via Z-Image Turbo](images/z_image_sample_2.png)

![Sample 3: Generated on AMD R9700 via Z-Image Turbo](images/z_image_sample_3.png)

These are three consecutive runs from the same prompt and settings - not cherry-picked. The consistency across runs demonstrates stable HIP inference with no artifacts or degradation.

---

## Comparison: R9700 vs. Arc Pro B70

Both the R9700 and the Arc Pro B70 target the same market - professional AI inference at 32 GB per card - but come from different architectural families with different tradeoffs. We tested both cards on equivalent workloads using our benchmark framework, allowing direct comparison.

> **Methodology note:** The B70 benchmarks used a custom test harness with multiple test types (Short Prompts, Medium Generation, Long Generation, Concurrent). The R9700 benchmarks used NVIDIA GenAI-Perf with a consistent 500-input/500-output token configuration across all tests. Both measure the same fundamental metric - decode throughput in tok/s at comparable output lengths - but the tooling differs. The numbers below compare equivalent test configurations (single-user, long generation) from each framework.

### Hardware Comparison

| | AMD Radeon AI PRO R9700 | Intel Arc Pro B70 |
|---|---|---|
| **Architecture** | RDNA 4 (gfx1201) | Xe2-HPG (Battlemage) |
| **VRAM** | 32 GB GDDR6 | 32 GB GDDR6 (ECC) |
| **Memory Bandwidth** | 640 GB/s | 608 GB/s |
| **AI TOPS (INT8)** | 766 TOPS | 367 TOPS |
| **TDP** | 300W | 230W |
| **Price per card (configured, July 2026)** | ~$1,880 | ~$1,110 |
| **Cards Tested** | 2 | 4 |
| **Total VRAM** | 64 GB (~$3,760) | 128 GB (~$4,450) |
| **Inference Stack** | ROCm + vLLM | XPU + vLLM / LLM Scaler |
| **Multi-GPU Method** | Pipeline Parallelism (PP) | Tensor Parallelism (TP) |

### Single-GPU Throughput (Concurrency = 1)

| Model | R9700 (tok/s) | B70 (tok/s) | R9700 Advantage |
|-------|---------------|-------------|-----------------|
| Qwen2.5 3B | **81.1** | 76.2 | +6.4% |
| Llama 3.1 8B | 31.9 | 36.1 | −11.6% |
| DeepSeek R1 8B | **61.3** | 36.1 | +69.8% |

The comparison is more nuanced than a simple speed ranking:

- **Qwen2.5 3B:** The R9700 is ~6% faster, consistent with its higher memory bandwidth (640 vs. 608 GB/s). Both cards are "fast enough" at this model size — over 75 tok/s is well beyond interactive requirements.

- **Llama 3.1 8B:** The B70 is ~12% faster here. This may reflect better XPU kernel optimization for the Llama architecture in Intel's vLLM fork, or differences in how vLLM schedules work across the two backends.

- **DeepSeek R1 8B:** The R9700 dramatically outperforms the B70, delivering 61.3 vs. 36.1 tok/s — a **70% advantage**. This model appears to benefit significantly from the R9700's higher compute throughput and memory bandwidth. DeepSeek's architecture may also map more efficiently to AMD's compute unit layout.

### Multi-GPU: 27B Dense Model

| | R9700 (PP=2, 2 cards) | B70 (TP=4, 4 cards) |
|---|---|---|
| **Throughput** | 10.9 tok/s | 13.2 tok/s |
| **TTFT** | 363 ms | — (not measured) |
| **ITL** | 91 ms | — |
| **Total GPU Cost (configured, July 2026)** | ~$3,760 (2 cards) | ~$4,450 (4 cards) |
| **Throughput per $1K GPU** | 2.90 tok/s | 2.97 tok/s |

The B70 4-card configuration delivers 21% higher raw throughput (13.2 vs. 10.9 tok/s) for about 18% more GPU cost — on a throughput-per-dollar basis, the two configurations are effectively tied (within ~2%). The meaningful differences are elsewhere: the R9700 gets there with half the cards (two PCIe slots instead of four, 600W of GPU TDP instead of 920W), while the B70 configuration brings twice the aggregate VRAM.

However, the B70's 4-card configuration offers 128 GB of total VRAM - enough for 35B MoE models and beyond - while the R9700 2-card setup is capped at 64 GB. Teams that need to run models larger than 27B FP16 will need either more R9700 cards or the B70's larger aggregate pool.

### Image Generation

| | R9700 | B70 |
|---|---|---|
| **Steady State** | 3.5s per image | 3.9s per image |
| **Throughput** | 13.85 img/min | 12.86 img/min |
| **VRAM Peak** | 19.8 GB | 19.3 GB |

The R9700 is approximately 8% faster at image generation, consistent with its bandwidth advantage. Both cards handle ComfyUI + Z-Image Turbo without issue.

---

## What Doesn't Work

Two issues required workarounds during testing:

**RCCL Tensor Parallelism failures in vLLM.** vLLM's Tensor Parallelism mode (TP=2) fails during the RCCL all-reduce collective operation on PCIe-connected RDNA 4 GPUs. This is a known ROCm issue, and our follow-up testing shows it is deeper than PCIe topology: even with platform-level GPU peer-to-peer enabled and verified, the RCCL collective kernels in current ROCm vLLM images do not launch on gfx1201. Setting `NCCL_P2P_DISABLE=1` alone is not sufficient to make TP work. Within vLLM, the reliable fix is Pipeline Parallelism (PP=2), which avoids collective ops entirely at the cost of 2.5–6.5% throughput. The practical workarounds outside vLLM: llama.cpp's row split (benchmarked above — both GPUs per token over HIP peer transfers, no RCCL involved), or SGLang with RDNA 4 patches for true TP=2 with int4/FP8 quantization. We expect AMD to address the RCCL gap as the ROCm stack matures for RDNA 4. It's worth noting how fast this stack is moving: llama.cpp builds from just weeks before this test crashed under concurrent row-split decode on RDNA 4, and the current build sailed through our full concurrent sweep.

**Container permissions for /dev/kfd.** The `rocm/pytorch:latest` container requires `privileged: true` and `user: root` to access `/dev/kfd` (AMD's kernel fusion driver device node). Without these, `torch.cuda.is_available()` returns `False` even with device passthrough configured. This is a container configuration issue, not a hardware limitation.

---

## Setup Notes for Practitioners

### Docker Compose Reference (vLLM)

```yaml
services:
  inference:
    image: vllm/vllm-openai-rocm:v0.20.2
    privileged: true
    shm_size: "32g"
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    environment:
      - VLLM_TARGET_DEVICE=rocm
      - NCCL_P2P_DISABLE=1
      - HIP_FORCE_DEV_KERNARG=1
    command:
      - python3 -m vllm.entrypoints.openai.api_server
        --pipeline-parallel-size=2
        --tensor-parallel-size=1
        --enforce-eager
        --gpu-memory-utilization=0.95
        --max-model-len=16384
```

### Key Environment Variables

```bash
# Disable peer-to-peer to avoid RCCL deadlocks
NCCL_P2P_DISABLE=1

# Force device kernel argument allocation (ROCm stability)
HIP_FORCE_DEV_KERNARG=1

# Target device selection
VLLM_TARGET_DEVICE=rocm
```

### Pipeline Parallelism for Multi-GPU

When using multiple AMD RDNA 4 GPUs with stock vLLM, always use PP (Pipeline Parallelism) instead of TP (Tensor Parallelism):

```bash
# ✅ Correct: Pipeline Parallelism
--pipeline-parallel-size=2 --tensor-parallel-size=1

# ❌ Fails: Tensor Parallelism (RCCL collective failure on gfx1201)
--tensor-parallel-size=2
```

If your workload requires true TP=2 (quantized int4/FP8 models, maximum concurrent throughput), SGLang with RDNA 4 patches is currently the demonstrated path on this hardware.

For quantized GGUF models, llama.cpp's row split is the simpler both-GPUs-per-token alternative — no RCCL, no special platform configuration:

```bash
# llama.cpp: both GPUs compute every token via HIP peer transfers
docker run -d --device /dev/kfd --device /dev/dri \
  --security-opt seccomp=unconfined --group-add video --group-add render \
  -p 8000:8000 --entrypoint /app/llama-server \
  ghcr.io/ggml-org/llama.cpp:server-rocm \
  -hf bartowski/Qwen2.5-32B-Instruct-GGUF:Q4_K_M \
  -ngl 99 --split-mode row -c 16384 --parallel 8 \
  --host 0.0.0.0 --port 8000 --jinja
```

### ComfyUI Docker Compose (Image Generation)

```yaml
services:
  comfyui:
    image: rocm/pytorch:latest
    privileged: true
    user: root
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    shm_size: "16g"
```

---

## Conclusion: How Do Two R9700 GPUs Perform for AI Inference?

The AMD Radeon AI PRO R9700 delivers genuine AI inference capability on RDNA 4 silicon - and the economics make a strong case for local deployment:

- **8B models at excellent speeds:** DeepSeek R1 8B hits 61.3 tok/s on a single card — faster than any Intel B70 result at the same parameter scale. Qwen3 8B, a thinking/reasoning model, delivers 37.4 tok/s with the best concurrency scaling tested (192 tok/s at 8 users). Llama 3.1 8B delivers 31.9 tok/s. Qwen2.5 3B reaches 81.1 tok/s. All are production-usable for interactive chat.

- **27B models that won't fit on a single card:** Qwen3.6-27B Dense runs at 10.9 tok/s with a 363 ms TTFT on two R9700 cards. Full FP16 precision, no quantization required, on roughly $3,800 of GPU hardware.

- **A genuine both-GPUs-per-token path for quantized models:** llama.cpp's row split runs a 32B-class model at 23 tok/s single-user — more than double our vLLM PP=2 result on the FP16 27B — scaling to 60 tok/s aggregate at 8 concurrent users, with no RCCL dependency.

- **Reliable image generation:** 1024×1024 images in 3.5 seconds steady-state via Z-Image Turbo, with zero failures across 10 runs.

- **Dramatically cheaper than cloud APIs:** With measured GPU power draw of 151–260W for single-GPU workloads, local inference costs $0.21–$0.50 per million output tokens at single-user — dropping below $0.10/1M at 8 concurrent users. Even with full hardware amortization over 3 years, single-user local inference is **1.6–8× cheaper** than frontier APIs (Claude Haiku 4.5 at $5/1M through Claude Opus 4.8 at $25/1M) — and at 8 concurrent users the all-in cost falls to ~$0.60/1M, widening the gap to **8–40×**.

- **Value per dollar is a genuine tie with Intel:** For the 27B model class, the R9700 2-card setup and the B70 4-card configuration land within 2% of each other on throughput per dollar at current (July 2026) pricing. The real differentiators are elsewhere: the R9700 gets there with half the cards, slots, and GPU power budget, while the B70 configuration brings double the aggregate VRAM for larger models down the road.

Here is how the three cards compare side by side:

| | AMD Radeon AI PRO R9700 | Intel Arc Pro B70 | NVIDIA RTX 5090 |
|---|---|---|---|
| **Architecture** | RDNA 4 (gfx1201) | Xe2-HPG (Battlemage) | Blackwell |
| **VRAM** | 32 GB GDDR6 | 32 GB GDDR6 (ECC) | 32 GB GDDR7 |
| **Memory Bandwidth** | 640 GB/s | 608 GB/s | 1,792 GB/s |
| **AI TOPS (INT8)** | 766 TOPS | 367 TOPS | 3,352 TOPS (FP4 sparse) |
| **TDP** | 300W | 230W | 575W |
| **Price per card (configured, July 2026)** | ~$1,880 | ~$1,110 | ~$4,130 |
| **Tested Config VRAM** | 64 GB (2 cards, ~$3,760) | 128 GB (4 cards, ~$4,450) | 64 GB (2 cards, ~$8,260) |
| **8B FP16 tok/s (single card)** | 61.3 (DeepSeek R1) | 36.1 | ~140–200 |
| **27B FP16 tok/s** | 10.9 (PP=2, 2 cards) | 13.2 (TP=4, 4 cards) | N/A (single), not tested (multi) |
| **$/1M tokens (8B, electricity)** | $0.30 | Not measured | Not measured |
| **Multi-GPU Method** | Pipeline Parallelism | Tensor Parallelism | Tensor Parallelism |

The RTX 5090 is roughly 4–5× faster per GPU on decode-bound workloads, driven by nearly 3× the memory bandwidth. But in today's supply-constrained market, that speed carries a steep premium: two R9700 cards deliver the same aggregate VRAM for less than half the cost of two RTX 5090s. The B70 offers the most VRAM per dollar at 128 GB across four cards, but with lower per-card throughput.

The caveats are real but manageable: Tensor Parallelism failures in stock vLLM require using Pipeline Parallelism instead (a minor throughput penalty), and container permissions need explicit configuration. Once configured, the system ran with zero crashes or stability issues across our complete benchmark suite.

For teams running FP16 models up to 27B parameters where **privacy, cost control, or volume** matter, the R9700 dual-card configuration is a compelling option — and volume is the deciding lever. A team generating 5 million output tokens per month spends about $185/year on local inference (electricity + full hardware amortization) versus $300/year through Claude Haiku 4.5 or $1,500/year through Claude Opus 4.8; at that volume, the case for local is privacy and control more than payback. Scale to 50 million tokens per month — where the concurrency numbers above apply — and local inference runs about $360/year against $3,000/year for Haiku 4.5, $6,000/year for Gemini 2.5 Pro, and $15,000/year for Opus 4.8. At that utilization, the workstation pays for itself in roughly six months if it displaces flagship-API traffic, and within one to three years against the budget tiers.

Teams needing larger VRAM pools (35B+ MoE models) should consider adding more R9700 cards or evaluating the 4-card B70 configuration.

---

*Tested June 2026 on a Puget Systems workstation with 2× AMD Radeon AI PRO R9700 GPUs running Ubuntu 25.04. All LLM benchmarks used `vllm/vllm-openai-rocm:v0.20.2` with `--enforce-eager` and `NCCL_P2P_DISABLE=1`. llama.cpp benchmarks used `ghcr.io/ggml-org/llama.cpp:server-rocm` (July 2026 build). Image generation used `rocm/pytorch:latest` with ComfyUI and Z-Image Turbo. GPU power measured via `sysfs hwmon` (`power1_average`). Cloud API pricing as of June 2026; GPU hardware pricing reflects Puget Systems configured-system pricing as of July 2026.*

