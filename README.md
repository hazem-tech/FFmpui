# shrk

**shrk makes your videos as small as you want them, as HEVC, without losing a single bit of their metadata or audio.**

*Formerly FFmpui.* On the Mac, shrk uses [FFmpeg](https://ffmpeg.org) under the hood; it isn't affiliated with the FFmpeg project.

shrk compresses your videos to HEVC (H.265), as small as you want them. Unlike a plain `ffmpeg` command, it **keeps all of the original metadata**, copied byte for byte, so a compressed clip shows the same recorded date, location and camera details as the original. The audio is never re-encoded: every audio track is copied bit for bit.

## Download

Get the latest Mac app from [**Releases**](https://github.com/hazem-tech/Shrk/releases/latest) (`shrk-…-macOS.dmg` or `.zip`). A new release is built automatically every time `main` changes.

The app is ad-hoc signed, not notarized by Apple, so macOS blocks it the first time:

1. Drag **shrk** into **Applications** and open it once (macOS says it can't be opened).
2. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

Or, in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/shrk.app
```

Then install FFmpeg (see [Requirements](#requirements)).

## Supported OS

shrk supports only the **latest macOS release** (and the latest iOS for the iPhone app). Each new OS version becomes the new minimum; older versions aren't supported.

## Features

- **Simple UI:** add videos or a whole folder (subfolders too), or drag & drop them, then press **Start**.
- **Four modes** (see [Modes](#modes)): **Size + Speed**, **Speed + Quality**, **Size + Quality** and **Size**, with a **Quality** level (High / Medium / Low) for the quality modes.
- **Scale:** 1×, 0.5× or 0.25× of the original width and height, in any mode.
- **Keep or replace:** by default the original is kept and the compressed file is saved next to it as `name_copy.mp4`. Turn on **Replace original files** to overwrite the originals instead (the Mac asks once when you turn it on, then remembers it). An original is only replaced after the new file has been checked (it must open and be the same length), and **never by a bigger file**: if the compressed video isn't smaller (an original that is already well compressed, in a quality mode), it's discarded and the original stays exactly as it was ("Kept the original" in its row).
- **Full metadata preservation:** the original's metadata is copied byte for byte by [`Shared/MetadataCopier.swift`](Shared/MetadataCopier.swift), the same code on Mac and iPhone:
  - Camera make, model and serial number
  - Lens make, model and serial number, plus focal length, aperture, shutter speed and ISO
  - GPS location
  - Apple tags (Live Photo pairing ID, software version, creation date with time zone, …), XMP and UserData
  - QuickTime movie, track and media create/modify dates
  - Rotation (the video isn't rotated twice)
  - All audio tracks, plus timecode, GoPro/DJI telemetry and other data tracks when the container supports them
  - macOS file **created** and **modified** dates, Finder tags and other extended attributes, and file permissions
- **Progress for each file**, total space saved, Stop at any time (half-written files are cleaned up), and the Mac stays awake while it works. Your choices (mode, quality, scale, Replace, High priority) are remembered.

## Requirements

- The latest macOS release, on a Mac with Apple's VideoToolbox HEVC encoder (any Apple silicon Mac)
- [Homebrew](https://brew.sh) packages:

  ```bash
  brew install ffmpeg
  ```

- The app must run **without the App Sandbox**, because it launches `ffmpeg` and writes next to your videos. In Xcode, open the shrk target, go to **Signing & Capabilities** and remove **App Sandbox**. If the sandbox is still on, the app tells you.

## Modes

| | Size + Speed | Speed + Quality | Size + Quality | Size |
|---|---|---|---|---|
| Goal | the smallest file the **hardware** encoder makes, quickly and without heating the device | looks like the original, quickly and without heating the device | looks like the original, in as few bytes as possible | the smallest file possible, whatever it looks like |
| Where | Mac and iPhone (same code: [`Shared/VideoTranscoder.swift`](Shared/VideoTranscoder.swift)) | Mac and iPhone (same code) | Mac | Mac |
| Encoder | Apple's VideoToolbox HEVC (media engine): lowest bitrate and quality, quantizer never below 51, no adaptive quantization (Mac), a keyframe every 10 s, speed over quality, power-saving | VideoToolbox HEVC at a constant quality for the chosen level (tuned to reach its VMAF score on the test clips), a keyframe every 10 s, power-saving | x265, 10-bit, `slower` preset, `aq-mode=4:sao=0:psy-rd=1.0` (16% fewer bytes than the usual settings for the same VMAF); for each video, the highest CRF that still reaches the chosen level's **VMAF** score against the original | x265 tuned for the floor (no SAO, 4×4 transforms, wide motion search…), a keyframe every 10 s |
| Frame rate | capped at 24 fps | unchanged | unchanged | capped at 24 fps |
| Speed | fast | fast | slow (a few test encodes per video, then the real one) | fast |

**Quality** (Speed + Quality and Size + Quality): how close to the original, as a VMAF score (0–100, how alike two videos look). **High** = 97 (hard to tell apart even side by side), **Medium** = 95 (differences hard to notice in normal viewing), **Low** = 92 (slightly softer if you look for it). Speed + Quality files are bigger than Size + Quality ones at the same level: the hardware encoder needs more bits for the same look.


- Videos at 24 fps or less keep their frame rate. HDR (HLG / PQ) videos stay 10-bit HDR in every mode (iPhone's extra Dolby Vision data isn't kept, as before).
- **High priority** (Mac, x265 modes only): on, x265 uses all of the Mac's power; off, it runs on the efficiency cores only, so the Mac stays cool and quiet but compressing takes much longer. It isn't shown for Size + Speed: the hardware encoder runs in a system process at its own pace, so priority makes no difference there (that's also why the iPhone app has no such switch).
- Every mode puts a keyframe every 10 s, so jumping around in a long video stays quick (a single keyframe was under 1% smaller).
- Known limit of the hardware modes (Size + Speed, Speed + Quality): on videos from non-Apple phones (Samsung, other Android phones), Apple's video framework drops the last ~44 ms of audio, because it assumes the encoder delay Apple's own AAC encoder adds. The audio itself is still copied, not re-encoded. iPhone videos, and the x265 modes, keep every bit of the audio.
- **How small?** On the sample iPhone clip (720p, 30 fps, 10.6 Mb/s, 7.1 MB), Size mode gives about 12 kb/s of video (less than a third of plain `-crf 51`) and Size + Speed about 100 kb/s (the hardware encoder's lowest bitrate alone gave about 460 kb/s); Size + Quality picks CRF 28 there, about 620 kb/s at VMAF 95. At these sizes the untouched audio is usually the biggest part of the file.

How the settings were chosen, and how to re-check them, is in [Tests](#tests).

## iOS app

The `shrk-iOS` target compresses videos from your **Photos library** on iPhone and iPad (the latest iOS), with the **Size + Speed** and **Speed + Quality** modes, the same code as on the Mac ([`Shared/VideoTranscoder.swift`](Shared/VideoTranscoder.swift)), so sizes and quality match.

- **Add Videos**, pick a **Mode** (and **Quality**) and a **Scale**, then **Start**. Each video is replaced by its compressed version, saved under the same name (unless that version isn't smaller: then the original is kept). When the run ends, iOS asks once to delete the originals (apps can't skip that question); they stay in **Recently Deleted** for 30 days.
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
- The apps' shared code (encoder and MetadataCopier) is built as a command-line tool ([`Tests/TranscoderHarness`](Tests/TranscoderHarness)), so every test takes the same steps as the app: the iPhone path, and the Mac path with the app's engine, [`shrk/compress_video.sh`](shrk/compress_video.sh), which encodes the x265 modes, checks the file and copies the file dates.
- [`Tests/compare_metadata.sh`](Tests/compare_metadata.sh) lists every metadata tag of each test clip (including a Samsung phone video) that goes missing, changes or is added in each mode, in the run summary.
- Each run's summary has a table of sizes, frame rates and VMAF scores.

Settings were picked with [`tune.yml`](.github/workflows/tune.yml) (run it from the Actions tab): [`Tests/tune.sh`](Tests/tune.sh) compares x265 settings for Size (total bytes) and Size + Quality (bytes at VMAF 95), and [`Tests/run_transcoder.sh`](Tests/run_transcoder.sh) compares Size + Speed variations on the runner's hardware encoder.

To benchmark Size + Speed on your own Mac (any clip; needs Xcode):

```bash
Tests/run_transcoder.sh ~/Movies/clip.mov
```
