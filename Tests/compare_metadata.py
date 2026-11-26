#!/usr/bin/env python3
"""compare_metadata.py <original> <label>=<copy> [<label>=<copy> ...]

Lists every metadata tag of <original> (ExifTool, all groups, duplicates
included) and, for each copy, which tags are missing, have a different
value, or were added. Prints Markdown.

Tracks are named by type ("video track", "audio track", "metadata track 2",
…) instead of ExifTool's position-based Track1, Track2, so a tag that lands
on the wrong track shows up as missing / added.

Tags that compression is expected to change (sizes, durations, codec,
bitrate, color description, encoder name, file-system dates …) are left out.
"""

import re
import subprocess
import sys
from collections import Counter, defaultdict

IGNORED_GROUPS = {"System", "File", "Composite", "ExifTool"}

# Container / codec details that any re-encode changes.
IGNORED_TAGS = {
    "MajorBrand", "MinorVersion", "CompatibleBrands", "MediaDataSize", "MediaDataOffset",
    "MovieHeaderVersion", "TimeScale", "Duration", "PreferredRate", "PreferredVolume",
    "PreviewTime", "PreviewDuration", "PosterTime", "SelectionTime", "SelectionDuration",
    "CurrentTime", "NextTrackID", "TrackHeaderVersion", "TrackID", "TrackDuration",
    "TrackLayer", "TrackVolume", "MatrixStructure", "ImageWidth", "ImageHeight",
    "MediaHeaderVersion", "MediaTimeScale", "MediaDuration", "HandlerVendorID",
    "HandlerDescription", "GraphicsMode", "OpColor", "CompressorID", "CompressorName",
    "VendorID", "SourceImageWidth", "SourceImageHeight", "XResolution", "YResolution",
    "BitDepth", "ColorProfiles", "ColorPrimaries", "TransferCharacteristics",
    "MatrixCoefficients", "VideoFullRangeFlag", "BufferSize", "MaxBitrate", "AverageBitrate",
    "VideoFrameRate", "Encoder", "PixelAspectRatio", "CleanApertureDimensions",
    "ProductionApertureDimensions", "EncodedPixelsDimensions", "GenMediaVersion",
    "GenFlags", "GenGraphicsMode", "GenOpColor", "GenBalance", "Balance", "SampleSizes",
    "MetaFormat", "Warning",
}

TRACK_NAMES = {"vide": "video", "soun": "audio", "meta": "metadata", "tmcd": "timecode",
               "text": "text", "sbtl": "subtitle", "subt": "subtitle"}

LINE = re.compile(r"^\[(.+?)\]\s+(\S+)\s*: ?(.*)$")


def tags(path):
    out = subprocess.run(
        ["exiftool", "-a", "-G1", "-s", "-n", "-api", "LargeFileSupport=1", path],
        capture_output=True, text=True, check=False).stdout
    rows = [m.groups() for m in map(LINE.match, out.splitlines()) if m]

    # Track1, Track2 … → "video track", "audio track", "metadata track 2" …
    handlers = {}
    for group, tag, value in rows:
        if re.fullmatch(r"Track\d+", group) and tag == "HandlerType":
            handlers.setdefault(group, value)
    per_type = Counter(handlers.values())
    seen = Counter()
    names = {}
    for group in sorted(handlers, key=lambda g: int(g[5:])):
        kind = handlers[group]
        seen[kind] += 1
        name = f"{TRACK_NAMES.get(kind, kind)} track"
        names[group] = f"{name} {seen[kind]}" if per_type[kind] > 1 else name

    result = defaultdict(list)
    for group, tag, value in rows:
        if group in IGNORED_GROUPS or tag in IGNORED_TAGS:
            continue
        result[(names.get(group, group), tag)].append(value)
    return {key: sorted(values) for key, values in result.items()}


def short(values):
    text = " | ".join(values)
    return text if len(text) <= 70 else text[:67] + "…"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    original = tags(sys.argv[1])
    print(f"Original: {len(original)} metadata tags.\n")
    for argument in sys.argv[2:]:
        label, _, path = argument.partition("=")
        try:
            copy = tags(path)
        except OSError as error:
            print(f"#### {label}\n\nCould not read: {error}\n")
            continue
        missing = sorted(k for k in original if k not in copy)
        changed = sorted(k for k in original if k in copy and copy[k] != original[k])
        added = sorted(k for k in copy if k not in original)
        kept = len(original) - len(missing) - len(changed)
        print(f"#### {label}\n")
        print(f"Kept {kept} of {len(original)} · missing {len(missing)} · "
              f"different {len(changed)} · added {len(added)}\n")
        for title, keys, show in (("Missing", missing, lambda k: short(original[k])),
                                  ("Different", changed, lambda k: f"{short(original[k])} → {short(copy[k])}"),
                                  ("Added", added, lambda k: short(copy[k]))):
            if not keys:
                continue
            print(f"<details><summary>{title} ({len(keys)})</summary>\n")
            for key in keys[:60]:
                print(f"- `[{key[0]}] {key[1]}`: {show(key)}")
            if len(keys) > 60:
                print(f"- … and {len(keys) - 60} more")
            print("\n</details>\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
