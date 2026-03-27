#!/usr/bin/env python3
"""
Puget Systems Benchmark Summary Generator

Parses genai-perf output files and generates a consolidated summary table.
Works with both JSON and CSV genai-perf exports.
"""

import json
import csv
import os
import sys
from pathlib import Path


def find_result_files(results_dir):
    """Find all genai-perf result files, grouped by concurrency level."""
    results = {}  # type: dict
    results_path = Path(results_dir)

    # Look for genai-perf JSON files in concurrency_* directories
    for json_file in sorted(results_path.glob("**/profile_export_genai_perf.json")):
        # Extract concurrency level from parent dir name (e.g., "concurrency_4")
        parent = json_file.parent.name
        if parent.startswith("concurrency_"):
            try:
                conc = int(parent.split("_")[1])
                results[conc] = json_file
            except (ValueError, IndexError):
                continue

    # Also check inside genai_perf_* subdirectories (from remote mode)
    for subdir in sorted(results_path.glob("genai_perf_*")):
        if subdir.is_dir():
            for json_file in sorted(subdir.glob("**/profile_export_genai_perf.json")):
                parent = json_file.parent.name
                if parent.startswith("concurrency_"):
                    try:
                        conc = int(parent.split("_")[1])
                        results[conc] = json_file
                    except (ValueError, IndexError):
                        continue

    return results


def parse_json_results(json_path):
    """Parse a genai-perf JSON result file and extract key metrics."""
    with open(json_path) as f:
        data = json.load(f)

    metrics = {}

    # Navigate the JSON structure — genai-perf stores metrics under different keys
    # depending on version, so we try multiple paths
    request_metrics = data if isinstance(data, dict) else {}

    # Try to find throughput metrics
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
    except Exception:
        pass
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


def generate_summary(results_dir, system_specs_file=None):
    """Generate and print the benchmark summary."""
    result_files = find_result_files(results_dir)

    if not result_files:
        print("No genai-perf results found.")
        return

    # Parse all results
    all_metrics = {}  # type: dict
    for conc, json_path in result_files.items():
        metrics = parse_json_results(json_path)
        if not metrics:
            # Try CSV fallback
            csv_path = json_path.with_suffix("").with_suffix(".csv")
            if csv_path.exists():
                metrics = parse_csv_results(csv_path)
        if metrics:
            all_metrics[conc] = metrics

    if not all_metrics:
        print("Could not parse any result files.")
        return

    # Read system specs if available
    system_info = ""
    if system_specs_file and os.path.exists(system_specs_file):
        with open(system_specs_file) as f:
            system_info = f.read()

    # Determine which columns we have data for
    has_ttft = any("ttft_avg_ms" in m for m in all_metrics.values())
    has_itl = any("itl_avg_ms" in m for m in all_metrics.values())

    # Print summary
    separator = "=" * 72
    print()
    print(separator)
    print("  BENCHMARK SUMMARY")
    print(separator)

    # Extract model name from system info or first result
    if system_info:
        for line in system_info.split("\n"):
            if "Hostname:" in line:
                print(f"  Host: {line.split(':', 1)[1].strip()}")
            if "Type:" in line:
                print(f"  Platform: {line.split(':', 1)[1].strip()}")

    # GPU info
    if system_info:
        for line in system_info.split("\n"):
            if any(gpu in line.lower() for gpu in ["rtx", "tesla", "a100", "h100", "gb10", "geforce"]):
                print(f"  GPU: {line.strip()}")
                break

    print(separator)
    print()

    # Build the table
    # Header
    cols = ["Concurrency", "Throughput", "Req/s", "Avg Latency", "P99 Latency"]
    if has_ttft:
        cols.append("TTFT (avg)")
    if has_itl:
        cols.append("ITL (avg)")

    widths = [12, 14, 10, 14, 14]
    if has_ttft:
        widths.append(12)
    if has_itl:
        widths.append(12)

    header = " | ".join(f"{col:>{w}}" for col, w in zip(cols, widths))
    divider = "-+-".join("-" * w for w in widths)

    print(f"  {header}")
    print(f"  {divider}")

    # Rows
    for conc in sorted(all_metrics.keys()):
        m = all_metrics[conc]
        throughput = format_throughput(m.get("output_token_throughput", 0))
        req_s = format_throughput(m.get("request_throughput", 0))
        avg_lat = format_latency(m.get("avg_latency_ms", 0))
        p99_lat = format_latency(m.get("p99_latency_ms", 0))

        row_vals = [
            f"{conc:>{widths[0]}}",
            f"{throughput + ' tok/s':>{widths[1]}}",
            f"{req_s:>{widths[2]}}",
            f"{avg_lat:>{widths[3]}}",
            f"{p99_lat:>{widths[4]}}",
        ]
        if has_ttft:
            ttft = format_latency(m.get("ttft_avg_ms", 0))
            row_vals.append(f"{ttft:>{widths[5]}}")
        if has_itl:
            itl = format_latency(m.get("itl_avg_ms", 0))
            row_vals.append(f"{itl:>{widths[-1]}}")

        print(f"  {' | '.join(row_vals)}")

    print()
    print(separator)

    # Save summary to file
    summary_file = os.path.join(results_dir, "summary.txt")
    with open(summary_file, "w") as f:
        # Redirect output to file too
        f.write(f"Benchmark Summary\n")
        f.write(f"{'=' * 50}\n")
        if system_info:
            f.write(f"\nSystem Specs:\n{system_info}\n")
        f.write(f"\nResults:\n")
        f.write(f"  {header}\n")
        f.write(f"  {divider}\n")
        for conc in sorted(all_metrics.keys()):
            m = all_metrics[conc]
            throughput = format_throughput(m.get("output_token_throughput", 0))
            req_s = format_throughput(m.get("request_throughput", 0))
            avg_lat = format_latency(m.get("avg_latency_ms", 0))
            p99_lat = format_latency(m.get("p99_latency_ms", 0))
            row_vals = [
                f"{conc:>{widths[0]}}",
                f"{throughput + ' tok/s':>{widths[1]}}",
                f"{req_s:>{widths[2]}}",
                f"{avg_lat:>{widths[3]}}",
                f"{p99_lat:>{widths[4]}}",
            ]
            if has_ttft:
                ttft = format_latency(m.get("ttft_avg_ms", 0))
                row_vals.append(f"{ttft:>{widths[5]}}")
            if has_itl:
                itl = format_latency(m.get("itl_avg_ms", 0))
                row_vals.append(f"{itl:>{widths[-1]}}")
            f.write(f"  {' | '.join(row_vals)}\n")

    print(f"  Summary saved to: {summary_file}")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir> [system_specs.txt]")
        sys.exit(1)

    results_dir = sys.argv[1]
    specs_file = sys.argv[2] if len(sys.argv) > 2 else None
    generate_summary(results_dir, specs_file)
