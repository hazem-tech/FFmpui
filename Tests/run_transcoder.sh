#!/usr/bin/env bash
#
# run_transcoder.sh <video>            benchmark "Size + Speed" on this Mac
# run_transcoder.sh --build <binary>   only build the harness (used by CI)
#
# Builds Tests/TranscoderHarness (the apps' shared VideoTranscoder +
# MetadataCopier, as a command-line tool) and encodes <video> with the
# app's settings and a few variations, printing size and time for each.
# Run it on a real Mac: CI's virtual Macs may not have the hardware encoder.
# Needs Xcode (or the Command Line Tools) with Swift 6.2 or later.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

build() {
  # Same language settings as the Xcode targets (Swift 5 mode, MainActor by
  # default, approachable concurrency, member import visibility).
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature MemberImportVisibility \
    "$root"/Shared/*.swift "$here"/TranscoderHarness/*.swift -o "$1"
}

if [ "${1:-}" = "--build" ]; then
  build "${2:?--build needs an output path}"
  exit 0
fi

video="${1:?usage: run_transcoder.sh <video>}"
work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-bench.XXXXXX")
trap 'rm -rf "$work"' EXIT
bin="$work/transcoder-harness"
echo "Building the harness…"
build "$bin"
"$bin" --encoders

ext="${video##*.}"
keyframes() {
  command -v ffprobe >/dev/null 2>&1 || { echo "?"; return; }
  ffprobe -v error -select_streams v:0 -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 "$1" | wc -l | tr -d ' '
}
printf '\n%-32s %12s %8s %10s\n' "Setting" "Bytes" "Seconds" "Keyframes"
run() {
  local label="$1"; shift
  local out="$work/out.$ext" log
  log=$("$bin" "$video" "$out" "$@" 2>&1) || { printf '%-32s %12s\n' "$label" "failed"; echo "$log" | tail -n 3; return; }
  printf '%-32s %12s %8s %10s   %s\n' "$label" "$(wc -c < "$out" | tr -d ' ')" "$(echo "$log" | sed -n 's/^SECONDS=//p')" \
    "$(keyframes "$out")" "$(echo "$log" | sed -n 's/^Encoder: HEVC [^,]*, //p')"
  rm -f "$out"
}
run "app (Size + Speed)"
run "  lowest bitrate only (before)" --no-quality --min-qp 0 --adaptive-qp
run "  without constant quality" --no-quality
run "  with adaptive QP" --adaptive-qp
run "  QP ≥ 45" --min-qp 45
run "  quality 0 alone" --no-bitrate --min-qp 0 --adaptive-qp
run "  without power saving" --no-power-saving
run "  without speed over quality" --no-prioritize-speed
run "  keyframe every 2 s" --keyframes 2
run "  keyframe every 60 s" --keyframes 60
run "  keyframe every 10 s (before)" --keyframes 10
run "  keyframes: encoder's choice" --keyframes auto
run "  no 24 fps cap" --no-fps-cap
run "  scale 0.5" --scale 0.5
run "  scale 0.25" --scale 0.25

# Small speed differences need repeated, alternating runs: 6 rounds of 4
# setups, then each setup's median time and size.
echo
echo "Repeated runs (6 rounds, alternating):"
labels=("every 10 s" "single keyframe" "every 10 s + speed over quality" "single + speed over quality")
options=("--keyframes 10 --no-prioritize-speed" "--keyframes single --no-prioritize-speed" "--keyframes 10 --prioritize-speed" "--keyframes single --prioritize-speed")
times=("" "" "" "")
sizes=("" "" "" "")
for round in 1 2 3 4 5 6; do
  for i in 0 1 2 3; do
    out="$work/out.$ext"
    # shellcheck disable=SC2086 # options are word lists
    log=$("$bin" "$video" "$out" ${options[$i]} 2>&1) || { echo "  ${labels[$i]}: failed"; continue; }
    t=$(echo "$log" | sed -n 's/^SECONDS=//p')
    b=$(wc -c < "$out" | tr -d ' ')
    times[i]="${times[i]} $t"
    sizes[i]="${sizes[i]} $b"
    printf '  round %s  %-34s %10s bytes %6s s\n' "$round" "${labels[$i]}" "$b" "$t"
    rm -f "$out"
  done
done
median() { tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR] = $1 } END { if (NR % 2) print v[(NR + 1) / 2]; else printf "%.2f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }
echo
printf '%-34s %14s %14s\n' "Median of 6" "Bytes" "Seconds"
for i in 0 1 2 3; do
  printf '%-34s %14s %14s\n' "${labels[$i]}" "$(echo "${sizes[$i]}" | median)" "$(echo "${times[$i]}" | median)"
done
"$bin" "$video" "$work/out.$ext" | grep '^Encoder:' || true
