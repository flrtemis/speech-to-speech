#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  HF Realtime Voice  –  Unified Startup Script
#
#  Launches both the AI backend and the web UI concurrently in one 
#  terminal. Handles background process tracking and clean shutdown 
#  on Ctrl+C (SIGINT/SIGTERM).
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Cleanup trap to ensure background processes are killed on exit
cleanup() {
    echo ""
    echo "Stopping servers cleanly..."
    if [ -n "$UI_PID" ]; then
        kill "$UI_PID" 2>/dev/null || true
    fi
    echo "All stopped. Have a great day!"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ── 1. Start UI Server in background ──────────────────────────────────
echo "Starting local Orb UI..."
./start-ui.sh > /tmp/local-ui.log 2>&1 &
UI_PID=$!

# Ensure the background process started
if ! ps -p "$UI_PID" > /dev/null; then
    echo "ERROR: Failed to start the UI Server."
    exit 1
fi

echo "Frontend UI running in background (logs: /tmp/local-ui.log)"
echo "Available at: http://localhost:8080"
echo ""

# ── 2. Start AI Engine in foreground ──────────────────────────────────
echo "Starting speech-to-speech engine..."
./start-server.sh
