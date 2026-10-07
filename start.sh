#!/usr/bin/env bash
# Start the local orb UI and offline speech-to-speech backend together,
# in one terminal. Ctrl+C stops both processes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UI_PID=""
S2S_PID=""
UI_PORT="${S2S_UI_PORT:-8080}"
WS_PORT="${S2S_WS_PORT:-8765}"

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    echo ""
    echo "Stopping the UI and speech server..."
    for pid in "$S2S_PID" "$UI_PID"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    for pid in "$S2S_PID" "$UI_PID"; do
        if [ -n "$pid" ]; then wait "$pid" 2>/dev/null || true; fi
    done
    echo "Both services stopped."
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_port() {
    local pid="$1" port="$2" label="$3" elapsed=0
    printf 'Waiting for %s on port %s' "$label" "$port"
    while [ "$elapsed" -lt 300 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo ""
            echo "ERROR: $label stopped before becoming ready." >&2
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            echo " ready."
            return 0
        fi
        if [ "$((elapsed % 5))" -eq 0 ]; then printf '.'; fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo ""
    echo "ERROR: timed out waiting for $label on port $port." >&2
    return 1
}

echo "Starting local web UI and offline speech server together..."
./start-ui.sh &
UI_PID=$!
./start-server.sh &
S2S_PID=$!

wait_for_port "$UI_PID" "$UI_PORT" "Web UI"
wait_for_port "$S2S_PID" "$WS_PORT" "speech-to-speech backend"

echo ""
echo "✓ Both services are ready."
echo "  Browser:       http://localhost:$UI_PORT"
echo "  UI server URL: ws://localhost:$WS_PORT"
echo "  Keep this terminal open; press Ctrl+C to stop both."
echo ""

# Stay attached to both services; if either exits, clean up the other.
wait -n "$UI_PID" "$S2S_PID"
