#!/usr/bin/env python3
"""Generate magnus-bridge PWA icons: a minimal suspension bridge glyph.

Pure stdlib (zlib + struct) so it runs anywhere; rerun after tweaking.
"""
import struct
import sys
import zlib
from pathlib import Path

BG = (13, 17, 23)        # #0d1117
FG = (124, 158, 219)     # #7c9edb accent
WHITE = (230, 237, 243)


def png(width, height, pixels):
    def chunk(tag, data):
        raw = tag + data
        return struct.pack(">I", len(data)) + raw + struct.pack(">I", zlib.crc32(raw))

    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in pixels)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def draw(size):
    px = [[BG] * size for _ in range(size)]

    def rect(x0, y0, x1, y1, color):
        for y in range(max(0, int(y0)), min(size, int(y1))):
            for x in range(max(0, int(x0)), min(size, int(x1))):
                px[y][x] = color

    def line(x0, y0, x1, y1, color, thick):
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(int(steps) + 1):
            t = i / steps
            cx, cy = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            rect(cx - thick / 2, cy - thick / 2, cx + thick / 2, cy + thick / 2, color)

    s = size / 100.0                     # design on a 100x100 grid
    deck_y = 62 * s
    tower_w = 5 * s

    rect(0, deck_y, size, deck_y + 4 * s, WHITE)             # deck
    rect(26 * s - tower_w / 2, 28 * s, 26 * s + tower_w / 2, deck_y + 8 * s, FG)  # left tower
    rect(74 * s - tower_w / 2, 28 * s, 74 * s + tower_w / 2, deck_y + 8 * s, FG)  # right tower
    # main cables
    line(2 * s, deck_y, 26 * s, 30 * s, FG, 2.5 * s)
    line(26 * s, 30 * s, 50 * s, 54 * s, FG, 2.5 * s)
    line(50 * s, 54 * s, 74 * s, 30 * s, FG, 2.5 * s)
    line(74 * s, 30 * s, 98 * s, deck_y, FG, 2.5 * s)
    # hangers
    for x in (38, 50, 62):
        line(x * s, 44 * s if x == 50 else 40 * s, x * s, deck_y, FG, 1.6 * s)
    return px


def main():
    out = Path(__file__).resolve().parent.parent / "pwa" / "icons"
    out.mkdir(parents=True, exist_ok=True)
    for size in (180, 192, 512):
        (out / f"icon-{size}.png").write_bytes(png(size, size, draw(size)))
        print(f"wrote icon-{size}.png")


if __name__ == "__main__":
    sys.exit(main())
