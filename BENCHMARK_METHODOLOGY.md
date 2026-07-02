# Puget LLM Benchmark Methodology (Standard)

This is the **single, vendor-neutral methodology** every GPU article benchmark must
follow so results are directly comparable across Intel (Arc Pro B70), AMD (Radeon AI
PRO R9700), and NVIDIA (RTX PRO 6000 Blackwell / 5090). It is derived from the R9700
and Blackwell runs and is now the standard for all future runs.

> **Why this exists:** earlier B70 numbers used an ad-hoc harness with mixed test
> types (Short / Medium / Long / Concurrent) and faked TTFT (TTFT was just the
> latency restated in ms). That made cross-vendor comparison impossible. This
> document fixes the methodology in one place.

## Tooling

- **NVIDIA GenAI-Perf** (Triton SDK container) for every LLM test.
- **`--streaming` is mandatory** — it is the only way to get real TTFT and ITL.
  Never report a TTFT that equals the request latency; that is the fake-data smell.
- genai-perf runs **on the inference host** (native networking), not over Docker
  Desktop, to avoid HTTP 400s at high concurrency.

## Standard run parameters (all models)

| Parameter | Value |
|---|---|
| Synthetic input tokens | **500** (`--synthetic-input-tokens-mean 500`) |
| Output tokens | **500** (`--output-tokens-mean 500`) |
| Prompts | **50** (`--num-prompts 50`) |
| Concurrency sweep | **1, 4, 8** (Blackwell may extend to 16, 32) |
| Measurement interval | **30 s** (`--measurement-interval 30000`) |
| Precision | **FP16** (`--dtype float16`; XPU cannot serve bfloat16) |
| vLLM mode | `--enforce-eager` |
| Max model len | 32768 (16384 for very large models that need the VRAM) |

## Reasoning / "thinking" models (exceptions, applied consistently)

Thinking models (e.g. Qwen3-8B, Qwen3.6 hybrids) emit a long internal reasoning
phase before visible output. In a 30 s window at concurrency=1 this can report
**0.0 tok/s** (no request completes in the window). Apply:

- **Measurement interval → 120 s** (`--measurement-interval 120000`)
- **Prompts → 20** (`--num-prompts 20`)
- For very large reasoning dense models that still blow the window (27B+), also
  **reduce output tokens → 200** so a request completes inside 120 s.

Always footnote in the article when a model used the extended window so the
config is reproducible.

## Metrics reported (every table)

Report these columns, in this order, at each concurrency (1/4/8):

`Throughput (tok/s) | TTFT avg (ms) | ITL avg (ms) | Avg Latency | P99 Latency`

- **Throughput** = genai-perf `output_token_throughput`. Note: reasoning models
  emit more tokens per request, so cross-model throughput is partly a function of
  verbosity, not just decode speed. **ITL is the length-independent decode metric** —
  use it when comparing per-token speed across models.
- **TTFT / ITL** come straight from streaming. Never synthesize them.

### Known cross-vendor result (sanity check)

`DeepSeek-R1-Distill-Llama-8B` consistently shows **~half the ITL** of
`Llama-3.1-8B` on both AMD (16 vs 31 ms) and Intel (7 vs 14 ms), making it the
fastest 8B model in our suite despite sharing the Llama-8B architecture. If a new
run shows them identical, suspect a non-streaming/faked measurement.

## Power monitoring

- Sample **every 2 s** for the duration of each model's run; bracket the genai-perf
  client so idle time before/after is excluded.
- Vendor sensor source:
  - **AMD:** `sysfs hwmon` `power1_average` (microwatts).
  - **NVIDIA:** `nvidia-smi` power draw.
  - **Intel (xe / i915):** B70 exposes **`energy1_input` (µJ), not `power1_average`** —
    use the energy-delta method: `watts = (ΔµJ × 1000) / Δns`.
- Report **avg** and **peak**. **Ignore the `min` column** (first sample is a
  0-energy-delta artifact).
- **State the GPU count the power covers.** On a 4-card box, a single-GPU (TP=1)
  test still draws idle power from the other 3 cards; report the **board total and
  say so** ("sum across all 4 installed cards, 3 idle during single-GPU tests")
  rather than implying a single-card figure.

## Cost-per-token section (standard add-on)

Every article includes a Local-vs-Cloud cost section:

- Electricity at **$0.12/kWh** (US average).
- System wall power = GPU average **+ ~300 W** workstation overhead (CPU/RAM/PSU).
- `$/1M tokens = (system_W / 1000) × ($0.12/kWh) / (tok/s × 3600 / 1e6)`.
- Compare against current frontier API output pricing (keep dates current):
  Claude Haiku 4.5 ($5/1M), Gemini 2.5 Pro ($10/1M), Claude Opus 4.8 ($25/1M).
- Show the multi-user table (cost drops at concurrency 4/8) and a 3-year TCO line.

## Model set (article baseline)

Single-GPU: Qwen2.5-3B, Qwen3-8B (thinking), Llama-3.1-8B, DeepSeek-R1-Distill-8B,
Gemma-2-9B (FP16). Multi-GPU: add Qwen3.6-27B (dense) and, where VRAM allows,
Qwen3.6-35B-A3B (MoE). Use ungated HF mirrors when no token is on the host
(`unsloth/meta-llama-3.1-8b-instruct`, `unsloth/gemma-2-9b-it`).
