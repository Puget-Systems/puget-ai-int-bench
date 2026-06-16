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
        # Try AMD GPU detection
        local amd_info
        amd_info=$($run_cmd "lspci 2>/dev/null | grep -iE 'vga|display|3d' | grep -iE 'amd|radeon|navi'" || echo "")
        if [ -n "$amd_info" ]; then
            echo "  AMD GPUs detected:" >> "$spec_file"
            echo "$amd_info" >> "$spec_file"
            # VRAM from sysfs
            local vram_info
            vram_info=$($run_cmd "for f in /sys/class/drm/card[0-9]*/device/mem_info_vram_total; do [ -f \"\\\$f\" ] && echo \"\\\$f: \$(cat \"\\\$f\")\"; done 2>/dev/null" || echo "")
            if [ -n "$vram_info" ]; then
                echo "" >> "$spec_file"
                echo "  VRAM:" >> "$spec_file"
                echo "$vram_info" >> "$spec_file"
            fi
            # ROCm info (if available)
            local rocm_info
            rocm_info=$($run_cmd "rocm-smi --showhw 2>/dev/null" || echo "")
            if [ -n "$rocm_info" ]; then
                echo "" >> "$spec_file"
                echo "  ROCm SMI:" >> "$spec_file"
                echo "$rocm_info" >> "$spec_file"
            fi
        else
            # Try Intel GPU detection
            local intel_info
            intel_info=$($run_cmd "lspci 2>/dev/null | grep -iE 'vga|display|3d' | grep -i 'intel'" || echo "")
            if [ -n "$intel_info" ]; then
                echo "  Intel GPUs detected:" >> "$spec_file"
                echo "$intel_info" >> "$spec_file"
                local dri_info
                dri_info=$($run_cmd "ls -la /dev/dri/ 2>/dev/null" || echo "")
                if [ -n "$dri_info" ]; then
                    echo "" >> "$spec_file"
                    echo "  DRI Render Nodes:" >> "$spec_file"
                    echo "$dri_info" >> "$spec_file"
                fi
            else
                echo "  No NVIDIA, AMD, or Intel GPUs detected." >> "$spec_file"
            fi
        fi
    fi
    echo "" >> "$spec_file"

    # OS
    echo "OS Information:" >> "$spec_file"
    $run_cmd "cat /etc/os-release 2>/dev/null | head -5" >> "$spec_file" || true
}
