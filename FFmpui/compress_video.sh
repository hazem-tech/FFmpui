#!/usr/bin/env bash
#
# compress_video.sh — FFmpui's compression engine.
#
# Re-encodes videos to HEVC and carries over *everything* from the original
# that can be carried over:
#
#   • every audio track, timecode, GoPro/DJI telemetry and other data tracks
#   • camera make / model / serial, lens make / model, focal length, ISO,
#     aperture, shutter, GPS location, Apple "Keys" tags (Live Photo IDs,
#     software, location, creation date with time zone, …), XMP, UserData
#   • the QuickTime internal dates (movie / track / media create & modify)
#   • the rotation flag (pixels are NOT rotated, so nothing is rotated twice)
#   • the macOS file dates (created + modified), Finder tags / extended
#     attributes, and file permissions
#
# Usage:
#   compress_video.sh [options] <file-or-folder>...
#
# Options:
#   --mode <mode>         What to optimize for (default: speed):
#                           speed    smallest file the hardware encoder
#                                    (hevc_videotoolbox) can make, quickly and
#                                    without much heat; frame rate capped at 24
#                           quality  x265 (10-bit): for each video, the
#                                    smallest file that still looks like the
#                                    original (VMAF target, see --vmaf); same
#                                    frame rate. Slow.
#                           size     x265: the smallest file possible, whatever
#                                    it looks like; frame rate capped at 24
#   --scale <factor>      Width and height factor: 1 (default), 0.5 or 0.25.
#   --vmaf <score>        Quality mode's target VMAF score (default: 95).
#   --replace             Replace the original file (default: keep the original
#                         and write "<name>_copy.<ext>" next to it).
#   --use-recording-date  Set the file's created/modified date to the date the
#                         clip was recorded instead of copying the original
#                         file's dates.
#   --bitrate <value>     Speed mode: video bitrate passed to ffmpeg (default:
#                         1, i.e. the lowest the encoder allows).
#   --encoder <name>      Speed mode: video encoder (default: hevc_videotoolbox).
#   --suffix <text>       Name ending for the kept-originals output
#                         (default: _copy, giving "<name>_copy.<ext>").
#   --encoded <file>      Skip the ffmpeg step: <file> was already encoded
#                         (e.g. by the app's AVFoundation encoder) from the
#                         single input given. It is checked, gets all the
#                         metadata / file attributes, and is moved into place
#                         (it is deleted if anything fails).
#   -h, --help            Show this help.
#
# Audio is always copied untouched, in every mode.
#
# Folders are searched recursively for .mp4 / .mov / .m4v files.
# Files that already end in "_copy" or "_copy_avf" are skipped when scanning
# a folder.
#
# Requires: ffmpeg, ffprobe, exiftool (brew install ffmpeg exiftool).
# Quality mode uses ffmpeg's libvmaf (included in Homebrew's ffmpeg); without
# it, a fixed quality setting is used.
#
# Machine-readable lines (used by the FFmpui app) start with "@@":
#   @@FILE_START <path>
#   @@DURATION <seconds>
#   @@PHASE <text>            what the script is doing (e.g. the quality search)
#   @@FILE_DONE <input-bytes> <output-bytes> <output-path>
#   @@FILE_FAIL <reason>
#   @@FILE_SKIP <reason>
# ffmpeg's own "-progress" lines (out_time_us=…) are also printed to stdout.

set -uo pipefail

# GUI apps don't inherit the shell PATH, so add the usual Homebrew/MacPorts dirs.
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MODE="speed"
SCALE="1"
VMAF_TARGET="95"
REPLACE=0
USE_RECORDING_DATE=0
BITRATE="1"
ENCODER="hevc_videotoolbox"
SUFFIX="_copy"
ENCODED=""
INPUTS=()

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) shift; MODE="${1:?--mode needs a value}" ;;
    --scale) shift; SCALE="${1:?--scale needs a value}" ;;
    --vmaf) shift; VMAF_TARGET="${1:?--vmaf needs a value}" ;;
    --replace) REPLACE=1 ;;
    --use-recording-date) USE_RECORDING_DATE=1 ;;
    --bitrate) shift; BITRATE="${1:?--bitrate needs a value}" ;;
    --encoder) shift; ENCODER="${1:?--encoder needs a value}" ;;
    --suffix) shift; SUFFIX="${1:?--suffix needs a value}" ;;
    --encoded) shift; ENCODED="${1:?--encoded needs a file}" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; INPUTS+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) INPUTS+=("$1") ;;
  esac
  shift
done

if [ ${#INPUTS[@]} -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$MODE" in
  speed|quality|size) ;;
  *) echo "Unknown --mode '$MODE' (use speed, quality or size)" >&2; exit 2 ;;
esac
if ! awk -v s="$SCALE" 'BEGIN { exit !(s + 0 > 0 && s + 0 <= 1) }'; then
  echo "--scale must be a number above 0 and at most 1 (e.g. 1, 0.5, 0.25)" >&2
  exit 2
fi
if ! awk -v v="$VMAF_TARGET" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= 100) }'; then
  echo "--vmaf must be a score between 0 and 100" >&2
  exit 2
fi

if [ -n "$ENCODED" ]; then
  if [ ${#INPUTS[@]} -ne 1 ] || [ ! -f "${INPUTS[0]}" ]; then
    echo "--encoded needs exactly one input file" >&2
    rm -f "$ENCODED"
    exit 2
  fi
  if [ ! -f "$ENCODED" ]; then
    echo "@@FILE_START ${INPUTS[0]}"
    echo "@@FILE_FAIL Encoded file not found"
    exit 1
  fi
fi

for tool in ffmpeg ffprobe exiftool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    [ -n "$ENCODED" ] && rm -f "$ENCODED"
    echo "@@FILE_FAIL Missing '$tool'. Install it with: brew install ffmpeg exiftool"
    echo "Error: '$tool' not found. Install it with: brew install ffmpeg exiftool" >&2
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

EXIFTOOL=(exiftool -q -q -m -api LargeFileSupport=1 -api QuickTimeUTC=1)

is_video() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mp4|mov|m4v) return 0 ;;
    *) return 1 ;;
  esac
}

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

FPS_CAP=24                  # speed / size: frame rate limit (lower rates are kept)
SPEED_KEYFRAME_SECONDS=10   # speed: one keyframe every 10 s (ffmpeg's default is every 12 frames)
QUALITY_KEYFRAME_SECONDS=10
X265_QUIET="log-level=error"
# size: the smallest file x265 can make. Found by searching x265's options on
# real iPhone footage (Tests/tune.sh): no SAO, 4×4 transforms only, big CUs,
# wide motion search, chroma at the highest quantizer and a single keyframe.
# This gives less than half the bytes of plain "-crf 51" (slower presets give
# *bigger* files at this quantizer), and it is quick.
SIZE_PRESET="${FFMPUI_SIZE_PRESET:-veryfast}"
SIZE_CRF="${FFMPUI_SIZE_CRF:-51}"
SIZE_X265="${FFMPUI_SIZE_X265:-keyint=-1:qpmin=51:aq-mode=0:sao=0:me=umh:subme=0:merange=200:min-cu-size=32:max-tu-size=4:rc-lookahead=5:cbqpoffs=12:crqpoffs=12:rskip=2:max-merge=1}"
# quality: 10-bit x265 at the slower preset; the CRF is picked per video
# (below). Chosen with Tests/tune.sh (bytes needed for VMAF 95 on the test
# clips): aq-mode 4 + no SAO + psy-rd 1.0 needs 16% fewer bytes than the
# usual aq-mode 3; veryslow saves under 1% more for about twice the time.
# (The FFMPUI_* environment variables are for tune.sh.)
QUALITY_PRESET="${FFMPUI_QUALITY_PRESET:-slower}"
QUALITY_X265="${FFMPUI_QUALITY_X265:-aq-mode=4:sao=0:psy-rd=1.0}"
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
  if [ "$MODE" != "quality" ] && awk -v f="$V_FPS" -v c="$FPS_CAP" 'BEGIN { exit !(f > c + 0.05) }'; then
    fps_filter="fps=$FPS_CAP"
    OUT_FPS="$FPS_CAP"
  fi
  VIDEO_FILTER="$fps_filter"
  if [ -n "$SCALE_FILTER" ]; then
    VIDEO_FILTER="${VIDEO_FILTER:+$VIDEO_FILTER,}$SCALE_FILTER"
  fi

  local seconds=$SPEED_KEYFRAME_SECONDS
  [ "$MODE" = "quality" ] && seconds=$QUALITY_KEYFRAME_SECONDS
  local gop
  gop=$(awk -v f="$OUT_FPS" -v s="$seconds" 'BEGIN { g = int(f * s + 0.5); if (g < 1) g = 1; print g }')

  case "$MODE" in
    speed)
      VIDEO_ARGS=(-c:v:0 "$ENCODER" -tag:v:0 hvc1 -b:v:0 "$BITRATE" -g:v:0 "$gop")
      if [ "$ENCODER" = "hevc_videotoolbox" ]; then
        # Same as the apps' Size + Speed: the hardware encoder (or Apple's
        # software one if there is none), quantizer never below 51 (the
        # lowest bitrate alone leaves it far above that), no adaptive
        # quantization, power-saving.
        VIDEO_ARGS+=(-allow_sw 1 -qmin 51)
        vt_has_option spatial_aq && VIDEO_ARGS+=(-spatial_aq 0)
        vt_has_option power_efficient && VIDEO_ARGS+=(-power_efficient 1)
      fi
      ;;
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

VT_OPTIONS=""
vt_has_option() {
  [ -z "$VT_OPTIONS" ] && VT_OPTIONS=$(ffmpeg -hide_banner -h encoder=hevc_videotoolbox 2>/dev/null)
  printf '%s\n' "$VT_OPTIONS" | grep -q -- "-$1 "
}

has_libvmaf() { ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' libvmaf '; }

# ---------------------------------------------------------------------------
# Quality mode: find the highest CRF (smallest file) whose VMAF score against
# the original still reaches --vmaf. The test encodes use the same settings as
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
  SEARCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-search.XXXXXX") || return
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
                    -movflags +use_metadata_tags)

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

copy_metadata() {
  local src="$1" dst="$2"

  # Copy every writable tag in its original group (QuickTime Keys / ItemList /
  # UserData, XMP, track & media dates, rotation, GPS, Apple IDs, …).
  # Then also mirror the camera / lens / exposure / GPS info into standard
  # Apple Keys + XMP tags, because many cameras (Sony, Canon, DJI, GoPro…)
  # store them in maker-specific boxes that can't be written back as-is, and
  # this way Finder, Photos, Lightroom, DaVinci etc. still see them.
  "${EXIFTOOL[@]}" -overwrite_original \
    -tagsFromFile "$src" -all:all -unsafe \
    '-Keys:Make<Make' '-Keys:Model<Model' '-Keys:Software<Software' \
    '-Keys:CreationDate<CreationDate' \
    '-Keys:GPSCoordinates<GPSCoordinates' \
    '-UserData:Make<Make' '-UserData:Model<Model' \
    '-XMP-tiff:Make<Make' '-XMP-tiff:Model<Model' \
    '-XMP-exifEX:BodySerialNumber<SerialNumber' \
    '-XMP-exifEX:LensMake<LensMake' '-XMP-exifEX:LensModel<LensModel' \
    '-XMP-exifEX:LensModel<LensType' \
    '-XMP-exifEX:LensSerialNumber<LensSerialNumber' \
    '-XMP-aux:Lens<LensModel' \
    '-XMP-exif:FocalLength<FocalLength' \
    '-XMP-exif:FocalLengthIn35mmFormat<FocalLengthIn35mmFormat' \
    '-XMP-exif:FNumber<FNumber' '-XMP-exif:ExposureTime<ExposureTime' \
    '-XMP-exif:ISO<ISO' \
    '-XMP-exif:GPSLatitude<GPSLatitude' '-XMP-exif:GPSLongitude<GPSLongitude' \
    '-XMP-exif:GPSAltitude<GPSAltitude' \
    '-XMP-photoshop:DateCreated<CreationDate' \
    "$dst"
}

# The rotation matrix of the video track carries an offset that depends on the
# frame size (e.g. "0 1 0 -1 0 0 720 0 1" for a 1280×720 portrait clip). After
# scaling, ffmpeg still writes the original offset, which would shift the
# picture in some players, so recompute it for the new size.
fix_rotation_offset() {
  local dst="$1" group="" line matrix width height fixed
  while IFS= read -r line; do
    case "$line" in
      *"[Track"*"]"*vide*) group=$(printf '%s' "$line" | sed -n 's/^\[\(Track[0-9]*\)\].*/\1/p'); break ;;
    esac
  done < <("${EXIFTOOL[@]}" -a -G1 -n -HandlerType "$dst" 2>/dev/null)
  [ -n "$group" ] || return 0

  matrix=$("${EXIFTOOL[@]}" -n -s3 "-$group:MatrixStructure" "$dst" 2>/dev/null)
  width=$("${EXIFTOOL[@]}" -n -s3 "-$group:ImageWidth" "$dst" 2>/dev/null)
  height=$("${EXIFTOOL[@]}" -n -s3 "-$group:ImageHeight" "$dst" 2>/dev/null)
  [ -n "$matrix" ] && [ -n "$width" ] && [ -n "$height" ] || return 0

  # Matrix "a b u c d v tx ty w" maps (x, y) to (a·x + c·y + tx, b·x + d·y + ty).
  # The right offset moves the rotated frame's corner back to (0, 0).
  fixed=$(printf '%s\n' "$matrix" | awk -v W="$width" -v H="$height" '{
      a = $1; b = $2; c = $4; d = $5
      split("0 " W " 0 " W, xs, " "); split("0 0 " H " " H, ys, " ")
      for (i = 1; i <= 4; i++) {
        x = a * xs[i] + c * ys[i]; y = b * xs[i] + d * ys[i]
        if (i == 1 || x < minx) minx = x
        if (i == 1 || y < miny) miny = y
      }
      tx = -minx; ty = -miny
      if (tx == $7 && ty == $8) exit 1
      printf "%s %s %s %s %s %s %g %g %s", $1, $2, $3, $4, $5, $6, tx, ty, $9
    }') || return 0
  "${EXIFTOOL[@]}" -overwrite_original "-$group:MatrixStructure=$fixed" "$dst" \
    || echo "Warning: could not update the rotation of '$(basename "$dst")'." >&2
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

  # File dates — this must be the very last write to the file.
  # Start from the original file's dates (also the fallback if the clip has
  # no recording date).
  touch -r "$src" "$dst"
  if [ "$USE_RECORDING_DATE" -eq 1 ]; then
    # Later arguments win, so the most precise source (CreationDate, which
    # carries the time zone) goes last.
    "${EXIFTOOL[@]}" -overwrite_original -tagsFromFile "$dst" \
      '-FileModifyDate<CreateDate' '-FileModifyDate<CreationDate' \
      '-FileCreateDate<CreateDate' '-FileCreateDate<CreationDate' \
      "$dst"
  else
    # Exactly the same created/modified dates as the original file.
    "${EXIFTOOL[@]}" -overwrite_original -tagsFromFile "$src" \
      '-FileCreateDate<FileCreateDate' '-FileModifyDate<FileModifyDate' \
      "$dst"
    touch -r "$src" "$dst"
  fi
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
    work="$dir/.${name}.ffmpui-tmp.${ext}"
  else
    final="$dir/${name}${SUFFIX}.${ext}"
    work="$dir/.${name}${SUFFIX}.ffmpui-tmp.${ext}"
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

  # 3. Metadata (camera, lens, GPS, dates, …)
  if ! copy_metadata "$src" "$work"; then
    echo "Warning: exiftool reported a problem copying metadata for '$base'." >&2
  fi

  # 4. Rotation offset for the new frame size (no change when it is right)
  fix_rotation_offset "$work"

  # 5. Extended attributes, permissions and file dates
  copy_file_attributes "$src" "$work"

  local in_size out_size
  in_size=$(file_size "$src")
  out_size=$(file_size "$work")

  # 6. Move into place (a rename keeps the dates we just set)
  if ! mv -f "$work" "$final"; then
    rm -f "$work"; CURRENT_TMP=""
    echo "@@FILE_FAIL Could not write $final"
    return 1
  fi
  CURRENT_TMP=""

  echo "@@FILE_DONE $in_size $out_size $final"
  return 0
}

# Expand folders into the list of video files.
FILES=()
failed=0
for input in "${INPUTS[@]}"; do
  if [ -d "$input" ]; then
    while IFS= read -r -d '' f; do
      b=$(basename "$f")
      case "$b" in .*) continue ;; esac
      n="${b%.*}"
      case "$n" in *_copy|*_copy_avf) continue ;; esac
      is_video "$f" && FILES+=("$f")
    done < <(find "$input" -type f -print0 | sort -z)
  elif [ -f "$input" ]; then
    FILES+=("$input")
  else
    echo "@@FILE_START $input"
    echo "@@FILE_FAIL File not found"
    failed=$((failed + 1))
  fi
done

for f in "${FILES[@]+"${FILES[@]}"}"; do
  if ! is_video "$f"; then
    echo "@@FILE_START $f"
    echo "@@FILE_SKIP Not a .mp4/.mov/.m4v file"
    continue
  fi
  process_file "$f" || failed=$((failed + 1))
done

[ "$failed" -eq 0 ]
