#!/usr/bin/env bash
#
# compare_metadata.sh <harness> <fixture>
#
# Compresses <fixture> the way the apps do and lists, for each, every
# metadata tag that is missing, different or added compared with the
# original (Tests/compare_metadata.py):
#
#   1. Size + Speed on the Mac    (encode, MetadataCopier, compress_video.sh --encoded)
#   2. Size + Speed on the iPhone (encode, MetadataCopier)
#   3. Size on the Mac            (compress_video.sh --encode-only, MetadataCopier,
#                                  compress_video.sh --encoded); Size + Quality
#                                  takes the same steps
#
# <harness> is Tests/TranscoderHarness, built by run_transcoder.sh --build.
# Prints Markdown. Never fails the job: it's a report.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../shrk/compress_video.sh"

bin="${1:?usage: compare_metadata.sh <harness> <fixture>}"
fixture="${2:?}"
base=$(basename "$fixture")
name="${base%.*}"
ext="${base##*.}"

work=$(mktemp -d "${TMPDIR:-/tmp}/shrk-meta.XXXXXX")
trap 'rm -rf "$work"' EXIT

prepare() {
  mkdir -p "$work/$1"
  cp -p "$fixture" "$work/$1/$base"
  printf '%s' "$work/$1"
}

d=$(prepare speed-mac)
{ "$bin" "$d/$base" "$d/.encoded.$ext" && "$bin" "$d/$base" "$d/.encoded.$ext" --metadata-only \
  && bash "$script" --encoded "$d/.encoded.$ext" -- "$d/$base"; } > "$d/log.txt" 2>&1

d=$(prepare speed-iphone)
"$bin" "$d/$base" "$d/${name}_copy.$ext" --copy-metadata > "$d/log.txt" 2>&1

d=$(prepare size-mac)
bash "$script" --mode size --encode-only -- "$d/$base" > "$d/log.txt" 2>&1
encoded=$(sed -n 's/^@@ENCODED //p' "$d/log.txt")
if [ -n "$encoded" ]; then
  { "$bin" "$d/$base" "$encoded" --metadata-only && bash "$script" --encoded "$encoded" -- "$d/$base"; } >> "$d/log.txt" 2>&1
fi

for run in speed-mac speed-iphone size-mac; do
  grep -E '^(Metadata|FAILED|Note|Warning|@@FILE_FAIL)' "$work/$run/log.txt" | sed "s/^/$run: /" >&2 || true
done

python3 "$here/compare_metadata.py" "$fixture" \
  "Size + Speed, Mac=$work/speed-mac/${name}_copy.$ext" \
  "Size + Speed, iPhone=$work/speed-iphone/${name}_copy.$ext" \
  "Size and Size + Quality, Mac=$work/size-mac/${name}_copy.$ext"
exit 0
