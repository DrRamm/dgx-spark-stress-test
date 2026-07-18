#!/bin/bash
# GX10 Stress Test Suite - One-Shot Environment Setup
# Based on SETUP.md. Idempotent: safe to re-run, completed steps are skipped.
#
# What it does:
#   1. Installs system build dependencies (apt) if missing
#   2. Checks CUDA toolkit (warns if missing - not auto-installed)
#   3. Installs uv (modern Python package manager)
#   4. Creates .venv in this folder and installs huggingface-hub
#   5. Clones llama.cpp and builds it with CUDA support (cmake)
#   6. Downloads the bundled dgxtop TUI monitor into tools/ (if missing)
#   7. Verifies llama-server binary works
#
# After this completes, just run ./run.sh to download a model and stress test.
#
# To force a llama.cpp rebuild: rm -rf llama.cpp/build && ./0-setup.sh

set -e

cd "$(dirname "$0")"
BASE_DIR="$(pwd)"

echo "========================================="
echo "GX10 Stress Test Suite - Setup"
echo "========================================="
echo "Install location: $BASE_DIR"
echo ""

# --- Step 1: System dependencies ---
echo "[1/7] Checking system dependencies..."
MISSING_PKGS=()
command -v gcc    &>/dev/null || MISSING_PKGS+=(build-essential)
command -v cmake  &>/dev/null || MISSING_PKGS+=(cmake)
command -v git    &>/dev/null || MISSING_PKGS+=(git)
command -v wget   &>/dev/null || MISSING_PKGS+=(wget)
command -v curl   &>/dev/null || MISSING_PKGS+=(curl)
command -v jq     &>/dev/null || MISSING_PKGS+=(jq)
command -v pkg-config &>/dev/null || MISSING_PKGS+=(pkg-config)
command -v python3 &>/dev/null || MISSING_PKGS+=(python3 python3-pip python3-venv)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "  Installing missing packages: ${MISSING_PKGS[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_PKGS[@]}" libgomp1
else
    echo "  All system dependencies present - skipping apt"
fi

# --- Step 2: CUDA toolkit check ---
echo ""
echo "[2/7] Checking CUDA toolkit..."
if [ -x /usr/local/cuda/bin/nvcc ] && ! command -v nvcc &>/dev/null; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
fi
if command -v nvcc &>/dev/null; then
    echo "  Found: $(nvcc --version | grep release)"
else
    echo "  WARNING: nvcc not found. CUDA toolkit is required to build llama.cpp with GPU support."
    echo "  Install it first (see SETUP.md Step 2), e.g. for Ubuntu 24.04:"
    echo "    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
    echo "    sudo dpkg -i cuda-keyring_1.1-1_all.deb"
    echo "    sudo apt update && sudo apt install -y cuda-toolkit-12-6"
    echo "  Then re-run this script."
    exit 1
fi
if ! command -v nvidia-smi &>/dev/null; then
    echo "  WARNING: nvidia-smi not found - NVIDIA driver may not be installed."
    exit 1
fi

# --- Step 3: Install uv ---
echo ""
echo "[3/7] Checking uv..."
export PATH="$HOME/.local/bin:$PATH"
if command -v uv &>/dev/null; then
    echo "  uv already installed: $(uv --version)"
else
    echo "  Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv &>/dev/null; then
        echo "  ERROR: uv installation failed"
        exit 1
    fi
    echo "  Installed: $(uv --version)"
fi

# --- Step 4: Python virtual environment ---
echo ""
echo "[4/7] Setting up Python virtual environment (.venv)..."
if [ -f ".venv/bin/activate" ]; then
    echo "  .venv already exists - skipping creation"
else
    uv venv
fi
source .venv/bin/activate
if python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "  huggingface-hub already installed"
else
    echo "  Installing huggingface-hub..."
    uv pip install huggingface-hub
fi

# --- Step 5: Clone and build llama.cpp ---
echo ""
echo "[5/7] Setting up llama.cpp..."
if [ -d "llama.cpp/.git" ]; then
    echo "  llama.cpp already cloned - skipping ($(cd llama.cpp && git log -1 --oneline))"
else
    git clone https://github.com/ggerganov/llama.cpp
fi

if [ -x "llama.cpp/build/bin/llama-server" ]; then
    echo "  llama-server already built - skipping build"
    echo "  (to rebuild: rm -rf llama.cpp/build && ./0-setup.sh)"
else
    echo "  Building llama.cpp with CUDA (takes 5-10 minutes)..."
    cmake -S llama.cpp -B llama.cpp/build -DGGML_CUDA=1
    cmake --build llama.cpp/build --config Release -j"$(nproc)"
fi

# --- Step 6: Bundled tools ---
echo ""
echo "[6/7] Checking bundled tools..."
mkdir -p tools
if [ -x "tools/dgxtop" ]; then
    echo "  tools/dgxtop already present"
else
    echo "  Downloading dgxtop (live TUI monitor) into tools/..."
    DGXTOP_URL="https://github.com/DennySORA/dgxtop/releases/download/v0.2.5/dgxtop-aarch64-unknown-linux-gnu.tar.gz"
    if curl -fsSL "$DGXTOP_URL" | tar -xz -C tools/ 2>/dev/null && [ -f tools/dgxtop ]; then
        chmod +x tools/dgxtop
        echo "  Installed tools/dgxtop"
    else
        echo "  WARNING: dgxtop download failed - live monitoring TUI unavailable"
        echo "  (not fatal: the stress tests log thermals to CSV regardless)"
    fi
fi

# --- Step 7: Verify ---
echo ""
echo "[7/7] Verifying installation..."
mkdir -p models logs
export LD_LIBRARY_PATH="$BASE_DIR/llama.cpp/build/bin:$LD_LIBRARY_PATH"
if VERSION_OUT=$(./llama.cpp/build/bin/llama-server --version 2>&1); then
    echo "$VERSION_OUT" | head -5
    echo "  llama-server OK"
else
    echo "  ERROR: llama-server verification failed"
    echo "  Check missing libraries with: ldd ./llama.cpp/build/bin/llama-server"
    exit 1
fi

echo ""
echo "========================================="
echo "Setup complete!"
echo "========================================="
echo ""
echo "Next step - launch the interactive CLI:"
echo "  ./run.sh"
echo ""
echo "  1) Download model       (needed once, ~40-95GB)"
echo "  2) Run server stress test"
echo ""
