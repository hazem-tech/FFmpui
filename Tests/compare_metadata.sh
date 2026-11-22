#!/usr/bin/env bash
#
# compare_metadata.sh <harness> <fixture>
#
# Compresses <fixture> four ways and lists, for each, every metadata tag that
# is missing, different or added compared with the original
# (Tests/compare_metadata.py):
#
#   1. Size + Speed, metadata by ExifTool         (the Mac app today)
#   2. Size + Speed, metadata by MetadataCopier   (the iPhone app today)
#   3. Size, metadata by ExifTool                 (the Mac app today)
#   4. Size, metadata by MetadataCopier           (proposed for the Mac)
#
# <harness> is Tests/TranscoderHarness, built by run_transcoder.sh --build.
# Prints Markdown. Never fails the job: it's a report.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../FFmpui/compress_video.sh"

bin="${1:?usage: compare_metadata.sh <harness> <fixture>}"
fixture="${2:?}"
base=$(basename "$fixture")
name="${base%.*}"
ext="${base##*.}"

work=$(mktemp -d "${TMPDIR:-/tmp}/ffmpui-meta.XXXXXX")
trap 'rm -rf "$work"' EXIT

prepare() {
  mkdir -p "$work/$1"
  cp -p "$fixture" "$work/$1/$base"
  printf '%s' "$work/$1"
}

d=$(prepare speed-exiftool)
"$bin" "$d/$base" "$d/.encoded.$ext" > "$d/log.txt" 2>&1
bash "$script" --encoded "$d/.encoded.$ext" -- "$d/$base" >> "$d/log.txt" 2>&1

d=$(prepare speed-copier)
"$bin" "$d/$base" "$d/${name}_copy.$ext" --copy-metadata > "$d/log.txt" 2>&1

d=$(prepare size-exiftool)
bash "$script" --mode size -- "$d/$base" > "$d/log.txt" 2>&1

d=$(prepare size-copier)
FFMPUI_SKIP_METADATA=1 bash "$script" --mode size -- "$d/$base" > "$d/log.txt" 2>&1
"$bin" "$d/$base" "$d/${name}_copy.$ext" --metadata-only >> "$d/log.txt" 2>&1

for run in speed-exiftool speed-copier size-exiftool size-copier; do
  grep -E '^(Metadata|FAILED|Note|Warning)' "$work/$run/log.txt" | sed "s/^/$run: /" >&2 || true
done

python3 "$here/compare_metadata.py" "$fixture" \
  "Size + Speed, ExifTool (Mac today)=$work/speed-exiftool/${name}_copy.$ext" \
  "Size + Speed, MetadataCopier (iPhone today)=$work/speed-copier/${name}_copy.$ext" \
  "Size, ExifTool (Mac today)=$work/size-exiftool/${name}_copy.$ext" \
  "Size, MetadataCopier (proposed for the Mac)=$work/size-copier/${name}_copy.$ext"
exit 0
