#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
#  Local realtime voice server  –  fully local, no API key
#  Matches the HF Space pipeline exactly:
#    VAD : silero-vad  (built-in)
#    STT : nvidia/parakeet-tdt-1.1b  (local, CUDA)
#    VLM : google/gemma-3-4b-it  (local, CUDA bfloat16)
#          ↑ same Gemma family as the Space's gemma-4-31B-it,
#            scaled to fit your 16 GB VRAM
#    TTS : Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice  (local, CUDA)
#          ↑ the exact same TTS model the Space uses
#  GPU : RTX 5070 Ti (16 GB)  |  Mode: realtime WebSocket :8765
# ──────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".venv/bin/activate" ]; then
    echo "ERROR: .venv not found."
    echo "Run:  uv sync --python 3.12 --extra kokoro --extra websocket"
    exit 1
fi

source .venv/bin/activate

# After the initial model download, force offline mode so the pipeline
# never contacts the HF Hub during inference. Remove this line only if
# you want to pull a model update.
export HF_HUB_OFFLINE=0  # set to 1 after first successful launch
export TRANSFORMERS_OFFLINE=0  # set to 1 after first successful launch

# If models are already cached, flip to fully offline:
PARAKEET_CACHED=$(find ~/.cache/huggingface/hub -name '*.safetensors' -path '*parakeet*' 2>/dev/null | head -1)
GEMMA_CACHED=$(find ~/.cache/huggingface/hub -name '*.safetensors' -path '*Qwen3*' 2>/dev/null | head -1)
QWEN_TTS_CACHED=$(find ~/.cache/huggingface/hub -name '*.safetensors' -path '*Qwen3-TTS*' 2>/dev/null | head -1)
if [ -n "$PARAKEET_CACHED" ] && [ -n "$GEMMA_CACHED" ] && [ -n "$QWEN_TTS_CACHED" ]; then
    echo "  All models found in local cache — running fully offline."
    export HF_HUB_OFFLINE=1
    export TRANSFORMERS_OFFLINE=1
else
    echo "  Some models not yet cached — downloading weights now (one-time)."
fi

echo ""
echo "==========================================================="
echo "  Local HF Realtime Voice - no limits, no account"
echo ""
echo "  VAD  silero-vad             (built-in)"
echo "  STT  parakeet-tdt           (local, CUDA)"
echo "  VLM  Qwen/Qwen3-4B-Instruct (local, CUDA fp16)"
echo "  TTS  Qwen3-TTS-1.7B         (local, CUDA)"
echo ""
echo "  WebSocket: ws://127.0.0.1:8765/v1/realtime"
echo "==========================================================="
echo ""
echo "  Once you see 'Application startup complete':" 
echo "    Open start-ui.sh in a second terminal for the orb UI"
echo "    or run start-client.sh for a terminal voice client"
echo ""

speech-to-speech \
    --mode realtime \
    --stt parakeet-tdt \
    --llm_backend transformers \
    --tts qwen3 \
    --model_name "Qwen/Qwen3-4B-Instruct-2507" \
    --llm_device cuda \
    --llm_torch_dtype float16 \
    --enable_live_transcription \
    --ws_host 0.0.0.0 \
    --ws_port 8765
