#!/usr/bin/env bash
#
# tune_speed_quality.sh <harness> <fixtures-dir>
#
# Finds the hardware encoder's constant-quality setting for each level of
# Speed + Quality (Shared/QualityLevel.swift): encodes every fixture with the
# Speed + Quality preset at several settings, measures VMAF against the
# original, and interpolates the setting that reaches each target (97, 95,
# 92). The app needs one setting for all videos, so the highest one (the
# hardest clip) is the suggestion. Prints Markdown.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
bin="${1:?usage: tune_speed_quality.sh <harness> <fixtures-dir>}"
dir="${2:?}"
settings=(0.40 0.50 0.60 0.70 0.75 0.80 0.85 0.90 0.95)
targets=(97 95 92)

work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-sq.XXXXXX")
trap 'rm -rf "$work"' EXIT

video_bytes() {
  ffprobe -v error -select_streams V:0 -show_entries packet=size -of csv=p=0 "$1" | awk '{ s += $1 } END { print s + 0 }'
}
vmaf() { # distorted reference, both read unrotated, frames paired in order
  ffmpeg -nostdin -hide_banner -noautorotate -i "$1" -noautorotate -i "$2" -filter_complex \
    "[0:V:0]format=yuv420p10le,settb=1/1000,setpts=N*40[d];[1:V:0]format=yuv420p10le,settb=1/1000,setpts=N*40[r];[d][r]libvmaf=n_threads=$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
    -f null - 2>&1 | sed -n 's/.*VMAF score: *\([0-9.]*\).*/\1/p' | tail -n1
}

echo "| Clip | Setting | Video bytes | VMAF |"
echo "|---|---|---|---|"
summary=""
for f in "$dir"/*.mov "$dir"/*.mp4; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  [ "$b" = "clip.mp4" ] && continue   # same picture as IMG_6758.mov
  curve=""
  for q in "${settings[@]}"; do
    out="$work/out.${b##*.}"
    "$bin" "$f" "$out" --speed-quality "$q" > /dev/null 2>&1 || { echo "| $b | $q | failed | |"; continue; }
    bytes=$(video_bytes "$out"); score=$(vmaf "$out" "$f")
    echo "| $b | $q | $bytes | $score |"
    curve+="$q $score"$'\n'
    rm -f "$out"
  done
  # Setting needed for each target, interpolated between the two around it.
  line="$b:"
  for t in "${targets[@]}"; do
    need=$(printf '%s' "$curve" | awk -v t="$t" '
      { q[NR] = $1; s[NR] = $2 }
      END {
        for (i = 1; i < NR; i++) if (s[i] < t && s[i + 1] >= t) {
          printf "%.3f", q[i] + (t - s[i]) / (s[i + 1] - s[i]) * (q[i + 1] - q[i]); exit
        }
        if (s[1] >= t) printf "%.3f", q[1]; else printf "unreached"
      }')
    line+=" VMAF $t → $need;"
  done
  summary+="$line"$'\n'
done
echo
echo "Setting needed per clip:"
echo '```'
printf '%s' "$summary"
echo '```'
