#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# encode.sh
# macOS (Apple Silicon ready). Batch-encode a directory of TV episodes.
# Video defaults: HEVC x265 (CPU, 10-bit) CRF 23, preset slow.
# NEW: --audio=<list> to keep audio tracks in a given ORDER (1-based among audio streams),
#      and --audio-mode copy|aac to remux or re-encode audio.

# -------- Configurable defaults --------
DEFAULT_ENCODER="cpu-x265"   # cpu-x265 | hw-hevc | av1
X265_CRF="23"
X265_PRESET="slow"
X265_TUNE=""                 # e.g. "grain" for heavy film grain, else empty

# Hardware HEVC (VideoToolbox): fast, a bit larger than x265 at same quality
HW_HEVC_AVG_BITRATE="3600k"
HW_HEVC_MAX_BITRATE="7600k"
HW_HEVC_BUFSIZE="15000k"

# AV1 (SVT-AV1): smallest, slower
AV1_CRF="30"
AV1_PRESET="7"

# Audio defaults (for AAC mode)
AUDIO_STEREO_BITRATE="160k"
AUDIO_SURROUND_BITRATE="384k"

# Input filters
VIDEO_EXTS=("mkv" "mp4" "m2ts" "mts" "ts" "avi" "mov")

# -------- Helpers --------
log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }
err() { printf "ERROR: %s\n" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

trap 'err "Command failed (exit $?) at line $LINENO"; exit $?' ERR

usage() {
  cat <<EOF
Usage: $(basename "$0") <input_dir> [--encoder cpu-x265|hw-hevc|av1] [--out "<dir>"]
                       [--audio "<list>"] [--audio-mode copy|aac]
                       [--subs "<list>"] [--tune-grain]

Options:
  --encoder         Video encoder (default: cpu-x265). hw-hevc uses Apple VideoToolbox.
  --out             Output directory (default: <input>_encoded).
  --audio           Comma-separated 1-based audio indices among *audio streams only*,
                    in the exact order you want, e.g. --audio=5,1,3
                    If omitted, script keeps/re-encodes the first audio only.
  --audio-mode      'copy' (remux selected audio as-is) or 'aac' (re-encode). Default: aac
  --subs            Comma-separated 1-based subtitle indices, in the desired order.
                    If omitted, script remuxes all subtitle tracks it finds.
  --tune-grain      Apply x265 tune=grain (better film grain retention; larger size).

Examples:
  $(basename "$0") "/path/to/Season 1"
  $(basename "$0") "/path/to/Season 1" --encoder hw-hevc
  $(basename "$0") "/path/to/Season 1" --audio=5,1,3 --audio-mode copy --subs=1,2,3
EOF
}

# -------- Parse args --------
if [[ $# -lt 1 ]]; then usage; exit 1; fi

INPUT_DIR=""
ENCODER="$DEFAULT_ENCODER"
OUT_DIR=""
AUDIO_ORDER=""         # e.g. "5,1,3" (1-based among audio streams)
AUDIO_MODE="aac"       # "aac" (default) or "copy"
SUBS_ORDER=""
TUNE_GRAIN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --encoder)     shift; ENCODER="${1:-$DEFAULT_ENCODER}";;
    --out)         shift; OUT_DIR="${1:-}";;
    --audio)       shift; AUDIO_ORDER="${1:-}";;
    --audio-mode)  shift; AUDIO_MODE="${1:-aac}";;
    --subs)        shift; SUBS_ORDER="${1:-}";;
    --tune-grain)  TUNE_GRAIN="1";;
    -h|--help)     usage; exit 0;;
    *)
      if [[ -z "$INPUT_DIR" ]]; then INPUT_DIR="$1"; else err "Unexpected arg: $1"; usage; exit 1; fi;;
  esac
  shift
done

[[ -z "$INPUT_DIR" ]] && { err "No input directory provided."; usage; exit 1; }
[[ ! -d "$INPUT_DIR" ]] && { err "Input directory not found: $INPUT_DIR"; exit 1; }

INPUT_DIR_ORIG="$INPUT_DIR"
if ! INPUT_DIR="$(cd "$INPUT_DIR_ORIG" && pwd)"; then
  err "Failed to resolve input directory: $INPUT_DIR_ORIG"
  exit 1
fi

[[ -z "$OUT_DIR" ]] && OUT_DIR="${INPUT_DIR%/}_encoded"
mkdir -p "$OUT_DIR"

# -------- Requirements --------
for bin in ffmpeg ffprobe; do
  if ! have "$bin"; then
    err "Missing $bin. Install via: brew install ffmpeg"
    exit 1
  fi
done

# -------- Enumerate input files --------
shopt -s nullglob
declare -a FILES=()
for ext in "${VIDEO_EXTS[@]}"; do
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$INPUT_DIR" -type f -iname "*.${ext}" -print0)
done
shopt -u nullglob
[[ ${#FILES[@]} -eq 0 ]] && { err "No video files found in: $INPUT_DIR"; exit 1; }

log "Encoder   : $ENCODER"
log "Audio sel : ${AUDIO_ORDER:-(first audio only)} (mode: $AUDIO_MODE)"
if [[ -n "$SUBS_ORDER" ]]; then
  log "Subs sel  : $SUBS_ORDER (mode: copy)"
else
  log "Subs sel  : all (mode: copy)"
fi
log "Input     : $INPUT_DIR"
log "Output    : $OUT_DIR"
log "Found     : ${#FILES[@]} file(s)"

# -------- Encoder args builders --------
video_args() {
  case "$ENCODER" in
    cpu-x265)
      local x265_params="crf=${X265_CRF}:aq-mode=2:psy-rd=2"
      if [[ "$TUNE_GRAIN" == "1" || -n "$X265_TUNE" ]]; then
        local tune_val="${X265_TUNE:-grain}"
        x265_params+=":tune=${tune_val}"
      fi
      printf '%s\n' \
        "-map" "0:v:0" \
        "-c:v" "libx265" \
        "-preset" "$X265_PRESET" \
        "-x265-params" "$x265_params" \
        "-pix_fmt" "yuv420p10le"
      ;;
    hw-hevc)
      printf '%s\n' \
        "-map" "0:v:0" \
        "-c:v" "hevc_videotoolbox" \
        "-b:v" "$HW_HEVC_AVG_BITRATE" \
        "-maxrate" "$HW_HEVC_MAX_BITRATE" \
        "-bufsize" "$HW_HEVC_BUFSIZE" \
        "-pix_fmt" "yuv420p" \
        "-vtag" "hvc1"
      ;;
    av1)
      printf '%s\n' \
        "-map" "0:v:0" \
        "-c:v" "libsvtav1" \
        "-crf" "$AV1_CRF" \
        "-preset" "$AV1_PRESET" \
        "-pix_fmt" "yuv420p"
      ;;
    *) err "Unknown encoder: $ENCODER"; exit 1;;
  esac
}

# Count helper for ffprobe stream selection. Returns 0 on errors.
stream_count() {
  local src="$1"; local selector="$2"
  local out=""
  if ! out="$(ffprobe -v error -select_streams "$selector" -show_entries stream=index -of csv=p=0 "$src")"; then
    err "ffprobe failed while probing '$selector' streams for: $src"
    printf "0"
    return
  fi
  if [[ -z "$out" ]]; then
    printf "0"
    return
  fi
  printf '%s\n' "$out" | awk 'NF {count++} END {print count+0}'
}

# Return number of audio streams
audio_count() {
  local src="$1"
  stream_count "$src" "a"
}

# Channels for a given 0-based audio index among audio streams
channels_for_audio_n() {
  local src="$1"; local n="$2"
  local out=""
  if ! out="$(ffprobe -v error -select_streams a:"$n" -show_entries stream=channels -of csv=p=0 "$src")"; then
    err "ffprobe failed while reading channels for audio index $n in: $src"
    echo ""
    return
  fi
  printf '%s\n' "$out"
}

# Return number of subtitle streams
subs_count() {
  local src="$1"
  stream_count "$src" "s"
}

# Build mapping & codec args for audio according to AUDIO_ORDER & AUDIO_MODE
audio_args() {
  local src="$1"
  local total_a; total_a="$(audio_count "$src")"
  total_a="${total_a:-0}"
  local -a args=()
  local -a indexes=()

  if (( total_a == 0 )); then
    log "No audio streams found in: $(basename "$src")"
    return
  fi

  if [[ -n "$AUDIO_ORDER" ]]; then
    local cleaned="${AUDIO_ORDER//[[:space:]]/}"
    local -a ORDER=()
    local IFS=','
    read -ra ORDER <<< "$cleaned" || true
    for ord in "${ORDER[@]}"; do
      if [[ -z "$ord" ]]; then continue; fi
      if [[ ! "$ord" =~ ^[0-9]+$ ]]; then
        log "Skipping invalid audio index: $ord"
        continue
      fi
      if (( ord < 1 )); then
        log "Skipping out-of-range audio index: $ord"
        continue
      fi
      local zero=$((ord-1))
      if (( zero >= total_a )); then
        log "Skipping audio index $ord (only $total_a audio stream(s) present)"
        continue
      fi
      indexes+=("$zero")
    done
    if (( ${#indexes[@]} == 0 )); then
      log "No valid audio indices from --audio. Falling back to first audio."
      indexes=(0)
    fi
  else
    indexes=(0)
  fi

  local idx
  for idx in "${indexes[@]}"; do
    args+=("-map" "0:a:${idx}")
  done

  if [[ "$AUDIO_MODE" == "copy" ]]; then
    args+=("-c:a" "copy")
  else
    local out_i=0
    for idx in "${indexes[@]}"; do
      local ch
      ch="$(channels_for_audio_n "$src" "$idx")"
      if [[ -z "$ch" ]]; then ch=2; fi
      if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch > 2 )); then
        args+=("-c:a:${out_i}" "aac" "-b:a:${out_i}" "$AUDIO_SURROUND_BITRATE" "-ac:${out_i}" "6")
      else
        args+=("-c:a:${out_i}" "aac" "-b:a:${out_i}" "$AUDIO_STEREO_BITRATE" "-ac:${out_i}" "2")
      fi
      out_i=$((out_i+1))
    done
  fi

  if (( ${#indexes[@]} > 0 )); then
    args+=("-disposition:a:0" "default")
    local disp=1
    while (( disp < ${#indexes[@]} )); do
      args+=("-disposition:a:${disp}" "0")
      disp=$((disp+1))
    done
  fi

  printf '%s\n' "${args[@]}"
}

# Copy selected subs if requested, otherwise keep all
subs_args() {
  local src="$1"
  if [[ -z "$SUBS_ORDER" ]]; then
    printf '%s\n' "-map" "0:s?" "-c:s" "copy"
    return
  fi

  local total_s; total_s="$(subs_count "$src")"
  total_s="${total_s:-0}"
  if [[ -z "$total_s" || "$total_s" -eq 0 ]]; then
    log "No subtitle streams found in: $(basename "$src")"
    return
  fi

  local -a args=()
  local -a indexes=()
  local cleaned="${SUBS_ORDER//[[:space:]]/}"
  local -a ORDER=()
  local IFS=','
  read -ra ORDER <<< "$cleaned" || true
  for ord in "${ORDER[@]}"; do
    if [[ -z "$ord" ]]; then continue; fi
    if [[ ! "$ord" =~ ^[0-9]+$ ]]; then
      log "Skipping invalid subtitle index: $ord"
      continue
    fi
    if (( ord < 1 )); then
      log "Skipping out-of-range subtitle index: $ord"
      continue
    fi
    local zero=$((ord-1))
    if (( zero >= total_s )); then
      log "Skipping subtitle index $ord (only $total_s subtitle stream(s) present)"
      continue
    fi
    indexes+=("$zero")
  done

  if (( ${#indexes[@]} == 0 )); then
    log "No valid subtitle indices from --subs. Falling back to all subtitles."
    printf '%s\n' "-map" "0:s?" "-c:s" "copy"
    return
  fi

  local idx
  for idx in "${indexes[@]}"; do
    args+=("-map" "0:s:${idx}")
  done

  args+=("-c:s" "copy")
  args+=("-disposition:s:0" "default")
  local disp=1
  while (( disp < ${#indexes[@]} )); do
    args+=("-disposition:s:${disp}" "0")
    disp=$((disp+1))
  done

  printf '%s\n' "${args[@]}"
}

# -------- Main loop --------
i=0
for in_file in "${FILES[@]}"; do
  ((++i))
  rel="${in_file#"$INPUT_DIR"/}"
  if [[ "$rel" == "$in_file" ]]; then
    rel="$(basename "$in_file")"
  fi
  base="${rel%.*}"
  out_dir_for_file="$(dirname "$OUT_DIR/$rel")"
  mkdir -p "$out_dir_for_file"
  out_file="$out_dir_for_file/${base}.mkv"

  if [[ -f "$out_file" ]]; then
    log "[$i/${#FILES[@]}] SKIP (exists): $out_file"
    continue
  fi

  declare -a v_args=()
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    v_args+=("$arg")
  done < <(video_args) || true

  declare -a a_args=()
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    a_args+=("$arg")
  done < <(audio_args "$in_file") || true

  declare -a s_args=()
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    s_args+=("$arg")
  done < <(subs_args "$in_file") || true

  log "[$i/${#FILES[@]}] Encoding: $rel"
  log "Output: $out_file"
  set -x
  ffmpeg -hide_banner -y -i "$in_file" \
    "${v_args[@]}" \
    "${a_args[@]}" \
    "${s_args[@]}" \
    -map_metadata 0 \
    -movflags +faststart \
    "$out_file"
  set +x

  if [[ -f "$out_file" ]]; then
    log "DONE: $out_file"
  else
    err "Failed: $rel"
  fi
done

log "All done. Output in: $OUT_DIR"
