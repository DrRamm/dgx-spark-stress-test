#!/bin/bash
# Download model for stress testing Asus Ascent GX10 (120GB VRAM)
# Using Python to download models (no CLI dependency)

set -e

# All default model choices are public - no HuggingFace token required.
# For gated models, export HF_TOKEN=<your token> before running this script.

echo "========================================="
echo "Asus Ascent GX10 Stress Test - Model Download"
echo "========================================="
echo ""

# Create directories
mkdir -p models
mkdir -p logs

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    echo "ERROR: Python3 not found!"
    exit 1
fi

# Install huggingface-hub if not present
echo "Checking for huggingface_hub package..."
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "Installing huggingface-hub..."
    uv pip install huggingface-hub
else
    echo "huggingface_hub already installed"
fi

echo ""
echo "========================================="
echo "Select model to download:"
echo "========================================="
echo "1. Mixtral 8x22B Q5_K_M (~95GB) - Recommended for 120GB VRAM"
echo "2. Llama 3.1 70B Q8_0 (~74GB) - High quality, good fit"
echo "3. Llama 3.1 70B Q5_K_M (~48GB) - Balanced"
echo "4. Llama 3.1 70B Q4_K_M (~40GB) - Smallest, fastest download"
echo ""
read -p "Enter choice [1-4] (default: 2): " choice
choice=${choice:-2}

case $choice in
    1)
        REPO="MaziyarPanahi/Mixtral-8x22B-Instruct-v0.1-GGUF"
        PATTERN="*Q5_K_M*"
        SIZE="~95GB"
        ;;
    2)
        REPO="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
        PATTERN="*Q8_0*"
        SIZE="~74GB"
        ;;
    3)
        REPO="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
        PATTERN="*Q5_K_M*"
        SIZE="~48GB"
        ;;
    4)
        REPO="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
        PATTERN="*Q4_K_M*"
        SIZE="~40GB"
        ;;
    *)
        echo "Invalid choice, using default (Llama 3.1 70B Q8)"
        REPO="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
        PATTERN="*Q8_0*"
        SIZE="~74GB"
        ;;
esac

echo ""
echo "Downloading: $PATTERN ($SIZE)"
echo "Repository: $REPO"
echo "Destination: ./models/"
echo ""
echo "This may take a while depending on your internet connection..."
echo "(Large models are split into multiple files - snapshot_download handles this automatically)"
echo ""

# Download using Python
python3 << EOF
from huggingface_hub import snapshot_download
import os
import glob

print("Starting download...")
print("")

try:
    # Use snapshot_download with pattern matching to handle split files
    local_dir = snapshot_download(
        repo_id="$REPO",
        local_dir="./models",
        allow_patterns=["$PATTERN"],
        token=os.environ.get("HF_TOKEN"),
    )

    # Find all .gguf files recursively (handles both flat and subdirectory layouts)
    all_ggufs = sorted(glob.glob(os.path.join(local_dir, "**/*.gguf"), recursive=True)
                     + glob.glob(os.path.join(local_dir, "*.gguf")))
    all_ggufs = sorted(set(all_ggufs))

    print("")
    print("=" * 50)
    print("Download complete!")
    print("=" * 50)
    if all_ggufs:
        print(f"Model file(s) saved to: {local_dir}/")
        for m in all_ggufs:
            rel = os.path.relpath(m, "./models")
            print(f"  {rel}")
        # For split files, llama.cpp loads the first part
        first_rel = os.path.relpath(all_ggufs[0], "./models")
        print("")
        print(f"Use this path in 3-stress-test.sh:")
        print(f"  MODEL_PATH=\"./models/{first_rel}\"")
    print("")

except Exception as e:
    print("")
    print("=" * 50)
    print(f"ERROR: Download failed!")
    print("=" * 50)
    print(f"Error details: {e}")
    print("")
    print("Possible solutions:")
    print("1. Check your internet connection")
    print("2. Ensure you have enough disk space")
    print("3. Try again - downloads can resume if interrupted")
    exit(1)
EOF

if [ $? -eq 0 ]; then
    echo ""
    echo "Model ready for stress testing!"
    echo ""
    echo "Next steps:"
    echo "1. Update MODEL_PATH in 3-stress-test.sh (see path printed above)"
    echo "2. Run: ./2-monitor-gpu.sh (in one terminal)"
    echo "3. Run: ./3-stress-test.sh (in another terminal)"
    echo ""
else
    echo ""
    echo "Download failed. Please check the errors above."
    exit 1
fi
