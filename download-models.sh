#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  download-models.sh  —  fetch the pipeline's models into ~/models
#
#  Downloads real weight files with their original names (no HF blob cache,
#  no symlinks). Re-running it only fetches what is missing.
#
#    bash download-models.sh                 # into ~/models
#    MODELS_DIR=/mnt/d/models bash download-models.sh
#
#  Models (these are the ones the pipeline actually loads):
#    ~/models/parakeet-tdt-0.6b-v3/    STT   (nvidia/parakeet-tdt-0.6b-v3)
#    ~/models/Qwen3-4B-Instruct-2507/  LLM   (Qwen/Qwen3-4B-Instruct-2507)
#    ~/models/qwen3-tts-1.7b/          TTS   (Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
#    ~/models/silero-vad/              VAD   (snakers4/silero-vad, .jit file)
#
#  To run the pipeline straight from these folders:
#    TORCH_HOME=~/models/torch ./start-server.sh
#  (start-server.sh auto-detects everything, including local checkpoints)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
mkdir -p "$MODELS_DIR"

# Find an hf CLI: prefer the project venv, then PATH, then a module fallback.
HF_CLI=""
for candidate in "${S2S_VENV:-}/bin/hf" "$PWD/.venv/bin/hf" "$HOME/speech-to-speech-0.2.10/.venv/bin/hf" \
                 "$(command -v hf 2>/dev/null || true)" \
                 "${S2S_VENV:-}/bin/huggingface-cli" "$PWD/.venv/bin/huggingface-cli" \
                 "$(command -v huggingface-cli 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then HF_CLI="$candidate"; break; fi
done
if [ -z "$HF_CLI" ]; then
    echo "ERROR: no 'hf' / 'huggingface-cli' found." >&2
    echo "Install it with:  pip install -U 'huggingface_hub[cli]'" >&2
    exit 1
fi
echo "using: $HF_CLI"
echo "target: $MODELS_DIR"
echo

fetch() { # $1 = repo id, $2 = destination folder
    echo "== $1"
    "$HF_CLI" download "$1" --local-dir "$MODELS_DIR/$2"
    echo
}

fetch nvidia/parakeet-tdt-0.6b-v3           parakeet-tdt-0.6b-v3
fetch Qwen/Qwen3-4B-Instruct-2507           Qwen3-4B-Instruct-2507
fetch Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice  qwen3-tts-1.7b

# silero VAD: the pipeline wants the .jit checkpoint, which lives in the repo's
# src/silero_vad/data/ folder. Copy it out to a stable location afterwards.
echo "== snakers4/silero-vad (VAD checkpoint)"
"$HF_CLI" download snakers4/silero-vad --local-dir "$MODELS_DIR/silero-vad"
SILERO_SRC="$(find "$MODELS_DIR/silero-vad" -name 'silero_vad.jit' | head -1 || true)"
if [ -n "$SILERO_SRC" ]; then
    mkdir -p "$MODELS_DIR/torch/hub/snakers4_silero-vad_master/src/silero_vad/data"
    cp -n "$SILERO_SRC" "$MODELS_DIR/torch/hub/snakers4_silero-vad_master/src/silero_vad/data/silero_vad.jit"
    echo "  VAD checkpoint ready for TORCH_HOME=$MODELS_DIR/torch"
else
    echo "  NOTE: no .jit in that repo snapshot; the pipeline will fall back to torch.hub."
fi
echo

echo "Done. Files are yours, with their original names:"
du -sh "$MODELS_DIR"/* 2>/dev/null || true
echo
echo "Run the pipeline against this folder:"
echo "    TORCH_HOME=$MODELS_DIR/torch ./start-server.sh"
