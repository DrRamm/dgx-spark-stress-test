#!/bin/bash
# Asus Ascent GX10 Combined Stress Test
# Runs the LLM server stress test (5-stress-test-server.sh) with a concurrent
# SDXL image-generation loop. Rationale:
#   - LLM decode is memory-bandwidth-bound: fills unified memory (~74-95GB)
#     and saturates the memory subsystem, but leaves GPU compute partly idle.
#   - Diffusion is compute-bound: near-100% SM utilization, max power/heat.
#   - Together: memory capacity + bandwidth + compute + thermals all loaded.
#
# Usage:
#   Interactive : ./6-stress-test-combined.sh
#   Arguments   : ./6-stress-test-combined.sh <length> <vram> <model>
#     (same arguments as 5-stress-test-server.sh, e.g. 12h high large)
#
# First run bootstraps the image side automatically:
#   - clones + builds stable-diffusion.cpp with CUDA (~10-15 min)
#   - downloads SDXL base 1.0 (~6.9GB) and fp16-fix VAE (~335MB), no HF login
#
# Memory note: SDXL adds ~10GB. Fine next to small/large LLM; with xlarge
# (Mixtral ~95GB) total is ~110GB of the ~120GB usable - still OK but tight.

set -e

cd "$(dirname "$0")"
BASE_DIR="$(pwd)"

SD_DIR="$BASE_DIR/stable-diffusion.cpp"
SD_BIN="$SD_DIR/build/bin/sd-cli"
SDXL_MODEL="$BASE_DIR/models/sd_xl_base_1.0.safetensors"
SDXL_VAE="$BASE_DIR/models/sdxl_vae.safetensors"
LOG_DIR="$BASE_DIR/logs"
IMG_DIR="$LOG_DIR/images"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMGGEN_LOG="$LOG_DIR/imagegen_${TIMESTAMP}.log"
IMGGEN_STOP="$LOG_DIR/.imagegen_stop_${TIMESTAMP}"

IMG_STEPS=30
IMG_SIZE=1024

# --- Bootstrap: build stable-diffusion.cpp if needed ---
if [ ! -x "$SD_BIN" ]; then
    echo "[bootstrap] stable-diffusion.cpp not built yet - building now (~10-15 min)..."
    if [ ! -d "$SD_DIR/.git" ]; then
        git clone --recursive https://github.com/leejet/stable-diffusion.cpp "$SD_DIR"
    fi
    # Non-login shells may not have CUDA on PATH
    if ! command -v nvcc &>/dev/null && [ -x /usr/local/cuda/bin/nvcc ]; then
        export PATH="/usr/local/cuda/bin:$PATH"
        export CUDACXX=/usr/local/cuda/bin/nvcc
    fi
    cmake -S "$SD_DIR" -B "$SD_DIR/build" -DSD_CUDA=ON \
        -DCMAKE_CUDA_COMPILER="$(command -v nvcc)"
    cmake --build "$SD_DIR/build" --config Release -j"$(nproc)"
    [ -x "$SD_BIN" ] || { echo "ERROR: sd-cli binary not found after build"; exit 1; }
fi

# --- Bootstrap: download SDXL weights if needed ---
if [ ! -f "$SDXL_MODEL" ]; then
    echo "[bootstrap] Downloading SDXL base 1.0 (~6.9GB)..."
    wget -c -O "$SDXL_MODEL.part" \
        "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"
    mv "$SDXL_MODEL.part" "$SDXL_MODEL"
fi
if [ ! -f "$SDXL_VAE" ]; then
    echo "[bootstrap] Downloading SDXL fp16-fix VAE (~335MB)..."
    wget -c -O "$SDXL_VAE.part" \
        "https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors"
    mv "$SDXL_VAE.part" "$SDXL_VAE"
fi

mkdir -p "$IMG_DIR"

# --- Image generation loop (runs in background until stop-file removed) ---
IMG_PROMPTS=(
    "a hyper-detailed oil painting of a futuristic city at sunset, dramatic clouds"
    "macro photograph of a mechanical watch movement, intricate gears, studio lighting"
    "fantasy landscape with floating islands and waterfalls, volumetric light"
    "portrait of an astronaut in a sunflower field, golden hour, 85mm photo"
    "cutaway illustration of a steampunk submarine, blueprint style, highly detailed"
    "snow-covered japanese temple in a cedar forest, morning fog, ukiyo-e style"
)

image_loop() {
    local n=0
    # Wait for llama-server to finish loading before adding GPU contention:
    # the 70B+ model load needs full memory bandwidth (~3.5 min). Start
    # generating images once the server is healthy, or after 15 min max
    # (so the image loop still runs if the LLM side fails).
    local waited=0
    echo "[imagegen] waiting for llama-server to become healthy before starting..." >> "$IMGGEN_LOG"
    while [ -e "$IMGGEN_STOP" ] && [ "$waited" -lt 900 ]; do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health 2>/dev/null)" == "200" ]]; then
            echo "[imagegen] llama-server healthy after ${waited}s - starting image loop" >> "$IMGGEN_LOG"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    while [ -e "$IMGGEN_STOP" ]; do
        n=$((n + 1))
        local prompt="${IMG_PROMPTS[$(( (n - 1) % ${#IMG_PROMPTS[@]} ))]}"
        echo "[imagegen] $(date '+%F %T') image batch $n starting: ${prompt:0:60}..." >> "$IMGGEN_LOG"
        "$SD_BIN" \
            -m "$SDXL_MODEL" \
            --vae "$SDXL_VAE" \
            --vae-tiling \
            -p "$prompt" \
            -H "$IMG_SIZE" -W "$IMG_SIZE" \
            --steps "$IMG_STEPS" \
            -b 2 \
            -s -1 \
            -o "$IMG_DIR/stress_${TIMESTAMP}_${n}.png" \
            >> "$IMGGEN_LOG" 2>&1 || \
            echo "[imagegen] WARNING: batch $n failed (exit $?)" >> "$IMGGEN_LOG"
        # Keep only the newest 20 images - this is a burn-in, not an art project
        ls -t "$IMG_DIR"/stress_*.png 2>/dev/null | tail -n +21 | xargs -r rm -f
    done
    echo "[imagegen] $(date '+%F %T') loop stopped after $n batches" >> "$IMGGEN_LOG"
}

IMG_PID=""
cleanup() {
    rm -f "$IMGGEN_STOP"
    if [[ -n "$IMG_PID" ]] && kill -0 "$IMG_PID" 2>/dev/null; then
        echo "Stopping image generation loop (PID $IMG_PID)..."
        # Also kill a currently running sd process so we don't wait minutes
        pkill -P "$IMG_PID" 2>/dev/null || true
        kill "$IMG_PID" 2>/dev/null || true
        wait "$IMG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "========================================="
echo "GX10 Combined Stress Test (LLM + SDXL)"
echo "========================================="
echo "Image gen : SDXL 1024x1024, ${IMG_STEPS} steps, continuous loop"
echo "Image log : $IMGGEN_LOG"
echo ""

touch "$IMGGEN_STOP"
image_loop &
IMG_PID=$!
echo "Image generation loop started (PID $IMG_PID)"
echo ""

# LLM decode will be slower under GPU contention - widen per-request timeout
export STRESS_SLOW_FACTOR=4
# Model load can also be slower if images are already generating (e.g. server
# restart scenarios) - allow up to 15 min instead of 5
export STRESS_STARTUP_TIMEOUT=900

# Foreground: the LLM stress test (interactive if no args were given)
./5-stress-test-server.sh "$@"

echo ""
echo "Combined stress test finished."
echo "Image generation log: $IMGGEN_LOG"
grep -c "image batch" "$IMGGEN_LOG" 2>/dev/null | xargs -I{} echo "Image batches attempted: {}"
