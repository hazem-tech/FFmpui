#!/usr/bin/env bash
#
# tune.sh size <fixtures-dir>                 compare Size mode settings
# tune.sh quality <fixtures-dir> <variant>    one Size + Quality candidate
# tune.sh quality-variants                    list the quality candidates
#
# Size: runs compress_video.sh --mode size with each candidate (through the
# FFMPUI_SIZE_* variables) on every fixture and adds up the video bytes.
# Smallest total wins.
#
# Quality: encodes each fixture at several CRFs with the candidate's x265
# settings (10-bit, like quality mode), measures VMAF against the original,
# and interpolates the video bytes needed for VMAF 95. Fewest bytes wins.
#
# Prints Markdown table rows; .github/workflows/tune.yml runs it.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../FFmpui/compress_video.sh"
target="${VMAF_TARGET:-95}"

# name|preset|x265 params
SIZE_VARIANTS=(
  "app|veryfast|keyint=-1:qpmin=51:aq-mode=0:sao=0:me=umh:subme=0:merange=200:min-cu-size=32:max-tu-size=4:rc-lookahead=5:cbqpoffs=12:crqpoffs=12:rskip=2:max-merge=1"
  "app-faster|faster|keyint=-1:qpmin=51:aq-mode=0:sao=0:me=umh:subme=0:merange=200:min-cu-size=32:max-tu-size=4:rc-lookahead=5:cbqpoffs=12:crqpoffs=12:rskip=2:max-merge=1"
  "app-medium|medium|keyint=-1:qpmin=51:aq-mode=0:sao=0:me=umh:subme=0:merange=200:min-cu-size=32:max-tu-size=4:rc-lookahead=5:cbqpoffs=12:crqpoffs=12:rskip=2:max-merge=1"
  "simple|veryfast|keyint=-1:qpmin=51:aq-mode=0:sao=0:max-tu-size=4:cbqpoffs=12:crqpoffs=12"
  "plain-crf51|medium|keyint=-1"
)
# Round 1 (bytes at VMAF 95 on the 3 clips): slower aq-mode 4 2,342,586;
# aq-mode 2 2,476,544; aq-mode 3 + no SAO 2,559,483; aq-mode 3 + psy-rd 1
# 2,578,079; veryslow aq-mode 3 2,663,685; slower aq-mode 3 2,687,569;
# slow aq-mode 3 2,734,411. Round 2 builds on aq-mode 4:
QUALITY_VARIANTS=(
  "slower-aq4|slower|aq-mode=4"
  "slower-aq4-nosao|slower|aq-mode=4:sao=0"
  "slower-aq4-psy1|slower|aq-mode=4:psy-rd=1.0"
  "slower-aq4-nosao-psy1|slower|aq-mode=4:sao=0:psy-rd=1.0"
  "veryslow-aq4|veryslow|aq-mode=4"
)
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
    for v in "${QUALITY_VARIANTS[@]}"; do echo "${v%%|*}"; done
    ;;

  size)
    dir="${2:?fixtures dir}"
    work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-tune.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    echo "| Size setting | Preset | Video bytes (all fixtures) | Seconds |"
    echo "|---|---|---|---|"
    for v in "${SIZE_VARIANTS[@]}"; do
      IFS='|' read -r name preset params <<< "$v"
      total=0; start=$(date +%s)
      while IFS= read -r f; do
        d="$work/$name"; mkdir -p "$d"; cp -p "$f" "$d/"
        b=$(basename "$f")
        FFMPUI_SIZE_PRESET="$preset" FFMPUI_SIZE_X265="$params" \
          bash "$script" --mode size "$d/$b" >/dev/null 2>&1
        out="$d/${b%.*}_copy.${b##*.}"
        [ -f "$out" ] && total=$((total + $(video_bytes "$out")))
        rm -f "$d"/*
      done < <(fixtures "$dir")
      echo "| $name | $preset | $total | $(( $(date +%s) - start )) |"
    done
    ;;

  quality)
    dir="${2:?fixtures dir}"; want="${3:?variant}"
    line=""
    for v in "${QUALITY_VARIANTS[@]}"; do [ "${v%%|*}" = "$want" ] && line="$v"; done
    [ -n "$line" ] || { echo "Unknown variant $want" >&2; exit 2; }
    IFS='|' read -r name preset params <<< "$line"
    work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-tune.XXXXXX")
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
