#!/usr/bin/env python3
"""Renders the legacy (pre-Android 8) launcher PNGs from the same shapes as
android/app/src/main/res/drawable/ic_launcher_foreground.xml: a video doorbell
on a dark green rounded square. Needs Pillow.

Usage: python3 tool/render_icon.py [res-dir]   (default android/app/src/main/res)
"""

import os
import sys

from PIL import Image, ImageDraw

SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
BACKGROUND = "#1E2A23"
# The adaptive icon's visible part is the middle 72 of its 108 units.
VIEW = (18, 18, 90, 90)
SUPERSAMPLE = 4


def render(size):
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=s * 0.22, fill=BACKGROUND)

    scale = s / (VIEW[2] - VIEW[0])

    def box(x0, y0, x1, y1):
        return [((x0 - VIEW[0]) * scale, (y0 - VIEW[1]) * scale),
                ((x1 - VIEW[0]) * scale, (y1 - VIEW[1]) * scale)]

    def circle(cx, cy, r, fill):
        d.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=fill)

    d.rounded_rectangle(box(40, 26, 68, 82), radius=12 * scale, fill="#FFFFFF")
    circle(54, 41, 9, BACKGROUND)
    circle(54, 41, 4, "#5C7A6A")
    circle(54, 67, 7, "#4CAF50")
    return img.resize((size, size), Image.LANCZOS)


def main():
    res = sys.argv[1] if len(sys.argv) > 1 else "android/app/src/main/res"
    for density, size in SIZES.items():
        folder = os.path.join(res, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        render(size).save(os.path.join(folder, "ic_launcher.png"))
        print(f"{folder}/ic_launcher.png {size}px")


if __name__ == "__main__":
    main()
