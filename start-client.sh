#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
#  Local realtime voice client
#  Connects to the server started by start-server.sh
#  Uses your default microphone + speakers
# ──────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".venv/bin/activate" ]; then
    echo "ERROR: .venv not found. Run start-server.sh first."
    exit 1
fi

source .venv/bin/activate

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Local Realtime Voice Client                        ║"
echo "║   Connecting to ws://127.0.0.1:8765/v1/realtime      ║"
echo "║   Speak freely – no time limits, no account needed.  ║"
echo "║   Press Ctrl+C to stop.                              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

python scripts/listen_and_play_realtime.py --host 127.0.0.1 --port 8765
