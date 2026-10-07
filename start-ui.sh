#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  Local orb UI server. For a one-terminal launch of UI + AI backend, use
#  ./start.sh; this script can also be run on its own for UI debugging.
#  It deliberately never runs pip or downloads dependencies.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/hf-ui"

if [ ! -f "$UI_DIR/server.py" ]; then
    echo "ERROR: hf-ui/ not found. Something went wrong with the checkout." >&2
    exit 1
fi

VENV="${S2S_VENV:-}"
if [ -z "$VENV" ]; then
    for candidate in "$SCRIPT_DIR/.venv" "$HOME/speech-to-speech-0.2.10/.venv" "$HOME/venvs/gemma-avatar-s2s"; do
        if [ -x "$candidate/bin/python" ]; then VENV="$candidate"; break; fi
    done
fi
if [ -z "$VENV" ] || [ ! -x "$VENV/bin/python" ]; then
    echo "ERROR: no usable Python environment found. Set S2S_VENV=/path/to/.venv" >&2
    exit 1
fi

if ! "$VENV/bin/python" -c 'import fastapi, httpx, uvicorn' >/dev/null 2>&1; then
    echo "ERROR: the selected environment lacks FastAPI, httpx, or uvicorn:" >&2
    echo "  $VENV" >&2
    echo "This offline launcher will not install packages. Choose an existing environment with those packages." >&2
    exit 1
fi

cd "$UI_DIR"
UI_PORT="${S2S_UI_PORT:-8080}"

printf '\nStarting local Orb UI\n'
printf '  Browser:       http://localhost:%s\n' "$UI_PORT"
printf '  S2S WebSocket: ws://localhost:%s/v1/realtime\n' "${S2S_WS_PORT:-8765}"
printf '  Python env:    %s\n\n' "$VENV"

exec "$VENV/bin/python" -m uvicorn server:app --host 0.0.0.0 --port "$UI_PORT"
