#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  s2s_inventory.sh  —  READ-ONLY inventory of what this machine already has
#                        that the speech-to-speech pipeline can use.
#
#  Writes nothing except a report file. Never installs, never downloads,
#  never touches the network. Safe to run as a normal user, no sudo needed.
#
#  Usage:
#      bash scripts/s2s_inventory.sh                 # full scan
#      S2S_QUICK=1 bash scripts/s2s_inventory.sh     # skip the big file scan
#      S2S_SCAN_ROOTS="/home /mnt/bigdisk" bash scripts/s2s_inventory.sh
#
#  Report: $S2S_INVENTORY_OUT, else ~/s2s-inventory-YYYYmmdd-HHMM.txt
# ─────────────────────────────────────────────────────────────────────────────

REPORT="${S2S_INVENTORY_OUT:-$HOME/s2s-inventory-$(date +%Y%m%d-%H%M).txt}"
QUICK="${S2S_QUICK:-0}"
MIN_MB="${S2S_MIN_MB:-100}"
MAX_LIST="${S2S_MAX_LIST:-400}"

exec > >(tee "$REPORT") 2>&1

sec() { printf '\n\n===== %s =====\n' "$1"; }
sub() { printf '\n--- %s ---\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
size_of() { if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1" 2>/dev/null; fi; }
human() { # bytes -> human
    local b="${1:-0}"
    if [ "$b" -ge 1073741824 ] 2>/dev/null; then echo "$((b / 1073741824))G"
    elif [ "$b" -ge 1048576 ] 2>/dev/null; then echo "$((b / 1048576))M"
    elif [ "$b" -ge 1024 ] 2>/dev/null; then echo "$((b / 1024))K"
    else echo "${b}B"; fi
}
dusize() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------- 0. header
sec "HEADER"
echo "report:       $REPORT"
echo "generated:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')  (local: $(date))"
echo "host:         $(hostname 2>/dev/null)"
echo "user:         $(whoami 2>/dev/null)"
echo "kernel/os:    $(uname -srm)"
[ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release
echo "quick mode:   $QUICK (1 = big file scan skipped)"
echo "min size:     ${MIN_MB}MB"

# ------------------------------------------------------------ 1. hardware
sec "HARDWARE"
sub "CPU / RAM"
if [ "$(uname -s)" = "Darwin" ]; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null
    echo "cores:      $(sysctl -n hw.ncpu 2>/dev/null)"
    echo "mem bytes:  $(sysctl -n hw.memsize 2>/dev/null)"
    sysctl -n hw.model 2>/dev/null
else
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-
    echo "cores:      $(nproc 2>/dev/null)"
    awk '/MemTotal|MemAvailable|SwapTotal/ {printf "%s %.1f GiB\n", $1, $2/1048576}' /proc/meminfo 2>/dev/null
fi

sub "GPU"
if have nvidia-smi; then
    nvidia-smi --query-gpu=index,name,memory.total,driver_version,compute_cap --format=csv 2>/dev/null
    echo "driver/cuda: $(nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9.]*' | head -1)"
    echo "processes on GPU:"; nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null | head -12
elif have rocm-smi; then
    rocm-smi --showproductname --showmeminfo vram 2>/dev/null | head -20
elif [ "$(uname -s)" = "Darwin" ]; then
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|VRAM|Metal|Total Number of Cores' | head
else
    echo "no nvidia-smi / rocm-smi found"
fi
echo "nvcc:        $(nvcc --version 2>/dev/null | grep -o 'release [0-9.]*' | head -1 || echo none)"
echo "cudnn/libs:  $(ldconfig -p 2>/dev/null | grep -c 'libcudnn\|libcublas') libs in ldconfig (Linux only)"
echo "tensorrt:    $(find /usr /opt /usr/local -maxdepth 4 -iname 'nvinfer*.so*' 2>/dev/null | head -3 | tr '\n' ' ')"

# ------------------------------------------------------------ 2. storage
sec "STORAGE / MOUNTS"
df -hP 2>/dev/null | grep -v -E 'tmpfs|devtmpfs|overlay|squashfs' | head -25

# --------------------------------------------------- 3. big model-ish files
mount_points() {
    if [ -n "${S2S_SCAN_ROOTS:-}" ]; then printf '%s\n' $S2S_SCAN_ROOTS; return; fi
    df -P 2>/dev/null | tail -n +2 | awk '{print $6}' | grep -v -E \
        '^/(proc|sys|dev|run|snap|boot|System/Volumes|private/var/vm|var/lib/docker|var/lib/kubelet)' | sort -u
}

sec "MODEL FILES (>${MIN_MB}MB) BY MOUNT"
if [ "$QUICK" = "1" ]; then
    echo "skipped (S2S_QUICK=1)"
else
    TMPF="${TMPDIR:-/tmp}/s2s_files.$$"; : > "$TMPF"
    for mp in $(mount_points); do
        [ -d "$mp" ] || continue
        [ -r "$mp" ] || continue
        echo "scanning mount: $mp"
        find "$mp" -xdev -type f -size +${MIN_MB}M \( \
              -iname '*.safetensors' -o -iname '*.gguf' -o -iname '*.nemo' -o -iname '*.bin' \
              -o -iname '*.pt' -o -iname '*.pth' -o -iname '*.onnx' -o -iname '*.ort' \
              -o -iname '*.engine' -o -iname '*.plan' -o -iname '*.msgpack' -o -iname '*.tflite' \
              -o -iname '*.mlpackage' -o -iname '*.ckpt' -o -iname '*.h5' -o -iname '*.npz' \
              -o -iname '*.jit' -o -iname '*.pt2' -o -iname '*.cb' -o -iname '*.nef' \
              -o -iname '*.mlmodel' -o -iname '*.mlmodelc' -o -iname '*.coreml' \
            \) 2>/dev/null | while IFS= read -r f; do
            printf '%s\t%s\n' "$(size_of "$f")" "$f"
        done >> "$TMPF"
    done
    if [ -s "$TMPF" ]; then
        echo "total matching files: $(wc -l < "$TMPF" | tr -d ' ')"
        echo "largest ${MAX_LIST}:"
        sort -rn "$TMPF" | head -n "$MAX_LIST" | while IFS="$(printf '\t')" read -r sz p; do
            printf '%8s  %s\n' "$(human "$sz")" "$p"
        done
    else
        echo "none found"
    fi
    rm -f "$TMPF"
fi

# ------------------------------------------------- 4. named model dirs/files
sec "MODEL-NAMED DIRECTORIES"
TMPD="${TMPDIR:-/tmp}/s2s_dirs.$$"; : > "$TMPD"
for mp in $(mount_points); do
    [ -d "$mp" ] && [ -r "$mp" ] || continue
    find "$mp" -xdev -type d \( \
          -iname '*parakeet*' -o -iname '*silero*' -o -iname '*whisper*' -o -iname '*qwen*' \
          -o -iname '*kokoro*' -o -iname '*kokoro*' -o -iname '*piper*' -o -iname '*chattts*' \
          -o -iname '*melo*' -o -iname '*paraformer*' -o -iname '*sensevoice*' -o -iname '*funasr*' \
          -o -iname '*gemma*' -o -iname '*llama*' -o -iname '*mistral*' -o -iname '*phi-*' \
          -o -iname '*deepfilter*' -o -iname '*sepformer*' -o -iname '*mossformer*' \
          -o -iname '*cosyvoice*' -o -iname '*f5-tts*' -o -iname '*orpheus*' -o -iname '*dia-*' \
          -o -iname '*vibevoice*' -o -iname '*mms-tts*' -o -iname '*xtts*' -o -iname '*bark*' \
          -o -iname '*espeak*' -o -iname '*nemo*' -o -iname '*parler*' -o -iname '*moonshine*' \
          -o -iname '*wav2vec*' -o -iname '*whisper.cpp*' -o -iname '*ctranslate*' \
          -o -iname '*sherpa*' -o -iname '*onnxruntime*' -o -iname '*tensorrt*' -o -iname '*mlx*' \
        \) 2>/dev/null | while IFS= read -r d; do
        printf '%s\t%s\n' "$(dusize "$d")" "$d"
    done >> "$TMPD"
done
if [ -s "$TMPD" ]; then
    echo "total: $(wc -l < "$TMPD" | tr -d ' ')"
    head -n "$MAX_LIST" "$TMPD"
else
    echo "none found"
fi
rm -f "$TMPD"

# ---------------------------------------------------------- 5. HF caches
sec "HUGGINGFACE CACHES"
sub "env vars"
env | grep -E '^(HF_|HUGGINGFACE|TRANSFORMERS|TORCH_HOME|XDG_CACHE_HOME|MODELSCOPE|OLLAMA|LM_STUDIO)' | sort
echo "(env not set is normal — checked again in shell rc files below)"

CACHES=""
for c in "${HF_HOME:-}/hub" "${HF_HUB_CACHE:-}" "${TRANSFORMERS_CACHE:-}" \
         "$HOME/.cache/huggingface/hub" "$HOME/.cache/huggingface" \
         "$HOME/.cache/modelscope/hub" "$HOME/.cache/modelscope" ; do
    [ -n "$c" ] && [ -d "$c" ] && CACHES="$CACHES $c"
done
for mp in $(mount_points); do
    for extra in "$mp/huggingface" "$mp/hf" "$mp/models/huggingface"; do
        [ -d "$extra" ] && CACHES="$CACHES $extra"
    done
done
CACHES=$(printf '%s\n' $CACHES | sort -u)

if [ -z "$CACHES" ]; then
    echo "no HF/modelscope cache directories found"
else
    for c in $CACHES; do
        sub "$c  (total $(dusize "$c"))"
        for repo in "$c"/models--* "$c"/datasets--*; do
            [ -e "$repo" ] || continue
            printf '  %8s  %s\n' "$(dusize "$repo")" "${repo##*/}"
        done
        # parakeet's .nemo lives inside a snapshot dir — repo's STT needs exactly this
        sub "snapshot files under $c (top level of each revision)"
        find "$c" -xdev -maxdepth 4 -path '*/snapshots/*' -type f 2>/dev/null | head -60
        find "$c" -xdev -type l 2>/dev/null | wc -l | awk '{print "  symlinked files (blob pointers): "$1}'
        find "$c" -xdev -name '*.incomplete' -o -name '*.lock' 2>/dev/null | head -10 | sed 's/^/  incomplete: /'
        find "$c" -xdev -name '*.nemo' 2>/dev/null | sed 's/^/  NEMO: /'
    done
fi

# ---------------------------------------------------------- 6. local runtimes
sec "LOCAL INFERENCE RUNTIMES"
sub "binaries on PATH"
for b in ollama llama-server llama-cli llama-bench main lms lmstudio vllm whisper-cli whisper-server \
         faster-whisper-xxl parakeet sherpa-onnx-offline sherpa-onnx-tts piper espeak-ng sox ffmpeg \
         hf huggingface-cli git-lfs aria2c nvtop cmake ninja gcc g++ nvcc trtexec; do
    p=$(command -v "$b" 2>/dev/null) && printf '  %-22s %s\n' "$b" "$p"
done
have ollama && { echo "ollama version: $(ollama --version 2>&1 | head -2)"; }
sub "candidate install roots"
for d in /opt/llama.cpp /opt/whisper.cpp /usr/local/bin "$HOME/llama.cpp" "$HOME/whisper.cpp" \
         "$HOME/.local/bin" /opt/nvidia /usr/local/cuda /opt/rocm "$HOME/vllm" /opt/vllm \
         "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3"; do
    [ -d "$d" ] && printf '  yes  %s\n' "$d"
done

sub "ollama models"
[ -d "$HOME/.ollama/models" ] && { echo "size: $(dusize "$HOME/.ollama/models")"; ls "$HOME/.ollama/models" 2>/dev/null; find "$HOME/.ollama/models/manifests" -maxdepth 3 -type f 2>/dev/null | sed 's#.*/manifests/##' | head -40; }

sub "LM Studio models"
for d in "$HOME/.lmstudio/models" "$HOME/.cache/lm-studio/models" "$HOME/.local/share/nomic.ai/GPT4All"; do
    [ -d "$d" ] && { echo "== $d ($(dusize "$d"))"; find "$d" -maxdepth 4 -type f \( -iname '*.gguf' -o -iname '*.safetensors' -o -iname '*.mlx*' \) 2>/dev/null | head -40; }
done

sub "llama.cpp / gguf caches"
for d in "$HOME/.cache/llama.cpp" "$HOME/.cache/gguf" "$HOME/.cache/huggingface/gguf" "$HOME/.cache/whisper.cpp"; do
    [ -d "$d" ] && { echo "== $d ($(dusize "$d"))"; ls -la "$d" 2>/dev/null | head -20; }
done

# ---------------------------------------------------------- 7. torch hub / VAD
sec "TORCH HUB (silero VAD lives here)"
for d in "${TORCH_HOME:-}/hub" "$HOME/.cache/torch/hub" "$HOME/.torch/hub" "/opt/torch/hub"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    echo "== $d ($(dusize "$d"))"
    ls -la "$d" 2>/dev/null | head -20
    find "$d" -maxdepth 3 -iname '*silero*' 2>/dev/null | sed 's/^/  SILERO: /'
    find "$d" -maxdepth 4 \( -iname '*.jit' -o -iname '*.pt' \) 2>/dev/null | sed 's/^/  jit/pt: /'
done

# ---------------------------------------------------------- 8. nltk corpora
sec "NLTK DATA (pipeline calls nltk.download() on startup if missing)"
NLTK_CAND="$HOME/nltk_data /usr/share/nltk_data /usr/local/share/nltk_data /usr/lib/nltk_data /usr/local/lib/nltk_data"
[ -n "${NLTK_DATA:-}" ] && NLTK_CAND="$NLTK_DATA $NLTK_CAND"
for d in $NLTK_CAND; do
    [ -d "$d" ] || continue
    echo "== $d ($(dusize "$d"))"
    for t in tokenizers/punkt_tab tokenizers/punkt taggers/averaged_perceptron_tagger_eng; do
        if [ -e "$d/$t" ]; then echo "  FOUND    $t"; else echo "  missing  $t"; fi
    done
done
[ -z "$(printf '%s\n' $NLTK_CAND | while read -r d; do [ -d "$d" ] && echo x; done)" ] && echo "no nltk_data dirs found at all -> startup WILL try to download punkt_tab"

# ---------------------------------------------------- 9. python environments
sec "PYTHON ENVIRONMENTS & KEY PACKAGES"
KEYPKGS='torch|torchaudio|transformers|nano-parakeet|faster-qwen3-tts|qwen-tts|mlx|mlx-lm|mlx-audio|kokoro|misaki|faster-whisper|funasr|modelscope|bitsandbytes|torchao|flash-attn|flash_attn|xformers|vllm|onnxruntime|onnxruntime-gpu|tensorrt|torch-tensorrt|nemo|nemo_toolkit|lightning-whisper-mlx|pocket-tts|df|deepfilternet|sounddevice|websockets|fastapi|nltk|spacy|phonemizer|espeakng|lingua|openai'
for root in "$HOME" /opt /srv /usr/local /media /mnt; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 4 -name 'pyvenv.cfg' 2>/dev/null | while IFS= read -r cfg; do
        venv=$(dirname "$cfg")
        echo "== $venv"
        grep -i -E 'version|executable' "$cfg" 2>/dev/null | sed 's/^/   /'
        sp="$venv/lib"
        found=$(find "$sp" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | sed 's#.*/##; s/\.dist-info$//' | grep -E -i "^($KEYPKGS)" | sort -u | tr '\n' ' ')
        [ -n "$found" ] && echo "   pkgs: $found"
        [ -e "$venv/bin/speech-to-speech" ] && echo "   >>> this venv has the speech-to-speech CLI <<<"
        find "$sp" -maxdepth 3 -name 'speech_to_speech*' -o -maxdepth 3 -name 'speech_to_speech*.dist-info' 2>/dev/null | head -3 | sed 's/^/   repo pkg: /'
        find "$sp" -maxdepth 3 -name 'ggml*qwen*' -o -maxdepth 3 -name 'qwentts*' -o -maxdepth 3 -name 'libqwen*' 2>/dev/null | head -3 | sed 's/^/   qwentts.cpp: /'
    done
done
sub "system pythons"
for py in python3 python3.10 python3.11 python3.12 python3.13; do
    have "$py" && printf '  %-10s %s\n' "$py" "$($py -V 2>&1)"
done
sub "conda envs (if any)"
for c in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "$HOME/miniforge3/bin/conda"; do
    [ -x "$c" ] && "$c" env list 2>/dev/null | head -20
done

# ---------------------------------------------------- 10. this repo checkouts
sec "SPEECH-TO-SPEECH CHECKOUTS ON DISK"
find "$HOME" /opt /srv -maxdepth 4 -type d -name 'speech-to-speech*' 2>/dev/null | while IFS= read -r d; do
    echo "== $d"
    [ -d "$d/.git" ] && git -C "$d" log -1 --format='   head: %h %ad %s' --date=short 2>/dev/null
    ls "$d" 2>/dev/null | tr '\n' ' ' | sed 's/^/   files: /'; echo
    [ -d "$d/.venv" ] && echo "   .venv: $(dusize "$d/.venv")"
    for localdir in models cache models_cache; do
        [ -d "$d/$localdir" ] && echo "   $localdir/: $(dusize "$d/$localdir")"
    done
done

# ---------------------------------------------------- 11. shell config / env
sec "SHELL CONFIG & ENV OVERRIDES"
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.config/environment.d"/*.conf; do
    [ -f "$rc" ] || continue
    hits=$(grep -n -E 'HF_|HUGGINGFACE|TRANSFORMERS|TORCH_HOME|MODELSCOPE|OLLAMA|CUDA_VISIBLE|PATH=' "$rc" 2>/dev/null | head -15)
    [ -n "$hits" ] && { echo "== $rc"; printf '%s\n' "$hits" | sed 's/^/   /'; }
done

# ---------------------------------------------------- 12. repo-relevant summary
sec "SUMMARY MATCHERS (what the pipeline can use immediately)"
summ() { n=$(grep -c "$2" "$3" 2>/dev/null); printf '  %-42s %s\n' "$1" "${n:-0}"; }
ALL="${TMPDIR:-/tmp}/s2s_all.$$"
{
    [ "$QUICK" = "1" ] || : # big-file list already consumed above
    find "$HOME" /opt /srv -maxdepth 5 -type f \( -iname '*.nemo' -o -iname '*.gguf' -o -iname '*.jit' \
        -o -iname '*.onnx' -o -iname '*.safetensors' -o -iname 'model.bin' \) 2>/dev/null
} > "$ALL"
summ "parakeet (.nemo / dirs)"        'parakeet'   "$ALL"
summ "silero vad (jit)"               'silero'     "$ALL"
summ "whisper (ct2/faster/gguf)"      'whisper'    "$ALL"
summ "qwen llm/tts (gguf/safetensors)" 'wen'       "$ALL"
summ "kokoro tts"                     'kokoro'     "$ALL"
summ "piper voices"                   'piper'      "$ALL"
summ "llama/gguf family"              'llama'      "$ALL"
summ "gemma"                          'gemma'      "$ALL"
summ "onnx (any)"                     '\.onnx'     "$ALL"
summ "gguf (any)"                     '\.gguf'     "$ALL"
rm -f "$ALL"

sec "DONE"
echo "report saved to: $REPORT"
echo "paste it back (or attach the file) — it contains no secrets, only paths/sizes."
