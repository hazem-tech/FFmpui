#!/usr/bin/env python3
"""make_icon.py <repo-root>: draws the app icon (the name "shrk" in a
monospaced font, terminal style, with a cursor) and writes every size the
Mac and iPhone asset catalogs need. Needs Pillow and the JetBrains Mono
font (OFL); run it again after changing the design."""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

NAME = "shrk"
BACKGROUND_TOP = (28, 32, 38)
BACKGROUND_BOTTOM = (12, 14, 17)
TEXT = (232, 237, 242)
ACCENT = (64, 214, 170)
FONT_PATHS = [
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Bold.ttf",
    "/Library/Fonts/JetBrainsMono-Bold.ttf",
    os.path.expanduser("~/Library/Fonts/JetBrainsMono-Bold.ttf"),
]


def font(size):
    for path in FONT_PATHS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    sys.exit("JetBrains Mono Bold not found")


def gradient(size):
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(BACKGROUND_TOP, BACKGROUND_BOTTOM))
        draw.line([(0, y), (size, y)], fill=color)
    return image


def artwork(size, text):
    """Square artwork: the text and a cursor block, centered."""
    image = gradient(size)
    draw = ImageDraw.Draw(image)
    face = font(round(size * (0.27 if len(text) > 2 else 0.5)))
    left, top, right, bottom = draw.textbbox((0, 0), text, font=face)
    cursor_w, gap = round(face.size * 0.5), round(face.size * 0.1)
    total = (right - left) + gap + cursor_w
    x = (size - total) / 2 - left
    ascent, descent = face.getmetrics()
    baseline_y = size / 2 + (ascent - descent) / 2 - descent * 0.2
    draw.text((x, baseline_y), text, font=face, fill=TEXT, anchor="ls")
    cx = x + left + (right - left) + gap
    cap_top = baseline_y - face.size * 0.73
    draw.rectangle([cx, cap_top, cx + cursor_w, baseline_y], fill=ACCENT)
    return image


def mac_icon(size, text=NAME):
    """macOS style: rounded square on a transparent canvas, with a shadow."""
    scale = size / 1024
    inset, body, radius = round(100 * scale), round(824 * scale), round(185 * scale)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [inset, inset + round(10 * scale), inset + body, inset + body + round(10 * scale)],
        radius=radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(max(1, round(14 * scale)))))
    art = artwork(body, text).convert("RGBA")
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)
    art.putalpha(mask)
    canvas.alpha_composite(art, (inset, inset))
    return canvas


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    mac_dir = os.path.join(root, "shrk/Assets.xcassets/AppIcon.appiconset")
    ios_dir = os.path.join(root, "shrk-iOS/Assets.xcassets/AppIcon.appiconset")

    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            filename = f"mac-{points}@{scale}x.png"
            # Draw big and shrink, so edges stay smooth; the smallest sizes
            # only fit the first letter.
            text = NAME if pixels >= 64 else NAME[0]
            mac_icon(max(pixels * 4, 256), text).resize((pixels, pixels), Image.LANCZOS).save(
                os.path.join(mac_dir, filename))
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(mac_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

    # iPhone / iPad: full square, iOS rounds the corners.
    artwork(1024, NAME).save(os.path.join(ios_dir, "icon-1024.png"))
    with open(os.path.join(ios_dir, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios",
                               "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    main()
