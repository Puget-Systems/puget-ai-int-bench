# R9700 Dual-GPU "TP-Equivalent" Rerun — Runbook

Goal: publication-grade numbers for the fastest dual-GPU path on 2× R9700
(llama.cpp `--split-mode row`, optionally SGLang TP=2), measured with the same
GenAI-Perf methodology as the article (500 in / 500 out, 50 prompts, 30s
interval, streaming). Feeds the "AMD Radeon AI PRO R9700" article (publish
target 2026-07-16).

**Reference numbers (June 26, bare metal, 3-run curl bench):**
- vLLM FP8 + PP=2, Qwen3.6-27B: 11.3 tok/s
- vLLM AWQ int4 + PP=2, 27B: 10.0 tok/s
- llama.cpp Q4_K_M row-split, Qwen2.5-32B: **22.7 tok/s** (both GPUs per token)

**Machines** (from hypervisor lab inventory):
- Rocky host (hypervisor): `ssh -p 30000 dustin@172.19.69.192` — sudo needs password
- VM `ai-dev-amd`: 172.19.54.227 as of 07-02, **DHCP drifts** — find via
  `virsh --connect qemu:///system domifaddr --source agent ai-dev-amd` on the host
- R9700s on host buses `03:00.0/.1` and `63:00.0/.1`, parent bridges `02:00.0` / `62:00.0`
- Intel B70s (buses 2e, 43) stay on vfio-pci throughout — Rocky's xe driver can't drive them anyway.

---

## Phase 0 — VM sanity check (~30 min, no infra changes)

Answers "is the VM P2P path a bottleneck for row-split?" empirically.

```bash
# 1. Find the VM IP (on the Rocky host)
ssh -p 30000 dustin@172.19.69.192 \
  "virsh --connect qemu:///system domifaddr --source agent ai-dev-amd"

# 2. On the VM: stop the running personal pack (it holds the GPUs)
ssh dustin@<VM_IP> 'docker ps --format "{{.Names}}"; cd ~/personal_llm 2>/dev/null && docker compose down'

# 3. Launch row-split 32B Q4 (exact June 26 config — team_llm AMD override)
ssh dustin@<VM_IP> 'docker run -d --name rowbench \
  --device /dev/kfd --device /dev/dri \
  --security-opt seccomp=unconfined --group-add video --group-add render \
  -v ~/llama_cache:/root/.cache/huggingface -e LLAMA_CACHE=/root/.cache/huggingface \
  -p 8000:8000 --entrypoint /app/llama-server ghcr.io/ggml-org/llama.cpp:server-rocm \
  -hf bartowski/Qwen2.5-32B-Instruct-GGUF:Q4_K_M -ngl 99 --split-mode row \
  -c 16384 --host 0.0.0.0 --port 8000 --jinja'
# Wait for load (watch: docker logs -f rowbench — GGUF pull can take a while first time)

# 4. Repeat the June 26 3-run curl bench
ssh dustin@<VM_IP> 'for i in 1 2 3; do
  curl -s http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed 300-word explanation of how transformer attention works.\"}],\"max_tokens\":256,\"temperature\":0}" \
    -w "\n%{time_total}\n" --max-time 180 | tail -2
done'
# tok/s = completion_tokens / time_total (server logs also print per-request timings)
```

**Decision gate:** ≥ ~21.5 tok/s (within 5% of 22.7) → VM P2P path is fine for
*iteration*; still do Phase 1 for publication numbers. Materially lower → the
VM tax is real and quantified; note the number and proceed to Phase 1.

Cleanup either way: `docker rm -f rowbench`.

---

## Phase 1 — bare metal on the Rocky host (maintenance window)

Takes down `ai-dev-amd` (and, if a cold cycle is needed, everything on the host —
neither VM autostarts; both VM IPs will drift on restart).

### 1. Preflight (before touching anything)

```bash
ssh -p 30000 dustin@172.19.69.192
# a. SBR hook installed? (staged June 30, deployment never confirmed)
sudo cat /etc/libvirt/hooks/qemu   # expect SBR on 02:00.0 / 62:00.0 on ai-dev-amd release
# b. RDNA4 firmware present on Rocky? (Navi 48 blobs required for amdgpu probe)
ls /usr/lib/firmware/amdgpu/ | grep -ci navi48 || sudo dnf info linux-firmware
# c. Docker present (used for Squid/Olah) and amdgpu module available
docker --version && modinfo amdgpu | head -2
```

If Navi 48 firmware is missing: `sudo dnf upgrade linux-firmware` first.

### 2. Release GPUs from the VM

```bash
virsh --connect qemu:///system shutdown ai-dev-amd
watch -n2 'virsh --connect qemu:///system list --all'   # wait for "shut off"
# If the hook is NOT installed, fire SBR manually:
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/reset
echo 1 | sudo tee /sys/bus/pci/devices/0000:62:00.0/reset
```

### 3. Rebind vfio-pci → amdgpu (audio functions can stay on vfio)

```bash
for d in 0000:03:00.0 0000:63:00.0; do
  echo $d | sudo tee /sys/bus/pci/devices/$d/driver/unbind
done
sudo modprobe amdgpu
for d in 0000:03:00.0 0000:63:00.0; do
  echo amdgpu | sudo tee /sys/bus/pci/devices/$d/driver_override
  echo $d | sudo tee /sys/bus/pci/drivers/amdgpu/bind
done
# Verify clean probe — the RDNA4 PSP reset bug shows up here:
sudo dmesg | tail -40 | grep -iE 'psp|amdgpu'
ls /dev/kfd /dev/dri/renderD*
```

**PSP failure signature** (`PSP load kdb failed`, `psp reg wait timed out`,
`hw_init of IP block <psp> failed -22`): the only reliable fix is a **cold
power-cycle** of the host (full off, ≥30s, on). FLR/warm reboot does not reset
RDNA4 PSP. After cold boot the GPUs bind to vfio again (kernel cmdline), so
redo step 3 (skip step 2).

### 4. Bare-metal P2P bandwidth (article footnote: native vs 10.6 GB/s in-VM)

```bash
docker run --rm --device /dev/kfd --device /dev/dri --security-opt seccomp=unconfined \
  rocm/rocm-terminal bash -lc \
  'sudo apt-get update -qq && sudo apt-get install -y -qq rocm-bandwidth-test && rocm-bandwidth-test -A'
# (or TransferBench; record GPU0<->GPU1 unidirectional + bidirectional GB/s)
```

### 5. Bench matrix (containers identical to VM/pack configs)

Launch llama.cpp exactly as Phase 0 step 3 (same `docker run`, on the host).
Then drive GenAI-Perf with the repo harness runner (same defaults as the
article: 500/500, 50 prompts, 30s interval, streaming):

```bash
# From the Mac: ship the runner
scp -P 30000 llm_tests/run_genai_perf.sh dustin@172.19.69.192:~/
# On the host (endpoint type "vllm" = OpenAI-compatible; llama.cpp serves that API):
./run_genai_perf.sh --endpoint vllm --url http://localhost:8000 \
  --model bartowski/Qwen2.5-32B-Instruct-GGUF:Q4_K_M \
  --concurrency 1 --results-dir ~/tp_rerun/row_32b
```

| # | Config | Concurrency | Notes |
|---|--------|-------------|-------|
| 1 | row-split, 32B Q4_K_M | **1 only** | headline number; row GPFs under concurrent decode |
| 2 | row-split + `--parallel 1`, 32B Q4 | 4, 8 | serialized queue — honest "concurrent" behavior of row |
| 3 | `--split-mode layer`, 32B Q4 | 1, 4, 8 | crash-safe multi-GPU baseline (~half row speed expected) |
| 4 | row-split, 27B-tier GGUF | 1 | apples-to-apples vs article's 27B — **verify a Qwen3.6-27B GGUF exists first**; else note quant mismatch (Q4 32B vs FP16 27B) explicitly |
| 5 | (optional) SGLang TP=2 | 1, 4, 8 | mattbucci/2x-R9700-RDNA4-GFX1201-sglang-inference config; true-TP data point, AWQ int4 |

Power capture: poll `/sys/class/hwmon/*/power1_average` every 2s during each
run (same method as the article) — on bare metal this reads the real GPU draw.

### 6. Restore the VM

```bash
# Unbind amdgpu, restore vfio, boot the VM
for d in 0000:03:00.0 0000:63:00.0; do
  echo $d | sudo tee /sys/bus/pci/devices/$d/driver/unbind
  echo vfio-pci | sudo tee /sys/bus/pci/devices/$d/driver_override
  echo $d | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
done
virsh --connect qemu:///system start ai-dev-amd
virsh --connect qemu:///system domifaddr --source agent ai-dev-amd   # new DHCP IP
# Restart the personal_llm pack in the VM if it was the standing test
```

If amdgpu→vfio rebind leaves the PSP dirty (VM GPUs fail to probe on boot with
the same PSP signature), cold-cycle the host and start the VM after boot.

---

## Article integration checklist

- [ ] Row-split conc-1 number (32B Q4) with power draw → new "fastest dual-GPU path" section
- [ ] Layer-split / serialized-row concurrency table → honest multi-user story
- [ ] Native P2P GB/s vs 10.6 GB/s in-VM → footnote
- [ ] Revise "Why Pipeline Parallelism?" + "What Doesn't Work": vLLM TP still broken (RCCL/gfx1201), but llama.cpp row-split delivers both-GPUs-per-token today; SGLang cited for true TP (or with our own numbers if run #5 happens)
- [ ] Label quantization honestly everywhere (Q4 GGUF ≠ FP16; do not compare directly to the 10.9 FP16 PP number without saying so)
- [ ] Sync updated draft to ClickUp page 8ckf918-59473
