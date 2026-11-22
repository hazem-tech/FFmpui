#!/usr/bin/env bash
#
# run_tests.sh script <mode> <fixture> <harness>
#     the Mac app's Size / Size + Quality: compress_video.sh --encode-only,
#     MetadataCopier (through the harness), compress_video.sh --encoded
# run_tests.sh harness <harness> <fixture>
#     the apps' shared hardware encoder (Tests/TranscoderHarness), Size +
#     Speed and Speed + Quality (Medium):
#     iPhone path (encode + MetadataCopier) and Mac path (encode +
#     MetadataCopier + compress_video.sh --encoded)
#
# Encodes <fixture> at 1× and 0.5× (and 0.25× for the iPhone sample), checks
# every result with check_output.sh and prints a Markdown table. Exits 1 if
# any check failed.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../shrk/compress_video.sh"

kind="${1:?usage: run_tests.sh script <mode> <fixture> <harness> | harness <harness> <fixture>}"
arg="${2:?}"
fixture="${3:?}"
harness="${4:-$arg}"
base=$(basename "$fixture")
name="${base%.*}"
ext="${base##*.}"

scales=(1 0.5)
[ "$base" = "IMG_6758.mov" ] && scales+=(0.25)

work=$(mktemp -d "${TMPDIR:-/tmp}/shrk-test.XXXXXX")
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

# Checks the Mac path's result. When the script kept the original (the
# compressed file wasn't smaller), the original must be untouched and no
# copy written; the discarded encode (saved as encoded-check) is checked
# instead, without file dates.
check_mac() { # <dir> <mode> <scale> <start> <label>
  local dir="$1" mode="$2" scale="$3" start="$4" label="$5"
  if grep -q '^@@FILE_SKIP' "$dir/log.txt"; then
    cmp -s "$fixture" "$dir/$base" \
      || { echo "FAIL [$base, $label, ${scale}x]: the original changed although it was kept" >&2; failed=1; }
    [ ! -e "$dir/${name}_copy.$ext" ] \
      || { echo "FAIL [$base, $label, ${scale}x]: a copy was written although the original was kept" >&2; failed=1; }
    SKIP_FILE_DATE=1 bash "$here/check_output.sh" "$dir/$base" "$dir/encoded-check.$ext" "$mode" "$scale" \
      "$(seconds_since "$start")" | sed "s/| $mode |/| $label, original kept |/" || failed=1
  else
    bash "$here/check_output.sh" "$dir/$base" "$dir/${name}_copy.$ext" "$mode" "$scale" \
      "$(seconds_since "$start")" | sed "s/| $mode |/| $label |/" || failed=1
  fi
}

for scale in "${scales[@]}"; do
  case "$kind" in
    script)
      mode="$arg"
      dir=$(prepare "script-$scale")
      start=$(date +%s)
      # The Mac app's steps: encode, metadata, finish.
      bash "$script" --mode "$mode" --scale "$scale" --encode-only -- "$dir/$base" > "$dir/log.txt" 2>&1
      encoded=$(sed -n 's/^@@ENCODED //p' "$dir/log.txt")
      if [ -n "$encoded" ] && "$harness" "$dir/$base" "$encoded" --metadata-only >> "$dir/log.txt" 2>&1 \
         && cp -p "$encoded" "$dir/encoded-check.$ext" \
         && bash "$script" --encoded "$encoded" -- "$dir/$base" >> "$dir/log.txt" 2>&1; then
        :
      else
        echo "FAIL [$base, $mode, ${scale}x]: compress_video.sh / MetadataCopier failed:" >&2
        grep -v '=' "$dir/log.txt" | tail -n 20 >&2
      fi
      grep -E '^(Quality|Note|Warning|Metadata|@@FILE_SKIP)' "$dir/log.txt" >&2 || true
      check_mac "$dir" "$mode" "$scale" "$start" "$mode"
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
      bin="$harness"
      # Size + Speed, and Speed + Quality at Medium (VMAF 95).
      for preset in speed speed-quality; do
        options=(--scale "$scale")
        [ "$preset" = "speed-quality" ] && options=(--level medium --scale "$scale")

        # iOS: encode, then MetadataCopier (Photos sets the file dates there).
        dir=$(prepare "ios-$preset-$scale")
        start=$(date +%s)
        "$bin" "$dir/$base" "$dir/${name}_copy.$ext" "${options[@]}" --copy-metadata > "$dir/log.txt" 2>&1 \
          || { echo "FAIL [$base, $preset, iOS path, ${scale}x]:" >&2; tail -n 20 "$dir/log.txt" >&2; }
        grep -E '^(Encoder|VideoToolbox|Note)' "$dir/log.txt" >&2 || true
        SKIP_FILE_DATE=1 bash "$here/check_output.sh" "$dir/$base" "$dir/${name}_copy.$ext" "$preset" "$scale" \
          "$(seconds_since "$start")" | sed "s/| $preset |/| $preset (iOS) |/" || failed=1

        # Mac: encode, MetadataCopier, then the script's checks / file dates.
        dir=$(prepare "mac-$preset-$scale")
        start=$(date +%s)
        { "$bin" "$dir/$base" "$dir/.encoded.$ext" "${options[@]}" \
            && "$bin" "$dir/$base" "$dir/.encoded.$ext" --metadata-only \
            && cp -p "$dir/.encoded.$ext" "$dir/encoded-check.$ext"; } > "$dir/log.txt" 2>&1 \
          || { echo "FAIL [$base, $preset, Mac path, ${scale}x]:" >&2; tail -n 20 "$dir/log.txt" >&2; }
        bash "$script" --encoded "$dir/.encoded.$ext" -- "$dir/$base" >> "$dir/log.txt" 2>&1 \
          || { echo "FAIL [$base, $preset, Mac path, ${scale}x]: compress_video.sh --encoded failed" >&2; grep -v '=' "$dir/log.txt" | tail -n 20 >&2; }
        grep '^@@FILE_SKIP' "$dir/log.txt" >&2 || true
        check_mac "$dir" "$preset" "$scale" "$start" "$preset (Mac)"
      done
      ;;
    *)
      echo "Unknown test kind '$kind'" >&2
      exit 2
      ;;
  esac
done

exit "$failed"
