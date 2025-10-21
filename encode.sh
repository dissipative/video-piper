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

usage() {
  cat <<EOF
Usage: $(basename "$0") <input_dir> [--encoder cpu-x265|hw-hevc|av1] [--out "<dir>"]
                       [--audio "<list>"] [--audio-mode copy|aac] [--tune-grain]

Options:
  --encoder         Video encoder (default: cpu-x265). hw-hevc uses Apple VideoToolbox.
  --out             Output directory (default: <input>_encoded).
  --audio           Comma-separated 1-based audio indices among *audio streams only*,
                    in the exact order you want, e.g. --audio=5,1,3
                    If omitted, script keeps/re-encodes the first audio only.
  --audio-mode      'copy' (remux selected audio as-is) or 'aac' (re-encode). Default: aac
  --tune-grain      Apply x265 tune=grain (better film grain retention; larger size).

Examples:
  $(basename "$0") "/path/to/Season 1"
  $(basename "$0") "/path/to/Season 1" --encoder hw-hevc
  $(basename "$0") "/path/to/Season 1" --audio=5,1,3 --audio-mode copy
EOF
}

# -------- Parse args --------
if [[ $# -lt 1 ]]; then usage; exit 1; fi

INPUT_DIR=""
ENCODER="$DEFAULT_ENCODER"
OUT_DIR=""
AUDIO_ORDER=""         # e.g. "5,1,3" (1-based among audio streams)
AUDIO_MODE="aac"       # "aac" (default) or "copy"
TUNE_GRAIN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --encoder)     shift; ENCODER="${1:-$DEFAULT_ENCODER}";;
    --out)         shift; OUT_DIR="${1:-}";;
    --audio)       shift; AUDIO_ORDER="${1:-}";;
    --audio-mode)  shift; AUDIO_MODE="${1:-aac}";;
    --tune-grain)  TUNE_GRAIN="1";;
    -h|--help)     usage; exit 0;;
    *)
      if [[ -z "$INPUT_DIR" ]]; then INPUT_DIR="$1"; else err "Unexpected arg: $1"; usage; exit 1; fi;;
  esac
  shift
done

[[ -z "$INPUT_DIR" ]] && { err "No input directory provided."; usage; exit 1; }
[[ ! -d "$INPUT_DIR" ]] && { err "Input directory not found: $INPUT_DIR"; exit 1; }

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
log "Input     : $INPUT_DIR"
log "Output    : $OUT_DIR"
log "Found     : ${#FILES[@]} file(s)"

# -------- Encoder args builders --------
video_args() {
  case "$ENCODER" in
    cpu-x265)
      local tune_arg=""
      if [[ "$TUNE_GRAIN" == "1" || -n "$X265_TUNE" ]]; then
        local tune_val="${X265_TUNE:-grain}"
        tune_arg=":tune=${tune_val}"
      fi
      # 10-bit improves compression of gradients/grain; VLC supports it.
      printf -- "-map 0:v:0 -c:v libx265 -preset %s -x265-params crf=%s:aq-mode=2:psy-rd=2%s -pix_fmt yuv420p10le " \
        "$X265_PRESET" "$X265_CRF" "$tune_arg"
      ;;
    hw-hevc)
      printf -- "-map 0:v:0 -c:v hevc_videotoolbox -b:v %s -maxrate %s -bufsize %s -pix_fmt yuv420p -vtag hvc1 " \
        "$HW_HEVC_AVG_BITRATE" "$HW_HEVC_MAX_BITRATE" "$HW_HEVC_BUFSIZE"
      ;;
    av1)
      printf -- "-map 0:v:0 -c:v libsvtav1 -crf %s -preset %s -pix_fmt yuv420p " \
        "$AV1_CRF" "$AV1_PRESET"
      ;;
    *) err "Unknown encoder: $ENCODER"; exit 1;;
  esac
}

# Return number of audio streams
audio_count() {
  local src="$1"
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src" | wc -l | tr -d ' '
}

# Channels for a given 0-based audio index among audio streams
channels_for_audio_n() {
  local src="$1"; local n="$2"
  ffprobe -v error -select_streams a:"$n" -show_entries stream=channels -of csv=p=0 "$src" 2>/dev/null || echo ""
}

# Build mapping & codec args for audio according to AUDIO_ORDER & AUDIO_MODE
audio_args() {
  local src="$1"
  local total_a; total_a="$(audio_count "$src")"
  local args=""
  local i=0

  if [[ -n "$AUDIO_ORDER" ]]; then
    # Use the provided ORDER (1-based among audio streams), filter invalid indices.
    IFS=',' read -ra ORDER <<< "$AUDIO_ORDER"
    local valid_count=0
    for ord in "${ORDER[@]}"; do
      if [[ ! "$ord" =~ ^[0-9]+$ ]]; then log "Skipping invalid audio index: $ord"; continue; fi
      if (( ord < 1 )); then log "Skipping out-of-range audio index: $ord"; continue; fi
      local zero=$((ord-1))
      if (( zero >= total_a )); then
        log "Skipping audio index $ord (only $total_a audio stream(s) present)"
        continue
      fi
      args+=" -map 0:a:${zero} "
      ((valid_count++))
    done
    if (( valid_count == 0 )); then
      log "No valid audio indices from --audio. Falling back to first audio."
      args+=" -map 0:a:0 "
      valid_count=1
    fi

    if [[ "$AUDIO_MODE" == "copy" ]]; then
      # Remux all selected audio streams as-is
      args+=" -c:a copy "
    else
      # Re-encode each selected audio stream individually
      i=0
      for ord in "${ORDER[@]}"; do
        local zero=$((ord-1))
        if (( zero < 0 || zero >= total_a )); then continue; fi
        local ch; ch="$(channels_for_audio_n "$src" "$zero")"
        if [[ -z "$ch" ]]; then ch=2; fi
        if (( ch > 2 )); then
          args+=" -c:a:${i} aac -b:a:${i} ${AUDIO_SURROUND_BITRATE} -ac:${i} 6 "
        else
          args+=" -c:a:${i} aac -b:a:${i} ${AUDIO_STEREO_BITRATE} -ac:${i} 2 "
        fi
        ((i++))
      done
    fi
    # First selected audio becomes default; clear default on others
    # (ffmpeg sets default on first a-track by default, but we enforce explicitly)
    args+=" -disposition:a:0 default "
    # Ensure others not default
    local idx=1
    while (( idx < i )); do
      args+=" -disposition:a:${idx} 0 "
      ((idx++))
    done
  else
    # No AUDIO_ORDER supplied: keep first audio only, encode per channels
    args+=" -map 0:a:0 "
    local ch; ch="$(channels_for_audio_n "$src" "0")"
    if [[ -z "$ch" ]]; then ch=2; fi
    if (( ch > 2 )); then
      args+=" -c:a aac -b:a ${AUDIO_SURROUND_BITRATE} -ac 6 "
    else
      args+=" -c:a aac -b:a ${AUDIO_STEREO_BITRATE} -ac 2 "
    fi
    args+=" -disposition:a:0 default "
  fi

  printf "%s" "$args"
}

# Copy all subs if present
subs_args() { printf -- "-map 0:s? -c:s copy "; }

# -------- Main loop --------
i=0
for in_file in "${FILES[@]}"; do
  ((i++))
  rel="${in_file#$INPUT_DIR/}"
  base="${rel%.*}"
  out_dir_for_file="$(dirname "$OUT_DIR/$rel")"
  mkdir -p "$out_dir_for_file"
  out_file="$out_dir_for_file/${base}.mkv"

  if [[ -f "$out_file" ]]; then
    log "[$i/${#FILES[@]}] SKIP (exists): $out_file"
    continue
  fi

  v_args="$(video_args)"
  a_args="$(audio_args "$in_file")"
  s_args="$(subs_args)"

  log "[$i/${#FILES[@]}] Encoding: $rel"
  log "Output: $out_file"
  set -x
  ffmpeg -hide_banner -y -i "$in_file" \
    $v_args \
    $a_args \
    $s_args \
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