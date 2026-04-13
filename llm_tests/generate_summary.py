#!/usr/bin/env python3
"""
Puget Systems Benchmark Summary Generator

Parses genai-perf output files and generates a consolidated summary table.
Supports multi-model/multi-pack benchmark runs with per-benchmark subdirectories.
Works with both JSON and CSV genai-perf exports.

Outputs:
  - summary.txt  (terminal-friendly table)
  - summary.md   (Markdown for findings/)
"""

import json
import csv
import os
import sys
from pathlib import Path
from datetime import datetime


def find_result_files(results_dir):
    """Find all genai-perf result files, grouped by (benchmark_name, concurrency).

    Returns dict of:
      { (bench_label, concurrency): Path }
    """
    results = {}
    results_path = Path(results_dir)

    # Strategy 1: Look in per-benchmark subdirectories (new automated mode)
    # e.g., results/host_timestamp/team_llm_Qwen_Qwen3-8B/concurrency_1/
    for subdir in sorted(results_path.iterdir()):
        if subdir.is_dir() and subdir.name != "." and not subdir.name.startswith("."):
            bench_label = subdir.name
            for json_file in sorted(subdir.glob("**/profile_export_genai_perf.json")):
                parent = json_file.parent.name
                if parent.startswith("concurrency_"):
                    try:
                        conc = int(parent.split("_")[1])
                        results[(bench_label, conc)] = json_file
                    except (ValueError, IndexError):
                        continue

    # Strategy 2: Look in top-level concurrency_* dirs (legacy single-model mode)
    for json_file in sorted(results_path.glob("concurrency_*/profile_export_genai_perf.json")):
        parent = json_file.parent.name
        if parent.startswith("concurrency_"):
            try:
                conc = int(parent.split("_")[1])
                results[("default", conc)] = json_file
            except (ValueError, IndexError):
                continue

    # Strategy 3: Inside genai_perf_* subdirectories (remote mode)
    for subdir in sorted(results_path.glob("genai_perf_*")):
        if subdir.is_dir():
            for json_file in sorted(subdir.glob("**/profile_export_genai_perf.json")):
                parent = json_file.parent.name
                if parent.startswith("concurrency_"):
                    try:
                        conc = int(parent.split("_")[1])
                        results[(subdir.name, conc)] = json_file
                    except (ValueError, IndexError):
                        continue

    return results


def parse_json_results(json_path):
    """Parse a genai-perf JSON result file and extract key metrics."""
    with open(json_path) as f:
        data = json.load(f)

    metrics = {}

    request_metrics = data if isinstance(data, dict) else {}

    # Throughput
    for key in ["output_token_throughput_per_request", "output_token_throughput"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["output_token_throughput"] = val.get("avg", val.get("value", 0))
            elif isinstance(val, (int, float)):
                metrics["output_token_throughput"] = val

    for key in ["request_throughput"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["request_throughput"] = val.get("avg", val.get("value", 0))
            elif isinstance(val, (int, float)):
                metrics["request_throughput"] = val

    # Request latency
    for key in ["request_latency"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["avg_latency_ms"] = val.get("avg", 0)
                metrics["p99_latency_ms"] = val.get("p99", 0)
                metrics["min_latency_ms"] = val.get("min", 0)
                metrics["max_latency_ms"] = val.get("max", 0)

    # Time to first token
    for key in ["time_to_first_token"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["ttft_avg_ms"] = val.get("avg", 0)
                metrics["ttft_p99_ms"] = val.get("p99", 0)

    # Inter-token latency
    for key in ["inter_token_latency"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["itl_avg_ms"] = val.get("avg", 0)

    # Output token count
    for key in ["output_sequence_length"]:
        if key in request_metrics:
            val = request_metrics[key]
            if isinstance(val, dict):
                metrics["avg_output_tokens"] = val.get("avg", 0)

    return metrics


def parse_csv_results(csv_path):
    """Fallback: parse a genai-perf CSV result file."""
    metrics = {}
    try:
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                metric_name = row.get("Metric", "").strip()
                if "throughput" in metric_name.lower() and "output" in metric_name.lower():
                    metrics["output_token_throughput"] = float(row.get("avg", 0))
                elif "request throughput" in metric_name.lower():
                    metrics["request_throughput"] = float(row.get("avg", 0))
                elif "request latency" in metric_name.lower():
                    metrics["avg_latency_ms"] = float(row.get("avg", 0))
                    metrics["p99_latency_ms"] = float(row.get("p99", 0))
    except (IOError, ValueError, KeyError, csv.Error) as e:
        print(f"  ⚠ CSV parse warning: {e}", file=sys.stderr)
    return metrics


def format_latency(ms):
    """Format milliseconds into a human-readable string."""
    if ms >= 1000:
        return f"{ms / 1000:.1f}s"
    return f"{ms:.0f}ms"


def format_throughput(val):
    """Format throughput values."""
    if val >= 100:
        return f"{val:.0f}"
    elif val >= 10:
        return f"{val:.1f}"
    else:
        return f"{val:.2f}"


def prettify_bench_label(label):
    """Convert a directory name like 'team_llm_Qwen_Qwen3-8B' to a readable label."""
    if label == "default":
        return "—"
    # Strip common pack prefixes for cleaner display
    for prefix in ["team_llm_", "personal_llm_"]:
        if label.startswith(prefix):
            pack = "vLLM" if "team" in prefix else "Ollama"
            model = label[len(prefix):].replace("_", "/", 1)
            return f"{pack}: {model}"
    return label




def generate_summary(results_dir, system_specs_file=None):
    """Generate and print the benchmark summary."""
    result_files = find_result_files(results_dir)

    if not result_files:
        print("No genai-perf results found.")
        return

    # Parse all results
    all_metrics = {}
    for key, json_path in result_files.items():
        metrics = parse_json_results(json_path)
        if not metrics:
            csv_path = json_path.with_suffix("").with_suffix(".csv")
            if csv_path.exists():
                metrics = parse_csv_results(csv_path)
        if metrics:
            all_metrics[key] = metrics

    if not all_metrics:
        print("Could not parse any result files.")
        return

    # Read system specs if available
    system_info = ""
    if system_specs_file and os.path.exists(system_specs_file):
        with open(system_specs_file) as f:
            system_info = f.read()

    # Determine if this is a multi-benchmark run
    bench_labels = sorted(set(k[0] for k in all_metrics.keys()))
    is_multi = len(bench_labels) > 1 or bench_labels[0] != "default"

    # Determine which columns we have data for
    has_ttft = any("ttft_avg_ms" in m for m in all_metrics.values())
    has_itl = any("itl_avg_ms" in m for m in all_metrics.values())

    # ---- Build terminal output ----
    separator = "=" * 78
    lines = []  # Collect lines for both stdout and file

    lines.append("")
    lines.append(separator)
    lines.append("  BENCHMARK SUMMARY")
    lines.append(separator)

    # System info
    host_name = ""
    platform_type = ""
    gpu_line = ""
    if system_info:
        for line in system_info.split("\n"):
            if "Hostname:" in line:
                host_name = line.split(":", 1)[1].strip()
                lines.append(f"  Host: {host_name}")
            if "Type:" in line:
                platform_type = line.split(":", 1)[1].strip()
                lines.append(f"  Platform: {platform_type}")
        for line in system_info.split("\n"):
            if any(gpu in line.lower() for gpu in ["rtx", "tesla", "a100", "h100", "gb10", "geforce"]):
                gpu_line = line.strip()
                lines.append(f"  GPU: {gpu_line}")
                break

    lines.append(f"  Date: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    lines.append(separator)
    lines.append("")

    # ---- Build table ----
    cols = []
    if is_multi:
        cols.append("Benchmark")
    cols.extend(["Conc", "Throughput", "Req/s", "Avg Latency", "P99 Latency"])
    if has_ttft:
        cols.append("TTFT (avg)")
    if has_itl:
        cols.append("ITL (avg)")

    widths = []
    if is_multi:
        max_label_len = max(len(prettify_bench_label(l)) for l in bench_labels)
        widths.append(max(max_label_len, 12))
    widths.extend([6, 14, 10, 14, 14])
    if has_ttft:
        widths.append(12)
    if has_itl:
        widths.append(12)

    header = " | ".join(f"{col:>{w}}" for col, w in zip(cols, widths))
    divider = "-+-".join("-" * w for w in widths)

    lines.append(f"  {header}")
    lines.append(f"  {divider}")

    # Sort by bench label then concurrency
    sorted_keys = sorted(all_metrics.keys(), key=lambda k: (k[0], k[1]))
    last_label = None

    for key in sorted_keys:
        bench_label, conc = key
        m = all_metrics[key]

        # Add separator between benchmark groups
        if is_multi and last_label is not None and bench_label != last_label:
            lines.append(f"  {divider}")
        last_label = bench_label

        throughput = format_throughput(m.get("output_token_throughput", 0))
        req_s = format_throughput(m.get("request_throughput", 0))
        avg_lat = format_latency(m.get("avg_latency_ms", 0))
        p99_lat = format_latency(m.get("p99_latency_ms", 0))

        row_vals = []
        if is_multi:
            label = prettify_bench_label(bench_label)
            row_vals.append(f"{label:>{widths[0]}}")
        idx = 1 if is_multi else 0
        row_vals.extend([
            f"{conc:>{widths[idx]}}",
            f"{throughput + ' tok/s':>{widths[idx+1]}}",
            f"{req_s:>{widths[idx+2]}}",
            f"{avg_lat:>{widths[idx+3]}}",
            f"{p99_lat:>{widths[idx+4]}}",
        ])
        if has_ttft:
            ttft = format_latency(m.get("ttft_avg_ms", 0))
            row_vals.append(f"{ttft:>{widths[idx+5]}}")
        if has_itl:
            itl = format_latency(m.get("itl_avg_ms", 0))
            row_vals.append(f"{itl:>{widths[-1]}}")

        lines.append(f"  {' | '.join(row_vals)}")

    lines.append("")
    lines.append(separator)

    # Print to stdout
    for line in lines:
        print(line)

    # ---- Save summary.txt ----
    summary_txt = os.path.join(results_dir, "summary.txt")
    with open(summary_txt, "w") as f:
        for line in lines:
            f.write(line + "\n")
    print(f"  Summary saved to: {summary_txt}")

    # ---- Generate summary.md (Markdown) ----
    md_lines = []
    md_lines.append(f"# Benchmark Summary — {host_name or 'Unknown Host'}")
    md_lines.append("")
    md_lines.append(f"**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    if platform_type:
        md_lines.append(f"**Platform:** {platform_type}")
    if gpu_line:
        md_lines.append(f"**GPU:** {gpu_line}")
    md_lines.append("")

    # Markdown table
    md_cols = []
    if is_multi:
        md_cols.append("Benchmark")
    md_cols.extend(["Concurrency", "Throughput (tok/s)", "Req/s", "Avg Latency", "P99 Latency"])
    if has_ttft:
        md_cols.append("TTFT (avg)")
    if has_itl:
        md_cols.append("ITL (avg)")

    md_lines.append("| " + " | ".join(md_cols) + " |")
    md_lines.append("| " + " | ".join("---" for _ in md_cols) + " |")

    last_label = None
    for key in sorted_keys:
        bench_label, conc = key
        m = all_metrics[key]

        throughput = format_throughput(m.get("output_token_throughput", 0))
        req_s = format_throughput(m.get("request_throughput", 0))
        avg_lat = format_latency(m.get("avg_latency_ms", 0))
        p99_lat = format_latency(m.get("p99_latency_ms", 0))

        row = []
        if is_multi:
            label = prettify_bench_label(bench_label)
            row.append(label)
        row.extend([str(conc), throughput, req_s, avg_lat, p99_lat])
        if has_ttft:
            row.append(format_latency(m.get("ttft_avg_ms", 0)))
        if has_itl:
            row.append(format_latency(m.get("itl_avg_ms", 0)))

        md_lines.append("| " + " | ".join(row) + " |")

    md_lines.append("")

    # System specs section
    if system_info:
        md_lines.append("## System Specifications")
        md_lines.append("")
        md_lines.append("```")
        md_lines.append(system_info.strip())
        md_lines.append("```")
        md_lines.append("")

    summary_md = os.path.join(results_dir, "summary.md")
    with open(summary_md, "w") as f:
        f.write("\n".join(md_lines) + "\n")
    print(f"  Markdown saved to: {summary_md}")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir> [system_specs.txt]")
        sys.exit(1)

    results_dir = sys.argv[1]
    specs_file = sys.argv[2] if len(sys.argv) > 2 else None
    generate_summary(results_dir, specs_file)
