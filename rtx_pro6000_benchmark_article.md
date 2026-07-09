# NVIDIA RTX PRO 6000 Blackwell: Dual-GPU AI Inference Performance

**What does local LLM inference look like when you remove the VRAM ceiling? Two NVIDIA RTX PRO 6000 Blackwell Max-Q cards put 192 GB of GDDR7 on the bench — enough to run a 70B dense model in full FP16 on a workstation.**

> **DRAFT — for review.** All LLM throughput, TTFT/ITL, GPU-power, and image-generation numbers below are final and measured. The only items still open are the three hardware-spec rows marked **`†verify`** (memory bandwidth, MSRP, core count), which should be confirmed against NVIDIA's datasheet before publish.

---

## Introduction

This is the third entry in our local-inference series. We've now run the same benchmark suite across three very different professional cards, and this one breaks the mold:

- The **[Intel Arc Pro B70](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/)** — the capacity play: 128 GB of aggregate VRAM across four cards for under $4,000.
- The **AMD Radeon AI PRO R9700** — the value play: the best throughput-per-dollar we measured at the 27B tier.
- And now the **NVIDIA RTX PRO 6000 Blackwell** — the performance ceiling. Where the other two are about *fitting* models affordably, this one is about *not compromising at all*.

The RTX PRO 6000 Blackwell carries **96 GB of GDDR7 per card**. Two of them deliver **192 GB of aggregate VRAM** — and that capacity comes paired with roughly **1.8 TB/s of memory bandwidth per card**, nearly 3× what the Intel and AMD cards offer. That combination changes what's on the menu. A single RTX PRO 6000 runs a 27B *and* a 35B model that needed two-to-four cards everywhere else. Two of them run **Llama 3.3 70B and Qwen2.5 72B in full FP16** — dense 70B-class models that simply do not fit on any other configuration in this series.

We tested the **Max-Q** variant — the 300W workstation card, not the 600W desktop part — which makes the efficiency story below all the more striking. The card is not cheap: at roughly **$8,500 each `†verify`**, a two-card system is a serious investment. So the question we set out to answer is sharper than "does it work":

**When you pay for NVIDIA's flagship workstation GPU, what do you actually get — in throughput, in models you can run, and in cost-per-token versus both the cheaper cards and the cloud?**

We tested single-GPU baselines (TP=1), dual-GPU tensor parallelism (TP=2), the 27B/35B middle tier, and two 70B-class dense models that only this configuration can host. Every benchmark was instrumented for GPU power draw so we can put a real cost-per-token next to today's cloud APIs.

---

## Test Setup

| Component | Spec |
|-----------|------|
| **GPUs** | 2× NVIDIA RTX PRO 6000 Blackwell **Max-Q** Workstation Edition |
| **Architecture** | Blackwell (GB202, compute capability `sm_120`) |
| **VRAM per GPU** | 96 GB GDDR7 (ECC) |
| **Total VRAM** | 192 GB |
| **Memory Bandwidth** | ~1,792 GB/s per GPU `†verify` |
| **CUDA Cores** | 24,064 per GPU `†verify` |
| **TDP** | 300W per GPU (Max-Q) — measured peak ~315W/card |
| **MSRP** | ~$8,500 per card `†verify` |
| **GPU Interconnect** | PCIe 5.0 — **no NVLink** (see [Setup Notes](#setup-notes-for-practitioners)) |
| **Host System** | AMD Ryzen Threadripper PRO 9995WX (96-core / 192-thread), 128 GB RAM |
| **OS** | Ubuntu 24.04.4 LTS |

**Inference Software:** All LLM benchmarks used the CUDA 13 vLLM build (`vllm/vllm-openai:cu130-nightly`) required for Blackwell's `sm_120` target, with unquantized FP16 weights. Multi-GPU models used Tensor Parallelism (TP=2). Because these two cards have **no NVLink bridge**, direct PCIe peer-to-peer deadlocks at distributed init; we set `NCCL_P2P_DISABLE=1` to route collectives through host memory (see [Setup Notes](#setup-notes-for-practitioners)).

**Benchmark Tool:** NVIDIA GenAI-Perf with `--streaming` enabled for all LLM tests — 500 input tokens, 500 output tokens, 50 prompts, 30-second measurement window for standard models (120-second window for thinking/reasoning models). Concurrency levels: 1, 4, and 8 simultaneous users. This is the same configuration used for the R9700 article, so single-user / long-generation numbers compare directly.

**Power Monitoring:** GPU power draw was sampled every 2 seconds via `nvidia-smi power.draw`, summed across both cards, throughout each benchmark.

**Matched comparison set:** Every model here uses **full FP16 weights** with the same token configuration as our R9700 and B70 re-runs, so the cross-vendor tables compare like-for-like.

---

## What Models Fit?

The headline of this card is capacity-without-compromise. A single 96 GB RTX PRO 6000 holds models that needed *the entire* B70 or R9700 multi-card pool — and the two-card pool opens a tier no other card in this series can reach.

| Model | Type | Params | FP16 VRAM | Fits 1× PRO 6000 (96 GB)? | Fits 2× PRO 6000 (192 GB)? |
|-------|------|--------|-----------|---------------------------|----------------------------|
| **Qwen2.5 3B Instruct** | Dense | 3B | ~6 GB | ✅ Yes | ✅ Yes |
| **Qwen3 8B** | Dense (thinking) | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **Llama 3.1 8B Instruct** | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **DeepSeek R1 Distill 8B** | Dense | 8B | ~16 GB | ✅ Yes | ✅ Yes |
| **Qwen3.6-27B** | Dense | 27B | ~54 GB | ✅ **Yes (single card!)** | ✅ Yes |
| **Qwen3.6-35B-A3B** | MoE | 35B (3B active) | ~70 GB | ✅ **Yes (single card!)** | ✅ Yes |
| **Qwen2.5 72B Instruct** | Dense | 72B | ~144 GB | ❌ No | ✅ **Tested** |
| **Llama 3.3 70B Instruct** | Dense | 70B | ~140 GB | ❌ No | ✅ **Tested** |

For context, recall where the other cards topped out: the R9700 needed *both* of its cards just to reach the 27B tier, and the B70's 35B MoE required *four* cards. On the RTX PRO 6000, both of those models run on **one** card — and the second card unlocks dense **70B-class FP16**, a model class out of reach for every other configuration in this series.

---

## Single-GPU Performance (TP=1)

A single RTX PRO 6000 Max-Q is, by a wide margin, the fastest card we've benchmarked in this series. The 8B models that defined "good local inference" on the other cards are nearly an afterthought here.

### Summary: Single-GPU Results (Concurrency = 1)

| Model | Throughput (tok/s) | TTFT (ms) | ITL (ms) | Avg GPU Power |
|-------|-------------------:|----------:|---------:|--------------:|
| **Qwen2.5 3B Instruct** | **176** | 24 | 6 | 289 W |
| **DeepSeek R1 Distill 8B** | **163** | 39 | 6 | 305 W |
| **Llama 3.1 8B Instruct** | **87** | 53 | 11 | 297 W |
| **Qwen3 8B** (thinking) | **82** | 38 | 12 | 305 W |
| **Qwen3.6-35B-A3B** (MoE) | **36** | 78 | 28 | 168 W |
| **Qwen3.6-27B** (dense) | **24** | 169 | 41 | 304 W |

*All tests: 500 input / 500 output tokens, FP16, single RTX PRO 6000. Qwen3 8B used a 120-second measurement window for its reasoning phase.*

The story the data tells:

- **The 8B class is no longer the workload — it's the warm-up.** DeepSeek R1 8B hits **163 tok/s on a single card** with a 39 ms TTFT and a 6 ms inter-token latency — output streams faster than anyone can read it. For reference, that's **2.7× the R9700** (61.3 tok/s) and **4.5× the B70** (36.1 tok/s) on the exact same model.

- **The 27B and 35B tier runs on one card** — and matches or beats what the four-card B70 and two-card R9700 delivered with their *entire* pools. The MoE's sparse activation (~3B active per token) lets it outrun the smaller-but-dense 27B (36 vs 24 tok/s), the same pattern we saw on the B70.

- **The MoE is also the efficiency standout.** Because only ~3B parameters are active per token, the 35B-A3B draws just **168 W** on a single card — roughly half the ~300 W the dense models pull. That power gap, not just the throughput, is what makes it the cheapest model per token in the lineup (below).

- **Even maxed, the card is efficient.** Under dense load every single-card model pegs near the Max-Q 300 W envelope (289–305 W) — and delivers 2.4–4.5× the throughput of the next-fastest card *at the same model*.

<details>
<summary><strong>Detailed Single-GPU Benchmark Tables</strong> (click to expand)</summary>

*Throughput / TTFT / ITL at concurrency 1 / 4 / 8.*

#### Qwen2.5 3B Instruct (FP16, TP=1)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 176 | 24 ms | 6 ms |
| 4 | 626 | 19 ms | 6 ms |
| 8 | 1214 | 99 ms | 6 ms |

#### DeepSeek R1 Distill 8B (FP16, TP=1)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 163 | 39 ms | 6 ms |
| 4 | 623 | 37 ms | 6 ms |
| 8 | 1200 | 57 ms | 7 ms |

#### Llama 3.1 8B Instruct (FP16, TP=1)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 87 | 53 ms | 11 ms |
| 4 | 320 | 44 ms | 12 ms |
| 8 | 615 | 101 ms | 12 ms |

#### Qwen3 8B — thinking model (FP16, TP=1, 120s window)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 82 | 38 ms | 12 ms |
| 4 | 321 | 38 ms | 12 ms |
| 8 | 614 | 83 ms | 13 ms |

#### Qwen3.6-27B Dense (FP16, TP=1)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 24 | 169 ms | 41 ms |
| 4 | 90 | 540 ms | 43 ms |
| 8 | 175 | 1.2 s | 43 ms |

#### Qwen3.6-35B-A3B MoE (FP16, TP=1)
| Conc | tok/s | TTFT | ITL |
|---|---:|---:|---:|
| 1 | 36 | 78 ms | 28 ms |
| 4 | 137 | 156 ms | 29 ms |
| 8 | 247 | 367 ms | 32 ms |

At concurrency 8, a single card pushes **over 1,200 tok/s** on the 8B models and the 3B — aggregate throughput that would have required multiple cards on the other platforms. Even the 27B dense model reaches 175 tok/s under load on one GPU.

</details>

---

## Dual-GPU Performance (TP=2)

With no NVLink bridge, the question for tensor parallelism is whether host-routed collectives (P2P disabled) cost more than the extra compute buys. The answer depends sharply on model size.

### 8B and smaller: TP=2 vs. single card

| Model | TP=1 (1 card) | TP=2 (2 cards) | Scaling |
|-------|--------------:|---------------:|--------:|
| Qwen2.5 3B | **176** | 160 | **0.91×** (slower) |
| Qwen3 8B (thinking) | 82 | **135** | 1.65× |
| Llama 3.1 8B | 87 | **143** | 1.64× |
| DeepSeek R1 8B | 163 | **276** | 1.69× |

*All at concurrency = 1, tok/s.*

Two clear effects:

- **The 3B model gets *slower* on two cards** (176 → 160 tok/s). Same lesson the B70 taught with its 3B control case: for a model this small, inter-GPU communication overhead exceeds the compute it saves. Small models belong on one card.

- **The 8B models scale ~1.65×.** Despite the missing NVLink — every collective bouncing through host memory — Llama, Qwen3, and DeepSeek all land near 1.65× of their single-card rate. DeepSeek R1 8B crosses **276 tok/s** on two cards at a single user. That the scaling holds up *without* NVLink is itself worth noting: these cards are fast enough that the host-memory collective path isn't the bottleneck at this model size.

### 27B / 35B: the middle tier, doubled

| Model | TP=1 | TP=2 | Scaling |
|-------|-----:|-----:|--------:|
| Qwen3.6-27B (dense) | 24 | 41 | 1.71× |
| Qwen3.6-35B-A3B (MoE) | 36 | 38 | 1.06× |

The 27B dense model nearly doubles to 41 tok/s across two cards. The MoE barely moves (36 → 38) — with only ~3B parameters active per token, it's already lightly loaded on one card, so a second card adds communication overhead without much compute to amortize against. **For the MoE, one card is the right call; for the 27B dense, the second card is a real upgrade.**

### 70B-class dense: the tier only this card can reach

This is the configuration no other card in the series can run. Both models require the full 192 GB pool.

| Model | Config | Conc=1 | Conc=4 | Conc=8 | TTFT (c=1) | ITL (c=1) | Power avg/peak (2-GPU) |
|-------|--------|-------:|-------:|-------:|-----------:|----------:|-----------------------:|
| **Qwen2.5 72B Instruct** | TP=2 | 18.4 | 65.1 | 114 | 290 ms | 53 ms | 573 / 605 W |
| **Llama 3.3 70B Instruct** | TP=2 | 18.8 | 64.8 | 117 | 292 ms | 52 ms | 575 / 602 W |

*FP16, TP=2 across 2× RTX PRO 6000. `max-model-len` capped to fit the KV cache alongside the ~140 GB of weights.*

Both 70B-class models land at **~18.5 tok/s single-user** — about 220 words/minute, comfortably interactive — with a sub-300 ms TTFT, and scale to **~115 tok/s at 8 concurrent users**. The two models tracking each other almost exactly (18.4 vs 18.8 single-user; 114 vs 117 at conc=8; 573 vs 575 W) is the expected result for two 70B-class dense architectures at the same precision, and a good consistency check on the run. Under this load both cards run flat-out, peaking right at ~600 W combined — exactly two Max-Q cards at their 300 W envelope.

> **A practitioner's note on 70B FP16.** Getting these to run took two fixes worth calling out. First, the cold-load of ~140 GB of weights is slow enough that a naive fixed load-timeout aborts mid-download; we replaced it with a **stall-based readiness check** that watches for *forward progress* (network + disk + GPU-memory + log movement) rather than wall-clock. Second, vLLM defaults the context window to the model's full 131K, whose KV cache won't fit *after* 140 GB of weights are resident — a crash-loop. Capping `max-model-len` leaves headroom and the models serve cleanly. Both are documented in [Setup Notes](#setup-notes-for-practitioners).

---

## Scaling Summary

| Model | Architecture | 1× PRO 6000 (TP=1) | 2× PRO 6000 (TP=2) | Notes |
|-------|-------------|-------------------:|-------------------:|-------|
| Qwen2.5 3B | Dense | **176** | 160 (0.91×) | Single GPU preferred |
| Qwen3 8B | Dense (thinking) | 82 | **135** (1.65×) | TP=2 helps |
| Llama 3.1 8B | Dense | 87 | **143** (1.64×) | TP=2 helps |
| DeepSeek R1 8B | Dense | 163 | **276** (1.69×) | Fastest 8B in the series |
| Qwen3.6-27B | Dense | 24 | **41** (1.71×) | Single card already usable |
| Qwen3.6-35B-A3B | MoE | **36** | 38 (1.06×) | Single GPU preferred (sparse) |
| **Qwen2.5 72B** | Dense | ❌ Does not fit | **18.4** | **Dual-GPU only — unique to this card** |
| **Llama 3.3 70B** | Dense | ❌ Does not fit | **18.8** | **Dual-GPU only — unique to this card** |

*Single-user numbers (concurrency = 1), tok/s.*

The pattern across three tiers:

1. **3B and MoE models** want a single card — the TP=2 overhead isn't worth it.
2. **8B and 27B dense models** scale cleanly (1.6–1.7×) to two cards even without NVLink.
3. **70B-class dense FP16** is the headline capability — and it exists *only* on this hardware in our testing.

---

## Cost of Inference: Local vs. Cloud

We instrument every benchmark with GPU power so we can put a real electricity cost-per-token next to cloud pricing. Using **$0.18/kWh** (US average, June 2026) and total system power (measured GPU draw + ~300 W workstation overhead):

### Measured GPU Power Under Load (single-user)

| Model | Config | GPUs Active | Avg GPU Power | Peak GPU Power |
|-------|--------|:-----------:|:-------------:|:--------------:|
| Qwen2.5 3B | TP=1 | 1 | 289 W | 315 W |
| Llama 3.1 8B | TP=1 | 1 | 297 W | 316 W |
| DeepSeek R1 8B | TP=1 | 1 | 305 W | 316 W |
| Qwen3 8B | TP=1 | 1 | 305 W | 319 W |
| Qwen3.6-27B | TP=1 | 1 | 304 W | 314 W |
| Qwen3.6-35B-A3B (MoE) | TP=1 | 1 | **168 W** | 248 W |
| Qwen2.5 72B | TP=2 | 2 | 573 W | 605 W |
| Llama 3.3 70B | TP=2 | 2 | 575 W | 602 W |

### Cost Per Million Output Tokens (single-user)

| Model | Config | tok/s | $/1M tokens | vs. Gemini 3.1 Pro ($12) | vs. Opus 4.8 ($25) | vs. GPT-5.5 ($30) |
|-------|--------|------:|------------:|-------------------------:|-------------------:|------------------:|
| Qwen2.5 3B | TP=1 | 176 | **$0.17** | 71× cheaper | 147× cheaper | 176× cheaper |
| DeepSeek R1 8B | TP=1 | 163 | **$0.19** | 63× cheaper | 132× cheaper | 158× cheaper |
| Llama 3.1 8B | TP=1 | 87 | **$0.35** | 34× cheaper | 71× cheaper | 86× cheaper |
| Qwen3 8B | TP=1 | 82 | **$0.37** | 32× cheaper | 68× cheaper | 81× cheaper |
| Qwen3.6-35B-A3B | TP=1 | 36 | **$0.65** | 18× cheaper | 38× cheaper | 46× cheaper |
| Qwen3.6-27B | TP=1 | 24 | **$1.25** | 9.6× cheaper | 20× cheaper | 24× cheaper |
| Llama 3.3 70B | TP=2 | 18.8 | **$2.33** | 5.2× cheaper | 10.7× cheaper | 12.9× cheaper |
| Qwen2.5 72B | TP=2 | 18.4 | **$2.37** | 5.1× cheaper | 10.5× cheaper | 12.7× cheaper |

*Cloud pricing as of June 2026. Local costs are electricity only.*

The MoE's low power pays off directly: at **$0.65/1M**, the 35B-A3B is cheaper per token than the dense 27B ($1.25) despite running a larger model — it draws 168 W where the 27B draws 304 W. And the headline: a **dense 70B model in full FP16 for $2.33 per million output tokens**, still ~5× cheaper than the cheapest frontier API, on hardware nothing else in this series can even load.

### Multi-User Economics

Because throughput scales far faster than power (the GPU draws nearly the same whether serving one request or eight), cost-per-token collapses under concurrent load:

| Model | Conc=1 | Conc=4 | Conc=8 |
|-------|-------:|-------:|-------:|
| Qwen2.5 3B | $0.17 | $0.05 | $0.02 |
| DeepSeek R1 8B | $0.19 | $0.05 | $0.03 |
| Llama 3.1 8B | $0.35 | $0.09 | $0.05 |
| Qwen3.6-27B | $1.25 | $0.33 | $0.17 |
| Llama 3.3 70B | $2.33 | $0.66 | $0.37 |

At concurrency 8, every 8B model costs **$0.02–0.05 per million output tokens** — and even the dense 70B drops to **$0.37/1M**, roughly what you'd pay a frontier API for *0.015* of a million.

### A Note on the Hardware Side of the Ledger

Electricity is only half the story. At ~$8,500/card, two cards are ~$17,000 in GPUs alone — this is not the value pick, and on pure throughput-per-dollar the [R9700 and B70](#cross-vendor-comparison-pro-6000-vs-r9700-vs-b70) win. What you're buying here is **throughput-per-watt and absolute capability**: 2.4–4.5× the per-card speed of anything else in the series, and a 70B-class FP16 tier that has no local alternative to price against at all.

---

## Image Generation: ComfyUI + Z-Image Turbo

We tested generative image workloads with ComfyUI and Z-Image Turbo — a distilled diffusion model doing fast 4-step generation at 1024×1024, the same workflow used in the B70 and R9700 articles.

### Results

**Prompt:** *"A majestic snow-capped mountain peak at golden hour, reflected perfectly in a crystal-clear alpine lake surrounded by wildflowers, professional landscape photography, 8k resolution"*

| Metric | Value |
|--------|-------|
| **Iterations** | 10/10 passed (0 failures) |
| **Cold Start (iter 1)** | 4.6s (model load + CUDA graph capture) |
| **Steady State (p50)** | **1.3s** |
| **Mean (all 10)** | 1.7s |
| **Throughput** | 35.6 images/min |
| **VRAM Peak** | 19.9 GB (of 95 GB) |

After the first cold-start iteration, the RTX PRO 6000 generates 1024×1024 images in **~1.3 seconds** — production-quality output faster than anyone can review it. The 19.9 GB peak barely dents the 96 GB card, leaving room for far larger diffusion models, batched generation, or multi-model pipelines. Zero failures across 10 consecutive runs.

### Cross-Vendor Image Generation

| | RTX PRO 6000 | R9700 | B70 |
|---|---:|---:|---:|
| **Steady State (per image)** | **1.3 s** | 3.5 s | 3.9 s |
| **Throughput** | **35.6 img/min** | 13.9 img/min | 12.9 img/min |
| **VRAM Peak** | 19.9 GB | 19.8 GB | 19.3 GB |

The RTX PRO 6000 is **~2.7× faster per image** than the R9700 and **~3× faster** than the B70 — the same memory-bandwidth dividend we saw on the LLM side, and consistent with the throughput gap. All three cards run the identical ComfyUI + Z-Image Turbo workflow without issue; the PRO 6000 simply clears each frame far sooner.

### Sample Output

These were generated on the RTX PRO 6000 using Z-Image Turbo with the benchmark prompt above — three consecutive steady-state runs (~1.3 s each), not cherry-picked:

![Sample 1: Generated on RTX PRO 6000 via Z-Image Turbo](article_assets/rtx_pro6000/z_image_samples/z_image_sample_1.png)

![Sample 2: Generated on RTX PRO 6000 via Z-Image Turbo](article_assets/rtx_pro6000/z_image_samples/z_image_sample_2.png)

![Sample 3: Generated on RTX PRO 6000 via Z-Image Turbo](article_assets/rtx_pro6000/z_image_samples/z_image_sample_3.png)

> *We also attempted a larger Flux.2 Dev FP8 workflow on this card. The model loaded but every generation failed in the diffusion step — a workflow/node compatibility issue we're still running down, unrelated to the hardware. It isn't part of the B70 or R9700 comparison, so it's omitted here; we'll revisit it separately.*

---

## Cross-Vendor Comparison: PRO 6000 vs. R9700 vs. B70

This is the payoff of running the same suite, same tooling, same FP16 weights across all three cards. The numbers below are single-user (concurrency = 1) from each article's matched configuration.

### Hardware

| | NVIDIA RTX PRO 6000 Blackwell (Max-Q) | AMD Radeon AI PRO R9700 | Intel Arc Pro B70 |
|---|---|---|---|
| **Architecture** | Blackwell (GB202) | RDNA 4 (gfx1201) | Xe2-HPG (Battlemage) |
| **VRAM / card** | 96 GB GDDR7 | 32 GB GDDR6 | 32 GB GDDR6 (ECC) |
| **Memory Bandwidth** | ~1,792 GB/s `†verify` | 640 GB/s | 608 GB/s |
| **TDP** | 300W (Max-Q) | 300W | 230W |
| **MSRP** | ~$8,500 `†verify` | ~$1,099 | $949 |
| **Cards Tested** | 2 | 2 | 4 |
| **Total VRAM** | **192 GB** (~$17,000) | 64 GB (~$2,200) | 128 GB (~$3,800) |
| **Multi-GPU Method** | Tensor Parallelism | Pipeline Parallelism | Tensor Parallelism |

### Single-Card Throughput (Concurrency = 1, tok/s)

| Model | PRO 6000 | R9700 | B70 | PRO 6000 vs. best other |
|-------|---------:|------:|----:|------------------------:|
| Qwen2.5 3B | **176** | 81.1 | 76.2 | 2.2× |
| DeepSeek R1 8B | **163** | 61.3 | 36.1 | 2.7× |
| Llama 3.1 8B | **87** | 31.9 | 36.1 | 2.4× |
| Qwen3 8B | **82** | 37.4 | 34.7 | 2.2× |

A single RTX PRO 6000 is consistently **~2.2–2.7× faster per card** than the next-best card on the same model — the dividend of nearly 3× the memory bandwidth on decode-bound workloads.

### The 27B Dense Model: One Card vs. Their Whole Pool

| | PRO 6000 (TP=1, **1 card**) | PRO 6000 (TP=2, 2 cards) | R9700 (PP=2, 2 cards) | B70 (TP=4, 4 cards) |
|---|---:|---:|---:|---:|
| **Qwen3.6-27B (tok/s)** | **24** | 41 | 10.9 | 13.1 |
| **GPU cost** | ~$8,500 | ~$17,000 | ~$2,200 | ~$3,800 |

A **single** RTX PRO 6000 runs the 27B dense model ~1.8× faster than **four** B70s and ~2.2× faster than **two** R9700s — using one GPU where they use their entire pool. The flip side is cost: that single card is ~2× the price of all four B70s. This is the series' core tension stated cleanly: the R9700 and B70 win **throughput-per-dollar**; the PRO 6000 wins **throughput-per-card** and **absolute capability**.

### The Tier Only One Card Reaches

| Model | PRO 6000 (2 cards) | R9700 | B70 |
|-------|-------------------:|------:|----:|
| Qwen2.5 72B (dense, FP16) | **18.4 tok/s** | ❌ Won't fit | ❌ Won't fit |
| Llama 3.3 70B (dense, FP16) | **18.8 tok/s** | ❌ Won't fit | ❌ Won't fit |

There is no comparison to draw here — and that's the point. Dense 70B-class FP16 inference at home is a capability unique to the 192 GB configuration.

---

## A Note on Concurrency and TTFT

One cross-card observation worth flagging. On the B70, single-user time-to-first-token for 8B models *dropped* as concurrency rose — an artifact of how the idle-GPU wake-up tail dominates a lightly-loaded slower card. On the RTX PRO 6000 we measured the opposite: TTFT is **flat-to-rising** with concurrency (DeepSeek 8B: 39 → 37 → 57 ms at conc 1/4/8; Llama 8B: 53 → 44 → 101 ms). The card is fast enough that the idle-wake tail is negligible, so TTFT is governed by prefill — which grows with batch size. It's a small reminder that a metric's *direction* under load can be an artifact of the hardware's speed, not the model's behavior.

---

## Setup Notes for Practitioners

A few Blackwell-specific items that cost us time so they don't cost you yours:

### 1. You need a CUDA 13 vLLM build

Blackwell workstation silicon is compute capability **`sm_120` (12.0)**. Stock vLLM images built against CUDA 12 won't generate kernels for it. Use a CUDA 13 build:

```bash
vllm/vllm-openai:cu130-nightly
```

### 2. No NVLink → disable PCIe P2P

These two cards have **no NVLink bridge**. vLLM tensor-parallel init attempts PCIe peer-to-peer, which **deadlocks** at the NCCL collective on this topology. Disable it and let collectives route through host memory:

```bash
NCCL_P2P_DISABLE=1
```

Detect whether a box actually has NVLink before disabling (so you keep P2P on systems that do):

```bash
nvidia-smi topo -m | grep -oE 'NV[0-9]+'   # NVLink pairs report NV<n>; PCIe-only reports NODE/SYS/PHB
```

### 3. Large-model load: watch progress, not the clock

Cold-loading ~140 GB of FP16 weights for a 70B model takes long enough that a fixed load-timeout will abort a download that's still healthy. Bound the load on **stall** (no forward progress in net I/O + disk I/O + GPU memory + log output) rather than a flat wall-clock timeout.

### 4. Cap context so the KV cache fits *after* the weights

vLLM defaults large models to their full context window (often 131K). For a 70B model, the KV cache for 131K tokens won't fit in the VRAM left after 140 GB of weights are resident — vLLM crash-loops with a `max seq len needs N GiB KV cache > available` error. Cap `--max-model-len` to leave headroom:

```bash
--max-model-len 32768   # plenty for 500-in/500-out benchmarking; fits KV cache alongside 70B weights
```

---

## Conclusion: What Do Two RTX PRO 6000 Blackwell GPUs Buy You?

Across three cards, the series now has a clear shape. The **B70** is the cheapest path to a big VRAM pool. The **R9700** is the throughput-per-dollar champion at the 27B tier. The **RTX PRO 6000 Blackwell** is the one you reach for when the answer to "what model do you want to run" is "all of them, in full precision, fast."

What the data shows:

- **The fastest single-card inference in the series** — ~2.2–2.7× the next-best card on every 8B-and-under model. DeepSeek R1 8B at **163 tok/s on one card**, 39 ms TTFT.
- **The middle tier collapses onto a single GPU.** Models that consumed the entire B70 (4 cards) or R9700 (2 cards) pool — 27B dense, 35B MoE — run on one RTX PRO 6000, and faster.
- **A model class no other card can host.** Dense **70B-class FP16** (Llama 3.3 70B, Qwen2.5 72B) at ~18.5 tok/s single-user, ~115 tok/s at 8 users — exclusive to the 192 GB configuration.
- **Clean TP=2 scaling without NVLink** — 1.6–1.7× on 8B/27B dense models even with collectives routed through host memory.
- **Real efficiency on a 300 W card** — the sparse 35B MoE runs at 168 W and $0.65/1M; even maxed dense models stay inside the Max-Q envelope while out-throughputting everything else.
- **Image generation to match** — 1024×1024 via Z-Image Turbo in **~1.3 s steady-state**, ~2.7× faster than the R9700 and ~3× the B70, with zero failures.

The honest caveat is price. At ~$17,000 for two cards, this is not the value pick, and on pure throughput-per-dollar the cheaper cards win. What you're buying is **capability and speed**: a 70B dense model in full FP16 on a workstation, and the 8B/27B models everyone else runs served at 2–4× the throughput. For teams where model quality, precision, and latency matter more than minimizing per-token cost — and who need to keep that workload on-premises — this is the card that says yes to everything.

---

*Tested June 2026 on a Puget Systems workstation with 2× NVIDIA RTX PRO 6000 Blackwell Max-Q GPUs and an AMD Ryzen Threadripper PRO 9995WX, running Ubuntu 24.04.4 LTS. LLM benchmarks used `vllm/vllm-openai:cu130-nightly` (CUDA 13, `sm_120`) with FP16 weights, `NCCL_P2P_DISABLE=1`, and stall-based load readiness. GenAI-Perf streaming, 500-in/500-out, concurrency 1/4/8. GPU power via `nvidia-smi power.draw` summed across both cards. Cross-vendor figures from the companion [Intel Arc Pro B70](https://www.pugetsystems.com/labs/articles/intel-arc-pro-b70-multi-gpu-ai-inference-performance/) and AMD Radeon AI PRO R9700 articles. Cloud API pricing as of June 2026.*
