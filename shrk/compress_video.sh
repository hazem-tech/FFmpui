#!/usr/bin/env bash
#
# compress_video.sh — the shrk Mac app's engine (run by the app, one video
# at a time). The app calls it once or twice per video:
#
#   Size / Size + Quality:
#     1. compress_video.sh --mode size|quality [--scale <f>] --encode-only -- <video>
#        encodes with x265, checks the result opens and is just as long, and
#        prints "@@ENCODED <file>"
#     2. the app copies the original's metadata into <file> (MetadataCopier,
#        byte for byte, as on iPhone)
#     3. compress_video.sh --encoded <file> -- <video>  (below)
#   Size + Speed: the app encodes (VideoTranscoder) and copies the metadata
#     itself, then runs step 3.
#
#   compress_video.sh --encoded <file> -- <video>
#     checks <file> again, gives it the original's Finder tags / other
#     extended attributes, permissions and created / modified dates, and moves
#     it into place ("<name>_copy.<ext>" next to the original, or over it with
#     --replace). <file> is deleted if anything fails.
#
#   --mode size       x265: the smallest file possible, whatever it looks like;
#                     frame rate capped at 24
#   --mode quality    x265, 10-bit: for each video, the smallest file that still
#                     scores VMAF 95 against the original; same frame rate. Slow.
#   --scale <f>       width and height factor: 1 (default), 0.5 or 0.25
#   --vmaf <score>    quality mode's target (default 95; the app's Quality
#                     menu: 97 / 95 / 92)
#   --replace         overwrite the original (default: keep it)
#
# Every audio track is copied untouched, as are timecode, telemetry and other
# data tracks when the container allows; the rotation flag is kept (pixels
# are not rotated).
#
# Requires: ffmpeg, ffprobe (brew install ffmpeg). Quality mode uses ffmpeg's
# libvmaf (included in Homebrew's ffmpeg); without it, a fixed quality setting
# is used.
#
# Lines for the app start with "@@":
#   @@FILE_START <path>
#   @@DURATION <seconds>
#   @@PHASE <text>            what the script is doing (e.g. the quality search)
#   @@ENCODED <path>          --encode-only: the encoded, checked file
#   @@FILE_DONE <input-bytes> <output-bytes> <output-path>
#   @@FILE_FAIL <reason>
#   @@FILE_SKIP <reason>      the result wasn't smaller: the original is kept
# ffmpeg's own "-progress" lines (out_time_us=…) are also printed to stdout.

set -uo pipefail

# GUI apps don't inherit the shell PATH, so add the usual Homebrew/MacPorts dirs.
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MODE=""
SCALE="1"
REPLACE=0
ENCODED=""
ENCODE_ONLY=0
INPUTS=()
SUFFIX="_copy"
VMAF_TARGET=95

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; MODE="${1:?--mode needs a value}" ;;
    --scale) shift; SCALE="${1:?--scale needs a value}" ;;
    --vmaf) shift; VMAF_TARGET="${1:?--vmaf needs a value}" ;;
    --replace) REPLACE=1 ;;
    --encoded) shift; ENCODED="${1:?--encoded needs a file}" ;;
    --encode-only) ENCODE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; INPUTS+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) INPUTS+=("$1") ;;
  esac
  shift
done

if [ ${#INPUTS[@]} -ne 1 ]; then
  echo "Give exactly one video." >&2
  usage >&2
  [ -n "$ENCODED" ] && rm -f "$ENCODED"
  exit 2
fi
if [ -z "$ENCODED" ]; then
  case "$MODE" in
    size|quality) ;;
    *) echo "Use --mode size or --mode quality, or --encoded <file>." >&2; exit 2 ;;
  esac
fi
if ! awk -v v="$VMAF_TARGET" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= 100) }'; then
  echo "--vmaf must be a score between 0 and 100" >&2
  exit 2
fi
if ! awk -v s="$SCALE" 'BEGIN { exit !(s + 0 > 0 && s + 0 <= 1) }'; then
  echo "--scale must be a number above 0 and at most 1 (e.g. 1, 0.5, 0.25)" >&2
  exit 2
fi
if [ -n "$ENCODED" ] && [ ! -f "$ENCODED" ]; then
  echo "@@FILE_START ${INPUTS[0]}"
  echo "@@FILE_FAIL Encoded file not found"
  exit 1
fi

for tool in ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    [ -n "$ENCODED" ] && rm -f "$ENCODED"
    echo "@@FILE_FAIL Missing '$tool'. Install it with: brew install ffmpeg"
    echo "Error: '$tool' not found. Install it with: brew install ffmpeg" >&2
    exit 3
  fi
done

# Clean up a half-written temp file if we are stopped or crash.
CURRENT_TMP=""
FFMPEG_PID=""
SEARCH_DIR=""
cleanup() {
  [ -n "$FFMPEG_PID" ] && kill "$FFMPEG_PID" 2>/dev/null
  [ -n "$CURRENT_TMP" ] && rm -f "$CURRENT_TMP"
  [ -n "$SEARCH_DIR" ] && rm -rf "$SEARCH_DIR"
  # An --encoded file is gone once it was moved into place; anything left over
  # is a failed or stopped run.
  [ -n "$ENCODED" ] && rm -f "$ENCODED"
}
trap cleanup EXIT
trap 'echo "Stopped." >&2; exit 143' INT TERM


file_size() { wc -c < "$1" | tr -d ' '; }

probe_duration() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}

# Run ffmpeg in the background so a Stop request can kill it immediately.
run_ffmpeg() {
  ffmpeg "$@" &
  FFMPEG_PID=$!
  wait "$FFMPEG_PID"
  local rc=$?
  FFMPEG_PID=""
  return $rc
}

# ---------------------------------------------------------------------------
# Encoding settings per mode. Audio is never re-encoded in any mode.

FPS_CAP=24                  # size: frame rate limit (lower rates are kept)
QUALITY_KEYFRAME_SECONDS=10
X265_QUIET="log-level=error"
# size: the smallest file x265 can make. Found by searching x265's options on
# real iPhone footage (Tests/tune.sh, Tests/tune/size.txt): no SAO, 4×4
# transforms only, wide motion search, chroma at the highest quantizer and a
# single keyframe. This gives under a third of the bytes of plain "-crf 51"
# at every scale (slower presets give *bigger* files at this quantizer), and
# it is quick. (min-cu-size=32 was dropped: with x265 4.3 it tripled the
# size at 640×360.)
SIZE_PRESET="${SHRK_SIZE_PRESET:-veryfast}"
SIZE_CRF="${SHRK_SIZE_CRF:-51}"
SIZE_X265="${SHRK_SIZE_X265:-keyint=-1:qpmin=51:aq-mode=0:sao=0:me=umh:subme=0:merange=200:max-tu-size=4:rc-lookahead=5:cbqpoffs=12:crqpoffs=12:rskip=2:max-merge=1}"
# quality: 10-bit x265 at the slower preset; the CRF is picked per video
# (below). Chosen with Tests/tune.sh (bytes needed for VMAF 95 on the test
# clips): aq-mode 4 + no SAO + psy-rd 1.0 needs 16% fewer bytes than the
# usual aq-mode 3; veryslow saves under 1% more for about twice the time.
# (The SHRK_* environment variables are for tune.sh.)
QUALITY_PRESET="${SHRK_QUALITY_PRESET:-slower}"
QUALITY_X265="${SHRK_QUALITY_X265:-aq-mode=4:sao=0:psy-rd=1.0}"
QUALITY_CRF_MIN=14
QUALITY_CRF_MAX=36
QUALITY_CRF_FALLBACK=22     # used when ffmpeg has no libvmaf

is_ten_bit() {
  case "$1" in
    *10le|*10be|*12le|*12be|p010*|p012*|p016*) return 0 ;;
    *) return 1 ;;
  esac
}

cpu_count() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; }

# Reads the main video stream into V_WIDTH, V_HEIGHT, V_FPS (decimal) and
# V_PIXFMT.
probe_video() {
  local key value avg="" rfr=""
  V_WIDTH=""; V_HEIGHT=""; V_PIXFMT=""
  while IFS='=' read -r key value; do
    case "$key" in
      width) V_WIDTH="$value" ;;
      height) V_HEIGHT="$value" ;;
      avg_frame_rate) avg="$value" ;;
      r_frame_rate) rfr="$value" ;;
      pix_fmt) V_PIXFMT="$value" ;;
    esac
  done < <(ffprobe -v error -select_streams V:0 \
             -show_entries stream=width,height,avg_frame_rate,r_frame_rate,pix_fmt \
             -of default=nw=1 "$1" 2>/dev/null)
  V_FPS=$(awk -v a="$avg" -v r="$rfr" '
    function rate(x,   p) { if (split(x, p, "/") == 2 && p[2] + 0 > 0) return p[1] / p[2]; return x + 0 }
    BEGIN { f = rate(a); if (f <= 0 || f > 1000) f = rate(r); printf "%.3f", f }')
}

# Width/height after --scale: rounded down to an even number (4:2:0 video).
scaled() { awk -v d="$1" -v s="$SCALE" 'BEGIN { v = int(d * s / 2) * 2; if (v < 2) v = 2; print v }'; }

# Decides the filters and video encoder arguments for one file:
#   SCALE_FILTER  "scale=W:H" or empty
#   VIDEO_FILTER  fps cap + scale, or empty
#   OUT_FPS       output frame rate (decimal)
#   VIDEO_ARGS    encoder arguments (array); quality mode adds the CRF later
plan_video() {
  local src="$1"
  probe_video "$src"

  SCALE_FILTER=""
  if [ -n "$V_WIDTH" ] && [ -n "$V_HEIGHT" ]; then
    local w h
    w=$(scaled "$V_WIDTH"); h=$(scaled "$V_HEIGHT")
    if [ "$w" != "$V_WIDTH" ] || [ "$h" != "$V_HEIGHT" ]; then
      SCALE_FILTER="scale=${w}:${h}"
      [ "$MODE" = "quality" ] && SCALE_FILTER="${SCALE_FILTER}:flags=lanczos"
    fi
  fi

  local fps_filter=""
  OUT_FPS="$V_FPS"
  if [ "$MODE" = "size" ] && awk -v f="$V_FPS" -v c="$FPS_CAP" 'BEGIN { exit !(f > c + 0.05) }'; then
    fps_filter="fps=$FPS_CAP"
    OUT_FPS="$FPS_CAP"
  fi
  VIDEO_FILTER="$fps_filter"
  if [ -n "$SCALE_FILTER" ]; then
    VIDEO_FILTER="${VIDEO_FILTER:+$VIDEO_FILTER,}$SCALE_FILTER"
  fi

  local gop
  gop=$(awk -v f="$OUT_FPS" -v s="$QUALITY_KEYFRAME_SECONDS" 'BEGIN { g = int(f * s + 0.5); if (g < 1) g = 1; print g }')

  case "$MODE" in
    size)
      local pix=yuv420p
      is_ten_bit "$V_PIXFMT" && pix=yuv420p10le   # keeps HDR (HLG/PQ) intact
      VIDEO_ARGS=(-c:v:0 libx265 -tag:v:0 hvc1 -pix_fmt:v:0 "$pix" -preset "$SIZE_PRESET"
                  -crf "$SIZE_CRF" -x265-params "$X265_QUIET:$SIZE_X265")
      ;;
    quality)
      VIDEO_ARGS=(-c:v:0 libx265 -tag:v:0 hvc1 -pix_fmt:v:0 yuv420p10le -preset "$QUALITY_PRESET"
                  -x265-params "$X265_QUIET:keyint=$gop:$QUALITY_X265")
      ;;
  esac
}

has_libvmaf() { ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' libvmaf '; }

# ---------------------------------------------------------------------------
# Quality mode: find the highest CRF (smallest file) whose VMAF score against
# the original still reaches VMAF_TARGET. The test encodes use the same settings as
# the real one, on the whole clip if it is short or on 6 spread-out 3-second
# pieces otherwise. Prints the CRF; progress notes go to stderr.

# Inputs for the test pieces, starting at input index 1 of the VMAF run.
sample_inputs() {
  local src="$1" duration="$2" i start
  SAMPLE_ARGS=()
  SAMPLE_COUNT=0
  if awk -v d="$duration" 'BEGIN { exit !(d + 0 <= 30) }'; then
    SAMPLE_ARGS=(-noautorotate -i "$src")
    SAMPLE_COUNT=1
    return
  fi
  for i in 0 1 2 3 4 5; do
    start=$(awk -v d="$duration" -v i="$i" 'BEGIN { printf "%.3f", d * (i + 0.5) / 6 - 1.5 }')
    SAMPLE_ARGS+=(-ss "$start" -t 3 -noautorotate -i "$src")
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
  done
}

# Filter graph joining the test pieces (inputs first..first+count-1) into [label],
# with the mode's filters applied.
sample_graph() {
  local first="$1" label="$2" i graph=""
  for ((i = 0; i < SAMPLE_COUNT; i++)); do graph+="[$((first + i)):V:0]"; done
  if [ "$SAMPLE_COUNT" -gt 1 ]; then
    graph+="concat=n=$SAMPLE_COUNT:v=1:a=0"
    [ -n "$VIDEO_FILTER" ] && graph+=",$VIDEO_FILTER"
  else
    graph+="${VIDEO_FILTER:-null}"
  fi
  printf '%s[%s]' "$graph" "$label"
}

# Sets VMAF_SCORE to the VMAF of the test pieces encoded at CRF $1.
# (Runs in the main shell, so Stop can kill its ffmpeg.)
vmaf_at() {
  local crf="$1" probe="$SEARCH_DIR/probe.mp4"
  VMAF_SCORE=""
  rm -f "$probe"
  run_ffmpeg -nostdin -hide_banner -loglevel error -y "${SAMPLE_ARGS[@]}" \
      -filter_complex "$(sample_graph 0 v)" -map '[v]' -an \
      "${VIDEO_ARGS[@]}" -crf "$crf" "$probe" >/dev/null 2>"$SEARCH_DIR/encode.log" || return 1
  # -noautorotate: the test encode carries the rotation flag too, and both
  # sides must stay unrotated to be compared.
  run_ffmpeg -nostdin -hide_banner -loglevel info -noautorotate -i "$probe" "${SAMPLE_ARGS[@]}" \
      -filter_complex "[0:v]settb=1/1000,setpts=N*40[d];$(sample_graph 1 s);[s]format=yuv420p10le,settb=1/1000,setpts=N*40[r];[d][r]libvmaf=n_threads=$(cpu_count)" \
      -f null - >/dev/null 2>"$SEARCH_DIR/vmaf.log" || return 1
  VMAF_SCORE=$(sed -n 's/.*VMAF score: *\([0-9.]*\).*/\1/p' "$SEARCH_DIR/vmaf.log" | tail -n1)
  [ -n "$VMAF_SCORE" ]
}

# Sets QUALITY_CRF for `src`.
pick_quality_crf() {
  local src="$1" duration="${2:-0}" name
  name=$(basename "$src")
  QUALITY_CRF=$QUALITY_CRF_FALLBACK
  if ! has_libvmaf; then
    echo "Note: this ffmpeg has no libvmaf, so quality mode uses CRF $QUALITY_CRF_FALLBACK for every video." >&2
    return
  fi
  SEARCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shrk-search.XXXXXX") || return
  sample_inputs "$src" "$duration"

  # Binary search for the highest CRF that reaches the target; the answer
  # stays within [lo, hi].
  local lo=$QUALITY_CRF_MIN hi=$QUALITY_CRF_MAX mid best_score=""
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi + 1) / 2 ))
    echo "@@PHASE Finding the best quality setting (trying CRF $mid)"
    if ! vmaf_at "$mid"; then
      local why
      why=$(cat "$SEARCH_DIR/encode.log" "$SEARCH_DIR/vmaf.log" 2>/dev/null | grep -iE 'error|invalid|fail|mismatch' | tail -n1)
      echo "Note: the quality search failed for '$name' (${why:-no details}); using CRF $QUALITY_CRF_FALLBACK." >&2
      rm -rf "$SEARCH_DIR"; SEARCH_DIR=""
      return
    fi
    echo "Quality search: CRF $mid → VMAF $VMAF_SCORE" >&2
    if awk -v s="$VMAF_SCORE" -v t="$VMAF_TARGET" 'BEGIN { exit !(s + 0 >= t + 0) }'; then
      lo=$mid; best_score=$VMAF_SCORE
    else
      hi=$((mid - 1))
    fi
  done
  rm -rf "$SEARCH_DIR"; SEARCH_DIR=""
  QUALITY_CRF=$lo
  echo "Quality: CRF $lo${best_score:+ (VMAF $best_score)} for '$name'" >&2
}

encode() {
  local src="$1" dst="$2" duration="$3"
  plan_video "$src"

  if [ "$MODE" = "quality" ]; then
    pick_quality_crf "$src" "$duration"
    VIDEO_ARGS+=(-crf "$QUALITY_CRF")
  fi
  echo "@@PHASE Compressing"

  local hwaccel=()
  # Decode on the media engine where possible (less CPU, less heat); ffmpeg
  # falls back to software decoding by itself.
  [ "$(uname)" = "Darwin" ] && hwaccel=(-hwaccel videotoolbox)
  local filter=()
  [ -n "$VIDEO_FILTER" ] && filter=(-filter:v:0 "$VIDEO_FILTER")

  local common_in=(-nostdin -hide_banner -loglevel warning -y -progress pipe:1 -nostats
                   "${hwaccel[@]+"${hwaccel[@]}"}" -noautorotate -i "$src")
  local common_out=(-map_metadata 0 -map_chapters 0
                    -c:a copy -c:d copy -c:s copy
                    "${filter[@]+"${filter[@]}"}" "${VIDEO_ARGS[@]}"
)

  # Attempt 1: main video + all audio + all data tracks (timecode, GoPro GPMF,
  # DJI/Apple metadata, …) + subtitles.
  if run_ffmpeg "${common_in[@]}" \
       -map 0:V:0 -map '0:a?' -map '0:d?' -map '0:s?' -copy_unknown \
       "${common_out[@]}" "$dst"; then
    return 0
  fi

  # Attempt 2: some data tracks can't be written into the container by ffmpeg.
  # Fall back to video + all audio (the metadata step below still copies the
  # camera/lens/GPS tags).
  echo "Note: some data tracks could not be kept for '$(basename "$src")'; retrying with video + audio only." >&2
  run_ffmpeg "${common_in[@]}" \
    -map 0:V:0 -map '0:a?' \
    "${common_out[@]}" "$dst"
}

copy_file_attributes() {
  local src="$1" dst="$2"

  # Finder tags, comments, "Where from", etc. (macOS extended attributes).
  if command -v xattr >/dev/null 2>&1 && [ "$(uname)" = "Darwin" ]; then
    local name value
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      value=$(xattr -px "$name" "$src" 2>/dev/null) || continue
      xattr -wx "$name" "$value" "$dst" 2>/dev/null || true
    done < <(xattr "$src" 2>/dev/null)
  fi

  # Permissions.
  local mode
  if [ "$(uname)" = "Darwin" ]; then
    mode=$(stat -f %Lp "$src" 2>/dev/null)
  else
    mode=$(stat -c %a "$src" 2>/dev/null)
  fi
  [ -n "${mode:-}" ] && chmod "$mode" "$dst" 2>/dev/null

  # File dates — this must be the very last write to the file: exactly the
  # same created and modified dates as the original. On macOS, giving a file
  # a modified date earlier than its created date moves the created date too,
  # so first set the original's created date as the modified date, then the
  # real modified date.
  if [ "$(uname)" = "Darwin" ]; then
    local created
    created=$(stat -f %B "$src" 2>/dev/null)
    if [ -n "$created" ] && [ "$created" -gt 0 ]; then
      touch -m -t "$(date -r "$created" +%Y%m%d%H%M.%S)" "$dst"
    fi
  fi
  touch -r "$src" "$dst"
}

process_file() {
  local src="$1"
  local dir base name ext final work

  dir=$(cd "$(dirname "$src")" && pwd) || { echo "@@FILE_FAIL Can't open folder"; return 1; }
  base=$(basename "$src")
  src="$dir/$base"
  name="${base%.*}"
  ext="${base##*.}"

  echo "@@FILE_START $src"

  if [ ! -f "$src" ]; then
    echo "@@FILE_FAIL File not found"
    return 1
  fi

  if [ "$REPLACE" -eq 1 ]; then
    final="$src"
    work="$dir/.${name}.shrk-tmp.${ext}"
  else
    final="$dir/${name}${SUFFIX}.${ext}"
    work="$dir/.${name}${SUFFIX}.shrk-tmp.${ext}"
  fi
  if [ -n "$ENCODED" ]; then
    work="$ENCODED"
  fi
  CURRENT_TMP="$work"

  local duration
  duration=$(probe_duration "$src")
  [ -n "$duration" ] && echo "@@DURATION $duration"

  # 1. Compress (unless the app already did it)
  if [ -z "$ENCODED" ] && ! encode "$src" "$work" "$duration"; then
    rm -f "$work"; CURRENT_TMP=""
    echo "@@FILE_FAIL ffmpeg could not encode this file"
    return 1
  fi

  # 2. Sanity check: the new file must be readable and just as long.
  local new_duration
  new_duration=$(probe_duration "$work")
  if [ -z "$new_duration" ] || { [ -n "$duration" ] && ! awk -v a="$duration" -v b="$new_duration" \
        'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 1.0 || d <= a * 0.01) }'; }; then
    rm -f "$work"; CURRENT_TMP=""
    echo "@@FILE_FAIL Output check failed (duration ${new_duration:-?}s vs ${duration:-?}s); original left untouched"
    return 1
  fi

  # --encode-only: hand the file to the app for the metadata (step 3 is its
  # job), then it runs us again with --encoded.
  if [ "$ENCODE_ONLY" -eq 1 ]; then
    CURRENT_TMP=""
    echo "@@ENCODED $work"
    return 0
  fi

  local in_size out_size
  in_size=$(file_size "$src")
  out_size=$(file_size "$work")

  # Never replace a video with a bigger one (an already well-compressed
  # original in a quality mode): keep the original and say so.
  if [ "$out_size" -ge "$in_size" ]; then
    rm -f "$work"; CURRENT_TMP=""
    echo "@@FILE_SKIP Kept the original: it's already smaller than this mode makes it"
    return 0
  fi

  # 3. Extended attributes, permissions and file dates
  copy_file_attributes "$src" "$work"

  # 4. Move into place (a rename keeps the dates we just set)
  if ! mv -f "$work" "$final"; then
    rm -f "$work"; CURRENT_TMP=""
    echo "@@FILE_FAIL Could not write $final"
    return 1
  fi
  CURRENT_TMP=""

  echo "@@FILE_DONE $in_size $out_size $final"
  return 0
}

process_file "${INPUTS[0]}"
