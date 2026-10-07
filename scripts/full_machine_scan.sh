#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  full_machine_scan.sh
#
#  Sweeps the ENTIRE machine (not just your project folder) for model files,
#  model runtimes, caches, and environments — especially things you forgot
#  you had.
#
#  * READ-ONLY. It changes nothing, installs nothing, deletes nothing.
#  * No sudo needed. No network needed.
#  * Writes exactly one file:  ~/s2s-machine-report.txt
#
#  Usage:   bash full_machine_scan.sh
#  Faster:  S2S_ROOTS="$HOME /mnt" bash full_machine_scan.sh
# ─────────────────────────────────────────────────────────────────────────────

OUT="${S2S_REPORT:-$HOME/s2s-machine-report.txt}"
ROOTS="${S2S_ROOTS:-/}"
MAXLIST="${S2S_MAX_LIST:-300}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/s2sscan.XXXXXX")"
IS_GNU_FIND=0
find --version 2>/dev/null | grep -q GNU && IS_GNU_FIND=1
IS_MAC=0
[ "$(uname -s)" = "Darwin" ] && IS_MAC=1
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

log() { printf '%s\n' "$*"; }

# Directories we never want to walk into (OS noise + container layers).
PRUNE_DIRS=(/proc /sys /dev /run /snap /var/lib/docker /var/lib/containerd
            /System/Volumes /private/var/vm)
WIN_NOISE=('*/Windows' '*/Program Files' '*/Program Files (x86)'
           '*/$Recycle.Bin' '*/System Volume Information' '*/.Trash*')
NAME_NOISE=('*/node_modules' '*/.git' '*/__pycache__')

# Build a proper find prune expression as an array (no quoting games).
PRUNE=()
for p in "${PRUNE_DIRS[@]}" "${WIN_NOISE[@]}"; do
    PRUNE+=( -path "$p" -prune -o )
done
PRUNE_NAME=("${PRUNE[@]}")
for p in "${NAME_NOISE[@]}"; do
    PRUNE_NAME+=( -path "$p" -prune -o )
done

size_of() { if [ "$IS_MAC" = 1 ]; then stat -f%z "$1" 2>/dev/null; else stat -c%s "$1" 2>/dev/null; fi; }
human() {
    awk -v b="${1:-0}" 'BEGIN{ if(b>=1073741824) printf "%.1f GB", b/1073741824;
                              else if(b>=1048576) printf "%.0f MB", b/1048576;
                              else if(b>=1024) printf "%.0f KB", b/1024; else printf "%d B", b }'
}
dusize() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
TAB="$(printf '\t')"

WEIGHT_EXTS=( '*.gguf' '*.nemo' '*.safetensors' '*.onnx' '*.ort' '*.engine' '*.plan'
              '*.mlmodel' '*.mlmodelc' '*.mlpackage' '*.ckpt' '*.h5' '*.tflite'
              '*.msgpack' '*.npz' 'silero_vad*.jit' '*.pt' '*.pth' '*.bin' )
WEIGHT_ARGS=()
for e in "${WEIGHT_EXTS[@]}"; do WEIGHT_ARGS+=( -o -iname "$e" ); done
WEIGHT_ARGS=( "${WEIGHT_ARGS[@]:1}" )   # drop the leading -o

NAME_PATTERNS=( '*parakeet*' '*silero*' '*whisper*' '*qwen*' '*kokoro*' '*piper*' '*vits*'
                '*melo*' '*chattts*' '*sensevoice*' '*paraformer*' '*funasr*' '*llama*'
                '*gemma*' '*mistral*' '*phi-*' '*moonshine*' '*cosyvoice*' '*xtts*' '*bark*'
                '*mms-tts*' '*espeak*' '*nemo*' '*ctranslate*' '*sherpa*' '*whisper.cpp*'
                '*ollama*' '*lmstudio*' '*mlx*' '*gguf*' '*comfyui*' '*stable-diffusion*'
                '*models' '*checkpoints*' '*hf_cache*' '*.cache' )
NAME_ARGS=()
for p in "${NAME_PATTERNS[@]}"; do NAME_ARGS+=( -o -iname "$p" ); done
NAME_ARGS=( "${NAME_ARGS[@]:1}" )

# ─────────────────────────────────────────────────────────────
log "Starting full-machine scan (read-only). This can take a few minutes..."
log "Drives being scanned:"
for r in $ROOTS; do log "    $r"; done
log ""

{
echo "=================================================================="
echo " FULL MACHINE MODEL / RUNTIME INVENTORY"
echo "=================================================================="
echo "generated : $(date)"
echo "host      : $(hostname 2>/dev/null)"
echo "user      : $(whoami 2>/dev/null)"
echo "os/kernel : $(uname -srm)"
echo "wsl       : $([ "$IS_WSL" = 1 ] && echo yes || echo no)"
[ -r /etc/os-release ] && grep -E '^PRETTY_NAME=' /etc/os-release

echo
echo "===== 1. MACHINE / GPU ====="
if [ "$IS_MAC" = 1 ]; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null
    echo "cores: $(sysctl -n hw.ncpu 2>/dev/null)   mem: $(( $(sysctl -n hw.memsize 2>/dev/null) / 1073741824 )) GiB"
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|VRAM|Total Number of Cores' | head -6
else
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-
    echo "cores: $(nproc 2>/dev/null)   mem: $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null)"
fi
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv 2>/dev/null
    nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9.]*' | head -1
elif command -v rocm-smi >/dev/null 2>&1; then
    rocm-smi --showproductname 2>/dev/null | head -6
fi

echo
echo "===== 2. DRIVES / MOUNTS ====="
df -hP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|overlay|squashfs|none)' | head -30

echo
echo "===== 3. ALL WEIGHT-LIKE FILES EVERYWHERE ====="
: > "$TMP/weights"
for r in $ROOTS; do
    [ -d "$r" ] || continue
    if [ "$IS_GNU_FIND" = 1 ]; then
        find "$r" "${PRUNE[@]}" -type f \( "${WEIGHT_ARGS[@]}" \) \
            -printf '%s\t%p\n' 2>/dev/null >> "$TMP/weights"
    else
        find "$r" "${PRUNE[@]}" -type f \( "${WEIGHT_ARGS[@]}" \) -print 2>/dev/null \
            | while IFS= read -r f; do printf '%s\t%s\n' "$(size_of "$f")" "$f"; done >> "$TMP/weights"
    fi
done
echo "total weight-like files found: $(wc -l < "$TMP/weights" | tr -d ' ')"
echo "-- biggest $MAXLIST (anything silently big is what you forgot you had):"
sort -rn "$TMP/weights" 2>/dev/null | head -n "$MAXLIST" | while IFS="$TAB" read -r sz p; do
    printf '%10s  %s\n' "$(human "$sz")" "$p"
done
echo "-- counts by extension:"
awk -F'\t' '{n=$2; sub(/.*\./,"",n); print tolower(n)}' "$TMP/weights" 2>/dev/null | sort | uniq -c | sort -rn | head -20

echo
echo "===== 4. TORCH HUB (silero VAD lives here) ====="
for d in "${TORCH_HOME:-}" "$HOME/.cache/torch" "$HOME/.torch"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    echo "-- $d ($(dusize "$d"))"
    find "$d" -maxdepth 4 \( -iname '*silero*' -o -iname '*.jit' -o -iname '*.pt' \) 2>/dev/null | head -20
done

echo
echo "===== 5. HUGGINGFACE / MODELSCOPE / OTHER CACHES ====="
for d in "${HF_HOME:-}" "${HUGGINGFACE_HUB_CACHE:-}" "$HOME/.cache/huggingface" \
         "$HOME/.cache/modelscope" "$HOME/.cache/huggingface/gguf" "$HOME/.cache/whisper" \
         "$HOME/.cache/llama.cpp" "$HOME/.cache/piper" "$HOME/.cache/kokoro" ; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    echo "-- $d ($(dusize "$d"))"
    ls "$d/hub" 2>/dev/null | grep -E '^(models|datasets)--' | head -80
    ls "$d" 2>/dev/null | grep -E '^(models|datasets)--' | head -80
    find "$d" -maxdepth 6 -name '*.nemo' 2>/dev/null | head -5 | sed 's/^/   NEMO: /'
done
echo "-- HF-style model caches found anywhere on the scanned drives:"
for r in $ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 6 -type d -name 'models--*' 2>/dev/null | sed 's#/models--[^/]*$##' | sort -u | head -20
done

echo
echo "===== 6. LOCAL MODEL RUNNERS (binaries + their model stores) ====="
for b in ollama llama-server llama-cli llama-bench main lms vllm whisper-cli whisper-server \
         whisper.cpp faster-whisper-xxl sherpa-onnx-offline piper espeak-ng hf huggingface-cli \
         docker podman conda micromamba python3 nvcc cmake nvtop ffmpeg; do
    p=$(command -v "$b" 2>/dev/null) && printf '  %-22s %s\n' "$b" "$p"
done
[ -d "$HOME/.ollama/models" ] && {
    echo "-- ollama store: $(dusize "$HOME/.ollama/models")"
    find "$HOME/.ollama/models/manifests" -type f 2>/dev/null | sed 's#.*/manifests/##' | head -40
}
for d in "$HOME/.lmstudio/models" "$HOME/.cache/lm-studio/models" "$HOME/.local/share/nomic.ai" \
         "$HOME/.cache/gpt4all" "$HOME/.cache/jan" "$HOME/sillytavern" "$HOME/.cache/text-generation-webui" ; do
    [ -d "$d" ] && { echo "-- $d ($(dusize "$d"))"; find "$d" -maxdepth 5 -type f \( -iname '*.gguf' -o -iname '*.safetensors' -o -iname '*.bin' \) 2>/dev/null | head -30; }
done
if command -v docker >/dev/null 2>&1; then
    echo "-- docker images (models sometimes live inside images):"
    docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | head -25
fi

echo
echo "===== 6b. WINDOWS SIDE, SEEN FROM WSL (/mnt/*) ====="
if [ -d /mnt ] && ls /mnt >/dev/null 2>&1; then
    echo "-- mounts present under /mnt:"
    ls -1 /mnt 2>/dev/null | sed 's/^/   /'
    for win in /mnt/[a-z]; do
        [ -d "$win/Users" ] || continue
        for prof in "$win"/Users/*; do
            [ -d "$prof" ] || continue
            case "${prof##*/}" in Public|Default|"All Users"|"Default User") continue;; esac
            found=""
            for rel in .ollama/models .lmstudio/models .cache/lm-studio/models \
                       .cache/huggingface/hub .cache/whisper .cache/piper \
                       AppData/Local/nomic.ai AppData/Roaming/nomic.ai AppData/Local/Jan \
                       .cache/text-generation-webui ComfyUI comfy ComfyUI_windows_portable \
                       stable-diffusion-webui Documents/ComfyUI; do
                [ -e "$prof/$rel" ] && found="$found $rel"
            done
            [ -n "$found" ] && {
                echo "-- Windows profile: $prof"
                for rel in $found; do
                    echo "   [$(dusize "$prof/$rel")] $rel"
                done
            }
        done
        # model-ish dirs directly on the Windows drive root / common spots
        for d in "$win/models" "$win/AI" "$win/ComfyUI" "$win/ComfyUI_windows_portable"; do
            [ -d "$d" ] && echo "-- [$(dusize "$d")] $d"
        done
    done
else
    echo "not inside WSL (no /mnt) - skipping"
fi

echo
echo "===== 6c. THIS PROJECT'S OWN FOLDERS (every copy on disk) ====="
for r in $ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 6 -type d -name 'speech-to-speech*' 2>/dev/null | head -20 | while IFS= read -r d; do
        echo "== $d"
        for sub in .venv models cache models_cache hf_cache; do
            [ -d "$d/$sub" ] && echo "   [$(dusize "$d/$sub")] $sub/"
        done
        find "$d" -maxdepth 2 -type d -name '*.egg-info' 2>/dev/null | head -2 | sed 's/^/   pkg: /'
        [ -d "$d/.venv" ] && {
            pkgs=$(find "$d/.venv/lib" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | sed 's#.*/##; s/\.dist-info$//' \
                   | grep -Ei '^(torch|transformers|nano-parakeet|faster-qwen3-tts|qwen-tts|kokoro|faster-whisper|funasr|speech-to-speech|mlx)' \
                   | sort -u | tr '\n' ' ')
            echo "   venv pkgs: $pkgs"
        }
    done
done

echo
echo "===== 7. PYTHON ENVIRONMENTS (find old GPU/audio envs you forgot) ====="
for r in $ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 5 -name 'pyvenv.cfg' 2>/dev/null | head -40 | while IFS= read -r cfg; do
        v="$(dirname "$cfg")"
        echo "-- $v"
        pkgs=$(find "$v/lib" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | sed 's#.*/##; s/\.dist-info$//' \
               | grep -Ei '^(torch|torchaudio|transformers|nano-parakeet|faster-qwen3-tts|qwen-tts|mlx|kokoro|faster-whisper|funasr|modelscope|bitsandbytes|flash|vllm|onnxruntime|nemo|speech-to-speech|pocket-tts|misaki)' \
               | sort -u | tr '\n' ' ')
        [ -n "$pkgs" ] && echo "   pkgs: $pkgs"
        [ -e "$v/bin/speech-to-speech" ] && echo "   *** has the speech-to-speech CLI ***"
    done
done
for c in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "$HOME/miniforge3/bin/conda"; do
    [ -x "$c" ] && { echo "-- conda envs:"; "$c" env list 2>/dev/null | head -25; }
done

echo
echo "===== 8. FOLDERS NAMED AFTER MODELS (even if files are small/odd) ====="
: > "$TMP/dirs"
for r in $ROOTS; do
    [ -d "$r" ] || continue
    find "$r" "${PRUNE_NAME[@]}" -type d \( "${NAME_ARGS[@]}" \) -print 2>/dev/null \
        | head -400 | while IFS= read -r d; do
            printf '%s\t%s\n' "$(dusize "$d")" "$d"
        done >> "$TMP/dirs"
done
echo "total model-named folders: $(wc -l < "$TMP/dirs" | tr -d ' ')"
sort -t"$TAB" -k1 -hr "$TMP/dirs" 2>/dev/null | head -n "$MAXLIST"

echo
echo "===== 9. OTHER COPIES OF THIS KIND OF PROJECT ====="
for r in $ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 6 -type d \( -name 'speech-to-speech*' -o -name 's2s*' -o -name '*tts*' -o -name '*stt*' -o -name '*voice-agent*' \) 2>/dev/null | head -40
done

echo
echo "===== 10. SHELL CONFIG (any env vars already pointing at models?) ====="
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" \
          "$HOME/.config/environment.d/"*.conf ; do
    [ -f "$rc" ] || continue
    hits=$(grep -n -E 'HF_|HUGGINGFACE|TRANSFORMERS|TORCH_HOME|MODELSCOPE|OLLAMA|CUDA|MODEL|GGUF|LLAMA' "$rc" 2>/dev/null | head -12)
    [ -n "$hits" ] && { echo "-- $rc"; printf '%s\n' "$hits" | sed 's/^/   /'; }
done

echo
echo "=================================================================="
echo " END OF REPORT"
echo "=================================================================="
} > "$OUT" 2>&1

rm -rf "$TMP"
log ""
log "DONE. Report written to: $OUT"
log "Size: $(dusize "$OUT")   Lines: $(wc -l < "$OUT" | tr -d ' ')"
log "Now attach that file here (or paste its contents)."
