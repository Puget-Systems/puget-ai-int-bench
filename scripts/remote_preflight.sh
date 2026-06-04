#!/bin/bash
# Puget Systems AI Benchmark — Remote Server Preflight
#
# Installs Docker CE, NVIDIA drivers, and NVIDIA Container Toolkit
# on a remote Ubuntu server. Designed for non-interactive SSH execution.
#
# The sudo password must be set as SUDO_PASS environment variable before
# this script runs. The orchestrator sets this up when invoking remotely.
#
# Exit codes:
#   0   = All dependencies satisfied, ready to benchmark
#   100 = NVIDIA drivers were freshly installed, REBOOT REQUIRED
#   1   = Fatal error

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# SUDO_PASS must be set by the caller
if [ -z "${SUDO_PASS:-}" ]; then
    echo -e "${RED}✗ SUDO_PASS not set. Cannot run preflight.${NC}"
    exit 1
fi

# Verify the password works
if ! echo "$SUDO_PASS" | command sudo -S true 2>/dev/null; then
    echo -e "${RED}✗ sudo password is incorrect.${NC}"
    exit 1
fi

# Set up SUDO_ASKPASS so sudo can get the password without consuming stdin.
# The stdin-pipe approach (echo PASS | sudo -S cmd) breaks commands like
# "curl ... | sudo gpg --dearmor" where sudo's child needs its own stdin.
_ASKPASS=$(mktemp)
chmod 700 "$_ASKPASS"
cat > "$_ASKPASS" <<'ASKEOF'
#!/bin/bash
echo "$SUDO_PASS"
ASKEOF
# Re-export so the askpass script inherits it
export SUDO_PASS
export SUDO_ASKPASS="$_ASKPASS"

# Wrap sudo to always use -A (askpass) instead of -S (stdin)
sudo() {
    command sudo -A "$@"
}

NEEDS_REBOOT=false

echo -e "${BLUE}[Preflight] Checking remote server dependencies...${NC}"

# ============================================
# 0. Distribution Check
# ============================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        echo -e "${RED}✗ Unsupported distribution: ${ID:-unknown}. Ubuntu required.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Ubuntu detected: $PRETTY_NAME${NC}"
else
    echo -e "${RED}✗ Cannot detect distribution.${NC}"
    exit 1
fi

# ============================================
# 1. Docker CE
# ============================================
if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | head -1)
    echo -e "${GREEN}✓ Docker found: $DOCKER_VERSION${NC}"
else
    echo -e "${YELLOW}Installing Docker CE...${NC}"

    # Remove old/conflicting packages
    sudo apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

    # Install prerequisites
    sudo apt update -y
    sudo apt install -y ca-certificates curl gnupg

    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine + Compose
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group
    sudo usermod -aG docker "$USER"

    echo -e "${GREEN}✓ Docker CE installed.${NC}"
    echo -e "${YELLOW}  Note: Docker group will take effect after re-login or sg docker.${NC}"
fi

# ============================================
# 2. Docker Compose Plugin
# ============================================
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ Docker Compose found: $COMPOSE_VERSION${NC}"
elif sg docker -c "docker compose version" &>/dev/null 2>&1; then
    COMPOSE_VERSION=$(sg docker -c "docker compose version --short" 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ Docker Compose found (via sg): $COMPOSE_VERSION${NC}"
else
    echo -e "${YELLOW}Installing Docker Compose plugin...${NC}"
    sudo apt install -y docker-compose-plugin
    echo -e "${GREEN}✓ Docker Compose plugin installed.${NC}"
fi

# ============================================
# 3. GPU Detection & Driver Management
# ============================================

# --- AMD GPU Detection ---
# Check for AMD GPUs via /dev/kfd and PCI vendor 0x1002
AMD_GPU_FOUND=false
if [ -e /dev/kfd ]; then
    for card_dir in /sys/class/drm/card[0-9]*/; do
        vendor_file="$card_dir/device/vendor"
        if [ -f "$vendor_file" ] && [ "$(cat "$vendor_file")" = "0x1002" ]; then
            AMD_GPU_FOUND=true
            break
        fi
    done
fi

if $AMD_GPU_FOUND; then
    echo -e "${GREEN}✓ AMD GPU detected via /dev/kfd${NC}"
    # Show AMD GPU info
    if command -v lspci &>/dev/null; then
        AMD_GPU_NAME=$(lspci 2>/dev/null | grep -iE 'vga|display|3d' | grep -i 'amd\|radeon\|navi' | head -1)
        echo -e "${GREEN}  $AMD_GPU_NAME${NC}"
    fi
    # VRAM from sysfs
    for f in /sys/class/drm/card[0-9]*/device/mem_info_vram_total; do
        if [ -f "$f" ]; then
            VRAM_BYTES=$(cat "$f")
            VRAM_GB=$((VRAM_BYTES / 1024 / 1024 / 1024))
            echo -e "${GREEN}  VRAM: ${VRAM_GB} GB${NC}"
            break
        fi
    done
    echo -e "${GREEN}  AMD GPUs use containerized ROCm — no host driver installation needed.${NC}"
elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    GPU_NAME=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -1)
    echo -e "${GREEN}✓ NVIDIA Driver found: $DRIVER_VERSION ($GPU_NAME)${NC}"
else
    echo -e "${YELLOW}Installing NVIDIA drivers...${NC}"

    # Ensure detection tools are available
    if ! command -v ubuntu-drivers &>/dev/null; then
        sudo apt update -y && sudo apt install -y ubuntu-drivers-common
    fi

    # Show detected hardware
    echo -e "${BLUE}  Detecting GPU hardware...${NC}"
    ubuntu-drivers devices 2>/dev/null || true
    echo ""

    # Install recommended drivers
    echo -e "${BLUE}  Installing recommended NVIDIA drivers...${NC}"
    DRIVER_OUTPUT=$(sudo ubuntu-drivers install 2>&1) || true
    echo "$DRIVER_OUTPUT"

    # Check if drivers were freshly installed vs already present
    if echo "$DRIVER_OUTPUT" | grep -qE "(0 newly installed|already the newest version|No drivers found)"; then
        echo ""
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}⚠ NVIDIA drivers installed but GPU not responding.${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "  Common causes:"
        echo "  1. Secure Boot blocking unsigned kernel module"
        echo "     Check:  mokutil --sb-state"
        echo "     Fix:    sudo mokutil --disable-validation (then reboot)"
        echo ""
        echo "  2. Kernel module not loaded after kernel update"
        echo "     Fix:    sudo modprobe nvidia"
        echo ""
        echo "  3. Kernel/driver version mismatch"
        echo "     Fix:    sudo dkms autoinstall && reboot"
        echo ""
        echo "  4. Blackwell/RTX 50 series requires '-open' kernel module variant"
        echo "     Check:  ubuntu-drivers devices"
        echo ""
        # Try modprobe before giving up — may just need to load the module
        if sudo modprobe nvidia 2>/dev/null && nvidia-smi &>/dev/null; then
            echo -e "${GREEN}✓ nvidia module loaded successfully via modprobe.${NC}"
        else
            exit 1
        fi
    else
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚠ NVIDIA drivers installed. REBOOT REQUIRED.${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        NEEDS_REBOOT=true
    fi
fi

# ============================================
# 4. Container Toolkit & GPU Runtime
# ============================================
if $AMD_GPU_FOUND; then
    # AMD GPUs use device mappings (--device /dev/kfd /dev/dri), no special toolkit needed
    echo -e "${GREEN}✓ AMD GPUs use device mappings — no container toolkit required.${NC}"
elif dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
    echo -e "${GREEN}✓ NVIDIA Container Toolkit found.${NC}"
else
    echo -e "${YELLOW}Installing NVIDIA Container Toolkit...${NC}"

    # Add NVIDIA repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt update -y && sudo apt install -y nvidia-container-toolkit

    echo -e "${GREEN}✓ NVIDIA Container Toolkit installed.${NC}"
fi

# ============================================
# 5. Verify GPU access from Docker containers
# ============================================
if $AMD_GPU_FOUND && command -v docker &>/dev/null && ! $NEEDS_REBOOT; then
    echo -e "${BLUE}Verifying AMD GPU access in Docker...${NC}"
    if sudo docker run --rm --device /dev/kfd --device /dev/dri \
        -e HSA_OVERRIDE_GFX_VERSION=12.0.1 \
        rocm/pytorch:rocm6.2.4-py3.11-ubuntu22.04 rocm-smi --showid &>/dev/null; then
        echo -e "${GREEN}✓ AMD GPU accessible from Docker containers.${NC}"
    else
        echo -e "${YELLOW}⚠ AMD GPU verification did not pass. Container access may need configuration.${NC}"
    fi
elif command -v nvidia-ctk &>/dev/null && command -v docker &>/dev/null && ! $NEEDS_REBOOT; then
    # Use sudo for docker commands since user may not have docker group active in this session
    if ! sudo docker info 2>/dev/null | grep -q "nvidia"; then
        echo -e "${BLUE}Configuring Docker NVIDIA runtime...${NC}"
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker

        echo "  Waiting for Docker to restart..."
        for i in {1..15}; do
            if sudo docker info &>/dev/null 2>&1; then
                break
            fi
            sleep 1
        done

        echo -e "${GREEN}✓ Docker GPU runtime configured.${NC}"
    else
        echo -e "${GREEN}✓ Docker NVIDIA runtime already configured.${NC}"
    fi

    # Verify GPU access in Docker
    echo -e "${BLUE}Verifying GPU access in Docker...${NC}"
    if sudo docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi &>/dev/null; then
        echo -e "${GREEN}✓ GPU accessible from Docker containers.${NC}"
    else
        echo -e "${YELLOW}⚠ GPU verification did not pass. May work after reboot.${NC}"
    fi
fi

# ============================================
# Exit
# ============================================
if $NEEDS_REBOOT; then
    echo ""
    echo -e "${YELLOW}Preflight complete but REBOOT REQUIRED for NVIDIA drivers.${NC}"
    exit 100
fi

echo ""
echo -e "${GREEN}✓ Preflight complete. Server is ready for benchmarking.${NC}"
exit 0
