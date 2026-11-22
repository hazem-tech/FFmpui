#!/usr/bin/env bash
#
# check_output.sh <source> <output> <mode> <scale> [seconds-taken]
#
# Checks one compressed file against its source and prints a Markdown table
# row with the results. Exits 1 if any check fails:
#
#   • HEVC video tagged hvc1, same duration (±1 s or 1%)
#   • width/height = source × scale, rounded down to even numbers
#   • same rotation, and a rotation matrix offset that fits the new size
#   • frame rate: speed/size modes cap > 24 fps sources at 24 (≥ 23);
#     otherwise unchanged
#   • every audio stream bit-for-bit identical to the source
#   • recorded date (QuickTime and Apple), Make, Model and GPS kept; file
#     created (macOS) and modified dates kept
#     (unless SKIP_FILE_DATE is set)
#   • HDR (HLG / PQ) sources stay 10-bit with the same color tags
#   • smaller than the source
#   • quality mode: whole-file VMAF ≥ target − 1 (when ffmpeg has libvmaf)
#
# The row's quality column is VMAF (or SSIM without libvmaf) against the
# source, at the output's size and frame rate.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

src="${1:?usage: check_output.sh <source> <output> <mode> <scale> [seconds]}"
out="${2:?}"
mode="${3:?}"
scale="${4:?}"
seconds="${5:-}"
vmaf_target="${VMAF_TARGET:-95}"
name="$(basename "$src")"

failed=0
fail() { echo "FAIL [$name, $mode, ${scale}x]: $*" >&2; failed=1; }

if [ ! -f "$out" ]; then
  fail "no output file ($out)"
  exit 1
fi

vprobe() {
  ffprobe -v error -select_streams V:0 -show_entries "stream=$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}
rotation() {
  ffprobe -v error -select_streams V:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1
}
rate() { awk -v x="$1" 'BEGIN { if (split(x, p, "/") == 2 && p[2] + 0 > 0) printf "%.3f", p[1] / p[2]; else printf "%.3f", x + 0 }'; }
duration() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
filesize() { wc -c < "$1" | tr -d ' '; }

# Codec
codec=$(vprobe "$out" codec_name)
tag=$(vprobe "$out" codec_tag_string)
[ "$codec" = "hevc" ] || fail "video codec is '$codec', not hevc"
[ "$tag" = "hvc1" ] || fail "video tag is '$tag', not hvc1 (Apple players need hvc1)"

# Duration
d_src=$(duration "$src"); d_out=$(duration "$out")
awk -v a="$d_src" -v b="$d_out" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(b > 0 && (d <= 1.0 || d <= a * 0.01)) }' \
  || fail "duration ${d_out}s vs ${d_src}s"

# Size
sw=$(vprobe "$src" width); sh=$(vprobe "$src" height)
ow=$(vprobe "$out" width); oh=$(vprobe "$out" height)
if [ "$scale" = "1" ]; then
  ew=$sw; eh=$sh
else
  ew=$(awk -v d="$sw" -v s="$scale" 'BEGIN { print int(d * s / 2) * 2 }')
  eh=$(awk -v d="$sh" -v s="$scale" 'BEGIN { print int(d * s / 2) * 2 }')
fi
[ "$ow" = "$ew" ] && [ "$oh" = "$eh" ] || fail "size ${ow}x${oh}, expected ${ew}x${eh}"

# Rotation and its matrix offset
r_src=$(rotation "$src"); r_out=$(rotation "$out")
[ "${r_src:-0}" = "${r_out:-0}" ] || fail "rotation ${r_out:-0}, expected ${r_src:-0}"
video_group=$(exiftool -a -G1 -n -HandlerType "$out" 2>/dev/null | sed -n 's/^\[\(Track[0-9]*\)\].*vide.*/\1/p' | head -n1)
if [ -n "$video_group" ]; then
  matrix=$(exiftool -n -s3 "-$video_group:MatrixStructure" "$out")
  printf '%s\n' "$matrix" | awk -v W="$ow" -v H="$oh" '{
      a = $1; b = $2; c = $4; d = $5
      split("0 " W " 0 " W, xs, " "); split("0 0 " H " " H, ys, " ")
      for (i = 1; i <= 4; i++) {
        x = a * xs[i] + c * ys[i]; y = b * xs[i] + d * ys[i]
        if (i == 1 || x < minx) minx = x
        if (i == 1 || y < miny) miny = y
      }
      exit !(($7 + 0) == -minx && ($8 + 0) == -miny)
    }' || fail "rotation matrix '$matrix' doesn't fit a ${ow}x${oh} frame"
fi

# Frame rate
fs=$(rate "$(vprobe "$src" avg_frame_rate)")
fo=$(rate "$(vprobe "$out" avg_frame_rate)")
capped=0
if [ "$mode" != "quality" ] && awk -v f="$fs" 'BEGIN { exit !(f > 24.05) }'; then
  capped=1
  awk -v f="$fo" 'BEGIN { exit !(f >= 23 && f <= 24.05) }' || fail "frame rate $fo, expected 23–24 (source $fs)"
else
  awk -v a="$fs" -v b="$fo" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.5 || d <= a * 0.02) }' \
    || fail "frame rate $fo, expected $fs"
fi

# Audio: identical packets
audio_hash() { ffmpeg -nostdin -v error -i "$1" -map 0:a -c copy -f streamhash -hash sha256 - 2>/dev/null; }
if [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src")" ]; then
  if [ "$(audio_hash "$src")" != "$(audio_hash "$out")" ]; then
    fail "audio is not bit-identical to the source"
    # Show how: per-packet timing, size and hash, first differences.
    packets() { ffmpeg -nostdin -v error -i "$1" -map 0:a:0 -c copy -f framemd5 - 2>/dev/null | grep -v '^#'; }
    echo "  audio packets: source $(packets "$src" | wc -l | tr -d ' '), output $(packets "$out" | wc -l | tr -d ' ')" >&2
    diff <(packets "$src") <(packets "$out") | head -n 12 | sed 's/^/  /' >&2
  fi
fi

# Metadata
# QuickTime:CreateDate is the recorded date every camera writes (Android
# phones only write this one); CreationDate is Apple's, with the time zone.
for tag_name in QuickTime:CreateDate CreationDate Make Model GPSLatitude GPSLongitude; do
  v_src=$(exiftool -n -s3 "-$tag_name" "$src" 2>/dev/null | head -n1)
  [ -n "$v_src" ] || continue
  v_out=$(exiftool -n -s3 "-$tag_name" "$out" 2>/dev/null | head -n1)
  [ "$v_src" = "$v_out" ] || fail "$tag_name '$v_out', expected '$v_src'"
done
if [ -z "${SKIP_FILE_DATE:-}" ]; then   # iOS path: Photos sets the dates
  [ "$(mtime "$src")" = "$(mtime "$out")" ] || fail "file modification date not kept"
  if [ "$(uname)" = "Darwin" ]; then
    [ "$(stat -f %B "$src")" = "$(stat -f %B "$out")" ] || fail "file created date not kept"
  fi
fi

# HDR
trc=$(vprobe "$src" color_transfer)
case "$trc" in
  arib-std-b67|smpte2084)
    [ "$(vprobe "$out" color_transfer)" = "$trc" ] || fail "transfer '$(vprobe "$out" color_transfer)', expected $trc"
    [ "$(vprobe "$out" color_primaries)" = "$(vprobe "$src" color_primaries)" ] || fail "color primaries changed"
    case "$(vprobe "$out" pix_fmt)" in *10le|*10be|p010*) ;; *) fail "HDR output is not 10-bit ($(vprobe "$out" pix_fmt))" ;; esac
    ;;
esac

# File size
in_size=$(filesize "$src"); out_size=$(filesize "$out")
[ "$out_size" -lt "$in_size" ] || fail "output ($out_size bytes) is not smaller than the source ($in_size bytes)"

# Quality score at the output's size and frame rate
ref_filters=""
dist_filters=""
if [ "$capped" -eq 1 ]; then ref_filters="fps=24,"; dist_filters="fps=24,"; fi
if [ "$ow" != "$sw" ] || [ "$oh" != "$sh" ]; then
  ref_filters="${ref_filters}scale=${ow}:${oh}:flags=bicubic,"
fi
align="format=yuv420p10le,settb=1/1000,setpts=N*40"
graph="[0:V:0]${dist_filters}${align}[d];[1:V:0]${ref_filters}${align}[r];[d][r]"
threads=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
if ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' libvmaf '; then
  score=$(ffmpeg -nostdin -hide_banner -noautorotate -i "$out" -noautorotate -i "$src" \
            -filter_complex "${graph}libvmaf=n_threads=$threads" -f null - 2>&1 \
          | sed -n 's/.*VMAF score: *\([0-9.]*\).*/\1/p' | tail -n1)
  quality="VMAF ${score:-?}"
  if [ "$mode" = "quality" ]; then
    awk -v s="${score:-0}" -v t="$vmaf_target" 'BEGIN { exit !(s + 0 >= t - 1) }' \
      || fail "VMAF ${score:-?} is below the target $vmaf_target"
  fi
else
  score=$(ffmpeg -nostdin -hide_banner -noautorotate -i "$out" -noautorotate -i "$src" \
            -filter_complex "${graph}ssim" -f null - 2>&1 \
          | sed -n 's/.*SSIM .*All:\([0-9.]*\).*/\1/p' | tail -n1)
  quality="SSIM ${score:-?}"
fi

kbps=$(ffprobe -v error -select_streams V:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$out" | head -n1)
kbps=$(awk -v b="${kbps:-0}" 'BEGIN { printf "%.0f", b / 1000 }')
percent=$(awk -v a="$out_size" -v b="$in_size" 'BEGIN { printf "%.1f%%", a * 100 / b }')
status="✅"
[ "$failed" -eq 0 ] || status="❌"
printf '| %s | %s | %s | %s× | %s → %s | %s | %s kb/s | %s fps | %sx%s | %s | %s |\n' \
  "$status" "$name" "$mode" "$scale" "$in_size" "$out_size" "$percent" "$kbps" "$fo" "$ow" "$oh" "$quality" "${seconds:+${seconds}s}"

exit "$failed"
