#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  Download all pipeline model weights to ~/models/ with original
#  filenames and extensions — no HF cache blobs, no symlinks.
#
#  After this runs you own the files outright:
#    ~/models/parakeet-tdt-1.1b/      → STT weights
#    ~/models/gemma-3-4b-it/          → VLM weights
#    ~/models/qwen3-tts-1.7b/         → TTS weights
#    ~/models/silero-vad/             → VAD weights
#
#  Uses: huggingface-cli download --local-dir
#  That flag downloads files with their original names directly into
#  the target folder — no blob cache, no content-hash renaming.
# ──────────────────────────────────────────────────────────────────────
set -e

MODELS_DIR="$HOME/models"
mkdir -p "$MODELS_DIR"

VENV_PYTHON="/home/l3ung/speech-to-speech-0.2.10/.venv/bin/python"
HF_CLI="/home/l3ung/speech-to-speech-0.2.10/.venv/bin/huggingface-cli"

if [ ! -f "$HF_CLI" ]; then
    echo "ERROR: huggingface-cli not found in venv. Run start-server.sh first."
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Downloading model weights to ~/models/                     ║"
echo "║   Files saved with original names and extensions.            ║"
echo "║   No HF blob cache. These files are yours.                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. STT: nvidia/parakeet-tdt-1.1b ─────────────────────────────────
echo "▶ STT  nvidia/parakeet-tdt-1.1b  →  $MODELS_DIR/parakeet-tdt-1.1b"
"$HF_CLI" download nvidia/parakeet-tdt-1.1b \
    --local-dir "$MODELS_DIR/parakeet-tdt-1.1b" \
    --local-dir-use-symlinks False
echo "  ✓ STT done"
echo ""

# ── 2. VLM: google/gemma-3-4b-it ─────────────────────────────────────
echo "▶ VLM  google/gemma-3-4b-it  →  $MODELS_DIR/gemma-3-4b-it"
echo "  (same Gemma family as the Space's gemma-4-31B-it, fits your 16 GB VRAM)"
"$HF_CLI" download google/gemma-3-4b-it \
    --local-dir "$MODELS_DIR/gemma-3-4b-it" \
    --local-dir-use-symlinks False
echo "  ✓ VLM done"
echo ""

# ── 3. TTS: Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice ─────────────────────
echo "▶ TTS  Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice  →  $MODELS_DIR/qwen3-tts-1.7b"
"$HF_CLI" download Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
    --local-dir "$MODELS_DIR/qwen3-tts-1.7b" \
    --local-dir-use-symlinks False
echo "  ✓ TTS done"
echo ""

# ── 4. VAD: snakers4/silero-vad ───────────────────────────────────────
echo "▶ VAD  snakers4/silero-vad  →  $MODELS_DIR/silero-vad"
"$HF_CLI" download snakers4/silero-vad \
    --local-dir "$MODELS_DIR/silero-vad" \
    --local-dir-use-symlinks False
echo "  ✓ VAD done"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   All weights downloaded to ~/models/                        ║"
echo "║   Run: ls -lh ~/models/*/  to see every file.               ║"
echo "║   Next: run ./start-server.sh                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
