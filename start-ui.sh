#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  HF Realtime Voice  –  local orb UI (exact copy of the HF Space)
#
#  This runs the same server.py the Space uses. Without LOAD_BALANCER_URL
#  and SPACE_ID set, all usage limits, login gates, and time metering are
#  automatically disabled by the server's own code.
#
#  Prerequisites: start-server.sh must already be running in another
#  terminal (the orb UI connects to it over WebSocket).
# ──────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/hf-ui"

if [ ! -f "$UI_DIR/server.py" ]; then
    echo "ERROR: hf-ui/ not found. Something went wrong with the clone."
    exit 1
fi

cd "$UI_DIR"

# Install the UI server's own deps (tiny – fastapi, uvicorn, httpx).
# These are separate from the speech-to-speech venv.
pip install --quiet fastapi uvicorn httpx 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   HF Realtime Voice  –  Local Orb UI  (no limits!)          ║"
echo "║                                                              ║"
echo "║   Open your browser:  http://localhost:8080                  ║"
echo "║                                                              ║"
echo "║   In the UI click Settings (gear icon) and set:             ║"
echo "║     Server URL →  ws://localhost:8765                        ║"
echo "║                                                              ║"
echo "║   Make sure start-server.sh is running first.               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# No LOAD_BALANCER_URL and no SPACE_ID = all limits are off.
uvicorn server:app --host 0.0.0.0 --port 8080
