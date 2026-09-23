#!/usr/bin/env python3
"""Bake the chrome study's four faces into coverage files, docs/CHROME.md section 5.

A face is a TrueType file under the SIL Open Font License, in tools/fonts. The
target never rasterizes an outline: this bakes each face at the sizes the look
uses into a `.face` file, an 8-bit coverage mask and the metrics per glyph, and
the build stages it to /lib/font/<role>/<px>.face. `sys/libfont`'s `face.odin`
reads the file, and `sys/libraster.coverage` lays a glyph.

The file, little-endian:

    magic    u32   'FACE'
    version  u16   1
    nranges  u16
    height   u16   the line: ascent plus descent
    ascent   u16   the baseline, down from the top of the line
    ranges   nranges of (lo u32, hi u32, first u32): a rune range, and the
                   index of its first glyph
    glyphs   one 16-byte record a rune: advance i16, left i16, top i16,
                   w u16, h u16, 0 u16, offset u32 into the masks
    masks    w*h bytes a glyph, one byte a pixel, 0 none and 255 all

`left` is the mask's first column from the pen, `top` its first row above the
baseline. The output is checked in, so a build stages it without Pillow.
Regenerate with:

    python3 tools/genface.py

Needs Pillow, which the build does not.
"""
import os
import struct
from PIL import ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "fonts")
OUT = os.path.join(HERE, "..", "lib", "font")

MAGIC = 0x45434146  # 'F','A','C','E' little-endian

# The runes a face carries: ASCII, Latin-1, the dashes and quotes, the arrows.
# The same ranges /lib/font/default.font gives the 8x16 face.
RANGES = [(0x20, 0x7E), (0xA0, 0xFF), (0x2010, 0x2027), (0x2190, 0x2193)]

# role, source file, pixel sizes, stem boost. The boost is the stem darkening
# a renderer does for small light-on-dark text: coverage times it, held to
# 255, so a stem one pixel wide reads as a stem.
FACES = [
    ("chrome", "ChakraPetch-SemiBold.ttf", [11], 1.15),
    ("interface", "IBMPlexSansCondensed-Regular.ttf", [13], 1.25),
    ("readout", "VT323-Regular.ttf", [20, 32], 1.0),
    ("namespace", "IBMPlexMono-Regular.ttf", [12], 1.25),
]


def glyph(font, cp, boost):
    """The advance, the mask's place and size, and its bytes, for one rune."""
    ch = chr(cp)
    advance = int(round(font.getlength(ch)))
    try:
        mask, (ox, oy) = font.getmask2(ch, mode="L", anchor="ls")
    except Exception:
        return advance, 0, 0, 0, 0, b""
    w, h = mask.size
    if w == 0 or h == 0:
        return advance, 0, 0, 0, 0, b""
    data = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            data[y * w + x] = min(255, int(round(mask.getpixel((x, y)) * boost)))
    # getmask2's offset is the mask's corner from the anchor, y down: the top
    # above the baseline is its negation.
    return advance, ox, -oy, w, h, bytes(data)


def bake(src, px, boost, path):
    font = ImageFont.truetype(src, px)
    ascent, descent = font.getmetrics()
    records = []
    masks = bytearray()
    ranges = []
    for lo, hi in RANGES:
        ranges.append((lo, hi, len(records)))
        for cp in range(lo, hi + 1):
            adv, left, top, w, h, data = glyph(font, cp, boost)
            records.append(struct.pack("<hhhHHHI", adv, left, top, w, h, 0, len(masks)))
            masks += data
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHHH", MAGIC, 1, len(ranges), ascent + descent, ascent))
        for lo, hi, first in ranges:
            f.write(struct.pack("<III", lo, hi, first))
        for r in records:
            f.write(r)
        f.write(masks)
    return os.path.getsize(path)


def main():
    for role, name, sizes, boost in FACES:
        os.makedirs(os.path.join(OUT, role), exist_ok=True)
        for px in sizes:
            path = os.path.join(OUT, role, f"{px}.face")
            n = bake(os.path.join(SRC, name), px, boost, path)
            print(f"{role}/{px}.face  {n} bytes  from {name}")
    # One license file for the four, as the OFL asks of a redistribution.
    with open(os.path.join(OUT, "OFL.txt"), "w") as out:
        out.write("The faces under /lib/font/{chrome,interface,readout,namespace} are\n")
        out.write("baked from these fonts, each under the SIL Open Font License 1.1:\n")
        out.write("Chakra Petch, IBM Plex Sans Condensed, VT323, IBM Plex Mono.\n\n")
        for lic in sorted(os.listdir(SRC)):
            if lic.startswith("OFL-"):
                out.write("=" * 72 + "\n" + lic[4:-4] + "\n" + "=" * 72 + "\n")
                out.write(open(os.path.join(SRC, lic)).read() + "\n")


if __name__ == "__main__":
    main()
