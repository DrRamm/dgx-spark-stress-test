#!/bin/bash
# GX10 Stress Test Suite - Interactive Launcher
# Menu-driven entry point so no arguments need to be remembered.
# The underlying scripts can still be run directly with arguments.

cd "$(dirname "$0")"

# Use the project virtual environment if it exists (created by 0-setup.sh)
[ -f ".venv/bin/activate" ] && source .venv/bin/activate

while true; do
    echo "========================================="
    echo "GX10 Stress Test Suite"
    echo "========================================="
    echo "  0) First-time setup         (0-setup.sh: uv, .venv, build llama.cpp)"
    echo "  1) Download model           (1-download-model.sh)"
    echo "  2) Run server stress test   (5-stress-test-server.sh: LLM only)"
    echo "  3) Run combined stress test (6-stress-test-combined.sh: LLM + SDXL image gen)"
    echo "  q) Quit"
    echo ""
    read -p "Choice [0/1/2/3/q]: " choice
    echo ""
    case "$choice" in
        0) ./0-setup.sh ;;
        1) ./1-download-model.sh ;;
        2) ./5-stress-test-server.sh ;;
        3) ./6-stress-test-combined.sh ;;
        q|Q) exit 0 ;;
        *) echo "Invalid choice, try again."; echo "" ;;
    esac
done
