# FFmpui

> FFmpui is not affiliated with, endorsed by, or part of the official [FFmpeg](https://ffmpeg.org) project.
> It's a small, independent app that uses FFmpeg under the hood (on the Mac).

FFmpui compresses your videos to HEVC (H.265), as small as you want them. Unlike a plain `ffmpeg` command, it **keeps all of the original metadata**, copied byte for byte, so a compressed clip shows the same recorded date, location and camera details as the original. The audio is never re-encoded: every audio track is copied bit for bit.

## Features

- **Simple UI:** add videos or a whole folder (subfolders too), or drag & drop them, then press **Start**.
- **Three modes** (see [Modes](#modes)): **Size + Speed**, **Size + Quality** and **Size**.
- **Scale:** 1×, 0.5× or 0.25× of the original width and height, in any mode.
- **Keep or replace:** by default the original is kept and the compressed file is saved next to it as `name_copy.mp4`. Turn on **Replace original files** to overwrite the originals instead (the Mac asks once when you turn it on, then remembers it). An original is only replaced after the new file has been checked (it must open and be the same length).
- **Full metadata preservation:** the original's metadata is copied byte for byte by [`Shared/MetadataCopier.swift`](Shared/MetadataCopier.swift), the same code on Mac and iPhone:
  - Camera make, model and serial number
  - Lens make, model and serial number, plus focal length, aperture, shutter speed and ISO
  - GPS location
  - Apple tags (Live Photo pairing ID, software version, creation date with time zone, …), XMP and UserData
  - QuickTime movie, track and media create/modify dates
  - Rotation (the video isn't rotated twice)
  - All audio tracks, plus timecode, GoPro/DJI telemetry and other data tracks when the container supports them
  - macOS file **created** and **modified** dates, Finder tags and other extended attributes, and file permissions
- **Progress for each file**, total space saved, Stop at any time (half-written files are cleaned up), and the Mac stays awake while it works. Your choices (mode, scale, Replace, High priority) are remembered.

## Requirements

- macOS with Apple's VideoToolbox HEVC encoder (any recent Mac)
- [Homebrew](https://brew.sh) packages:

  ```bash
  brew install ffmpeg
  ```

- The app must run **without the App Sandbox**, because it launches `ffmpeg` and writes next to your videos. In Xcode, open the FFmpui target, go to **Signing & Capabilities** and remove **App Sandbox**. If the sandbox is still on, the app tells you.

## Modes

| | Size + Speed | Size + Quality | Size |
|---|---|---|---|
| Goal | the smallest file the **hardware** encoder makes, quickly and without heating the device | looks like the original, in as few bytes as possible | the smallest file possible, whatever it looks like |
| Where | Mac and iPhone (same code: [`Shared/VideoTranscoder.swift`](Shared/VideoTranscoder.swift)) | Mac | Mac |
| Encoder | Apple's VideoToolbox HEVC (media engine): lowest bitrate and quality, quantizer never below 51, no adaptive quantization (Mac), one keyframe, speed over quality, power-saving | x265, 10-bit, `slower` preset, `aq-mode=4:sao=0:psy-rd=1.0` (16% fewer bytes than the usual settings for the same VMAF); for each video, the highest CRF that still scores **VMAF ≥ 95** against the original | x265 tuned for the floor (no SAO, 4×4 transforms, wide motion search, one keyframe…) |
| Frame rate | capped at 24 fps | unchanged | capped at 24 fps |
| Speed | fast | slow (a few test encodes per video, then the real one) | fast |

- Videos at 24 fps or less keep their frame rate. HDR (HLG / PQ) videos stay 10-bit HDR in every mode (iPhone's extra Dolby Vision data isn't kept, as before).
- **High priority** (Mac, x265 modes only): on, x265 uses all of the Mac's power; off, it runs on the efficiency cores only, so the Mac stays cool and quiet but compressing takes much longer. It isn't shown for Size + Speed: the hardware encoder runs in a system process at its own pace, so priority makes no difference there (that's also why the iPhone app has no such switch).
- Size and Size + Speed use a single keyframe, so jumping around in a long video takes a moment longer.
- **How small?** On the sample iPhone clip (720p, 30 fps, 10.6 Mb/s, 7.1 MB), Size mode gives about 12 kb/s of video (less than a third of plain `-crf 51`) and Size + Speed about 100 kb/s (the hardware encoder's lowest bitrate alone gave about 460 kb/s); Size + Quality picks CRF 28 there, about 620 kb/s at VMAF 95. At these sizes the untouched audio is usually the biggest part of the file.

How the settings were chosen, and how to re-check them, is in [Tests](#tests).

## iOS app

The `FFmpui-iOS` target compresses videos from your **Photos library** on iPhone and iPad (iOS 26 or later), with the **Size + Speed** mode, the same code as on the Mac ([`Shared/VideoTranscoder.swift`](Shared/VideoTranscoder.swift)), so sizes and quality match.

- **Add Videos**, pick a **Scale**, then **Start**. Each video is replaced by its compressed version, saved under the same name. When the run ends, iOS asks once to delete the originals (apps can't skip that question); they stay in **Recently Deleted** for 30 days.
- **Edited videos** (trimmed, filtered, slow-motion ramps…): the edited version, as Photos shows it, is compressed, so the edit is kept (baked in) when the original is replaced.
- **Metadata:** [`Shared/MetadataCopier.swift`](Shared/MetadataCopier.swift), the same code as on the Mac, copies the original file's metadata boxes into the new file byte for byte:
  - Apple Keys (creation date with time zone, GPS, make/model/software, lens, focal length, Live Photo ID)
  - UserData, XMP and iTunes tags
  - camera maker blocks (Canon, Sony, GoPro, DJI, …)
  - every QuickTime movie/track/media create and modify date

  In Photos, the new video gets the original's date, location, favorite and hidden state, and its albums. Make/model/GPS stored only as UserData are also copied into Apple Keys, so Photos shows them. (Photos' own "date modified" is set by iOS and can't be changed by any app.)
- It keeps running in the background, with progress shown by iOS, and the screen stays on while the app is open.
- It needs **full** Photos access, and enough free space for a temporary copy of the original (and of its edited version) plus the compressed file.

## Tests

Everything runs on GitHub Actions' Apple Silicon Macs on every push ([`encode-tests.yml`](.github/workflows/encode-tests.yml)):

- Test clips: [`Tests/Fixtures/IMG_6758.mov`](Tests/Fixtures/IMG_6758.mov), an iPhone 13 clip, plus clips [`Tests/make_fixtures.sh`](Tests/make_fixtures.sh) makes from it: 10-bit HLG HDR at 60 fps, MP4, and 23.976 fps, each with GPS and iPhone metadata.
- Every mode × clip × scale is compressed, and [`Tests/check_output.sh`](Tests/check_output.sh) fails the run unless:
  - the output is HEVC tagged `hvc1` and just as long as the source
  - it has the right size and frame rate, the same rotation, and a rotation matrix that fits the new size
  - the **audio is bit-identical** to the source
  - Make, Model, creation date, GPS and file dates are kept, and HDR stays HDR
  - Size + Quality reaches its VMAF target
- The apps' shared code (encoder and MetadataCopier) is built as a command-line tool ([`Tests/TranscoderHarness`](Tests/TranscoderHarness)), so every test takes the same steps as the app: the iPhone path, and the Mac path with the app's engine, [`FFmpui/compress_video.sh`](FFmpui/compress_video.sh), which encodes the x265 modes, checks the file and copies the file dates.
- [`Tests/compare_metadata.sh`](Tests/compare_metadata.sh) lists every metadata tag of each test clip (including a Samsung phone video) that goes missing, changes or is added in each mode, in the run summary.
- Each run's summary has a table of sizes, frame rates and VMAF scores.

Settings were picked with [`tune.yml`](.github/workflows/tune.yml) (run it from the Actions tab): [`Tests/tune.sh`](Tests/tune.sh) compares x265 settings for Size (total bytes) and Size + Quality (bytes at VMAF 95), and [`Tests/run_transcoder.sh`](Tests/run_transcoder.sh) compares Size + Speed variations on the runner's hardware encoder.

To benchmark Size + Speed on your own Mac (any clip; needs Xcode):

```bash
Tests/run_transcoder.sh ~/Movies/clip.mov
```
