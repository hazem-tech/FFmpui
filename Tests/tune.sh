#!/usr/bin/env bash
#
# tune.sh size <fixtures-dir>                 compare Size mode settings
# tune.sh quality <fixtures-dir> <variant>    one Size + Quality candidate
# tune.sh quality-variants                    list the quality candidates
#
# Size: runs compress_video.sh --mode size with each candidate (through the
# SHRK_SIZE_* variables) on every fixture at each scale and adds up the
# video bytes. Smallest totals win.
#
# Quality: encodes each fixture at several CRFs with the candidate's x265
# settings (10-bit, like quality mode), measures VMAF against the original,
# and interpolates the video bytes needed for VMAF 95. Fewest bytes wins.
#
# Prints Markdown table rows; .github/workflows/tune.yml runs it.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../shrk/compress_video.sh"
target="${VMAF_TARGET:-95}"

# Candidates (name|preset|x265 params) live in Tests/tune/size.txt and
# Tests/tune/quality.txt, so tune.yml can rerun just the sweep that changed.
read_variants() { grep -v '^#' "$here/tune/$1.txt" | grep -v '^[[:space:]]*$'; }
QUALITY_CRFS=(18 21 24 27 30)

video_bytes() {
  ffprobe -v error -select_streams V:0 -show_entries packet=size -of csv=p=0 "$1" | awk '{ s += $1 } END { print s + 0 }'
}

vmaf() { # distorted reference
  ffmpeg -nostdin -hide_banner -noautorotate -i "$1" -noautorotate -i "$2" -filter_complex \
    "[0:V:0]format=yuv420p10le,settb=1/1000,setpts=N*40[d];[1:V:0]format=yuv420p10le,settb=1/1000,setpts=N*40[r];[d][r]libvmaf=n_threads=$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
    -f null - 2>&1 | sed -n 's/.*VMAF score: *\([0-9.]*\).*/\1/p' | tail -n1
}

fixtures() { find "$1" -maxdepth 1 -type f \( -name '*.mov' -o -name '*.mp4' \) ! -name '*_copy*' | sort; }

case "${1:-}" in
  quality-variants)
    read_variants quality | cut -d'|' -f1
    ;;

  size)
    dir="${2:?fixtures dir}"
    work=$(mktemp -d "${TMPDIR:-/tmp}/shrk-tune.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    scales=(1 0.5 0.25)
    echo "| Size setting | Preset | Video bytes at 1× | 0.5× | 0.25× | Seconds |"
    echo "|---|---|---|---|---|---|"
    while IFS='|' read -r name preset params; do
      row="| $name | $preset |"; start=$(date +%s)
      for scale in "${scales[@]}"; do
        total=0
        while IFS= read -r f; do
          d="$work/$name-$scale"; mkdir -p "$d"; cp -p "$f" "$d/"
          b=$(basename "$f")
          SHRK_SIZE_PRESET="$preset" SHRK_SIZE_X265="$params" \
            bash "$script" --mode size --scale "$scale" "$d/$b" >/dev/null 2>&1 < /dev/null
          out="$d/${b%.*}_copy.${b##*.}"
          [ -f "$out" ] && total=$((total + $(video_bytes "$out")))
          rm -f "$d"/*
        done < <(fixtures "$dir")
        row+=" $total |"
      done
      echo "$row $(( $(date +%s) - start )) |"
    done < <(read_variants size)
    ;;

  quality)
    dir="${2:?fixtures dir}"; want="${3:?variant}"
    line=$(read_variants quality | grep "^$want|" | head -n1)
    [ -n "$line" ] || { echo "Unknown variant $want" >&2; exit 2; }
    IFS='|' read -r name preset params <<< "$line"
    work=$(mktemp -d "${TMPDIR:-/tmp}/shrk-tune.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    total=0; start=$(date +%s); points=""
    while IFS= read -r f; do
      b=$(basename "$f")
      [ "$b" = "clip.mp4" ] && continue   # same picture as IMG_6758.mov
      curve=""
      for crf in "${QUALITY_CRFS[@]}"; do
        out="$work/$crf.mp4"
        ffmpeg -nostdin -hide_banner -loglevel error -y -noautorotate -i "$f" -map 0:V:0 \
          -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le -preset "$preset" -crf "$crf" \
          -x265-params "log-level=error:keyint=300:$params" "$out"
        curve+="$(video_bytes "$out") $(vmaf "$out" "$f")"$'\n'
      done
      # Bytes at the target VMAF, interpolated on log(bytes) between the two
      # CRFs around it.
      bytes=$(printf '%s' "$curve" | awk -v t="$target" '
        { s[NR] = $1; q[NR] = $2 }
        END {
          for (i = 1; i < NR; i++) if (q[i] >= t && q[i + 1] < t) {
            f = (q[i] - t) / (q[i] - q[i + 1])
            printf "%.0f", exp(log(s[i]) + f * (log(s[i + 1]) - log(s[i]))); exit
          }
          printf "%.0f", (q[1] < t) ? s[1] : s[NR]
        }')
      points+=" ${b%.*}:$bytes"
      total=$((total + bytes))
    done < <(fixtures "$dir")
    echo "| $name | $preset | $params | $total |$points | $(( $(date +%s) - start )) |"
    ;;

  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
