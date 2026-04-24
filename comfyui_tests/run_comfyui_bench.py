#!/usr/bin/env python3
"""
Puget Systems — ComfyUI Benchmark Runner

Submits a workflow to a running ComfyUI instance via the REST + WebSocket API,
measures per-iteration execution time, and outputs a CSV + JSON summary.

Usage:
    python3 run_comfyui_bench.py \\
        --url http://REMOTE_IP:8188 \\
        --workflow workflows/z_image_turbo_txt2img_api.json \\
        --iterations 10 \\
        --results-dir /path/to/results

Dependencies:
    pip install websockets requests
"""

import argparse
import asyncio
import csv
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    print("✗ Missing dependency: requests. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

try:
    import websockets
except ImportError:
    print("✗ Missing dependency: websockets. Install with: pip install websockets", file=sys.stderr)
    sys.exit(1)


# ─── Helpers ────────────────────────────────────────────────────────────────

def find_seed_node(workflow: dict) -> str | None:
    """
    Find the node ID that contains a seed/noise_seed field.
    Used for per-iteration seed randomization.
    """
    for node_id, node in workflow.items():
        if node_id.startswith("_"):
            continue
        inputs = node.get("inputs", {})
        if "seed" in inputs or "noise_seed" in inputs:
            return node_id
    return None


def find_output_node(workflow: dict) -> str | None:
    """
    Find the SaveImage (or equivalent output) node ID.
    Used to detect when execution is complete.
    """
    for node_id, node in workflow.items():
        if node_id.startswith("_"):
            continue
        if node.get("class_type") in ("SaveImage", "PreviewImage", "VHS_VideoCombine"):
            return node_id
    return None


def inject_seed(workflow: dict, seed_node_id: str, seed: int) -> dict:
    """Inject a new seed into the workflow for this iteration."""
    inputs = workflow[seed_node_id]["inputs"]
    if "seed" in inputs:
        inputs["seed"] = seed
    elif "noise_seed" in inputs:
        inputs["noise_seed"] = seed
    return workflow


def get_vram_info(base_url: str) -> dict:
    """Query ComfyUI system stats for VRAM usage."""
    try:
        r = requests.get(f"{base_url}/api/system_stats", timeout=5)
        r.raise_for_status()
        data = r.json()
        devices = data.get("devices", [])
        if devices:
            d = devices[0]
            return {
                "vram_total_gb": round(d.get("vram_total", 0) / (1024**3), 2),
                "vram_free_gb": round(d.get("vram_free", 0) / (1024**3), 2),
                "vram_used_gb": round(
                    (d.get("vram_total", 0) - d.get("vram_free", 0)) / (1024**3), 2
                ),
            }
    except Exception:
        pass
    return {"vram_total_gb": None, "vram_free_gb": None, "vram_used_gb": None}


def wait_for_api(base_url: str, timeout: int = 300) -> bool:
    """Poll /api/system_stats until ComfyUI responds or timeout."""
    deadline = time.time() + timeout
    attempt = 0
    while time.time() < deadline:
        try:
            r = requests.get(f"{base_url}/api/system_stats", timeout=5)
            if r.status_code == 200:
                return True
        except requests.exceptions.ConnectionError:
            pass
        attempt += 1
        if attempt % 6 == 0:
            elapsed = int(time.time() - (deadline - timeout))
            print(f"  Waiting for ComfyUI API... ({elapsed}s elapsed)", flush=True)
        time.sleep(5)
    return False


# ─── Core Benchmark Loop ─────────────────────────────────────────────────────

async def run_single_iteration(
    base_url: str,
    ws_url: str,
    workflow: dict,
    seed_node_id: str,
    output_node_id: str,
    iteration: int,
    client_id: str,
) -> dict:
    """
    Submit one workflow run and wait for completion via WebSocket.
    Returns timing and status for this iteration.
    """
    seed = random.randint(0, 2**32 - 1)
    workflow_copy = json.loads(json.dumps(workflow))  # deep copy
    inject_seed(workflow_copy, seed_node_id, seed)

    # Remove internal _puget_meta key before submitting
    workflow_copy.pop("_puget_meta", None)

    payload = {"prompt": workflow_copy, "client_id": client_id}

    # Queue the prompt
    queue_start = time.monotonic()
    try:
        r = requests.post(f"{base_url}/prompt", json=payload, timeout=15)
        r.raise_for_status()
        prompt_id = r.json()["prompt_id"]
    except Exception as e:
        return {
            "iteration": iteration,
            "seed": seed,
            "status": "QUEUE_ERROR",
            "error": str(e),
            "queue_time_ms": None,
            "execution_time_ms": None,
            "total_time_ms": None,
            "vram_used_gb": None,
        }

    queue_time_ms = int((time.monotonic() - queue_start) * 1000)

    # Wait for completion via WebSocket
    exec_start = time.monotonic()
    status = "UNKNOWN"
    error_msg = None

    try:
        async with websockets.connect(
            f"{ws_url}?clientId={client_id}",
            ping_interval=20,
            ping_timeout=60,
            open_timeout=10,
        ) as ws:
            # Listen for events until our prompt finishes or errors
            deadline = time.time() + 600  # 10-minute per-image timeout
            while time.time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=30)
                    msg = json.loads(raw)
                except asyncio.TimeoutError:
                    # Heartbeat — keep waiting
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "executed":
                    data = msg.get("data", {})
                    if data.get("prompt_id") == prompt_id:
                        status = "OK"
                        break

                elif msg_type == "execution_error":
                    data = msg.get("data", {})
                    if data.get("prompt_id") == prompt_id:
                        status = "EXEC_ERROR"
                        error_msg = data.get("exception_message", "Unknown error")
                        break

                elif msg_type == "status":
                    # status.exec_info.queue_remaining == 0 after our job
                    queue_remaining = (
                        msg.get("data", {})
                        .get("status", {})
                        .get("exec_info", {})
                        .get("queue_remaining", -1)
                    )
                    if queue_remaining == 0 and status == "UNKNOWN":
                        # Job likely finished — confirm via /history
                        try:
                            hist = requests.get(
                                f"{base_url}/history/{prompt_id}", timeout=5
                            )
                            if hist.status_code == 200 and prompt_id in hist.json():
                                status = "OK"
                                break
                        except Exception:
                            pass

            else:
                status = "TIMEOUT"

    except Exception as e:
        status = "WS_ERROR"
        error_msg = str(e)

    execution_time_ms = int((time.monotonic() - exec_start) * 1000)
    total_time_ms = queue_time_ms + execution_time_ms

    # Grab VRAM snapshot after execution
    vram = get_vram_info(base_url)

    return {
        "iteration": iteration,
        "seed": seed,
        "status": status,
        "error": error_msg,
        "queue_time_ms": queue_time_ms,
        "execution_time_ms": execution_time_ms,
        "total_time_ms": total_time_ms,
        "vram_used_gb": vram["vram_used_gb"],
    }


async def run_benchmark(
    base_url: str,
    workflow_path: str,
    iterations: int,
    results_dir: str,
) -> int:
    """Main benchmark loop. Returns exit code (0 = success)."""

    # ── Setup ──────────────────────────────────────────────────────────────
    ws_scheme = "wss" if base_url.startswith("https") else "ws"
    ws_url = f"{ws_scheme}://{base_url.split('://', 1)[1]}/ws"

    print(f"  ComfyUI URL: {base_url}")
    print(f"  Workflow:    {workflow_path}")
    print(f"  Iterations:  {iterations}")
    print(f"  Results dir: {results_dir}")
    print()

    # Load workflow
    with open(workflow_path) as f:
        workflow = json.load(f)

    meta = workflow.get("_puget_meta", {})
    if meta.get("placeholder"):
        print(
            "  ⚠  WARNING: This is a placeholder workflow JSON.\n"
            "     Validate it by exporting 'Save (API Format)' from a live ComfyUI instance.\n"
            "     See the _puget_meta.note field for instructions.\n",
            file=sys.stderr,
        )

    # Detect seed + output nodes (use meta override if present, else auto-detect)
    seed_node_id = meta.get("seed_node") or find_seed_node(workflow)
    output_node_id = meta.get("output_node") or find_output_node(workflow)

    if not seed_node_id:
        print("✗ Could not find a seed node in the workflow JSON.", file=sys.stderr)
        return 1
    if not output_node_id:
        print("✗ Could not find an output (SaveImage) node in the workflow JSON.", file=sys.stderr)
        return 1

    print(f"  Seed node:   {seed_node_id} ({workflow[seed_node_id]['class_type']})")
    print(f"  Output node: {output_node_id} ({workflow[output_node_id]['class_type']})")
    print()

    # ── Health Check ───────────────────────────────────────────────────────
    print("  Waiting for ComfyUI API to be ready...", end=" ", flush=True)
    if not wait_for_api(base_url):
        print(f"\n✗ ComfyUI API did not respond at {base_url} within 300s.", file=sys.stderr)
        return 1
    print("✓")

    vram_before = get_vram_info(base_url)
    print(f"  VRAM (pre-bench): {vram_before['vram_used_gb']} GB used / {vram_before['vram_total_gb']} GB total")
    print()

    # ── Run Iterations ────────────────────────────────────────────────────
    client_id = str(uuid.uuid4())
    results = []

    for i in range(1, iterations + 1):
        print(f"  [{i:02d}/{iterations:02d}] Running... ", end="", flush=True)
        result = await run_single_iteration(
            base_url=base_url,
            ws_url=ws_url,
            workflow=workflow,
            seed_node_id=seed_node_id,
            output_node_id=output_node_id,
            iteration=i,
            client_id=client_id,
        )
        results.append(result)

        status_icon = "✓" if result["status"] == "OK" else "✗"
        exec_s = (
            f"{result['execution_time_ms'] / 1000:.1f}s"
            if result["execution_time_ms"] is not None
            else "N/A"
        )
        print(f"{status_icon} {exec_s}  (seed={result['seed']})", flush=True)

    print()

    # ── Output ────────────────────────────────────────────────────────────
    os.makedirs(results_dir, exist_ok=True)
    workflow_name = Path(workflow_path).stem

    # CSV
    csv_path = os.path.join(results_dir, f"{workflow_name}_iterations.csv")
    fieldnames = [
        "iteration", "seed", "status", "error",
        "queue_time_ms", "execution_time_ms", "total_time_ms", "vram_used_gb",
    ]
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)
    print(f"  CSV:  {csv_path}")

    # Summary stats (successful runs only)
    ok_runs = [r for r in results if r["status"] == "OK" and r["execution_time_ms"] is not None]
    failed = len(results) - len(ok_runs)

    summary: dict = {
        "workflow": workflow_name,
        "url": base_url,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "iterations_total": iterations,
        "iterations_ok": len(ok_runs),
        "iterations_failed": failed,
        "vram_total_gb": vram_before.get("vram_total_gb"),
        "stats": {},
    }

    if ok_runs:
        times = sorted(r["execution_time_ms"] for r in ok_runs)
        n = len(times)
        summary["stats"] = {
            "execution_time_ms": {
                "min": times[0],
                "max": times[-1],
                "mean": int(sum(times) / n),
                "p50": times[n // 2],
                "p95": times[int(n * 0.95)],
            },
            "images_per_minute": round(60_000 / (sum(times) / n), 2),
        }
        vram_snapshots = [r["vram_used_gb"] for r in ok_runs if r["vram_used_gb"] is not None]
        if vram_snapshots:
            summary["stats"]["vram_peak_gb"] = max(vram_snapshots)

    json_path = os.path.join(results_dir, f"{workflow_name}_summary.json")
    with open(json_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  JSON: {json_path}")

    # Human-readable summary
    print()
    print("  ┌──────────────────────────────────────────────────┐")
    print(f"  │  Workflow:   {workflow_name:<37}│")
    print(f"  │  Completed:  {len(ok_runs)}/{iterations} iterations, {failed} failed{' ' * (22 - len(str(failed)))}│")
    if ok_runs:
        s = summary["stats"]["execution_time_ms"]
        print(f"  │  Time (mean): {s['mean'] / 1000:>6.1f}s   p95: {s['p95'] / 1000:>6.1f}s              │")
        print(f"  │  Time (min):  {s['min'] / 1000:>6.1f}s   max: {s['max'] / 1000:>6.1f}s              │")
        print(f"  │  Throughput:  {summary['stats']['images_per_minute']:>5.2f} images/min                    │")
        if "vram_peak_gb" in summary["stats"]:
            print(f"  │  VRAM peak:   {summary['stats']['vram_peak_gb']:>5.1f} GB                             │")
    print("  └──────────────────────────────────────────────────┘")

    return 0 if failed < iterations else 1


# ─── Entry Point ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Puget Systems — ComfyUI Headless Benchmark Runner"
    )
    parser.add_argument("--url", required=True, help="ComfyUI base URL (e.g. http://10.0.0.5:8188)")
    parser.add_argument("--workflow", required=True, help="Path to API-format workflow JSON")
    parser.add_argument("--iterations", type=int, default=10, help="Number of images to generate (default: 10)")
    parser.add_argument("--results-dir", required=True, help="Directory to write CSV and JSON results")
    args = parser.parse_args()

    exit_code = asyncio.run(
        run_benchmark(
            base_url=args.url.rstrip("/"),
            workflow_path=args.workflow,
            iterations=args.iterations,
            results_dir=args.results_dir,
        )
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
