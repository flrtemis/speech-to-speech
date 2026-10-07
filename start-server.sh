#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  start-server.sh  —  local realtime voice server, fully offline by default
#
#  What it uses (all of these already exist on this machine):
#    VAD : silero-vad, loaded from the local .jit checkpoint (no GitHub call)
#    STT : nvidia/parakeet-tdt-0.6b-v3   (nano-parakeet, CUDA, bf16)
#    LLM : Qwen/Qwen3-4B-Instruct-2507   (transformers, CUDA, bf16)
#    TTS : Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice  (faster-qwen3-tts / CUDA)
#
#  Offline behaviour: network access is blocked by default. If a required asset
#  is missing, startup stops instead of silently downloading it. To explicitly
#  permit downloads: S2S_ONLINE=1 ./start-server.sh
#
#  Optional env overrides:
#    S2S_VENV=/path/to/.venv         pick a specific venv
#    S2S_LLM_MODEL=Qwen/Qwen3-4B-Instruct-2507      (or a local directory)
#    S2S_TTS_MODEL=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice (or a local directory)
#    S2S_TTS_BACKEND=ggml            use the local GGUF weights via qwentts.cpp
#    S2S_TTS_GGUF_DIR=~/gemma-avatar/models/qwen3-tts-gguf
#    S2S_VAD_PATH=/path/silero_vad.jit
#    S2S_LLM_DTYPE=bfloat16|float16
#    S2S_WS_PORT=8765
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"

# ── pick a venv ──────────────────────────────────────────────────────────────
VENV="${S2S_VENV:-}"
if [ -z "$VENV" ]; then
    for candidate in "$SCRIPT_DIR/.venv" "$HOME/speech-to-speech-0.2.10/.venv" "$HOME/venvs/gemma-avatar-s2s"; do
        if [ -f "$candidate/bin/activate" ]; then VENV="$candidate"; break; fi
    done
fi
if [ -z "$VENV" ] || [ ! -f "$VENV/bin/activate" ]; then
    echo "ERROR: no virtualenv found. Set S2S_VENV=/path/to/.venv" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$VENV/bin/activate"
# Use this checkout's source even if the selected venv has a stale editable
# install or its console script points back at another speech-to-speech clone.
export PYTHONPATH="$SCRIPT_DIR/src${PYTHONPATH:+:$PYTHONPATH}"
echo "venv: $VENV"
echo "source: $SCRIPT_DIR/src"

# ── locate everything on disk ────────────────────────────────────────────────
have() { [ -n "${1:-}" ]; }
# Hugging Face creates .no_exist placeholders for files that are not in a repo;
# those must never count as cached model weights.
find_first() { find "$1" ! -path '*/.no_exist/*' "${@:2}" 2>/dev/null | head -1 || true; }

PARAKEET_FILE="$(find_first "$HF_CACHE" -name '*.nemo' -path '*parakeet*')"
LLM_FILE="$(find_first "$HF_CACHE" -name '*.safetensors' -path '*Qwen3-4B*')"
TTS_FILE="$(find_first "$HF_CACHE" -name '*.safetensors' -path '*Qwen3-TTS*')"

SILERO_JIT="${S2S_VAD_PATH:-}"
if [ -n "$SILERO_JIT" ] && [ ! -f "$SILERO_JIT" ]; then
    echo "WARNING: S2S_VAD_PATH is not a file: $SILERO_JIT" >&2
    SILERO_JIT=""
fi
if [ -z "$SILERO_JIT" ]; then
    SILERO_JIT="$(find_first "${TORCH_HOME:-$HOME/.cache/torch}/hub" -name 'silero_vad.jit')"
fi

NLTK_OK=""
for dir in "${NLTK_DATA:-}" "$HOME/nltk_data" /usr/share/nltk_data /usr/local/share/nltk_data; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/tokenizers/punkt_tab" ] || [ -e "$dir/tokenizers/punkt_tab.zip" ]; then NLTK_OK="$dir"; break; fi
done

# ── offline decision ─────────────────────────────────────────────────────────
echo ""
echo "===================== local assets ====================="
printf '  %-14s %s\n' "STT parakeet" "${PARAKEET_FILE:-MISSING from HF cache}"
printf '  %-14s %s\n' "LLM qwen3-4b" "${LLM_FILE:-MISSING from HF cache}"
printf '  %-14s %s\n' "TTS qwen3-tts" "${TTS_FILE:-MISSING from HF cache}"
printf '  %-14s %s\n' "VAD silero"   "${SILERO_JIT:-MISSING (required for offline mode)}"
printf '  %-14s %s\n' "NLTK punkt"   "${NLTK_OK:-MISSING (required for offline mode)}"
echo "========================================================"
echo ""

MISSING_ASSETS=()
have "$PARAKEET_FILE" || MISSING_ASSETS+=("Parakeet STT .nemo checkpoint")
have "$LLM_FILE" || MISSING_ASSETS+=("Qwen3-4B LLM safetensors")
have "$TTS_FILE" || MISSING_ASSETS+=("Qwen3-TTS safetensors")
have "$SILERO_JIT" || MISSING_ASSETS+=("local Silero VAD .jit checkpoint")
have "$NLTK_OK" || MISSING_ASSETS+=("NLTK punkt_tab data")

if [ "${S2S_ONLINE:-0}" = "1" ]; then
    export HF_HUB_OFFLINE=0
    export TRANSFORMERS_OFFLINE=0
    echo "  S2S_ONLINE=1 -> network access explicitly allowed."
else
    export HF_HUB_OFFLINE=1
    export TRANSFORMERS_OFFLINE=1
    export HF_HUB_DISABLE_TELEMETRY=1
    export DO_NOT_TRACK=1
    export S2S_NLTK_DOWNLOAD=0
    export S2S_VAD_LOCAL_ONLY=1
    echo "  Network blocked: offline mode is enforced by default."
    if [ "${#MISSING_ASSETS[@]}" -gt 0 ]; then
        echo "  ERROR: required offline assets are missing; nothing was downloaded:" >&2
        printf '    - %s\n' "${MISSING_ASSETS[@]}" >&2
        echo "  Add those local files or explicitly allow network with S2S_ONLINE=1." >&2
        exit 1
    fi
    echo "  All required assets are local; proceeding with zero HF/NLTK/Torch Hub downloads."
fi
if have "$SILERO_JIT"; then
    export SILERO_VAD_PATH="$SILERO_JIT"
fi

# ── TTS backend (GGUF via qwentts.cpp, or the default torch path) ────────────
TTS_ARGS=()
if [ "${S2S_TTS_BACKEND:-torch}" = "ggml" ]; then
    GGUF_DIR="${S2S_TTS_GGUF_DIR:-$HOME/gemma-avatar/models/qwen3-tts-gguf}"
    TALKER="$(find_first "$GGUF_DIR" -name '*talker*.gguf')"
    CODEC="$(find_first "$GGUF_DIR" -name '*tokenizer*.gguf')"
    if have "$TALKER" && have "$CODEC"; then
        TTS_ARGS=(--qwen3_tts_backend ggml --qwen3_tts_gguf_talker_path "$TALKER" --qwen3_tts_gguf_codec_path "$CODEC")
        echo "  TTS backend: ggml (qwentts.cpp)  talker=$(basename "$TALKER")  codec=$(basename "$CODEC")"
    else
        echo "WARNING: S2S_TTS_BACKEND=ggml but no GGUF pair found under $GGUF_DIR; using the torch backend." >&2
    fi
else
    echo "  TTS backend: torch (faster-qwen3-tts)"
fi

# ── run ──────────────────────────────────────────────────────────────────────
WS_PORT="${S2S_WS_PORT:-8765}"
LLM_MODEL="${S2S_LLM_MODEL:-Qwen/Qwen3-4B-Instruct-2507}"
TTS_MODEL="${S2S_TTS_MODEL:-Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice}"
LLM_DTYPE="${S2S_LLM_DTYPE:-bfloat16}"

echo ""
echo "  WebSocket: ws://127.0.0.1:${WS_PORT}/v1/realtime"
echo ""

exec "$VENV/bin/python" -m speech_to_speech.s2s_pipeline \
    --mode realtime \
    --stt parakeet-tdt \
    --llm_backend transformers \
    --tts qwen3 \
    --model_name "$LLM_MODEL" \
    --llm_device cuda \
    --llm_torch_dtype "$LLM_DTYPE" \
    --qwen3_tts_model_name "$TTS_MODEL" \
    --qwen3_tts_attn_implementation sdpa \
    --enable_live_transcription \
    "${TTS_ARGS[@]+"${TTS_ARGS[@]}"}" \
    --ws_host 0.0.0.0 \
    --ws_port "$WS_PORT"
