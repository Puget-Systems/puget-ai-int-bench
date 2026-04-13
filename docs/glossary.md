# Benchmark Glossary

A guide to the metrics measured by [NVIDIA GenAI-Perf](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/client/src/c%2B%2B/perf_analyzer/genai-perf/README.html), what they mean, and how to interpret them when evaluating AI inference performance.

---

## Test Parameters

These are the inputs to each benchmark run — they define the workload shape.

### Input Tokens
The number of tokens in each request prompt. Our standard test uses **500 input tokens**, providing a realistic prompt length that exercises the model's attention mechanism without being trivially short.

### Output Tokens
The target number of tokens for the model to generate per request. Our standard is **500 output tokens**, though the model may naturally produce slightly more or fewer (see *Output Sequence Length* below).

### Concurrency
The number of simultaneous requests sent to the inference server at once. This simulates real-world multi-user load:

| Concurrency | What It Simulates |
|---|---|
| **1** | A single user chatting with the model. Measures raw per-request speed. |
| **4** | A small team sharing the server. Tests basic batching efficiency. |
| **8** | A department-level deployment. Tests how well the GPU parallelizes work. |
| **16** | An organization-wide deployment. Tests throughput at scale. |

**Why it matters:** A model that's fast at concurrency 1 but collapses at 16 isn't suitable for team deployments. vLLM is designed for multi-user serving; Ollama is optimized for single-user.

---

## Throughput Metrics

These measure how much work the system accomplishes per unit of time. **Higher is better.**

### Output Token Throughput (tok/s)
**The most important metric.** The total number of tokens generated per second across *all* concurrent requests. This is the headline number for comparing systems.

**How to read it:**
- **10–30 tok/s** — Typical for single-user Ollama on a single consumer GPU
- **50–100 tok/s** — Good single-request performance on enterprise GPUs
- **200–500 tok/s** — Strong multi-user serving performance
- **1,000+ tok/s** — Exceptional throughput, typically multi-GPU vLLM at high concurrency

**Analyst tip:** Compare throughput at the *same concurrency level* between systems. A system doing 80 tok/s at c1 vs 1,200 tok/s at c16 shows excellent scaling — the hardware is being utilized efficiently.

### Request Throughput (req/s)
The number of complete requests (prompt→full response) processed per second. This is throughput divided by average response length.

**How to read it:** Useful for capacity planning. If your team sends ~100 requests/hour, you need at least 0.028 req/s sustained. At 2.19 req/s (our c16 result), you could theoretically handle ~7,884 requests/hour.

---

## Latency Metrics

These measure how long users wait. **Lower is better.**

### Request Latency (ms)
The total wall-clock time from sending a request to receiving the complete response (all tokens generated). This is what the end user experiences as "how long the answer took."

**How to read it:**
- **< 3s** — Feels instant to users
- **3–10s** — Acceptable for chat applications
- **10–30s** — Noticeable wait; acceptable for complex/long outputs
- **> 30s** — Users will perceive the system as slow

**Reported percentiles:**
| Stat | Meaning |
|---|---|
| **avg** | Average across all requests. Good for general comparison. |
| **min** | Best-case latency (often first request when caches are warm). |
| **max** | Worst-case latency. Outliers can indicate GPU memory pressure. |
| **p99** | 99th percentile — 99% of requests were faster than this. The "worst realistic case." |
| **p90** | 90th percentile — 90% of requests were faster than this. |
| **p75** | 75th percentile — a typical "slightly slower than average" experience. |

**Analyst tip:** The gap between **avg** and **p99** tells you about consistency. A small gap (e.g., 7.0s avg, 7.4s p99) means the system is extremely predictable. A large gap (e.g., 3.3s avg, 20.2s p99) means occasional outlier requests take much longer — common in single-GPU Ollama when the model swaps context.

### Time to First Token (TTFT)
How long after sending a request until the first token of the response begins streaming. This is the user's perception of "how fast the system starts responding."

**How to read it:**
- **< 1s** — Model starts typing almost immediately
- **1–3s** — Brief pause before response begins
- **3–10s** — Noticeable wait; common for large models doing extensive prefill
- **> 10s** — Indicates the model may be loading, swapping, or under heavy load

**Analyst tip:** TTFT is dominated by the *prefill phase* — the model processing all 500 input tokens before generating the first output. Larger models and longer prompts increase TTFT. If TTFT ≈ Request Latency, it means most of the time is spent in prefill (suggests the prompt is large relative to the output, or concurrency 1 isn't batching).

---

## Sequence Length Metrics

These describe the actual token counts processed.

### Output Sequence Length
The actual number of tokens generated per response. Even though we request 500 output tokens, the model may produce slightly more or fewer depending on its natural stopping behavior.

**Analyst tip:** If this is significantly lower than the target (e.g., 91 tokens when 500 were requested), the model may be hitting an early stop token or the inference engine may be truncating. This affects throughput comparisons — a system generating 91 tokens at 10 tok/s is doing less total work than one generating 565 tokens at 80 tok/s.

### Input Sequence Length
The actual number of prompt tokens sent. Should match the configured 500 for all tests in our suite.

---

## Understanding vLLM vs Ollama Results

### Why vLLM throughput is much higher
vLLM uses **continuous batching** — it dynamically groups incoming requests and processes them in parallel across all available GPUs. At concurrency 16, all 4 GPUs are fully saturated. This is why throughput scales nearly linearly with concurrency.

### Why Ollama throughput is lower
Ollama is designed for **single-user, desktop use**. It processes one request at a time and is optimized for fast single-response generation, not server throughput. Its lower output token throughput reflects this architectural choice, not a hardware limitation.

### Why Ollama latency can be lower
Ollama's simpler pipeline (no batching overhead, no continuous scheduling) means a single request can complete faster in absolute wall-clock time, even though it generates fewer tokens per second. For a single person using a local AI assistant, Ollama provides a snappier experience.

---

## Quick Reference Card

| Metric | Good For | Watch Out For |
|---|---|---|
| **Output Throughput** | Comparing systems head-to-head | Must compare at same concurrency |
| **Request Latency (avg)** | General user experience | Can hide outliers |
| **Request Latency (p99)** | Tail latency / worst case | Most honest UX metric |
| **TTFT** | Streaming responsiveness | Dominated by prefill cost |
| **Concurrency scaling** | ROI on multi-GPU | Linear = great; sublinear = bottleneck |
| **Output Sequence Length** | Validating test fairness | Low counts inflate apparent latency |
