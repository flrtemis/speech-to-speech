#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  s2s_doctor.sh  —  read-only readiness check for the speech-to-speech pipeline
#
#  Answers one question: "can this machine run the pipeline completely offline,
#  and with which backends?"  Changes nothing. Needs no network, no sudo.
#
#      bash scripts/s2s_doctor.sh
# ─────────────────────────────────────────────────────────────────────────────

HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
TORCH_HUB="${TORCH_HOME:-$HOME/.cache/torch}/hub"
PASS=0; FAIL=0; WARN=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'
else
    G=; R=; Y=; B=; D=; Z=
fi

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$Z" "$1"; }
info() { printf '        %s%s%s\n' "$D" "$1" "$Z"; }

# Ignore Hugging Face's .no_exist sentinels: they stand for absent files.
find_first() { find "$1" ! -path '*/.no_exist/*' "${@:2}" 2>/dev/null | head -1 || true; }

printf '\n%sSPEECH-TO-SPEECH  ·  offline readiness report%s\n' "$B" "$Z"
printf '%s%s%s\n' "$D" "$(date)" "$Z"

echo
echo "${B}1. Required models (Hugging Face cache)${Z}"
PARAKEET="$(find_first "$HF_CACHE" -name '*.nemo' -path '*parakeet*')"
if [ -n "$PARAKEET" ]; then ok "Parakeet STT: $(basename "$PARAKEET")"
    info "$(dirname "$PARAKEET")"
else bad "Parakeet STT (.nemo) not in $HF_CACHE — the repo cannot run offline without it"; fi

LLM="$(find_first "$HF_CACHE" -name '*.safetensors' -path '*Qwen3-4B*')"
if [ -n "$LLM" ]; then ok "LLM Qwen3-4B-Instruct-2507 present"
    info "$(dirname "$LLM" | sed "s#$HF_CACHE/##" | cut -d/ -f1)"
else bad "Qwen3-4B-Instruct-2507 not found in HF cache"; fi

TTS="$(find_first "$HF_CACHE" -name '*.safetensors' -path '*Qwen3-TTS*')"
if [ -n "$TTS" ]; then ok "TTS Qwen3-TTS-12Hz-1.7B present"
    info "$(dirname "$TTS" | sed "s#$HF_CACHE/##" | cut -d/ -f1)"
else bad "Qwen3-TTS-12Hz-1.7B not found in HF cache"; fi

echo
echo "${B}2. Voice activity detection (silero)${Z}"
JIT="${SILERO_VAD_PATH:-}"
[ -n "$JIT" ] && [ -f "$JIT" ] || JIT="$(find_first "$TORCH_HUB" -name 'silero_vad.jit')"
if [ -n "$JIT" ] && [ -f "$JIT" ]; then ok "local checkpoint found — no GitHub call needed"
    info "$JIT"
else warn "no local silero_vad.jit — first run will download it from GitHub"; fi

echo
echo "${B}3. NLTK data (startup should not need the internet)${Z}"
NLTK_HIT=""
for d in "${NLTK_DATA:-}" "$HOME/nltk_data" /usr/share/nltk_data /usr/local/share/nltk_data; do
    [ -n "$d" ] || continue
    if [ -e "$d/tokenizers/punkt_tab" ] || [ -e "$d/tokenizers/punkt_tab.zip" ]; then NLTK_HIT="$d"; break; fi
done
if [ -n "$NLTK_HIT" ]; then ok "punkt_tab present"
    info "$NLTK_HIT"
else warn "punkt_tab missing — startup would try to download it"; fi
TAGGER=""
for d in "${NLTK_DATA:-}" "$HOME/nltk_data" /usr/share/nltk_data /usr/local/share/nltk_data; do
    [ -n "$d" ] || continue
    if [ -e "$d/taggers/averaged_perceptron_tagger_eng" ] || [ -e "$d/taggers/averaged_perceptron_tagger_eng.zip" ]; then TAGGER="$d"; break; fi
done
if [ -n "$TAGGER" ]; then ok "perceptron tagger present in NLTK's taggers/ folder"
else warn "tagger missing — harmless with the patched pipeline, noisy without it"; fi

echo
echo "${B}4. GGUF / GGML text-to-speech (optional, lower VRAM)${Z}"
GGUF_DIR="${S2S_TTS_GGUF_DIR:-$HOME/gemma-avatar/models/qwen3-tts-gguf}"
TALKER="$(find_first "$GGUF_DIR" -name '*talker*.gguf')"
CODEC="$(find_first "$GGUF_DIR" -name '*tokenizer*.gguf')"
if [ -n "$TALKER" ] && [ -n "$CODEC" ]; then
    ok "GGUF TTS weights found — start with S2S_TTS_BACKEND=ggml"
    info "$(du -h "$TALKER" 2>/dev/null | awk '{print $1}')  $(basename "$TALKER")"
    info "$(du -h "$CODEC" 2>/dev/null | awk '{print $1}')  $(basename "$CODEC")"
else
    warn "no GGUF talker+tokenizer pair under $GGUF_DIR (torch backend still available)"
fi
LIBHIT="$(find "$HOME" -maxdepth 6 -name 'libqwen*' -o -maxdepth 6 -type d -name 'qwentts_cpp' 2>/dev/null | head -1 || true)"
if [ -n "$LIBHIT" ]; then ok "qwentts.cpp runtime present"
    info "$LIBHIT"
else warn "qwentts_cpp not found — needed only for the ggml backend"; fi

echo
echo "${B}5. Python environments holding the pipeline${Z}"
FOUND_CORE_VENV=0
while IFS= read -r cfg; do
    v="$(dirname "$cfg")"
    # Normalize distribution names: packaging allows underscores, dots, and
    # hyphens interchangeably (e.g. nano_parakeet == nano-parakeet).
    pkgs=$(find "$v/lib" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | sed 's#.*/##; s/\.dist-info$//; s/[_\.]/-/g' | tr '[:upper:]' '[:lower:]')
    cli="no"; printf '%s\n' "$pkgs" | grep -q '^speech-to-speech' && cli="yes"
    fa=$(printf '%s\n' "$pkgs" | grep -c '^faster-qwen3-tts' || true)
    np=$(printf '%s\n' "$pkgs" | grep -c '^nano-parakeet' || true)
    tp=$(printf '%s\n' "$pkgs" | grep -c '^torch-' || true)
    tr=$(printf '%s\n' "$pkgs" | grep -c '^transformers-' || true)
    printf '  %s%s%s\n' "$B" "$v" "$Z"
    info "console package: $cli   nano-parakeet: $([ "$np" -gt 0 ] && echo yes || echo NO)   faster-qwen3-tts: $([ "$fa" -gt 0 ] && echo yes || echo NO)   torch: $([ "$tp" -gt 0 ] && echo yes || echo NO)   transformers: $([ "$tr" -gt 0 ] && echo yes || echo NO)"
    [ "$tp" -gt 0 ] && [ "$tr" -gt 0 ] && FOUND_CORE_VENV=1
done < <(find "$HOME" -maxdepth 4 -name pyvenv.cfg 2>/dev/null | head -12)
[ "$FOUND_CORE_VENV" = 1 ] || bad "no venv with both torch and transformers found under $HOME (maxdepth 4)"
info "start-server.sh runs this checkout's Python source; an installed console command is optional"

echo
echo "${B}6. Hardware${Z}"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | while IFS= read -r l; do ok "GPU: $l"; done
    BF16=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    info "bf16 is recommended for this card (start-server.sh uses it by default)"
else warn "nvidia-smi not found — CUDA will not be available"; fi

echo
echo "${B}7. Other runtimes worth knowing about${Z}"
command -v ollama >/dev/null 2>&1 && ok "ollama: $(command -v ollama)" || info "ollama not installed in WSL"
[ -d /mnt/c/Users/*/.ollama/models ] 2>/dev/null && info "Windows-side ollama store visible at /mnt/c/Users/<you>/.ollama/models"
command -v ffmpeg >/dev/null 2>&1 && ok "ffmpeg present" || warn "ffmpeg missing"

echo
printf '%s────────────────────────────────────────────%s\n' "$D" "$Z"
printf '  %s%d passed%s   %s%d warnings%s   %s%d failed%s\n' "$G" "$PASS" "$Z" "$Y" "$WARN" "$Z" "$R" "$FAIL" "$Z"
echo
if [ "$FAIL" -eq 0 ]; then
    printf '  %sFully offline-ready.%s  Start UI + backend together:  ./start.sh\n' "$G$B" "$Z"
else
    printf '  %sMissing pieces above must be resolved before a fully offline run.%s\n' "$R$B" "$Z"
fi
echo
echo "  Notes:"
echo "    • ./start.sh launches both the local browser UI and backend in one terminal."
echo "    • the launcher blocks downloads by default and stops if an offline asset is missing."
echo "    • explicitly allow downloads with: S2S_ONLINE=1 ./start.sh"
echo "    • standalone backend only:         ./start-server.sh"
echo
