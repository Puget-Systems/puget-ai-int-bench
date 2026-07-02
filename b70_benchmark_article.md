**How do four Intel Arc Pro B70 GPUs perform for local LLM inference and image generation?**
* * *

## Introduction

In our [hardware review of the Intel® Arc™ Pro B70](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-review/), we found that Intel views this card "not primarily as a general-purpose professional GPU, but primarily as an AI-first GPU." Equipped with 32 GB of VRAM, and priced at only $950, the B70 is aggressively positioned for multi-GPU inference workstations. We wrapped up that review with the conclusion that this was "an area that we need to investigate further."

**This article is that investigation.**

We installed four Arc Pro B70 cards in a [Puget Systems X142-XL workstation](https://www.pugetsystems.com/products/workstations/xeon/x142-xl/), giving us 128 GB of aggregate GPU memory for under $4,000 in GPU cost alone. The closest NVIDIA equivalent at the same VRAM tier is the GeForce RTX 5090: also 32 GB, but $1,999 MSRP - and frequently priced much higher on the open market. At $949, the B70 costs less than half as much per card, and four B70 cards (128 GB, ~$3,800) deliver twice the aggregate VRAM of two 5090s (64 GB, ~$4,000). The tradeoff is per-GPU speed: the 5090's 1,792 GB/s memory bandwidth is nearly 3× the B70's 608 GB/s, and NVIDIA's mature CUDA stack supports AWQ/GPTQ quantization that Intel's XPU backend does not.

The question is straightforward: can you run production-quality LLM inference and image generation on Intel's Battlemage silicon today? We tested single-GPU baselines, multi-GPU tensor parallelism scaling across all four cards, and generative image workloads to find out - and we instrumented GPU power draw during every benchmark to calculate real-world cost-per-token against today's frontier cloud APIs.
* * *

## Test Setup

| Component | Spec |
| ---| --- |
| GPUs | 4× Intel® Arc™ Pro B70 (Xe2-HPG / Battlemage) |
| VRAM per GPU | 32 GB GDDR6 (ECC supported) |
| Total VRAM | 128 GB |
| Xe-cores | 32 per GPU |
| AI Performance | 367 TOPS (Int8) per GPU |
| Memory Bandwidth | 608 GB/s per GPU |
| TBP | 230W per GPU |
| Host System | Puget Workstation X142-XL<br>Intel® Xeon® 658X CPU (24 cores / 48 threads)<br>128 GB DDR5 RAM |
| OS | Ubuntu 25.04 |
| Driver | Intel PPA `kobuk-team/intel-graphics` (26.09.x) |

**Inference Software:** All LLM benchmarks used Intel's purpose-built `intel/llm-scaler-vllm:0.14.0-b8.2.1` container with oneCCL for inter-GPU communication, running unquantized FP16 weights. Image generation used ComfyUI with Z-Image Turbo.

**Benchmark Tool:** NVIDIA GenAI-Perf with `--streaming` mode enabled for all LLM tests, giving us real Time-To-First-Token (TTFT) and Inter-Token Latency (ITL). Each test used 500 synthetic input tokens, 500 output tokens, and 50 prompts with a 30-second measurement interval for standard models. Thinking/reasoning models (Qwen3 8B) used a 120-second measurement interval and 20 prompts to properly capture the extended reasoning phase. Concurrency levels tested: 1, 4, and 8 simultaneous users.

**Power Monitoring:** GPU power was sampled every 2 seconds throughout each benchmark via the Intel `xe` driver's `hwmon` energy counters (`energy1_input`, converted from microjoules to watts via the energy-delta method). Reported power is the **sum across all four installed B70 cards**; during single-GPU (TP=1) tests the other three cards idle but still draw power (~190 W combined idle floor), so single-GPU figures include that idle overhead - the honest draw for this 4-card workstation.

> **Note:** Getting multi-GPU inference running on Battlemage requires specific container configuration and environment variables. If you are setting this up yourself, see [Appendix A: Setup Guide for Practitioners](https://app.clickup.com/9013011496/v/dc/8ckf918-54353/8ckf918-58893#block-cpJTD6rp7L) for the full walkthrough - including driver conflict resolution, fork-safety workarounds, and PCIe topology configuration.
* * *

## What Models Fit?

Before looking at performance numbers, it is important to understand what models can actually run on this hardware. Upstream vLLM's XPU backend only supports unquantized FP16 weights — the AWQ/GPTQ dequantization kernels are CUDA-only. Intel's [LLM Scaler](https://github.com/intel/llm-scaler) container (which we used for all testing) adds **INT4 and FP8 online quantization** as well as **GPTQ** support on XPU. We did not test quantized inference for this article and all benchmarks below use full FP16 weights, but the capability exists in the container we tested with. We plan to benchmark quantized performance in a follow-up.

| Model | Type | Params | FP16 VRAM | Fits 1× B70 (32 GB)? | Fits 4× B70 (128 GB)? |
| ---| ---| ---| ---| ---| --- |
| Qwen2.5-3B Instruct | Dense | 3B | ~6 GB | ✅ Yes | ✅ Yes |
| Qwen3-8B | Dense (thinking) | 8.2B | ~16 GB | ✅ Yes | ✅ Yes |
| Llama 3.1 8B Instruct | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| DeepSeek R1 Distill 8B | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| Qwen3.6-27B | Dense | 27B | ~54 GB | ❌ No | ✅ Tested |
| Qwen3.6-35B-A3B | MoE | 35B (3B active) | ~70 GB | ❌ No | ✅ Tested |
| Gemma 2 9B | Dense | 9B | ~18 GB | ⚠️ Requires bfloat16 | ⚠️ Requires bfloat16 |
| Llama 4 Scout | MoE | 109B (17B active) | ~218 GB | ❌ No | ❌ No |
| Gemma 4 31B | Dense | 31B | ~62 GB | ❌ No | ⚠️ Requires bfloat16 |
| DeepSeek V4 Flash | MoE | 284B (13B active) | ~568 GB | ❌ No | ❌ No |

A single B70 card comfortably runs 8B-class models. Anything larger requires multi-GPU, and this is where the 4-card, 128 GB configuration earns its keep. The entire 27B to 35B tier of models, which represents the current sweet spot for serious local inference, becomes accessible. Models requiring bfloat16 precision (such as the Gemma family) cannot currently be served via vLLM on this hardware (see [What Doesn't Work](https://app.clickup.com/9013011496/v/dc/8ckf918-54353/8ckf918-58893#block-PG1rZ_SST8)).
* * *

## Single-GPU Performance

We started by establishing what a single Arc Pro B70 can deliver on its own. Each model was tested at concurrency levels 1, 4, and 8 to measure both interactive responsiveness and throughput under load, using the consistent 500-input / 500-output token configuration.

### Summary: Single-GPU Results (Concurrency = 1)

| Model | Throughput (tok/s) | TTFT (ms) | ITL (ms) | Avg Latency |
| ---| ---| ---| ---| --- |
| Qwen2.5 3B Instruct | **72.9** | 48 ms | 14 ms | 4.6s |
| DeepSeek R1 Distill 8B | **66.9** | 92 ms | 15 ms | 11.8s |
| Llama 3.1 8B Instruct | **35.4** | 86 ms | 28 ms | 9.9s |
| Qwen3 8B (thinking) | **34.7** | 69 ms | 29 ms | 14.4s |

*All tests: 500 input tokens, 500 output tokens, FP16, enforce-eager, single Arc Pro B70, max-model-len 32768. Qwen3 8B used a 120-second measurement interval to accommodate its reasoning/thinking token generation.*

The data reveals a clear performance story:

* **3B models** (Qwen2.5 3B) hit 72.9 tok/s — output appears nearly instantaneous, roughly 3,300 words per minute. The 48 ms TTFT means the model begins responding before a user could notice any delay, and the 14 ms ITL keeps token delivery perfectly smooth.

* **DeepSeek R1 8B** is the fastest 8B model we tested at 66.9 tok/s, with a remarkably low 15 ms ITL — roughly half the per-token latency of Llama 3.1 8B despite both being built on the Llama-8B architecture. We observed this same pattern on AMD's R9700 (16 ms vs. 31 ms ITL), so it is a consistent, cross-vendor characteristic of the DeepSeek distill rather than a measurement artifact.

* **Llama 3.1 8B** delivers 35.4 tok/s with a 28 ms ITL — comfortable for interactive chat. The 86 ms TTFT means responses start quickly.

* **Qwen3 8B** is a thinking/reasoning model that generates internal reasoning tokens before visible output. At 34.7 tok/s with a 69 ms TTFT and 29 ms ITL, it is fully suitable for interactive use once measured with the correct (extended) window — see the note below.

### Detailed Single-GPU Benchmark Tables

#### Qwen2.5 3B Instruct (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **72.9** | 48 | 14 | 4.6s | 6.8s |
| 4 | **280** | 30 | 14 | 4.9s | 7.1s |
| 8 | **526** | 31 | 15 | 5.2s | 7.6s |

Throughput scales from 73 tok/s (single user) to 280 tok/s at 4 users (3.8×) and 526 tok/s at 8 users (7.2×), while latency barely moves (4.6s → 5.2s). The 3B model parallelizes almost perfectly on a single card.

#### DeepSeek R1 Distill Llama 8B (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **66.9** | 92 | 15 | 11.8s | 14.3s |
| 4 | **258** | 100 | 15 | 13.0s | 14.9s |
| 8 | **486** | 71 | 16 | 14.1s | 15.3s |

DeepSeek R1 8B is the throughput champion at 66.9 tok/s single-user, scaling to 486 tok/s at 8 users (7.3×). The 15 ms ITL means token delivery is exceptionally smooth. As a reasoning-distilled model it generates longer responses (it works through an internal chain of thought), which is reflected in the higher per-request latency.

#### Llama 3.1 8B Instruct (FP16, TP=1)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **35.4** | 86 | 28 | 9.9s | 14.1s |
| 4 | **133** | 76 | 29 | 9.9s | 14.8s |
| 8 | **256** | 65 | 30 | 9.9s | 15.2s |

Llama 3.1 scales from 35.4 tok/s to 256 tok/s at 8 users (7.2×) with essentially flat average latency — a textbook demonstration of vLLM's continuous batching extracting parallelism while keeping each user's experience consistent.

#### Qwen3 8B (FP16, TP=1) - Thinking Model

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **34.7** | 69 | 29 | 14.4s | 14.5s |
| 4 | **133** | 69 | 30 | 15.1s | 15.1s |
| 8 | **255** | 81 | 31 | 15.7s | 15.8s |

Qwen3 8B delivers 34.7 tok/s single-user, scaling to 255 tok/s at 8 concurrent users (7.4×) — the best concurrency scaling of any 8B model tested. The 69 ms TTFT and 29 ms ITL make it fully suitable for interactive use.

> **A note on benchmarking reasoning models:** Qwen3 8B initially appeared to produce **0.0 tok/s** in our standard 30-second measurement window. The model's thinking phase - where it generates internal reasoning tokens before visible output - consumed the entire measurement interval, causing GenAI-Perf to report zero completed requests. Extending the measurement window to 120 seconds revealed the true throughput. This is a cautionary example for anyone benchmarking thinking models: standard measurement configurations can fundamentally misrepresent their performance.

* * *

## Multi-GPU Performance (TP=4)

Single-GPU performance establishes a capable baseline, but the B70's real value proposition is the 4-card configuration: 128 GB of VRAM at a price point comparable to two NVIDIA RTX 5090s, but with twice the memory capacity. We used Intel's LLM Scaler container with tensor parallelism across all four cards.

### 8B Models and Smaller (TP=4)

These are the models where we can directly compare single-GPU and multi-GPU performance on the same workloads.

#### Llama 3.1 8B Instruct (TP=4)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **70.3** | 79 | 14 | 4.2s | 6.9s |
| 4 | **247** | 48 | 16 | 5.3s | 8.2s |
| 8 | **472** | 34 | 17 | 5.6s | 8.3s |

Compared with a single card, Llama 3.1 8B nearly doubles its single-user throughput: 35.4 → 70.3 tok/s, a **1.99× speedup**. Latency also drops (9.9s → 4.2s) because the prefill computation is split across four GPUs. These are strong scaling numbers, especially considering our configuration routes inter-GPU communication through host RAM rather than direct PCIe peer-to-peer transfers (we set `CCL_TOPO_P2P_ACCESS=0`; see [Appendix A: Problem 3](https://app.clickup.com/9013011496/v/dc/8ckf918-54353/8ckf918-58893#block--cW48AB1yD)).

#### DeepSeek R1 Distill Llama 8B (TP=4)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **136** | 91 | 7 | 6.2s | 7.1s |
| 4 | **471** | 69 | 8 | 7.0s | 8.1s |
| 8 | **905** | 36 | 9 | 7.5s | 8.2s |

DeepSeek R1 8B roughly doubles single-user throughput from one card to four (66.9 → 136 tok/s, **2.03×**) and reaches 905 tok/s of aggregate throughput at 8 users. Its 7–9 ms ITL is the fastest per-token decode of any model in the suite.¹

*¹ DeepSeek R1 is a reasoning model and generated ~840 output tokens per request versus ~300 for the non-reasoning 8B models. Its higher token throughput therefore partly reflects longer generations; the **ITL** column is the length-independent measure of per-token decode speed, and DeepSeek's ITL is consistently the lowest in the suite on both Intel and AMD hardware.*

#### Qwen2.5 3B Instruct (TP=4): When Not to Scale

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **62.6** | 46 | 16 | 4.9s | 7.5s |
| 4 | **216** | 46 | 18 | 6.0s | 9.1s |
| 8 | **410** | 37 | 19 | 6.4s | 9.4s |

This is the control case. The 3B model's single-user throughput *drops* from 72.9 tok/s (TP=1) to 62.6 tok/s (TP=4) — a 0.86× "speedup," meaning **multi-GPU actually hurts performance**. The model is too small to benefit from sharding: inter-GPU communication overhead exceeds the compute savings from distributing the workload. For models this size, a single B70 is the right configuration.

### 27B–35B Models: Where Multi-GPU Earns Its Keep

These models simply cannot run on a single B70 card. Their FP16 weight footprints exceed 32 GB, making the 4-card TP=4 configuration mandatory.

#### Qwen3.6-27B Dense (TP=4)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **13.1** | 265 | 76 | 38.2s | 38.7s |
| 4 | **50.4** | 871 | 78 | 39.7s | 39.9s |
| 8 | **95.9** | 950 | 81 | 41.1s | 42.6s |

*Benchmark: 500 input tokens, 500 output tokens, FP16, enforce-eager, TP=4 across 4× B70, max-model-len 32768, 120-second measurement window.*

The Qwen3.6-27B is a 27 billion parameter dense model where every parameter is active on every forward pass, requiring approximately 54 GB in FP16. It will not fit on a single B70 card; across four cards it runs comfortably. At 13.1 tok/s for a single user, this is not blazingly fast — dense 27B models are compute-hungry — but the scaling is compelling: throughput climbs to 50.4 tok/s at 4 users (3.85×) and 95.9 tok/s at 8 users (7.3×), with average latency rising only ~3s. The 265 ms TTFT at single-user means the model begins responding in about a quarter second even at this size.

#### Qwen3.6-35B-A3B MoE (TP=4)

| Concurrency | Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency |
| ---| ---| ---| ---| ---| --- |
| 1 | **16.3** | 113 | 61 | 30.7s | 30.8s |
| 4 | **63.7** | 256 | 62 | 31.4s | 31.6s |
| 8 | **122** | 384 | 65 | 32.8s | 33.2s |

*Benchmark: 500 input tokens, 500 output tokens, FP16, enforce-eager, TP=4 across 4× B70, 120-second measurement window.*

The 35B MoE model's total weight footprint exceeds 70 GB in FP16, more than twice what a single B70 can hold. Sharded across all four GPUs, the combined 128 GB pool accommodates it with room to spare. It scales from 16.3 tok/s to 63.7 tok/s at 4 users (3.91×) and 122 tok/s at 8 users (7.5×).

The comparison with the 27B dense model is instructive. Despite having more total parameters (35B vs. 27B), the MoE variant is *faster*: 16.3 tok/s versus 13.1 tok/s at single-user. This is because the MoE architecture only activates ~3B parameters per token, compared to all 27B in the dense model — exactly the tradeoff Mixture-of-Experts architectures are designed for, validated on this hardware.

* * *

## Multi-GPU Scaling Summary

| Model | Architecture | TP=1 (1× B70) | TP=4 (4× B70) | Speedup |
| ---| ---| ---| ---| --- |
| Qwen2.5 3B | Dense | 72.9 tok/s | 62.6 tok/s | 0.86× (overhead) |
| Qwen3-8B | Dense (thinking) | 34.7 tok/s | — | Single-GPU only |
| Llama 3.1 8B | Dense | 35.4 tok/s | 70.3 tok/s | 1.99× |
| DeepSeek R1 8B | Dense | 66.9 tok/s | 136 tok/s | 2.03× |
| Qwen3.6-27B | Dense | ❌ Does not fit (54 GB) | 13.1 / 50.4 / 95.9 tok/s (1/4/8 users) | Multi-GPU required |
| Qwen3.6-35B-A3B | MoE | ❌ Does not fit (70 GB) | 16.3 / 63.7 / 122 tok/s (1/4/8 users) | Multi-GPU required |

*All single-user numbers at Concurrency=1.*

The results tell a clear story across three performance tiers:

1. **Small models (3B)** run best on a single B70. At 3B scale the model is too small to benefit from sharding — TP=4 actually costs ~14% throughput.
2. **8B models** roughly double their single-user throughput with TP=4 (Llama 1.99×, DeepSeek 2.03×), turning "usable" into "cloud-competitive," and reach 470–905 tok/s of aggregate throughput at 8 concurrent users.
3. **Mid-tier dense (27B) and frontier MoE (35B+) models** require the 4-card configuration and run only because the full 128 GB VRAM pool is available. Both scale better than 7× from 1 to 8 concurrent users.

For comparison, a single RTX 5090 runs 8B FP16 models at 140–200 tok/s — roughly 4–5× faster than the B70 on the same workload, driven by its 1,792 GB/s memory bandwidth. But neither card can fit a model larger than ~15B in FP16 on a single GPU. The B70 4-card configuration trades per-GPU speed for VRAM capacity: 27B–35B FP16 models run natively here, where the 5090 would require 4-bit quantization to fit.
* * *

## Cost of Inference: Local vs. Cloud

With throughput established, the practical question is: **what does it actually cost to run these models locally - and how does that compare to a cloud API?** Frontier output pricing remains high - OpenAI's GPT-5.5 costs $30 per million output tokens, Anthropic's Claude Opus 4.8 $25/1M, and Google's Gemini 3.1 Pro $12/1M. We instrumented every benchmark with GPU power monitoring to answer this with measured data.

### Measured GPU Power Under Load

| Model | Config | GPUs Active | Avg GPU Power | Peak GPU Power |
| ---| ---| :---: | :---: | :---: |
| Qwen2.5 3B | TP=1 | 1 of 4 | **328 W** | 343 W |
| Qwen3 8B | TP=1 | 1 of 4 | **293 W** | 368 W |
| DeepSeek R1 8B | TP=1 | 1 of 4 | **350 W** | 366 W |
| Llama 3.1 8B | TP=1 | 1 of 4 | **350 W** | 367 W |
| Qwen2.5 3B | TP=4 | 4 | **344 W** | 486 W |
| DeepSeek R1 8B | TP=4 | 4 | **558 W** | 631 W |
| Llama 3.1 8B | TP=4 | 4 | **563 W** | 622 W |
| Qwen3.6-27B | TP=4 | 4 | **532 W** | 632 W |
| Qwen3.6-35B-A3B | TP=4 | 4 | **420 W** | 492 W |

*Power is the sum across all four installed B70 cards via the Intel `xe` driver's energy counters. In TP=1 tests the three idle cards still draw ~190 W combined, so single-GPU figures carry that idle overhead. Add ~300 W for the Xeon host (CPU/RAM/PSU) to estimate total wall power. Even the heaviest 4-card workload (632 W peak) stays well under the theoretical 920 W (4× 230 W TBP).*

The 35B MoE model draws notably less power (420 W avg) than the 27B dense model (532 W avg), reflecting the efficiency of sparse activation — fewer parameters are active per token.

### Cost Per Million Output Tokens

Using $0.12/kWh (US average) and total system power (GPU average + 300 W host overhead):

| Model | Config | tok/s | System W | $/1M tokens | vs. Gemini 3.1 Pro ($12) | vs. Opus 4.8 ($25) | vs. GPT-5.5 ($30) |
| ---| ---| ---: | ---: | ---: | ---: | ---: | ---: |
| Qwen2.5 3B | TP=1 | 72.9 | 628 | **$0.29** | 41× cheaper | 86× cheaper | 103× cheaper |
| DeepSeek R1 8B | TP=1 | 66.9 | 650 | **$0.32** | 38× cheaper | 78× cheaper | 94× cheaper |
| Qwen3 8B | TP=1 | 34.7 | 593 | **$0.57** | 21× cheaper | 44× cheaper | 53× cheaper |
| Llama 3.1 8B | TP=1 | 35.4 | 650 | **$0.61** | 20× cheaper | 41× cheaper | 49× cheaper |
| Qwen3.6-35B-A3B | TP=4 | 16.3 | 720 | **$1.47** | 8.2× cheaper | 17× cheaper | 20× cheaper |
| Qwen3.6-27B | TP=4 | 13.1 | 832 | **$2.12** | 5.7× cheaper | 12× cheaper | 14× cheaper |

*Cloud pricing as of June 2026: GPT-5.5 ($30/1M output), Claude Opus 4.8 ($25/1M), Gemini 3.1 Pro ($12/1M). Local costs are electricity only. Single-GPU figures include the idle draw of the three unused cards in this 4-card workstation; a dedicated single-card system would be cheaper per token.*

Even the most expensive local configuration — the 27B dense model on all four cards — costs $2.12 per million output tokens, still **5.7× cheaper than the least expensive frontier model** (Gemini 3.1 Pro at $12/1M). The 8B-and-smaller models range from $0.29–$0.61 per million tokens at single-user, and the cost drops sharply under load.

### Multi-User Economics

Because throughput scales far faster than power as concurrency rises, cost-per-token falls dramatically with more users:

| Model | Conc=1 | Conc=4 | Conc=8 |
| ---| ---: | ---: | ---: |
| Qwen2.5 3B (TP=1) | $0.29/1M | $0.075/1M | $0.040/1M |
| DeepSeek R1 8B (TP=1) | $0.32/1M | $0.084/1M | $0.045/1M |
| Qwen3 8B (TP=1) | $0.57/1M | $0.149/1M | $0.078/1M |
| Llama 3.1 8B (TP=1) | $0.61/1M | $0.163/1M | $0.085/1M |

At concurrency=8, every 8B-and-smaller model costs **under $0.10 per million output tokens** — well over 100× cheaper than even the least-expensive frontier model. For a team running a busy internal assistant, the four-card B70 workstation pays for its electricity many times over against any cloud API.
* * *

## Image Generation: ComfyUI + Z-Image Turbo

LLMs are only half the AI inference story. We also tested the B70 for generative image workloads using ComfyUI with the Z-Image Turbo model, a distilled diffusion model designed for fast 4-step generation at 1024×1024.

Because ComfyUI uses raw PyTorch for diffusion inference with no NVIDIA-specific CUDA kernels, it immediately detected the B70 as an XPU device with no patches or workarounds required:

```
Device: xpu:0 Intel(R) Graphics [0xe223]
Total VRAM 32656 MB, total RAM 128161 MB
pytorch version: 2.10.0+xpu
Set vram state to: NORMAL_VRAM
```

The entire 15.6 GB pipeline fits comfortably within the card's 32 GB VRAM without offloading.

### Results

**Prompt:** *"A majestic snow-capped mountain peak at golden hour, reflected perfectly in a crystal-clear alpine lake surrounded by wildflowers, professional landscape photography, 8k resolution"*

| Metric | Value |
| ---| --- |
| Iterations | 10/10 passed (0 failures) |
| Cold Start (iter 1) | 10.6s (model loading + JIT) |
| Steady State (iter 2–10) | 3.9s average |
| Mean (all 10) | 4.7s |
| p50 | 3.96s |
| Throughput | 12.86 images/min |
| Diffusion Speed | 1.13 it/s (4 steps) |
| VRAM Peak | 19.3 GB |

The Steady State row is the number that matters for production use: after the first cold-start iteration, the B70 generates 1024×1024 images in under 4 seconds consistently. The VRAM Peak of 19.3 GB leaves 13 GB of headroom for larger models or higher resolutions. The XPU compute path handles all diffusion operators (attention, convolution, VAE decode) without any failures across 10 consecutive runs.

For batch workloads or local creative workflows where cost-per-image matters, this is a compelling result. No NVIDIA hardware is required.

### Sample Output

These images were generated on the Arc Pro B70 using Z-Image Turbo with the benchmark prompt above. Each took under 4 seconds at steady state:

![Sample 1: Generated on Intel Arc Pro B70 via Z-Image Turbo](https://t9013011496.p.clickup-attachments.com/t9013011496/cc022206-628e-4f6a-ae92-e8069ed56b56/z_image_sample_1.png)

![Sample 2: Generated on Intel Arc Pro B70 via Z-Image Turbo](https://t9013011496.p.clickup-attachments.com/t9013011496/b06e53c7-f51f-4b39-8d45-f5328b2d6155/z_image_sample_2.png)

![Sample 3: Generated on Intel Arc Pro B70 via Z-Image Turbo](https://t9013011496.p.clickup-attachments.com/t9013011496/8c896f38-c360-423a-8d74-119087f14372/z_image_sample_3.png)

These are not cherry-picked. They are three consecutive runs from the same prompt and settings. The consistency across runs demonstrates stable XPU inference with no artifacts or degradation.
* * *

## What Doesn't Work

Two constraints remain on Arc Pro B70 AI inference via vLLM as of June 2026:

**bfloat16 models cannot be served through vLLM.** Models that require bfloat16 precision will not run through the current vLLM XPU backend, which serves FP16. The Gemma 2 family is the clearest example: when we attempted Gemma 2 9B in FP16, the current LLM Scaler container refused to load it outright — `The model type 'gemma2' does not support float16. Reason: Numerical instability. Please use bfloat16 or float32 instead.` Because the XPU backend cannot serve bfloat16, Gemma 2 has no working path on the B70 today. This is a **software maturity gap, not a hardware limitation**: the B70's Xe2 XMX engines natively support BF16 at 2,048 ops/clock at the silicon level. The blocker is vLLM's XPU platform code. In the meantime, models that support FP16 (Llama, Qwen, DeepSeek, Mistral families) work well.

**Quantized model support exists but is untested.** Upstream vLLM's AWQ/GPTQ Marlin dequantization kernels are CUDA-only with no XPU/SYCL equivalent. However, Intel's LLM Scaler container — the same `intel/llm-scaler-vllm:0.14.0-b8.2.1` image we used here — adds [INT4 and FP8 online quantization plus GPTQ support](https://github.com/intel/llm-scaler) on XPU. We did not test quantized inference for this article; all benchmarks used full FP16 weights. Quantized performance on the B70 is an open question we plan to address in a follow-up.

**Worth watching: llama.cpp + SYCL.** For users who need quantized model support or BF16 on Battlemage today, llama.cpp's SYCL backend is an emerging alternative. Community benchmarks show approximately 60 tok/s on Qwen 3.5-9B with Q4\_K\_M quantization. It also supports BF16 natively. We plan to test this path in a future article.
* * *

## How Do Four Arc Pro B70 GPUs Perform for AI Inference?

The Intel Arc Pro B70 is, as we suspected in our [initial hardware review](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-review/), a card designed first for AI. In a 4-card configuration, it delivers a genuine multi-GPU inference capability at a price point that was previously inaccessible:

* **8B models at cloud-competitive speeds:** With TP=4, Llama 3.1 8B reaches 70.3 tok/s and DeepSeek R1 8B 136 tok/s single-user — roughly 2× their single-card speeds — scaling to 472 and 905 tok/s respectively at 8 concurrent users. On a single card, DeepSeek R1 8B leads the 8B field at 66.9 tok/s with the lowest ITL in the suite.
* **27B–35B models that would not fit on a single card:** Qwen3.6-27B dense runs at 13.1 tok/s single-user (95.9 tok/s at 8 users); the 35B MoE variant reaches 16.3 tok/s single-user (122 tok/s at 8 users). Full FP16, no quantization, on under $4,000 of GPU hardware.
* **Dramatically cheaper than cloud APIs:** Measured power puts 8B-class inference at $0.29–$0.61 per million output tokens single-user, dropping below $0.10/1M at 8 concurrent users — 20–100× cheaper than frontier APIs (GPT-5.5 $30, Claude Opus 4.8 $25, Gemini 3.1 Pro $12 per 1M output). Even the 27B model on four cards is ~6× cheaper than the most affordable frontier model.
* **Rock-solid image generation:** Production-quality 1024×1024 images in under 4 seconds via Z-Image Turbo on XPU, with zero failures.

Here is how the two cards compare side by side:

|  | Intel Arc Pro B70 | NVIDIA RTX 5090 |
| ---| ---| --- |
| VRAM | 32 GB GDDR6 (ECC) | 32 GB GDDR7 |
| Memory Bandwidth | 608 GB/s | 1,792 GB/s |
| AI TOPS (INT8) | 367 TOPS | 3,352 TOPS (FP4 sparse) |
| TDP | 230W | 575W |
| MSRP | $949 | $1,999 |
| 4-card VRAM | 128 GB (~$3,800) | 128 GB (~$8,000) |
| Single-card 8B FP16 | 35–67 tok/s | ~140–200 tok/s |
| FP16 model ceiling (1 card) | ~15B | ~15B |
| Quantized models (INT4/FP8/GPTQ) | ⚠️ Available via LLM Scaler (untested) | ✅ Full support |

The RTX 5090 is roughly 4–5× faster per GPU on decode-bound workloads, driven by nearly 3× the memory bandwidth. The B70 offers the same VRAM at less than half the price, and a 4-card B70 configuration costs less than two 5090s while delivering twice the aggregate memory pool. Teams running FP16-compatible models where VRAM capacity matters more than single-GPU throughput will find better economics with the B70. Teams that need quantized model support or maximum per-card speed will prefer the 5090.

The caveats are real: bfloat16 models are software-blocked in vLLM, quantized inference via LLM Scaler is available but untested by us, and the initial software setup requires careful container configuration (see Appendix A). But for teams running FP16-compatible models — which covers the most popular Llama, Qwen, DeepSeek, and Mistral families — the hardware is ready for production multi-GPU inference. Zero crashes were observed across our full benchmark suite once the system was properly configured.
* * *

*LLM benchmarks re-run June 2026 on a Puget Systems X142-XL workstation with 4× Intel Arc Pro B70 GPUs running Ubuntu 25.04, using `intel/llm-scaler-vllm:0.14.0-b8.2.1` with `VLLM_WORKER_MULTIPROC_METHOD=spawn` and `CCL_TOPO_P2P_ACCESS=0`. All LLM tests used NVIDIA GenAI-Perf with `--streaming` (500 in / 500 out / 50 prompts, concurrency 1/4/8). GPU power measured via the Intel `xe` driver's `hwmon` energy counters. Image generation used ComfyUI with Z-Image Turbo. Cloud API pricing as of June 2026.*
* * *

## Appendix A: Setup Guide for Practitioners

Getting multi-GPU inference running on Battlemage silicon requires solving three problems. This section documents each one and its fix. If you are using the `intel/llm-scaler-vllm:0.14.0-b8.2.1` container, problem #1 is already handled for you.

### Problem 1: The Driver Conflict ("Split-Brain")

Intel's official `intel/vllm:0.17.0-xpu` container ships with OneAPI 2025.x, which bundles its own Level Zero and OpenCL ICD libraries built for Intel Data Center GPUs (Flex/Max series), not the Arc Pro B70. When the container starts, the SYCL runtime discovers two competing OpenCL vendors:

* `/etc/OpenCL/vendors/intel.icd` → PPA-provided `libze_intel_gpu` (correct for B70)
* `/etc/OpenCL/vendors/intel64.icd` → OneAPI-bundled `libintelocl.so` (built for Flex/Max)

The result: `torch.xpu` sees zero devices.

**The fix:** Remove the conflicting libraries at container build time:

```dockerfile
# Remove conflicting OneAPI ICD and OpenCL libraries
RUN rm -f /etc/OpenCL/vendors/intel64.icd && \
    rm -f /opt/intel/**/libintelocl.so
```

```dockerfile
# Prevent setvars.sh from clobbering LD_LIBRARY_PATH
RUN sed -i '/setvars.sh/d' ~/.bashrc
```

```dockerfile
# Disable precompiled kernels that don't exist for Battlemage silicon
ENV NEO_ReadDeviceBinaryBuiltins=0
```

Setting `NEO_ReadDeviceBinaryBuiltins=0` is required. Without it, the NEO driver attempts to load precompiled kernels that do not exist for Battlemage silicon, causing silent fallback failures.

### Problem 2: Fork-Safety (The SYCL Context Crash)

vLLM's V1 engine (versions 0.15+) forks an `EngineCore` subprocess for KV cache profiling. The SYCL Level Zero context is not fork-safe on Xe2 silicon: the forked child process inherits `/dev/dri` file descriptors but loses the GPU context, causing an immediate crash:

```
terminate called after throwing an instance of 'sycl::_V1::exception'
  what(): No device of requested type available.
```

**The fix:** Set `VLLM_WORKER_MULTIPROC_METHOD=spawn`. This forces vLLM to start fresh Python interpreters for each tensor-parallel worker instead of forking the parent process. The fresh workers initialize clean GPU connections from scratch, completely avoiding the fork-safety issue.

### Problem 3: PCIe Peer-to-Peer Bus Errors

Direct GPU-to-GPU peer-to-peer memory copies (`CCL_TOPO_P2P_ACCESS=1`) can trigger physical PCIe bus transmission errors (`RxErr`) depending on the motherboard's PCIe slot topology, causing the kernel's GPU copy engine to reset and the container to deadlock:

```
xe 0000:aa:00.0: [drm] Engine reset: engine_class=bcs
aer_status: 0x00000001, RxErr
```

**The fix:** Set `CCL_TOPO_P2P_ACCESS=0` to route inter-GPU communication through Unified Shared Memory (USM) via host RAM. The latency penalty is small (microseconds for the host RAM round-trip), and the stability gain is absolute.

**Update:** We traced these errors to a PCIe riser used by one of the four B70 cards. After removing the riser and seating all four cards directly into motherboard PCIe slots, we re-ran the full multi-GPU benchmark suite with zero stability issues. We have not re-tested with `CCL_TOPO_P2P_ACCESS=1` (direct P2P) on the updated configuration, so the USM fallback remains our recommended default. The root cause was a signal integrity limitation of the PCIe riser, not a defect in the B70 silicon.

### Complete Environment Variables

```bash
# Driver / runtime selection
SYCL_DEVICE_FILTER=level_zero:gpu          # Force Level Zero GPU backend
ONEAPI_DEVICE_SELECTOR=level_zero:gpu      # Same, for OneAPI selector
NEO_ReadDeviceBinaryBuiltins=0             # Disable precompiled kernel loading
SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMAND_LISTS=0  # Use regular cmd lists
ZES_ENABLE_SYSMAN=0                        # Disable Sysman (reduces init errors)

# Critical for multi-GPU vLLM
VLLM_WORKER_MULTIPROC_METHOD=spawn         # Bypass fork() GPU context crash
CCL_TOPO_P2P_ACCESS=0                      # USM fallback, avoids PCIe bus errors
```

### Docker Compose Reference

```yaml
services:
  inference:
    image: intel/llm-scaler-vllm:0.14.0-b8.2.1
    privileged: true
    shm_size: "32g"
    environment:
      - VLLM_TARGET_DEVICE=xpu
      - VLLM_WORKER_MULTIPROC_METHOD=spawn
      - CCL_TOPO_P2P_ACCESS=0
      - ZES_ENABLE_SYSMAN=0
    command:
      - python3 -m vllm.entrypoints.openai.api_server
        --tensor-parallel-size=4
        --enforce-eager
        --gpu-memory-utilization=0.90
        --max-model-len=32768
```

### Known Working Models

Models tested on `intel/llm-scaler-vllm:0.14.0-b8.2.1` with `VLLM_WORKER_MULTIPROC_METHOD=spawn`. Unquantized FP16 weights only.

| Architecture | Supported | Tested Models | Status |
| ---| ---| ---| --- |
| `Qwen2ForCausalLM` | ✅ Yes | Qwen2.5-3B-Instruct | ✅ 72.9 tok/s (TP=1) |
| `Qwen3ForCausalLM` | ✅ Yes | Qwen3-8B | ✅ 34.7 tok/s (TP=1), 255 tok/s (8 users) |
| `Qwen3ForCausalLM` | ✅ Yes | Qwen3.6-27B Dense | ✅ 13.1 tok/s (TP=4), 95.9 tok/s (8 users) |
| `Qwen3MoeForCausalLM` | ✅ Yes | Qwen3.6-35B-A3B MoE | ✅ 16.3 tok/s (TP=4), 122 tok/s (8 users) |
| `LlamaForCausalLM` | ✅ Yes | Llama 3.1 8B | ✅ 35.4 tok/s (TP=1), 70.3 tok/s (TP=4) |
| `LlamaForCausalLM` | ✅ Yes | DeepSeek R1 Distill 8B | ✅ 66.9 tok/s (TP=1), 136 tok/s (TP=4) |
| `Gemma2ForCausalLM` | ❌ No | Gemma 2 9B IT | ❌ Blocked: requires bfloat16 (XPU serves FP16 only) |
| `MistralForCausalLM` | ✅ Yes | N/A | Expected working |

### Files to Remove from intel/vllm Containers

```bash
/etc/OpenCL/vendors/intel64.icd            # Conflicting OneAPI ICD
/opt/intel/**/libintelocl.so               # Conflicting OpenCL library
~/.bashrc entries for setvars.sh           # Prevents LD_LIBRARY_PATH clobbering
```
