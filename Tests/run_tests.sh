#!/usr/bin/env bash
#
# run_tests.sh script <mode> <fixture>      compress_video.sh --mode size|quality
# run_tests.sh harness <binary> <fixture>   the apps' shared Size + Speed
#                                           encoder (Tests/TranscoderHarness):
#                                           iOS path (MetadataCopier) and Mac
#                                           path (compress_video.sh --encoded)
#
# Encodes <fixture> at 1× and 0.5× (and 0.25× for the iPhone sample), checks
# every result with check_output.sh and prints a Markdown table. Exits 1 if
# any check failed.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../FFmpui/compress_video.sh"

kind="${1:?usage: run_tests.sh script <mode> <fixture> | harness <binary> <fixture>}"
arg="${2:?}"
fixture="${3:?}"
base=$(basename "$fixture")
name="${base%.*}"
ext="${base##*.}"

scales=(1 0.5)
[ "$base" = "IMG_6758.mov" ] && scales+=(0.25)

work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
failed=0

echo "| | File | Mode | Scale | Bytes | Of original | Video | FPS | Size | Quality | Time |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"

# Copies the fixture into its own folder (the script writes next to it).
prepare() {
  local dir="$work/$1"
  mkdir -p "$dir"
  cp -p "$fixture" "$dir/$base"
  printf '%s' "$dir"
}

seconds_since() { echo $(( $(date +%s) - $1 )); }

video_bytes() {
  ffprobe -v error -select_streams V:0 -show_entries packet=size -of csv=p=0 "$1" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}
full_size_video=""

for scale in "${scales[@]}"; do
  case "$kind" in
    script)
      mode="$arg"
      dir=$(prepare "script-$scale")
      start=$(date +%s)
      if ! bash "$script" --mode "$mode" --scale "$scale" "$dir/$base" > "$dir/log.txt" 2>&1; then
        echo "FAIL [$base, $mode, ${scale}x]: compress_video.sh failed:" >&2
        grep -v '=' "$dir/log.txt" | tail -n 20 >&2
      fi
      grep -E '^(Quality|Note|Warning)' "$dir/log.txt" >&2 || true
      bash "$here/check_output.sh" "$dir/$base" "$dir/${name}_copy.$ext" "$mode" "$scale" "$(seconds_since "$start")" || failed=1
      # Size mode: a smaller scale must never give more video bytes.
      if [ "$mode" = "size" ] && [ -f "$dir/${name}_copy.$ext" ]; then
        bytes=$(video_bytes "$dir/${name}_copy.$ext")
        if [ "$scale" = "1" ]; then
          full_size_video=$bytes
        elif [ -n "$full_size_video" ] && [ "$bytes" -gt "$full_size_video" ]; then
          echo "FAIL [$base, size, ${scale}x]: $bytes video bytes, more than at 1x ($full_size_video)" >&2
          failed=1
        fi
      fi
      ;;
    harness)
      bin="$arg"
      # iOS: encode, then MetadataCopier (Photos sets the file dates there).
      dir=$(prepare "ios-$scale")
      start=$(date +%s)
      "$bin" "$dir/$base" "$dir/${name}_copy.$ext" --scale "$scale" --copy-metadata > "$dir/log.txt" 2>&1 \
        || { echo "FAIL [$base, iOS path, ${scale}x]:" >&2; tail -n 20 "$dir/log.txt" >&2; }
      grep -E '^(Encoder|VideoToolbox|Note)' "$dir/log.txt" >&2 || true
      SKIP_FILE_DATE=1 bash "$here/check_output.sh" "$dir/$base" "$dir/${name}_copy.$ext" speed "$scale" \
        "$(seconds_since "$start")" | sed 's/| speed |/| speed (iOS) |/' || failed=1

      # Mac: encode, then the script's checks / ExifTool metadata / file dates.
      dir=$(prepare "mac-$scale")
      start=$(date +%s)
      "$bin" "$dir/$base" "$dir/.encoded.$ext" --scale "$scale" > "$dir/log.txt" 2>&1 \
        || { echo "FAIL [$base, Mac path, ${scale}x]:" >&2; tail -n 20 "$dir/log.txt" >&2; }
      bash "$script" --encoded "$dir/.encoded.$ext" -- "$dir/$base" >> "$dir/log.txt" 2>&1 \
        || { echo "FAIL [$base, Mac path, ${scale}x]: compress_video.sh --encoded failed" >&2; grep -v '=' "$dir/log.txt" | tail -n 20 >&2; }
      bash "$here/check_output.sh" "$dir/$base" "$dir/${name}_copy.$ext" speed "$scale" \
        "$(seconds_since "$start")" | sed 's/| speed |/| speed (Mac) |/' || failed=1
      ;;
    *)
      echo "Unknown test kind '$kind'" >&2
      exit 2
      ;;
  esac
done

exit "$failed"
