#!/usr/bin/env bash
#
# make_fixtures.sh <out-dir>
#
# Builds the test clips used by CI from the committed iPhone sample
# (Tests/Fixtures/IMG_6758.mov: 1280×720 H.264, 30 fps, rotated, AAC):
#
#   IMG_6758.mov   the sample itself
#   samsung.mp4    a Samsung phone video (committed as is: Android-style
#                  metadata, recorded date only in the movie header)
#   hlg60.mov      10-bit HLG HEVC at 60 fps (like an iPhone HDR video), with GPS
#   clip.mp4       the sample in an MP4 container, with GPS
#   film23.mov     23.976 fps H.264 (below the 24 fps cap, so it must stay as is)
#
# Each keeps the original's audio and rotation, and gets the original's
# metadata (Make, Model, CreationDate …) so the metadata checks have something
# to compare.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

here=$(cd "$(dirname "$0")" && pwd)
sample="$here/Fixtures/IMG_6758.mov"
out="${1:?usage: make_fixtures.sh <out-dir>}"
mkdir -p "$out"

ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
gps() {
  exiftool -q -q -m -overwrite_original -api QuickTimeUTC=1 \
    -tagsFromFile "$sample" -Keys:all -UserData:all \
    '-Keys:GPSCoordinates=48.8584, 2.2945, 35' "$1"
}

cp -p "$sample" "$out/IMG_6758.mov"
cp -p "$here/Fixtures/samsung.mp4" "$out/samsung.mp4"

ff -noautorotate -i "$sample" -map 0:v:0 -map 0:a \
   -filter:v "fps=60,format=yuv420p10le" \
   -c:v libx265 -preset fast -crf 18 -tag:v hvc1 \
   -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
   -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
   -c:a copy -map_metadata 0 -movflags +use_metadata_tags "$out/hlg60.mov"
gps "$out/hlg60.mov"

ff -noautorotate -i "$sample" -map 0:v:0 -map 0:a -c copy -map_metadata 0 "$out/clip.mp4"
gps "$out/clip.mp4"

ff -noautorotate -i "$sample" -map 0:v:0 -map 0:a \
   -filter:v "fps=24000/1001" -c:v libx264 -preset fast -crf 18 \
   -c:a copy -map_metadata 0 -movflags +use_metadata_tags "$out/film23.mov"
gps "$out/film23.mov"

touch -r "$sample" "$out"/*
ls -l "$out"
