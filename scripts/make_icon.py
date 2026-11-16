#!/usr/bin/env python3
"""Builds Packaging/AppIcon.iconset from one square picture.

Usage:
    python3 scripts/make_icon.py path/to/icon.png      # your own 1024x1024 artwork
    python3 scripts/make_icon.py --placeholder         # Mr. Oops on an ink plate

The artwork should fill the whole square with no rounded corners. This script cuts the
macOS icon shape (a rounded square with a little breathing room) and adds a soft shadow.
If the picture already has transparent corners it is used as it is.

Needs Pillow:  python3 -m pip install pillow
The build script then turns the iconset into AppIcon.icns with macOS's own `iconutil`.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "Packaging", "AppIcon.iconset")
CANVAS = 1024
PLATE = 824          # Apple's icon grid: the plate is 824 px on a 1024 px canvas
RADIUS = 185
INK = (22, 21, 19, 255)
LINE = (52, 48, 43, 255)


def rounded_mask(size, radius, scale=4):
    big = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, size * scale - 1, size * scale - 1), radius * scale, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def has_transparent_corners(image):
    alpha = image.getchannel("A")
    w, h = image.size
    corners = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
    return all(alpha.getpixel(p) < 16 for p in corners)


def compose(plate):
    """Puts an 824 px plate on the 1024 px canvas with a soft shadow."""
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - PLATE) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_shape = Image.new("RGBA", (PLATE, PLATE), (0, 0, 0, 110))
    shadow.paste(shadow_shape, (offset, offset + 12), rounded_mask(PLATE, RADIUS))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(plate, (offset, offset))
    return canvas


def from_artwork(path):
    art = Image.open(path).convert("RGBA")
    if art.width != art.height:
        side = min(art.size)
        left = (art.width - side) // 2
        top = (art.height - side) // 2
        art = art.crop((left, top, left + side, top + side))
    if has_transparent_corners(art):
        return art.resize((CANVAS, CANVAS), Image.LANCZOS)
    art = art.resize((PLATE, PLATE), Image.LANCZOS)
    plate = Image.new("RGBA", (PLATE, PLATE), (0, 0, 0, 0))
    plate.paste(art, (0, 0), rounded_mask(PLATE, RADIUS))
    return compose(plate)


def placeholder():
    plate = Image.new("RGBA", (PLATE, PLATE), INK)
    border = ImageDraw.Draw(plate)
    border.rounded_rectangle((3, 3, PLATE - 4, PLATE - 4), RADIUS - 3, outline=LINE, width=6)
    mascot = Image.open(os.path.join(ROOT, "Sources", "StupidTalk", "Resources", "oops-rock.png")).convert("RGBA")
    height = 560
    width = round(mascot.width * height / mascot.height)
    mascot = mascot.resize((width, height), Image.LANCZOS)
    plate.alpha_composite(mascot, ((PLATE - width) // 2 + 10, (PLATE - height) // 2))
    masked = Image.new("RGBA", (PLATE, PLATE), (0, 0, 0, 0))
    masked.paste(plate, (0, 0), rounded_mask(PLATE, RADIUS))
    return compose(masked)


def write_iconset(icon):
    os.makedirs(ICONSET, exist_ok=True)
    for name in os.listdir(ICONSET):
        if name.endswith(".png"):
            os.remove(os.path.join(ICONSET, name))
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "" if scale == 1 else "@2x"
            icon.resize((pixels, pixels), Image.LANCZOS).save(
                os.path.join(ICONSET, f"icon_{points}x{points}{suffix}.png"), optimize=True
            )
    print(f"Wrote {ICONSET}")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    icon = placeholder() if sys.argv[1] == "--placeholder" else from_artwork(sys.argv[1])
    write_iconset(icon)


if __name__ == "__main__":
    main()
