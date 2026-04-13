#!/bin/bash
# Puget Systems AI Benchmark — Shared System Specs Collection
#
# Extracts hardware and OS info from a target machine into a specs file.
# Used by the main orchestrator and can be sourced by any benchmark script.
#
# Usage:
#   source scripts/collect_specs.sh
#   collect_system_specs "target_cmd" "/path/to/system_specs.txt" "hostname"
#
# The first argument is the name of a shell function that executes commands
# on the target machine (e.g., target_cmd for SSH, or eval for local).

collect_system_specs() {
    local run_cmd="$1"
    local spec_file="$2"
    local target_hostname="$3"

    echo "=============================================" > "$spec_file"
    echo "System Specifications — $target_hostname" >> "$spec_file"
    echo "=============================================" >> "$spec_file"
    echo "Date: $(date)" >> "$spec_file"
    echo "" >> "$spec_file"

    echo "Hostname: $target_hostname" >> "$spec_file"
    echo "" >> "$spec_file"

    # Virtualization detection
    local virt_type
    virt_type=$($run_cmd "systemd-detect-virt 2>/dev/null || echo 'unknown'")
    echo "Virtualization:" >> "$spec_file"
    if [ "$virt_type" = "none" ] || [ "$virt_type" = "unknown" ]; then
        echo "  Type: Bare Metal" >> "$spec_file"
    else
        echo "  Type: Virtual Machine ($virt_type)" >> "$spec_file"
    fi
    echo "" >> "$spec_file"

    # CPU
    echo "CPU Information:" >> "$spec_file"
    $run_cmd "lscpu 2>/dev/null | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core|Socket'" >> "$spec_file" || true
    echo "" >> "$spec_file"

    # Memory
    echo "Memory Information:" >> "$spec_file"
    $run_cmd "free -h 2>/dev/null" >> "$spec_file" || true
    echo "" >> "$spec_file"

    # GPU
    echo "GPU Information:" >> "$spec_file"
    local gpu_info
    gpu_info=$($run_cmd "nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv 2>/dev/null" || echo "")
    if [ -n "$gpu_info" ]; then
        echo "$gpu_info" >> "$spec_file"
    else
        echo "  nvidia-smi not found. No NVIDIA GPUs detected." >> "$spec_file"
    fi
    echo "" >> "$spec_file"

    # OS
    echo "OS Information:" >> "$spec_file"
    $run_cmd "cat /etc/os-release 2>/dev/null | head -5" >> "$spec_file" || true
}
