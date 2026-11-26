#!/usr/bin/env python3
"""Draws PortCat's app icon from the waving tabby sprite.

The cat comes from Sources/PortCat/CatFrames.swift, so the icon always matches
the menu bar cat. Needs Pillow:  pip install pillow
Run from the PortCat folder:  python3 Icon/make-icon.py
Writes Icon/PortCat.icns and Icon/PortCat-1024.png.
"""
import re
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
FRAMES = HERE.parent / "Sources" / "PortCat" / "CatFrames.swift"

PALETTE = {
    "o": (64, 41, 48),
    "#": (255, 235, 207),
    "t": (235, 143, 84),
    "x": (64, 41, 48),
    "+": (255, 135, 158),
    "~": (94, 211, 209),
    "*": (255, 194, 107),
}
TOP, BOTTOM = (45, 114, 112), (25, 51, 68)
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def cat_grid():
    """First 'waving' frame: the cat sitting with one paw up."""
    text = FRAMES.read_text(encoding="utf-8")
    block = text.split(".waving: [", 1)[1]
    first = re.search(r"\[\n((?:\s+\"[^\"]*\",?\n)+)\s+\]", block).group(1)
    return re.findall(r'"([^"]*)"', first)


def render(size):
    """Draws at 4x and shrinks, so the rounded corners are smooth."""
    big = size * 4
    margin = round(big * 0.098)          # macOS icons leave a little room around the shape
    body = big - 2 * margin
    radius = round(body * 0.2237)        # macOS "squircle"-like corner

    bg = Image.new("RGB", (body, body))
    px = bg.load()
    for y in range(body):
        t = y / (body - 1)
        color = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        for x in range(body):
            px[x, y] = color
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body - 1, body - 1), radius, fill=255)

    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    out.paste(bg, (margin, margin), mask)

    grid = cat_grid()
    cells = [(x, y, ch) for y, row in enumerate(grid) for x, ch in enumerate(row) if ch != "."]
    x0, x1 = min(c[0] for c in cells), max(c[0] for c in cells)
    y0, y1 = min(c[1] for c in cells), max(c[1] for c in cells)
    unit = int(body * 0.77) // max(x1 - x0 + 1, y1 - y0 + 1)
    left = margin + (body - unit * (x1 - x0 + 1)) // 2
    top = margin + (body - unit * (y1 - y0 + 1)) // 2
    draw = ImageDraw.Draw(out)
    shadow_width = (x1 - x0 + 1) * unit
    floor = top + (y1 - y0 + 1) * unit
    draw.ellipse((left, floor - unit, left + shadow_width, floor + unit),
                 fill=(21, 53, 65))
    for dx, dy, color in [(3, 0, (152, 221, 208)), (shadow_width // unit - 3, 2, PALETTE["*"])]:
        cx, cy = left + dx * unit, top + dy * unit
        arm = unit if dx == 3 else unit * 3 // 4
        draw.polygon([(cx, cy - arm), (cx + arm, cy), (cx, cy + arm), (cx - arm, cy)],
                     fill=color)
    for x, y, ch in cells:
        color = PALETTE[ch]
        px0, py0 = left + (x - x0) * unit, top + (y - y0) * unit
        draw.rectangle((px0, py0, px0 + unit - 1, py0 + unit - 1), fill=color)
    return out.resize((size, size), Image.LANCZOS)


def main():
    images = {s: render(s) for s in SIZES}
    images[1024].save(HERE / "PortCat-1024.png")
    images[1024].save(HERE / "PortCat.icns", append_images=[images[s] for s in SIZES[:-1]])
    print("wrote", HERE / "PortCat.icns")


if __name__ == "__main__":
    main()
