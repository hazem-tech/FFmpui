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

## Comparing encoders (AVFoundation test)

An iOS app can't run `ffmpeg` or `exiftool`, so an iOS version would encode with Apple's AVFoundation instead. It uses the same VideoToolbox HEVC hardware encoder that ffmpeg's `hevc_videotoolbox` wraps. To check that it gives the same small files and the same quality, the Mac app has an **Encoder** switch:

- **ffmpeg** (default): the normal path, unchanged.
- **AVFoundation (test)**: encodes with AVFoundation ([`VideoTranscoder.swift`](FFmpui/VideoTranscoder.swift)), then runs the same check, metadata copy and file-date steps of the script (`compress_video.sh --encoded`). Kept copies are named `name_copy_avf.ext`, so they sit next to ffmpeg's `name_copy.ext`.

Run both on the same clips. Each finished file adds a line to **Details** with its size and video bitrate. To measure quality, compare each result with the original using ffmpeg's built-in SSIM filter (closer to 1.0 = closer to the original):

```bash
ffmpeg -i clip_copy.MOV     -i clip.MOV -lavfi "[0:v][1:v]ssim" -f null - 2>&1 | grep SSIM
ffmpeg -i clip_copy_avf.MOV -i clip.MOV -lavfi "[0:v][1:v]ssim" -f null - 2>&1 | grep SSIM
```

Known difference: AVFoundation may not be able to copy some data tracks, such as GoPro/DJI telemetry. When that happens it retries with video and audio only, like the script does, and notes it in Details.

## iOS app

The `FFmpui-iOS` target compresses videos from your **Photos library** on iPhone and iPad (iOS 26 or later). It uses the same AVFoundation encoder and settings as the Mac's AVFoundation option ([`Shared/VideoTranscoder.swift`](Shared/VideoTranscoder.swift)), so sizes and quality match.

- **Add Videos**, then **Start**. Each compressed video is added to your library as `name_copy`, next to the original.
- **Replace originals:** the compressed video is saved first. When the run ends, iOS asks once to delete the originals, which stay in **Recently Deleted** for 30 days. A video edited in Photos is skipped in this mode, so an edit is never thrown away.
- **Metadata:** iOS can't run ExifTool, so [`Shared/MetadataCopier.swift`](Shared/MetadataCopier.swift) copies the original file's metadata boxes into the new file byte for byte:
  - Apple Keys (creation date with time zone, GPS, make/model/software, lens, focal length, Live Photo ID)
  - UserData, XMP and iTunes tags
  - camera maker blocks (Canon, Sony, GoPro, DJI, …)
  - every QuickTime movie/track/media create and modify date

  In Photos, the new video gets the original's date, location, favorite and hidden state, and its albums. Make/model/GPS stored only as UserData are also copied into Apple Keys, so Photos shows them. (Photos' own "date modified" is set by iOS and can't be changed by any app.)
- It keeps running in the background, with progress shown by iOS, and the screen stays on while the app is open.
- It needs **full** Photos access, and enough free space for a temporary copy of the original plus the compressed file.

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
