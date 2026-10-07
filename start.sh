#!/usr/bin/env bash
# Start the local orb UI and offline speech-to-speech backend together,
# in one terminal. Defaults to local Ollama; choose its installed model in
# browser Settings. Set S2S_LLM_BACKEND=transformers to use the cached LM instead.
# Ctrl+C stops both processes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UI_PID=""
S2S_PID=""
UI_PORT="${S2S_UI_PORT:-8080}"
WS_PORT="${S2S_WS_PORT:-8765}"
LLM_BACKEND="${S2S_LLM_BACKEND:-ollama}"
export S2S_LLM_BACKEND="$LLM_BACKEND"

case "$LLM_BACKEND" in
    ollama)
        export S2S_OLLAMA_ENABLED=1
        OLLAMA_URL="${S2S_OLLAMA_URL:-http://127.0.0.1:11434}"
        case "$OLLAMA_URL" in http://*|https://*) ;; *) OLLAMA_URL="http://$OLLAMA_URL" ;; esac
        OLLAMA_URL="${OLLAMA_URL%/}"
        case "$OLLAMA_URL" in */v1) OLLAMA_URL="${OLLAMA_URL%/v1}" ;; esac
        export S2S_OLLAMA_URL="$OLLAMA_URL"
        OLLAMA_BASE_URL="${S2S_OLLAMA_BASE_URL:-$OLLAMA_URL/v1}"
        export S2S_OLLAMA_BASE_URL="$OLLAMA_BASE_URL"
        OLLAMA_MODELS="${S2S_OLLAMA_MODELS:-}"
        if [ -z "$OLLAMA_MODELS" ]; then
            printf 'Checking local Ollama models'
            OLLAMA_MODELS="$(python3 -c 'import json,sys,urllib.request; op=urllib.request.build_opener(urllib.request.ProxyHandler({})); d=json.load(op.open(sys.argv[1], timeout=3)); print(",".join(m["name"] for m in d.get("models", []) if isinstance(m.get("name"), str) and m["name"]))' "$OLLAMA_URL/api/tags" 2>/dev/null || true)"
            echo ""
        fi
        if [ -z "$OLLAMA_MODELS" ]; then
            echo "ERROR: Ollama returned no local models at $OLLAMA_URL/api/tags." >&2
            echo "Start Ollama or set S2S_OLLAMA_URL; to use the cached Transformers model set S2S_LLM_BACKEND=transformers." >&2
            exit 1
        fi
        export S2S_OLLAMA_MODELS="$OLLAMA_MODELS"
        IFS=',' read -r -a OLLAMA_MODEL_LIST <<< "$OLLAMA_MODELS"
        if [ -z "${S2S_LLM_MODEL:-}" ]; then export S2S_LLM_MODEL="${OLLAMA_MODEL_LIST[0]}"; fi
        case ",$OLLAMA_MODELS," in
            *",$S2S_LLM_MODEL,"*) ;;
            *) echo "ERROR: S2S_LLM_MODEL '$S2S_LLM_MODEL' is not in the local Ollama model list." >&2; exit 1 ;;
        esac
        echo "LLM: Ollama — $(printf '%s' "$OLLAMA_MODELS" | tr ',' ' ') (default: $S2S_LLM_MODEL)"
        ;;
    transformers)
        export S2S_OLLAMA_ENABLED=0
        echo "LLM: local Transformers backend"
        ;;
    *)
        echo "ERROR: S2S_LLM_BACKEND must be 'ollama' or 'transformers' (got '$LLM_BACKEND')." >&2
        exit 1
        ;;
esac

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
