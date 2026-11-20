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
printf '\n%-28s %12s %8s\n' "Setting" "Bytes" "Seconds"
run() {
  local label="$1"; shift
  local out="$work/out.$ext" log
  log=$("$bin" "$video" "$out" "$@" 2>&1) || { printf '%-28s %12s\n' "$label" "failed"; echo "$log" | tail -n 3; return; }
  printf '%-28s %12s %8s\n' "$label" "$(wc -c < "$out" | tr -d ' ')" "$(echo "$log" | sed -n 's/^SECONDS=//p')"
  rm -f "$out"
}
run "app (Size + Speed)"
run "  without power saving" --no-power-saving
run "  with speed over quality" --prioritize-speed
run "  keyframe every 2 s" --keyframes 2
run "  keyframe every 60 s" --keyframes 60
run "  constant quality 0" --quality 0
run "  no 24 fps cap" --no-fps-cap
run "  scale 0.5" --scale 0.5
run "  scale 0.25" --scale 0.25
"$bin" "$video" "$work/out.$ext" | grep '^Encoder:' || true
