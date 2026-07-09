**How does the NVIDIA DGX Spark (GB10) perform for local LLM inference and image generation?**
* * *

## Introduction

Every other system we've benchmarked in this series — the dual RTX PRO 6000 Blackwell, the dual AMD Radeon AI PRO R9700, the quad Intel Arc Pro B70 — is built the same way: discrete GPUs, each with its own fast dedicated VRAM, in a full-size workstation. The NVIDIA DGX Spark is something different. It is a **GB10 Grace-Blackwell superchip**: a single Blackwell GPU fused to a 20-core Arm CPU, sharing **one 128 GB pool of unified LPDDR5X memory** — in a box the size of a hardcover book, drawing a fraction of the power of a single discrete card.

That design trades bandwidth for capacity and efficiency. The Spark's ~273 GB/s of memory bandwidth is roughly a quarter of the B70 or R9700 and a seventh of the RTX PRO 6000 — and for decode-bound LLM inference, bandwidth is destiny. So the Spark is the **slowest per-stream machine we've tested**. But it holds **128 GB in a single address space**, which means it runs models that simply will not fit on one discrete card — a 122B-parameter model loads on this one chip — and it does so at an estimated ~140 W for the whole system.

The question for this article: where does a machine like this actually fit? We ran the same benchmark suite we used on the other systems — single-GPU FP16 baselines, the larger quantized models the Spark's big memory pool unlocks, and a ComfyUI image-generation pass — and we instrumented power throughout. The short answer: the DGX Spark is not a throughput server. It is a **large-model development and prototyping machine**, and a remarkably efficient one.
* * *

## Test Setup

| Component | Spec |
| ---| --- |
| GPU | 1× NVIDIA GB10 (Grace-Blackwell superchip, sm_121) |
| Unified Memory | 128 GB LPDDR5X (shared CPU + GPU) |
| Memory Bandwidth | ~273 GB/s (published GB10 spec)† |
| CPU | 20-core Arm (10× Cortex-X925 + 10× Cortex-A725) |
| Host System | NVIDIA DGX Spark (`spark-5743`) |
| OS | Ubuntu 24.04 (aarch64) |
| Driver / CUDA | 580.159.03 / CUDA 13 |

**Inference Software:** All LLM benchmarks used vLLM (`vllm/vllm-openai:cu130-nightly`, the arm64 CUDA 13 nightly required for GB10's sm_121). FP16 weights for the baseline models; AWQ 4-bit for the larger models.

**Benchmark Tool:** NVIDIA GenAI-Perf with `--streaming` for real Time-To-First-Token (TTFT) and Inter-Token Latency (ITL). Each test used 500 input tokens, 500 output tokens. Standard models used a 30-second measurement window; reasoning/thinking models used a 120-second window to capture the extended reasoning phase. Because the Spark is a single GPU, we pushed concurrency further than on the multi-card systems — **1, 4, 8, 16, and 32 simultaneous users** — to find the saturation point of the unified-memory bus.

**Power Monitoring:** GPU power was sampled every 2 seconds via `nvidia-smi`. On GB10's unified design this appears to report a package rail rather than full system draw, so we treat these figures as a lower bound and reference the platform's ~140 W typical-load system power for the cost analysis (see [Cost of Inference](#cost-of-inference)).

> † `nvidia-smi` reports `memory.total = [N/A]` on GB10's unified memory; the 128 GB / ~273 GB/s figures are NVIDIA's published GB10 specification, not measured on-box.
* * *

## What Models Fit?

This is where the Spark's design inverts the usual conversation. On a discrete card the question is "does the model fit in VRAM?" On the Spark, with 128 GB of unified memory, almost everything fits — the question becomes "is it fast enough to be useful?"

| Model | Type | Params | Precision | Fits on the Spark (128 GB)? |
| ---| ---| ---| ---| --- |
| Qwen2.5-3B Instruct | Dense | 3B | FP16 | ✅ Yes |
| Llama 3.1 8B Instruct | Dense | 8B | FP16 | ✅ Yes |
| DeepSeek R1 Distill 8B | Dense | 8B | FP16 | ✅ Yes |
| Qwen3-8B | Dense (thinking) | 8B | FP16 | ✅ Yes |
| Qwen3.6-27B | Dense | 27B | FP16 (~54 GB) | ✅ Yes |
| Qwen3.6-35B-A3B | MoE | 35B (3B active) | AWQ 4-bit | ✅ Yes |
| DeepSeek R1 70B | Dense | 70B | AWQ 4-bit | ✅ Yes |
| Qwen3.5-122B-A10B | MoE | 122B (10B active) | AWQ 4-bit | ✅ Yes |

A 122-billion-parameter model running on a single ~140 W chip is the DGX Spark's entire reason to exist. On the discrete systems in this series, a model that size requires the full multi-card VRAM pool (or doesn't fit at all). Here it loads on one device, in unified memory, with room to spare. What follows is whether the bandwidth keeps up.
* * *

## Single-GPU FP16 Performance

We started with the FP16 baseline models — the same set we ran on the RTX PRO 6000, R9700, and B70 — so the numbers are directly comparable. All run on the Spark's single GB10 GPU.

### Summary: FP16 Results (Concurrency = 1)

| Model | Throughput (tok/s) | TTFT (ms) | ITL (ms) | Avg GPU Power |
| ---| ---| ---| ---| --- |
| Qwen2.5 3B Instruct | **30.6** | 88 | 32 | 24 W |
| DeepSeek R1 Distill 8B | **14.4** | 234 | 69 | 39 W |
| Qwen3 8B (thinking) | **14.2** | 141 | 70 | 39 W |
| Llama 3.1 8B Instruct | **14.4** | 183 | 69 | 39 W |

*All tests: 500 input / 500 output tokens, FP16, single GB10 GPU. Qwen3 8B used a 120-second measurement window for its reasoning phase.*

The single-stream story is consistent with the hardware: a small 3B model decodes at ~30 tok/s — comfortable reading speed — while the 8B-class models land near 14 tok/s, roughly half that. The ~70 ms ITL on the 8B models is the bandwidth tax: every generated token requires streaming the model's weights from LPDDR5X, and at 273 GB/s that takes time. This is usable for single-user interactive work, but it is not fast.

### Detailed Tables — Concurrency Scaling

Where the Spark surprises is under concurrency. Even on a single GPU, vLLM's continuous batching extracts strong aggregate throughput as users are added — the unified-memory pool has the *capacity* to hold many sequences' KV cache at once.

#### Qwen2.5 3B Instruct (FP16)

| Concurrency | Throughput (tok/s) | TTFT (ms) | ITL (ms) |
| ---| ---| ---| --- |
| 1 | **30.6** | 88 | 32 |
| 4 | **131.9** | 104 | 29 |
| 8 | **252.9** | 406 | 30 |
| 16 | **497.3** | 98 | 31 |
| 32 | **830.0** | 110 | 36 |

The 3B model scales 27× from 1 to 32 users (30.6 → 830 tok/s) with ITL essentially flat — a near-perfect demonstration that the Spark's bottleneck is memory bandwidth per stream, not compute. Pack the bus with parallel work and aggregate throughput climbs all the way to 830 tok/s.

#### DeepSeek R1 Distill Llama 8B (FP16)

| Concurrency | Throughput (tok/s) | TTFT (ms) | ITL (ms) |
| ---| ---| ---| --- |
| 1 | **14.4** | 234 | 69 |
| 4 | **57.8** | 328 | 69 |
| 8 | **113.0** | 261 | 70 |
| 16 | **213.9** | 324 | 74 |
| 32 | **377.1** | 248 | 85 |

#### Qwen3 8B (FP16) — Thinking Model

| Concurrency | Throughput (tok/s) | TTFT (ms) | ITL (ms) |
| ---| ---| ---| --- |
| 1 | **14.2** | 141 | 70 |
| 4 | **57.8** | 243 | 69 |
| 8 | **112.1** | 483 | 71 |
| 16 | **213.3** | 222 | 75 |
| 32 | **379.7** | 270 | 84 |

> **A note on benchmarking reasoning models:** like every system in this series, the Spark required a 120-second measurement window for Qwen3 8B. In the standard 30-second window the model's internal thinking phase consumes the entire interval and GenAI-Perf reports 0 tok/s. This is a cross-platform property of how thinking models are measured, not a hardware trait — but it bites harder on a bandwidth-bound machine, which is why our harness now automatically extends the window for reasoning models on both the vLLM and Ollama paths.

#### Llama 3.1 8B Instruct (FP16)

| Concurrency | Throughput (tok/s) | TTFT (ms) | ITL (ms) |
| ---| ---| ---| --- |
| 1 | **14.4** | 183 | 69 |
| 4 | **50.4** | 233 | 68 |
| 8 | **103.1** | 509 | 71 |
| 16 | **191.9** | 505 | 74 |
| 32 | **325.1** | 264 | 83 |

The 8B models tell the same story as the 3B: ~25× aggregate scaling from 1 to 32 concurrent users, flat ITL. The Spark is slow for one user and genuinely capable for many — provided you have the latency budget for ~70 ms per token.
* * *

## The Frontier: Large Models on One Chip

The FP16 baselines are the apples-to-apples comparison, but they undersell the machine. The Spark's real differentiator is the quantized large-model tier — models in the 35B–122B range that the discrete single cards in this series cannot hold. All of the following run on the **single GB10 GPU** in AWQ 4-bit.

| Model | Architecture | tok/s @ c1 | tok/s @ c8 | tok/s @ c32 | ITL (ms) | Power |
| ---| ---| ---| ---| ---| ---| --- |
| Qwen3.6-35B-A3B | MoE (3B active) | **35.7** | 188 | 394 | 28 | 36 W |
| Qwen3.5-35B-A3B | MoE (3B active) | **35.5** | 187 | 395 | 28 | 28 W |
| Qwen3.5-122B-A10B | MoE (10B active) | **14.0** | 68 | 136 | 71 | 39 W |
| DeepSeek R1 70B | Dense | **5.9** | 43 | 144 | 167 | 34 W |
| Qwen3.6-27B | Dense | **12.0** | 79 | 160 | 83 | 45 W |

The pattern here is the most important result in the article. **Architecture matters more than parameter count on a bandwidth-bound machine:**

* The **35B MoE** models run at **35.7 tok/s** single-user — *faster* than the 8B FP16 dense models — because only ~3B parameters are active per token, so far less weight crosses the bus per step.
* The **122B MoE** runs at **14 tok/s** — the same speed as an 8B FP16 dense model — on a single chip. A 122-billion-parameter model at usable interactive speed, in a box you can carry, is genuinely novel.
* The **70B dense** model is the slow outlier at 5.9 tok/s: every one of its 70B parameters (quantized) must stream per token, and at 273 GB/s that is the worst case for this hardware.

The takeaway for Spark users is clear: **prefer MoE architectures and quantization.** A 122B MoE is more practical here than a 70B dense model, despite having 1.7× the parameters.
* * *

## Cross-System Comparison

Here is where the DGX Spark sits against the other systems in this series. Because the Spark is single-GPU and the others were tested to 8 concurrent users, the cleanest comparison is **single-stream (concurrency = 1) throughput**, single card where the model fits on one.

### 8B-and-Smaller (FP16, single card, tok/s @ c1)

| Model | DGX Spark (GB10) | Intel B70 | AMD R9700 | RTX PRO 6000 |
| ---| ---: | ---: | ---: | ---: |
| Qwen2.5 3B | 30.6 | 72.9 | 81.1 | **176** |
| DeepSeek R1 8B | 14.4 | 66.9 | 61.3 | **163** |
| Qwen3 8B | 14.2 | 34.7 | 37.4 | **82** |
| Llama 3.1 8B | 14.4 | 35.4 | 31.9 | **87** |

### Frontier Tier — Where It Gets Interesting

The small-model table is the bandwidth ladder in its purest form, and the Spark sits at the bottom of it. But the frontier models — the 27B–35B tier that is the actual reason to want a large memory pool — tell a more nuanced story, because here *precision and architecture* start to matter as much as raw bandwidth.

**Qwen3.6-27B (dense, FP16)** — the one large model every system ran in FP16, so the cleanest like-for-like. Note the configuration differences: the Spark runs it on one GPU; the others need their full multi-card pool.

| System | Config | Throughput @ c1 | Throughput @ peak |
| ---| ---| ---: | ---: |
| DGX Spark (GB10) | FP16, 1 GPU (unified) | 4.5 | 89.8 @ 32 users |
| AMD R9700 | FP16, PP=2 (2 cards) | 10.9 | — |
| Intel B70 | FP16, TP=4 (4 cards) | 13.1 | 95.9 @ 8 users |
| RTX PRO 6000 | FP16, 1 card | 24 | 175 @ 8 users |
| RTX PRO 6000 | FP16, 2 cards | 41 | — |

On the dense 27B in FP16, the Spark is last — 4.5 tok/s, because all 27B parameters must stream from LPDDR5X every token. This is the worst case for the hardware, and it shows.

**Qwen3.6-35B-A3B (MoE)** — now change two things: a sparse MoE architecture (only ~3B of 35B parameters active per token) *and* 4-bit AWQ quantization. Both reduce bytes-moved-per-token, which is exactly the Spark's constraint. To make this a true same-precision comparison, we re-ran the model in AWQ on a single RTX PRO 6000 (TP=1) as well. (The Intel B70 cannot run AWQ — the Marlin dequant kernels are CUDA-only — so it stays FP16.)

| System | Precision / Config | Throughput @ c1 | Throughput @ peak |
| ---| ---| ---: | ---: |
| **DGX Spark (GB10)** | **AWQ, 1 GPU** | **35.7** | 394 @ 32 users |
| RTX PRO 6000 | AWQ, 1 card | 42.6 | ~1,000 @ 32 users |
| RTX PRO 6000 | FP16, 1 card | 36 | 247 @ 8 users |
| Intel B70 | FP16, TP=4 (4 cards) | 16.3 | 122 @ 8 users |
| AMD R9700 | — does not fit | — | — |

This is the result worth dwelling on. Same precision (AWQ), same single-GPU configuration, the Spark's **35.7 tok/s lands within ~20% of the RTX PRO 6000's 42.6** — a card with **6.5× the memory bandwidth**. Contrast that with the small dense FP16 models, where the same RTX PRO 6000 is **5–10× faster**. The bandwidth gap doesn't just shrink on a quantized MoE; it nearly closes. The reason is the same one that lets the Spark run the model at all: with only ~3B parameters active per token and 4-bit weights, the bytes that must cross the memory bus each step drop low enough that the Spark's narrow bus stops being the bottleneck. A 122B MoE in AWQ at 14 tok/s (above) is the same principle taken further. **For dense FP16 the Spark is hopelessly slow; for quantized MoE — the architecture you'd actually deploy at this scale — it is genuinely competitive with cards costing several times more.**

For the small dense models, the ordering is the bandwidth ladder, **slowest to fastest: DGX Spark < AMD R9700 ≈ Intel B70 < RTX PRO 6000** — tracking memory bandwidth almost perfectly:

| System | Bandwidth (per GPU) | Single-card 8B FP16 (rough) |
| ---| ---: | ---: |
| **DGX Spark (GB10)** | **~273 GB/s** | ~14 tok/s |
| Intel B70 | 608 GB/s | ~35–67 tok/s |
| AMD R9700 | 640 GB/s | ~32–61 tok/s |
| RTX PRO 6000 | ~1,792 GB/s | ~160–176 tok/s |

The RTX PRO 6000 is **5–10× faster per stream** than the Spark. That is the cost of unified LPDDR5X versus dedicated GDDR7/HBM. But raw speed is one axis. Compared on what each machine is *for*:

| | DGX Spark | Intel B70 (4×) | AMD R9700 (2×) | RTX PRO 6000 (2×) |
| ---| ---| ---| ---| --- |
| Usable memory | **128 GB unified** | 128 GB (4×32) | 64 GB (2×32) | 192 GB (2×96) |
| Largest model on ONE GPU | **~120 GB** | 32 GB | 32 GB | 96 GB |
| Whole-system power | **~140 W** | ~920 W | ~600 W | ~600 W |
| Per-stream speed | slowest | mid | mid | **fastest** |
| Form factor | **book-sized** | full tower | full tower | full tower |
| Best fit | large-model dev / prototyping | scale-out FP16 throughput | mid-range value | production throughput |

The Spark loses every throughput race and wins decisively on memory-per-watt, largest-model-on-one-device, and footprint.
* * *

## Cost of Inference

The Spark's headline number isn't tokens per second — it's **tokens per second per watt**. Even being conservative and using the platform's ~140 W typical-load system power (the `nvidia-smi` rail readings of 24–44 W are lower), the low draw produces very low cost-per-token despite modest throughput.

Using $0.12/kWh and ~140 W system power, single-user:

| Model | tok/s @ c1 | $/1M tokens | vs. Gemini 3.1 Pro ($12) | vs. Opus 4.8 ($25) |
| ---| ---: | ---: | ---: | ---: |
| Qwen2.5 3B (FP16) | 30.6 | **$0.15** | 78× cheaper | 163× cheaper |
| Qwen3.5-122B-A10B (AWQ) | 14.0 | **$0.33** | 36× cheaper | 75× cheaper |
| Llama 3.1 8B (FP16) | 14.4 | **$0.32** | 37× cheaper | 78× cheaper |
| Qwen3.6-27B (FP16) | 4.5 | **$1.04** | 12× cheaper | 24× cheaper |

*Cloud pricing as of June 2026: GPT-5.5 ($30/1M output), Claude Opus 4.8 ($25/1M), Gemini 3.1 Pro ($12/1M). Local cost is electricity only. **Power caveat:** these figures use the ~140 W published system-load spec; we have not yet confirmed wall draw with a meter, so treat the absolute dollar figures as estimates and the *relative* efficiency story as the takeaway.*

Under concurrency the cost collapses further — at 32 users the 3B model's 830 tok/s brings it to well under $0.01 per million tokens. Running a 122B-class model for **$0.33 per million output tokens** — 36× cheaper than the most affordable frontier API — is the kind of economics that makes a low-power large-memory box compelling for sustained internal workloads, even at modest speed.
* * *

## Image Generation: ComfyUI

We tested ComfyUI on the Spark with two workflows: Z-Image Turbo (BF16) and Flux.2 Dev (FP8).

**Z-Image Turbo (BF16)** generates 1024×1024 images cleanly through the standard PyTorch path — the same result we saw across the other systems.

**Flux.2 Dev (FP8)** also works, on a CUDA 13 / torch `cu130` build (which we wired into the app-pack's GPU auto-detection so the Spark selects it automatically for sm_121; sm_120 cards keep the proven cu128). It is slow — Flux.2 is a large model and the Spark is bandwidth-bound:

| Metric | Value |
| ---| --- |
| Iterations | 3/3 passed (0 failures) |
| Cold start (iter 1) | 73.0 s |
| Steady state (iter 2–3) | ~51.7 s |
| Mean | 58.8 s |
| Throughput | 1.02 images/min |
| VRAM peak | 117.1 GB |

At ~52 s per 1024×1024 image in steady state, Flux.2 on the Spark is roughly an order of magnitude slower than the B70's ~4 s — again, the memory-bandwidth tax on a large model. But it runs to completion with zero failures, and its 117 GB VRAM peak is a model footprint no single discrete card in this series could hold. For Z-Image Turbo the Spark is a perfectly usable interactive image box; for Flux.2 it is a "set it and come back" batch tool.
* * *

## What Doesn't Work (Yet)

The DGX Spark hardware is capable, and over the course of this testing most of what initially "didn't work" turned out to be fixable software and configuration issues rather than hardware limits. It is worth separating the two.

**Works:** FP16, BF16, and **AWQ** 4-bit — every model in the tables above, including the 122B MoE — plus ComfyUI BF16 (Z-Image) and, on a CUDA 13 build, ComfyUI FP8 (Flux.2). The 35B/122B AWQ models and Flux.2 FP8 all run.

**Genuine GB10 software-maturity gaps (mid-2026), each with a known cause:**

| Path | Symptom | Root cause | Status |
| ---| ---| ---| --- |
| vLLM **NVFP4** (Nemotron Nano/Super) | engine crash / hang | NVFP4 kernels immature on sm_121 in the CUDA 13 nightly | Use AWQ; expect fixes as kernels mature |
| vLLM **MXFP4** (GPT-OSS 20B/120B) | crash-loop | MXFP4 kernel gap on sm_121 | Use AWQ |
| vLLM **Gemma-4 MoE AWQ** | crash-loop | Gemma-4 MoE architecture support in the nightly | Pending upstream |

These are the real remaining gaps — the **newest low-bit numeric formats (NVFP4, MXFP4)** that the rest of the Blackwell line is only beginning to lean on. This is a snapshot of software maturity, not a hardware limit; stable kernels have historically lagged Blackwell silicon by a release or two, and AWQ covers the same models today.

**Two issues that looked like hardware limits but weren't** — worth calling out, because they're the kind of thing that gets misattributed to a new platform:

* **ComfyUI Flux.2 FP8** appeared to fail on GB10. The actual cause was a benchmark/app-pack bug — the harness downloaded a `bf16` text encoder on high-VRAM GPUs while the workflow referenced the `fp8` one, so ComfyUI rejected the job at submission (HTTP 400) before any GPU work. The same bug was latent on the RTX PRO 6000. With the filenames aligned and a CUDA 13 / torch `cu130` build for sm_121 FP8 support, Flux.2 generates cleanly (see above).
* **Ollama Llama 4 Scout** crashed its runner (`HTTP 500`). Not a kernel issue: Scout's ~10M-token default context made Ollama pre-allocate a KV cache larger than the unified pool. Capping the context (`num_ctx=8192`) with flash-attention and a quantized KV cache, the 109B model loads and serves normally — the unified-memory equivalent of "don't ask for a 10M-token context on a 128 GB box."
* * *

## How Does the DGX Spark Perform for AI Inference?

The DGX Spark is not competing with the RTX PRO 6000 — or even the B70 and R9700 — on throughput. Its ~273 GB/s of memory bandwidth makes it the slowest per-stream machine in this series, by 5–10×, exactly as the hardware predicts. Trying to use it as a serving box would be a mistake.

What it offers instead has no equivalent among the discrete-card systems:

* **A 122B model on a single device.** With 128 GB of unified memory, the Spark loads 35B–122B models that need a full multi-card pool elsewhere — and MoE + AWQ variants run at genuinely usable interactive speeds (35B MoE at 35.7 tok/s, 122B MoE at 14 tok/s single-user).
* **Remarkable efficiency.** At an estimated ~140 W for the whole system, even modest throughput translates to very low cost-per-token — $0.15–$1.04 per million tokens across the range, 12–160× cheaper than frontier cloud APIs.
* **A desk-sized, book-sized form factor** that runs quietly at a fraction of a workstation's power.

This is a **large-model development and prototyping machine.** For an engineer who needs to load a 70B–122B model, iterate against it, validate behavior, and do so locally and cheaply — not serve it to a team at scale — the Spark delivers a capability that previously required either a multi-card workstation or the cloud.

The caveats are real and worth budgeting for: per-stream speed is low, and the newest low-bit vLLM formats (NVFP4, MXFP4) don't yet work on GB10's software stack — AWQ, FP16, and BF16 are the safe, fully-working paths today, and they cover the models that matter. (Notably, two things that *looked* like hardware limits — Flux.2 FP8 and Llama 4 Scout — turned out to be a benchmark bug and a context-size default, both fixable.) For the narrow, genuinely new thing the Spark does — big models, low power, small box — there is nothing else quite like it.
* * *

*Benchmarks run June 2026 on an NVIDIA DGX Spark (GB10, 128 GB unified memory, Ubuntu 24.04 aarch64, CUDA 13) using vLLM `cu130-nightly`. All LLM tests used NVIDIA GenAI-Perf with `--streaming` (500 in / 500 out, concurrency 1/4/8/16/32; 120 s window for reasoning models). GPU power via `nvidia-smi`. Llama models use the ungated `unsloth` mirrors (identical weights). Cloud API pricing as of June 2026.*
