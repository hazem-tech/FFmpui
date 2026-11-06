#!/usr/bin/env bash
#
# compress_video.sh — FFmpui's compression engine.
#
# Re-encodes videos to HEVC (hardware accelerated through VideoToolbox) and
# carries over *everything* from the original that can be carried over:
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
#   --replace             Replace the original file (default: keep the original
#                         and write "<name>_copy.<ext>" next to it).
#   --use-recording-date  Set the file's created/modified date to the date the
#                         clip was recorded instead of copying the original
#                         file's dates.
#   --bitrate <value>     Video bitrate passed to ffmpeg (default: 1, same as
#                         the original only_bit.sh script).
#   --encoder <name>      Video encoder (default: hevc_videotoolbox).
#   -h, --help            Show this help.
#
# Folders are searched recursively for .mp4 / .mov / .m4v files.
# Files that already end in "_copy" are skipped when scanning a folder.
#
# Requires: ffmpeg, ffprobe, exiftool (brew install ffmpeg exiftool)
#
# Machine-readable lines (used by the FFmpui app) start with "@@":
#   @@FILE_START <path>
#   @@DURATION <seconds>
#   @@FILE_DONE <input-bytes> <output-bytes> <output-path>
#   @@FILE_FAIL <reason>
#   @@FILE_SKIP <reason>
# ffmpeg's own "-progress" lines (out_time_us=…) are also printed to stdout.

set -uo pipefail

# GUI apps don't inherit the shell PATH, so add the usual Homebrew/MacPorts dirs.
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

REPLACE=0
USE_RECORDING_DATE=0
BITRATE="1"
ENCODER="hevc_videotoolbox"
INPUTS=()

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --replace) REPLACE=1 ;;
    --use-recording-date) USE_RECORDING_DATE=1 ;;
    --bitrate) shift; BITRATE="${1:?--bitrate needs a value}" ;;
    --encoder) shift; ENCODER="${1:?--encoder needs a value}" ;;
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

for tool in ffmpeg ffprobe exiftool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "@@FILE_FAIL Missing '$tool'. Install it with: brew install ffmpeg exiftool"
    echo "Error: '$tool' not found. Install it with: brew install ffmpeg exiftool" >&2
    exit 3
  fi
done

# Clean up a half-written temp file if we are stopped or crash.
CURRENT_TMP=""
FFMPEG_PID=""
cleanup() {
  [ -n "$FFMPEG_PID" ] && kill "$FFMPEG_PID" 2>/dev/null
  [ -n "$CURRENT_TMP" ] && rm -f "$CURRENT_TMP"
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

encode() {
  local src="$1" dst="$2"
  local common_in=(-nostdin -hide_banner -loglevel warning -y -progress pipe:1 -nostats
                   -noautorotate -i "$src")
  local common_out=(-map_metadata 0 -map_chapters 0
                    -c:a copy -c:d copy -c:s copy
                    -c:v:0 "$ENCODER" -tag:v:0 hvc1 -b:v:0 "$BITRATE"
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
    final="$dir/${name}_copy.${ext}"
    work="$dir/.${name}_copy.ffmpui-tmp.${ext}"
  fi
  CURRENT_TMP="$work"

  local duration
  duration=$(probe_duration "$src")
  [ -n "$duration" ] && echo "@@DURATION $duration"

  # 1. Compress
  if ! encode "$src" "$work"; then
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

  # 4. Extended attributes, permissions and file dates
  copy_file_attributes "$src" "$work"

  local in_size out_size
  in_size=$(file_size "$src")
  out_size=$(file_size "$work")

  # 5. Move into place (a rename keeps the dates we just set)
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
      case "$n" in *_copy) continue ;; esac
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
