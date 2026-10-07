#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  full_machine_scan.sh  —  v2 (live dashboard edition)
#
#  Sweeps the ENTIRE machine for model files, model runtimes, caches and
#  environments — the things you forgot you had — while showing a live
#  progress dashboard so you always know exactly what it is doing.
#
#  * READ-ONLY. Nothing is changed, installed, moved or deleted.
#  * No sudo. No internet needed while running.
#  * Writes exactly one file:  ~/s2s-machine-report.txt
#
#    bash full_machine_scan.sh
#    S2S_ROOTS="/" bash full_machine_scan.sh          # maximal sweep
#    NO_COLOR=1 bash full_machine_scan.sh             # plain output
# ─────────────────────────────────────────────────────────────────────────────

OUT="${S2S_REPORT:-$HOME/s2s-machine-report.txt}"
ROOTS="${S2S_ROOTS:-/}"
MAXLIST="${S2S_MAX_LIST:-300}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/s2sscan.XXXXXX")"
TAB="$(printf '\t')"
START_TS=$SECONDS

IS_GNU_FIND=0; find --version 2>/dev/null | grep -q GNU && IS_GNU_FIND=1
IS_MAC=0; [ "$(uname -s)" = "Darwin" ] && IS_MAC=1
IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

# ── terminal / UI setup ──────────────────────────────────────────────────────
UI=0
{ [ -t 1 ] || [ -w /dev/tty ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] && UI=1
if [ "$UI" = 1 ] && ! { : > /dev/tty; } 2>/dev/null; then UI=0; fi
TTY=/dev/tty
[ "$UI" = 1 ] || TTY=/dev/null

utf8() { case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) return 0;; esac; return 1; }
if utf8; then
    SPIN=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    BF='█'; BE='░'
else
    SPIN=( '|' '/' '-' '\' ); BF='#'; BE='-'
fi
ESC=$'\033'
if [ "$UI" = 1 ]; then
    C0="$ESC[0m"; CB="$ESC[1m"; CD="$ESC[2m"
    CC="$ESC[36m"; CG="$ESC[32m"; CY="$ESC[33m"; CK="$ESC[90m"
else
    C0=; CB=; CD=; CC=; CG=; CY=; CK=
fi

W=80
get_width() {
    local w=""
    if [ "$UI" = 1 ]; then w=$(tput cols 2>/dev/null || true); fi
    case "$w" in ''|*[!0-9]*) w="${COLUMNS:-80}";; esac
    [ "$w" -lt 60 ] 2>/dev/null && w=80
    W=$((w - 1))
}
get_width

trunc() {
    local t="$1" m="$2"
    if [ "${#t}" -gt "$m" ] && [ "$m" -gt 1 ]; then printf '%s…' "${t:0:$((m - 1))}"; else printf '%s' "$t"; fi
}
rep() { local n=$1 c=$2 i out=""; for ((i = 0; i < n; i++)); do out+="$c"; done; printf '%s' "$out"; }
bar() {
    local pct=$1 wd=$2 f e
    f=$((pct * wd / 100)); [ "$f" -gt "$wd" ] && f=$wd; [ "$f" -lt 0 ] && f=0
    e=$((wd - f))
    printf '%s%s%s%s' "$CG" "$(rep "$f" "$BF")" "$CK" "$(rep "$e" "$BE")$C0"
}
bar_ind() {
    local wd=$1 t=$2 pos i c out=""
    pos=$((t % (wd - 4)))
    for ((i = 0; i < wd; i++)); do
        if [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + 4)) ]; then c="$CY"; else c="$CK"; fi
        out+="$c$BE"
    done
    printf '%s%s' "$out" "$C0"
}
fmt_time() { printf '%d:%02d' $((${1:-0} / 60)) $((${1:-0} % 60)); }
human() {
    awk -v b="${1:-0}" 'BEGIN{ if(b>=1073741824) printf "%.1f GB", b/1073741824;
                              else if(b>=1048576) printf "%.1f MB", b/1048576;
                              else if(b>=1024) printf "%.1f KB", b/1024; else printf "%d B", b }'
}
dusize() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
size_of() { if [ "$IS_MAC" = 1 ]; then stat -f%z "$1" 2>/dev/null; else stat -c%s "$1" 2>/dev/null; fi; }

# ── phases ───────────────────────────────────────────────────────────────────
PHASE_LABELS=(
    "machine + GPU"
    "drives + mounts"
    "WEIGHT FILES (the big one)"
    "torch hub / silero VAD"
    "HF + ModelScope caches"
    "model runners + their stores"
    "Windows side (/mnt)"
    "this project's own folders"
    "python envs + conda"
    "folders named like models"
    "other copies of this project"
    "shell config / env vars"
    "finalise + save report"
)
PHASE_FUNCS=(
    ph_machine ph_drives ph_weights ph_torchhub ph_hfcaches ph_runners
    ph_windowsside ph_project ph_pyenvs ph_nameddirs ph_otherprojects
    ph_shellcfg ph_finalise
)
NPH=${#PHASE_LABELS[@]}
declare -a PHASE_STATE PHASE_SECS
for ((i = 0; i < NPH; i++)); do PHASE_STATE[$i]=pending; PHASE_SECS[$i]=0; done
PHASE_STATE[0]=running

CUR_PHASE=0
TICK=0
DONE_UNITS=0; TOTAL_UNITS=0
RUN_FILES=0; RUN_BYTES=0
FIND_PID=""
STAT_LINE=""
CUR_PATH="starting up"
PHASE_RUN_FRAC=-1        # 0..100 = known progress inside current phase, -1 = unknown

render() {
    local i lines=$((8 + NPH))
    local frac overall spin="${SPIN[$((TICK % ${#SPIN[@]}))]}"
    frac="$PHASE_RUN_FRAC"
    if [ "$frac" -ge 0 ]; then
        overall=$(((CUR_PHASE * 100 + frac) / NPH))
    else
        overall=$((CUR_PHASE * 100 / NPH))
    fi

    if [ "$UI" != 1 ]; then
        if [ $((TICK % 20)) -eq 0 ]; then
            printf '[%s] %s | overall %d%% | phase %d/%d %s | %s\n' \
                "$(date +%H:%M:%S)" "$(fmt_time $((SECONDS - START_TS)))" "$overall" \
                $((CUR_PHASE + 1)) "$NPH" "${PHASE_LABELS[$CUR_PHASE]}" \
                "${STAT_LINE:-files $RUN_FILES}"
        fi
        return
    fi

    if [ "${FIRST_RENDER:-1}" = 1 ]; then FIRST_RENDER=0; else printf '%s[%dA' "$ESC" "$lines" >"$TTY"; fi

    printf '%s╭─%s %sFULL MACHINE SCAN%s %s· read-only, nothing is changed%s\033[K\n' \
        "$CC" "$C0" "$CB$CC" "$C0$CC" "$CD" "$C0$CC" >"$TTY"
    printf '%s│%s %sOverall%s [%s] %s%3d%%%s   phase %d/%d   elapsed %s%s\033[K\n' \
        "$CC" "$C0" "$CB" "$C0" "$(bar "$overall" 28)" "$CB" "$overall" "$C0" \
        $((CUR_PHASE + 1)) "$NPH" "$(fmt_time $((SECONDS - START_TS)))" "$C0" >"$TTY"
    if [ "$frac" -ge 0 ]; then
        printf '%s│%s %sNow%s     [%s] %s%3d%%%s   %s%s\033[K\n' \
            "$CC" "$C0" "$CB" "$C0" "$(bar "$frac" 28)" "$CB" "$frac" "$C0" \
            "${PHASE_LABELS[$CUR_PHASE]}" "$C0" >"$TTY"
    else
        printf '%s│%s %sNow%s     [%s]  %s   %s%s%s\033[K\n' \
            "$CC" "$C0" "$CB" "$C0" "$(bar_ind 28 "$TICK")" "$spin" "${PHASE_LABELS[$CUR_PHASE]}" "$C0" >"$TTY"
    fi
    printf '%s│%s %s%s %s%s\033[K\n' "$CC" "$C0" "$CK" "$spin" "$(trunc "${CUR_PATH:-...}" $((W - 10)))" "$C0" >"$TTY"
    if [ -n "$STAT_LINE" ]; then
        printf '%s│%s %s%s%s\033[K\n' "$CC" "$C0" "$CK" "$(trunc "$STAT_LINE" $((W - 10)))" "$C0" >"$TTY"
    else
        printf '%s│%s %supdating live — nothing is frozen%s\033[K\n' "$CC" "$C0" "$CK" "$C0" >"$TTY"
    fi
    printf '%s│%s\033[K\n' "$CC" "$C0" >"$TTY"
    for ((i = 0; i < NPH; i++)); do
        case "${PHASE_STATE[$i]}" in
            done) printf '%s│%s %s✓%s %-34s %s%7s%s\033[K\n' "$CC" "$C0" "$CG" "$C0" \
                      "$(trunc "${PHASE_LABELS[$i]}" 34)" "$CK" "$(fmt_time "${PHASE_SECS[$i]}")" "$C0" >"$TTY" ;;
            running) printf '%s│%s %s%s%s %s%-34s%s %s running%s\033[K\n' "$CC" "$C0" "$CY" "$spin" "$C0" "$CB" \
                      "$(trunc "${PHASE_LABELS[$i]}" 34)" "$C0" "$CY" "$C0" >"$TTY" ;;
            *) printf '%s│%s %s·%s %s%-34s%s %s   to do%s\033[K\n' "$CC" "$C0" "$CK" "$C0" "$CD" \
                      "$(trunc "${PHASE_LABELS[$i]}" 34)" "$C0" "$CK" "$C0" >"$TTY" ;;
        esac
    done
    printf '%s│%s %sCtrl+C = stop safely (partial report is kept)%s\033[K\n' "$CC" "$C0" "$CD" "$C0" >"$TTY"
    printf '%s╰──────────────────────────────────────────────────────\033[K%s\n' "$CC" "$C0" >"$TTY"
}

# ── cleanup / interrupt ──────────────────────────────────────────────────────
FINISHED=0
cleanup() {
    [ "$FINISHED" = 1 ] && return
    FINISHED=1
    [ -n "$FIND_PID" ] && kill "$FIND_PID" 2>/dev/null
    [ "$UI" = 1 ] && printf '%s[?25h%s\n' "$ESC" "$C0" >"$TTY"
}
trap 'cleanup
      printf "\nSCAN INTERRUPTED BY USER - partial report\n" >> "$OUT" 2>/dev/null
      printf "\n%sStopped safely.%s Nothing on the machine was changed.\nPartial report so far: %s\n" "$CG" "$C0" "$OUT" >"$TTY" 2>/dev/null
      [ "$UI" != 1 ] && printf "\nStopped safely. Nothing on the machine was changed.\nPartial report so far: %s\n" "$OUT"
      exit 130' INT TERM
[ "$UI" = 1 ] && printf '%s[?25l%s' "$ESC" "$C0" >"$TTY"

# ── shared find machinery ────────────────────────────────────────────────────
PRUNE_DIRS=(/proc /sys /dev /run /snap /var/lib/docker /var/lib/containerd /System/Volumes /private/var/vm)
UNIT_SKIP_NAMES=(Windows '$Recycle.Bin' 'System Volume Information' 'All Users' Default 'Default User' Public 'Program Files' 'Program Files (x86)' 'ProgramData' 'PerfLogs')
PRUNE=()
for p in "${PRUNE_DIRS[@]}"; do PRUNE+=( -path "$p" -prune -o ); done
for n in node_modules .git __pycache__ .venv venv; do PRUNE+=( -name "$n" -prune -o ); done

WEIGHT_EXTS=( '*.gguf' '*.nemo' '*.safetensors' '*.onnx' '*.ort' '*.engine' '*.plan'
              '*.mlmodel' '*.mlmodelc' '*.mlpackage' '*.ckpt' '*.h5' '*.tflite'
              '*.msgpack' '*.npz' 'silero_vad*.jit' '*.pt' '*.pth' '*.bin' )
WEIGHT_ARGS=(); for e in "${WEIGHT_EXTS[@]}"; do WEIGHT_ARGS+=( -o -iname "$e" ); done
WEIGHT_ARGS=("${WEIGHT_ARGS[@]:1}")

NAME_ARGS=( -o -iname '*parakeet*' -o -iname '*silero*' -o -iname '*whisper*' -o -iname '*qwen*' \
    -o -iname '*kokoro*' -o -iname '*piper*' -o -iname '*vits*' -o -iname '*melo*' \
    -o -iname '*chattts*' -o -iname '*sensevoice*' -o -iname '*paraformer*' -o -iname '*funasr*' \
    -o -iname '*llama*' -o -iname '*gemma*' -o -iname '*mistral*' -o -iname '*phi-*' \
    -o -iname '*moonshine*' -o -iname '*cosyvoice*' -o -iname '*xtts*' -o -iname '*bark*' \
    -o -iname '*mms-tts*' -o -iname '*espeak*' -o -iname '*nemo*' -o -iname '*ctranslate*' \
    -o -iname '*sherpa*' -o -iname '*whisper.cpp*' -o -iname '*ollama*' -o -iname '*lmstudio*' \
    -o -iname '*mlx*' -o -iname '*gguf*' -o -iname '*comfyui*' -o -iname '*stable-diffusion*' \
    -o -iname '*models' -o -iname '*checkpoints*' -o -iname '*hf_cache*' -o -iname '*.cache' )
NAME_ARGS=("${NAME_ARGS[@]:1}")

unit_skip() {
    local b="$1" n
    for n in "${UNIT_SKIP_NAMES[@]}"; do [ "$b" = "$n" ] && return 0; done
    return 1
}

MAXD="${S2S_UNIT_DEPTH:-3}"     # how deep the tree is split into progress units

# Units partition the tree so NO file is scanned twice:
#   depth <  MAXD : a real directory scanned only one level deep (its own files)
#   depth == MAXD : a "leaf" scanned recursively (covers everything deeper)
build_units() {
    : > "$TMP/units.raw"
    local r m level nxt dir sub b d
    level="$TMP/lvl"; nxt="$TMP/nxt"
    for r in $ROOTS; do
        if [ "$r" = "/" ]; then
            while IFS= read -r m; do
                case "$m" in /proc|/sys|/dev|/run|/snap|/var/lib/docker|/var/lib/containerd) continue;; esac
                [ -d "$m" ] || continue
                bfs_mount "$m"
            done < <(df -P 2>/dev/null | awk 'NR>1{print $6}' | sort -u)
        else
            [ -d "$r" ] || continue
            bfs_mount "$r"
        fi
    done
    awk -F"$TAB" '!seen[$1]++' "$TMP/units.raw" > "$TMP/units"
}

bfs_mount() {
    local m="$1" d=0
    printf '%s\t0\n' "$m" >> "$TMP/units.raw"
    printf '%s\n' "$m" > "$TMP/lvl"
    while [ -s "$TMP/lvl" ] && [ "$d" -lt "$MAXD" ]; do
        : > "$TMP/nxt"
        while IFS= read -r dir; do
            while IFS= read -r sub; do
                b="${sub##*/}"
                unit_skip "$b" && continue
                printf '%s\t%d\n' "$sub" $((d + 1)) >> "$TMP/units.raw"
                printf '%s\n' "$sub" >> "$TMP/nxt"
            done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
        done < "$TMP/lvl"
        cp "$TMP/nxt" "$TMP/lvl"
        d=$((d + 1))
        # safety valve: never build an absurd unit list
        [ "$(wc -l < "$TMP/units.raw")" -gt 20000 ] && break
    done
}

# mode = weights | names ; consumer callback name in $2
poll_find() {
    local unit="$1" udepth="$2" mode="$3" consumer="$4"
    local DEPTH_ARGS=( -mindepth 1 )
    [ "$udepth" -lt "$MAXD" ] && DEPTH_ARGS+=( -maxdepth 1 )
    : > "$TMP/cur"; READ_AT=0
    if [ "$mode" = weights ]; then
        if [ "$IS_GNU_FIND" = 1 ]; then
            find "$unit" "${DEPTH_ARGS[@]}" "${PRUNE[@]}" -type f \( "${WEIGHT_ARGS[@]}" \) -printf '%s\t%p\n' >> "$TMP/cur" 2>/dev/null &
        else
            ( find "$unit" "${DEPTH_ARGS[@]}" "${PRUNE[@]}" -type f \( "${WEIGHT_ARGS[@]}" \) -print 2>/dev/null \
              | while IFS= read -r f; do printf '%s\t%s\n' "$(size_of "$f")" "$f"; done ) >> "$TMP/cur" &
        fi
    else
        find "$unit" "${DEPTH_ARGS[@]}" "${PRUNE[@]}" -type d \( "${NAME_ARGS[@]}" \) -print 2>/dev/null >> "$TMP/cur" &
    fi
    FIND_PID=$!
    while kill -0 "$FIND_PID" 2>/dev/null; do
        "$consumer"
        TICK=$((TICK + 1))
        render
        sleep 0.2 &
        wait $! 2>/dev/null
    done
    wait "$FIND_PID" 2>/dev/null
    "$consumer"
    FIND_PID=""
}

consume_weights() {
    local line n=0
    while IFS= read -r line; do
        n=$((n + 1))
        printf '%s\n' "$line" >> "$TMP/weights"
        RUN_FILES=$((RUN_FILES + 1))
        RUN_BYTES=$((RUN_BYTES + ${line%%"$TAB"*}))
        CUR_PATH="${line#*"$TAB"}"
    done < <(tail -n +$((READ_AT + 1)) "$TMP/cur" 2>/dev/null)
    READ_AT=$((READ_AT + n))
    STAT_LINE="files found: $RUN_FILES   size: $(human "$RUN_BYTES")   units scanned: $DONE_UNITS/$TOTAL_UNITS"
}

consume_names() {
    local line n=0 sz
    while IFS= read -r line; do
        n=$((n + 1))
        sz=$(dusize "$line")
        printf '%s\t%s\n' "${sz:-?}" "$line" >> "$TMP/names"
        DIRS_FOUND=$((DIRS_FOUND + 1))
        CUR_PATH="$line"
    done < <(tail -n +$((READ_AT + 1)) "$TMP/cur" 2>/dev/null)
    READ_AT=$((READ_AT + n))
    STAT_LINE="model-named folders found: $DIRS_FOUND   units scanned: $DONE_UNITS/$TOTAL_UNITS"
}

# ── report pages ─────────────────────────────────────────────────────────────
ph_machine() {
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
}

ph_drives() {
    echo "===== 2. DRIVES / MOUNTS ====="
    df -hP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|overlay|squashfs|none)' | head -30
}

ph_weights() {
    echo "===== 3. ALL WEIGHT-LIKE FILES EVERYWHERE ====="
    : > "$TMP/weights"
    build_units
    TOTAL_UNITS=$(wc -l < "$TMP/units" | tr -d ' ')
    DONE_UNITS=0
    echo "units scanned: $TOTAL_UNITS   (tree split into non-overlapping folders, depth $MAXD)"
    local unit udepth
    while IFS="$TAB" read -r unit udepth; do
        [ -n "$unit" ] || continue
        udepth="${udepth:-99}"
        if [ ! -d "$unit" ]; then
            DONE_UNITS=$((DONE_UNITS + 1)); PHASE_RUN_FRAC=$((DONE_UNITS * 100 / TOTAL_UNITS)); continue
        fi
        CUR_PATH="$unit"
        poll_find "$unit" "$udepth" weights consume_weights
        DONE_UNITS=$((DONE_UNITS + 1))
        PHASE_RUN_FRAC=$((DONE_UNITS * 100 / TOTAL_UNITS))
        TICK=$((TICK + 1))
        render
    done < "$TMP/units"
    PHASE_RUN_FRAC=-1
    echo
    echo "total weight-like files found: $RUN_FILES"
    echo "-- biggest $MAXLIST (anything silently big is what you forgot you had):"
    sort -rn "$TMP/weights" 2>/dev/null | head -n "$MAXLIST" | while IFS="$TAB" read -r sz p; do
        printf '%10s  %s\n' "$(human "$sz")" "$p"
    done
    echo "-- counts by extension:"
    awk -F'\t' '{n=$2; sub(/.*\./,"",n); print tolower(n)}' "$TMP/weights" 2>/dev/null | sort | uniq -c | sort -rn | head -20
    STAT_LINE=""
}

ph_torchhub() {
    echo "===== 4. TORCH HUB (silero VAD lives here) ====="
    local d
    for d in "${TORCH_HOME:-}" "$HOME/.cache/torch" "$HOME/.torch"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        echo "-- $d ($(dusize "$d"))"
        find "$d" -maxdepth 4 \( -iname '*silero*' -o -iname '*.jit' -o -iname '*.pt' \) 2>/dev/null | head -20
    done
}

ph_hfcaches() {
    echo "===== 5. HUGGINGFACE / MODELSCOPE / OTHER CACHES ====="
    local d r
    for d in "${HF_HOME:-}" "${HUGGINGFACE_HUB_CACHE:-}" "$HOME/.cache/huggingface" \
             "$HOME/.cache/modelscope" "$HOME/.cache/huggingface/gguf" "$HOME/.cache/whisper" \
             "$HOME/.cache/llama.cpp" "$HOME/.cache/piper" "$HOME/.cache/kokoro"; do
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
}

ph_runners() {
    echo "===== 6. LOCAL MODEL RUNNERS (binaries + their model stores) ====="
    local b p d c
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
             "$HOME/.cache/gpt4all" "$HOME/.cache/jan" "$HOME/sillytavern" "$HOME/.cache/text-generation-webui"; do
        [ -d "$d" ] && { echo "-- $d ($(dusize "$d"))"; find "$d" -maxdepth 5 -type f \( -iname '*.gguf' -o -iname '*.safetensors' -o -iname '*.bin' \) 2>/dev/null | head -30; }
    done
    if command -v docker >/dev/null 2>&1; then
        echo "-- docker images (models sometimes live inside images):"
        docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | head -25
    fi
    for c in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "$HOME/miniforge3/bin/conda"; do
        [ -x "$c" ] && { echo "-- conda envs:"; "$c" env list 2>/dev/null | head -25; }
    done
}

ph_windowsside() {
    echo "===== 6b. WINDOWS SIDE, SEEN FROM WSL (/mnt/*) ====="
    local win prof rel found d
    if [ -d /mnt ] && ls /mnt >/dev/null 2>&1; then
        echo "-- mounts present under /mnt:"
        ls -1 /mnt 2>/dev/null | sed 's/^/   /'
        for win in /mnt/*/; do
            win="${win%/}"
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
                    for rel in $found; do echo "   [$(dusize "$prof/$rel")] $rel"; done
                }
            done
            for d in "$win/models" "$win/AI" "$win/ComfyUI" "$win/ComfyUI_windows_portable"; do
                [ -d "$d" ] && echo "-- [$(dusize "$d")] $d"
            done
        done
    else
        echo "not inside WSL (no /mnt) - skipping"
    fi
}

ph_project() {
    echo "===== 6c. THIS PROJECT'S OWN FOLDERS (every copy on disk) ====="
    local r d sub pkgs
    for r in $ROOTS; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 6 -type d -name 'speech-to-speech*' 2>/dev/null | head -20 | while IFS= read -r d; do
            echo "== $d"
            for sub in .venv models cache models_cache hf_cache; do
                [ -d "$d/$sub" ] && echo "   [$(dusize "$d/$sub")] $sub/"
            done
            if [ -d "$d/.venv" ]; then
                pkgs=$(find "$d/.venv/lib" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | sed 's#.*/##; s/\.dist-info$//' \
                       | grep -Ei '^(torch|transformers|nano-parakeet|faster-qwen3-tts|qwen-tts|kokoro|faster-whisper|funasr|speech-to-speech|mlx)' \
                       | sort -u | tr '\n' ' ')
                echo "   venv pkgs: $pkgs"
            fi
        done
    done
}

ph_pyenvs() {
    echo "===== 7. PYTHON ENVIRONMENTS (old GPU/audio envs you forgot) ====="
    local r v pkgs
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
}

ph_nameddirs() {
    echo "===== 8. FOLDERS NAMED AFTER MODELS ====="
    : > "$TMP/names"
    DIRS_FOUND=0
    if [ ! -s "$TMP/units" ]; then
        build_units
    fi
    TOTAL_UNITS=$(wc -l < "$TMP/units" | tr -d ' ')
    DONE_UNITS=0
    local unit udepth
    while IFS="$TAB" read -r unit udepth; do
        udepth="${udepth:-99}"
        if [ -d "$unit" ]; then
            CUR_PATH="$unit"
            poll_find "$unit" "$udepth" names consume_names
        fi
        DONE_UNITS=$((DONE_UNITS + 1))
        PHASE_RUN_FRAC=$((DONE_UNITS * 100 / TOTAL_UNITS))
        TICK=$((TICK + 1))
        render
    done < "$TMP/units"
    PHASE_RUN_FRAC=-1
    echo "total model-named folders found: $DIRS_FOUND"
    sort -t"$TAB" -k1 -hr "$TMP/names" 2>/dev/null | head -n "$MAXLIST"
    STAT_LINE=""
}

ph_otherprojects() {
    echo "===== 9. OTHER COPIES OF THIS KIND OF PROJECT ====="
    local r
    for r in $ROOTS; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 6 -type d \( -name 'speech-to-speech*' -o -name 's2s*' -o -name '*tts*' -o -name '*stt*' -o -name '*voice-agent*' \) 2>/dev/null | head -40
    done
}

ph_shellcfg() {
    echo "===== 10. SHELL CONFIG (env vars already pointing at models?) ====="
    local rc hits
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" \
              "$HOME"/.config/environment.d/*.conf; do
        [ -f "$rc" ] || continue
        hits=$(grep -n -E 'HF_|HUGGINGFACE|TRANSFORMERS|TORCH_HOME|MODELSCOPE|OLLAMA|CUDA|MODEL|GGUF|LLAMA' "$rc" 2>/dev/null | head -12)
        [ -n "$hits" ] && { echo "-- $rc"; printf '%s\n' "$hits" | sed 's/^/   /'; }
    done
}

ph_finalise() {
    echo
    echo "=================================================================="
    echo " END OF REPORT"
    echo "=================================================================="
}

# ── run ──────────────────────────────────────────────────────────────────────
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
    echo "scan roots: $ROOTS"
    echo
} > "$OUT"

for ((i = 0; i < NPH; i++)); do
    CUR_PHASE=$i
    PHASE_STATE[$i]=running
    T0=$SECONDS
    "${PHASE_FUNCS[$i]}" >> "$OUT" 2>&1
    PHASE_SECS[$i]=$((SECONDS - T0))
    PHASE_STATE[$i]=done
    TICK=$((TICK + 1))
    render
done

CUR_PHASE=$((NPH - 1))
PHASE_RUN_FRAC=100
STAT_LINE="scan complete — report saved"
TICK=$((TICK + 1))
render
FINISHED=1
[ "$UI" = 1 ] && printf '%s[?25h%s' "$ESC" "$C0" >"$TTY"

rm -rf "$TMP"
printf '\n%sDONE.%s Report written to:\n  %s\n' "$CG$CB" "$C0" "$OUT"
printf 'Size: %s   Lines: %s\n' "$(dusize "$OUT")" "$(wc -l < "$OUT" | tr -d ' ')"
printf 'Files found: %s   Total size: %s   Scan took: %s\n' \
    "$RUN_FILES" "$(human "$RUN_BYTES")" "$(fmt_time $((SECONDS - START_TS)))"
printf '\nFrom Windows Explorer, open:  \\\\wsl.localhost\\<your-distro>\\home\\%s\\  then drag the file into the chat.\n' "$(whoami)"
