# FFmpui

> FFmpui is not affiliated with, endorsed by, or part of the official [FFmpeg](https://ffmpeg.org) project.
> It's a small, independent app that uses FFmpeg (and ExifTool) under the hood.

FFmpui compresses your videos to HEVC (H.265) with Apple's hardware encoder. Unlike a plain `ffmpeg` command, it **keeps all of the original metadata**, so a compressed clip still looks the same in Finder, Photos, Lightroom or DaVinci Resolve.

## Features

- **Simple UI:** add videos or a whole folder (subfolders too), or drag & drop them, then press **Start**.
- **Keep or replace:** by default the original is kept and the compressed file is saved next to it as `name_copy.mp4`. Turn on **Replace original files** to overwrite the originals instead. An original is only replaced after the new file has been checked (it must open and be the same length).
- **Full metadata preservation:**
  - Camera make, model and serial number
  - Lens make, model and serial number, plus focal length, aperture, shutter speed and ISO
  - GPS location
  - Apple tags (Live Photo pairing ID, software version, creation date with time zone, …), XMP and UserData
  - QuickTime movie, track and media create/modify dates
  - Rotation (the video isn't rotated twice)
  - All audio tracks, plus timecode, GoPro/DJI telemetry and other data tracks when the container supports them
  - macOS file **created** and **modified** dates, Finder tags and other extended attributes, and file permissions
- **Progress for each file**, total space saved, Stop at any time (half-written files are cleaned up), and the Mac stays awake while it works.

## Requirements

- macOS with Apple's VideoToolbox HEVC encoder (any recent Mac)
- [Homebrew](https://brew.sh) packages:

  ```bash
  brew install ffmpeg exiftool
  ```

- The app must run **without the App Sandbox**, because it launches `ffmpeg`/`exiftool` and writes next to your videos. In Xcode, open the FFmpui target, go to **Signing & Capabilities** and remove **App Sandbox**. If the sandbox is still on, the app tells you.

## Command line

The engine is a plain shell script, [`FFmpui/compress_video.sh`](FFmpui/compress_video.sh), which also works on its own:

```bash
# keep originals, write *_copy files
./FFmpui/compress_video.sh "/Volumes/NVMe Cross/only bit rate"

# replace originals
./FFmpui/compress_video.sh --replace clip1.MOV clip2.MP4

# set file dates to the recording date instead of copying the original file's dates
./FFmpui/compress_video.sh --use-recording-date ~/Movies/Trip
```

Run `./FFmpui/compress_video.sh --help` for all options (`--bitrate`, `--encoder`, …).
