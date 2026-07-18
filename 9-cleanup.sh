#!/bin/bash
# GX10 Stress Test Suite - Delivery Cleanup
# Run this when a unit has passed burn-in and is being prepared for a client.
# Removes every trace the suite left on the machine:
#   - the tools installed OUTSIDE this folder by 0-setup.sh (uv + its caches,
#     HuggingFace cache, the .bashrc line the uv installer added)
#   - optionally the shell history
#   - finally this whole folder itself
# After it finishes, the machine is as if the stress test never happened.

cd "$(dirname "$0")"
BASE_DIR="$(pwd)"

echo "========================================="
echo "GX10 Stress Test Suite - Delivery Cleanup"
echo "========================================="
echo ""
echo "This will remove from this machine:"
echo "  - uv/uvx and installer files (~/.local/bin/uv, uvx, env, env.fish)"
echo "  - caches: ~/.cache/uv, ~/.cache/huggingface"
echo "  - the uv line in ~/.bashrc"
echo "  - THIS ENTIRE FOLDER: $BASE_DIR"
echo ""
read -p "Proceed? [y/N]: " ans
if [[ ! "${ans:-n}" =~ ^[Yy] ]]; then
    echo "Aborted - nothing removed."
    exit 0
fi

echo ""
echo "[1/4] Removing uv and installer files..."
rm -f ~/.local/bin/uv ~/.local/bin/uvx ~/.local/bin/env ~/.local/bin/env.fish
rmdir ~/.local/bin 2>/dev/null || true   # only removes it if now empty

echo "[2/4] Removing caches..."
rm -rf ~/.cache/uv ~/.cache/huggingface

echo "[3/4] Cleaning ~/.bashrc..."
sed -i '\#\. "\$HOME/\.local/bin/env"#d' ~/.bashrc
sed -i '\#export PATH="\$HOME/\.local/bin:\$PATH"#d' ~/.bashrc

read -p "Also clear shell history? [y/N]: " ans
if [[ "${ans:-n}" =~ ^[Yy] ]]; then
    cat /dev/null > ~/.bash_history 2>/dev/null || true
    history -c 2>/dev/null || true
    echo "History cleared."
fi

echo "[4/4] Removing the stress-test folder itself..."
cd ~
rm -rf "$BASE_DIR"

echo ""
echo "Done. The machine is clean - no stress-test traces remain."
echo "(A reboot clears any remaining shell sessions' in-memory history.)"
