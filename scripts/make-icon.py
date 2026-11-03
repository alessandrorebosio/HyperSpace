#!/usr/bin/env python3
"""Draws Resources/AppIcon.icns.

The icon follows the macOS app icon grid: an 824 pt rounded square centered in the
1024 canvas, with a soft drop shadow underneath, so it sits at the same size as the
other icons in the Dock and Finder. The 16 and 32 px sizes are drawn without the
glyphs, which turn to noise at that size: only the three tiles are kept.

Needs Pillow (`pip3 install pillow`). Run from the repository root:

    python3 scripts/make-icon.py
"""

import io
import struct
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
SS = 4  # supersampling: drawn at 4x, then scaled down

BG_TOP = (98, 130, 255)
BG_BOTTOM = (52, 72, 214)
TILE_TOP = (255, 255, 255)
TILE_BOTTOM = (221, 228, 255)
GLYPH = (44, 64, 196)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def gradient(size, top, bottom):
    """A vertical gradient filling `size`."""
    w, h = size
    column = Image.new("RGB", (1, h))
    for y in range(h):
        column.putpixel((0, y), lerp(top, bottom, y / max(h - 1, 1)))
    return column.resize((w, h))


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def draw_icon(glyphs=True):
    """The icon at 1024 px (drawn at SS times that, returned at 1024)."""
    k = SS
    size = (CANVAS * k, CANVAS * k)
    out = Image.new("RGBA", size, (0, 0, 0, 0))

    # Body: 824 on the 1024 grid, 100 from the edges, slightly above center for the shadow.
    body = (100 * k, 92 * k, 924 * k, 916 * k)
    # Corner radius of the system icon template (185 on 824).
    body_mask = rounded_mask(size, body, 185 * k)

    # Drop shadow, like the system icons.
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    shadow_alpha = body_mask.point(lambda v: v * 0.32)
    shadow.putalpha(shadow_alpha)
    shadow = ImageChops.offset(shadow, 0, 12 * k).filter(ImageFilter.GaussianBlur(14 * k))
    out = Image.alpha_composite(out, shadow)

    background = gradient((body[2] - body[0], body[3] - body[1]), BG_TOP, BG_BOTTOM).convert("RGBA")
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    layer.paste(background, body[:2])
    layer.putalpha(body_mask)
    out = Image.alpha_composite(out, layer)

    # Tiles: one tall window on the left, two stacked on the right.
    gap = 36
    left, top, right, bottom = 220, 212, 804, 796
    mid_x = (left + right) // 2
    mid_y = (top + bottom) // 2
    radius = 58
    tiles = [
        (left, top, mid_x - gap // 2, bottom),
        (mid_x + gap // 2, top, right, mid_y - gap // 2),
        (mid_x + gap // 2, mid_y + gap // 2, right, bottom),
    ]
    tile_fill = gradient(size, TILE_TOP, TILE_BOTTOM).convert("RGBA")
    for x0, y0, x1, y1 in tiles:
        box = (x0 * k, y0 * k, x1 * k, y1 * k)
        mask = rounded_mask(size, box, radius * k)
        # A soft shadow under each tile lifts it off the background.
        tile_shadow = Image.new("RGBA", size, (16, 24, 110, 0))
        tile_shadow.putalpha(mask.point(lambda v: v * 0.35))
        tile_shadow = ImageChops.offset(tile_shadow, 0, 8 * k).filter(ImageFilter.GaussianBlur(10 * k))
        out = Image.alpha_composite(out, tile_shadow)
        tile = tile_fill.copy()
        tile.putalpha(mask)
        out = Image.alpha_composite(out, tile)

    if glyphs:
        draw = ImageDraw.Draw(out)
        stroke = 26 * k

        # Command symbol in the top right tile.
        tx0, ty0, tx1, ty1 = tiles[1]
        cx, cy = (tx0 + tx1) / 2 * k, (ty0 + ty1) / 2 * k
        half = 30 * k  # half side of the inner square
        loop = 25 * k  # radius of the corner loops (centerline)
        # The sides of the square run on to the loops, which are tangent to them.
        reach = half + loop
        for offset in (-half, half):
            draw.line((cx - reach, cy + offset, cx + reach, cy + offset), fill=GLYPH, width=stroke)
            draw.line((cx + offset, cy - reach, cx + offset, cy + reach), fill=GLYPH, width=stroke)
            # Round caps where the sides meet the loops: no notch at the joint.
            for end in (-reach, reach):
                for x, y in ((cx + end, cy + offset), (cx + offset, cy + end)):
                    draw.ellipse((x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2), fill=GLYPH)
        for sx in (-1, 1):
            for sy in (-1, 1):
                ox, oy = cx + sx * reach, cy + sy * reach
                r = loop + stroke / 2
                draw.ellipse((ox - r, oy - r, ox + r, oy + r), outline=GLYPH, width=stroke)

        # Mouse in the bottom right tile.
        mx0, my0, mx1, my1 = tiles[2]
        cx, cy = (mx0 + mx1) / 2 * k, (my0 + my1) / 2 * k
        w, h = 108 * k, 160 * k
        box = (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
        draw.rounded_rectangle(box, radius=w / 2, outline=GLYPH, width=stroke)
        wheel_top, wheel_bottom = cy - h / 2 + 32 * k, cy - h / 2 + 68 * k
        draw.line((cx, wheel_top, cx, wheel_bottom), fill=GLYPH, width=stroke)
        for y in (wheel_top, wheel_bottom):
            draw.ellipse((cx - stroke / 2, y - stroke / 2, cx + stroke / 2, y + stroke / 2), fill=GLYPH)

    return out.resize((CANVAS, CANVAS), Image.LANCZOS)


def png(image, size):
    buffer = io.BytesIO()
    image.resize((size, size), Image.LANCZOS).save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def main(path="Resources/AppIcon.icns", preview=None):
    full = draw_icon(glyphs=True)
    simple = draw_icon(glyphs=False)
    # (type, pixels, image): retina variants share the pixel size of the next 1x size.
    entries = [
        ("icp4", 16, simple),
        ("ic11", 32, simple),   # 16@2x
        ("icp5", 32, simple),
        ("ic12", 64, full),     # 32@2x
        ("ic07", 128, full),
        ("ic13", 256, full),    # 128@2x
        ("ic08", 256, full),
        ("ic14", 512, full),    # 256@2x
        ("ic09", 512, full),
        ("ic10", 1024, full),   # 512@2x
    ]
    chunks = b""
    for kind, pixels, image in entries:
        data = png(image, pixels)
        chunks += kind.encode() + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
    if preview:
        full.save(preview)


if __name__ == "__main__":
    # Optional: a path where to also save the 1024 px PNG, to look at it.
    main(preview=sys.argv[1] if len(sys.argv) > 1 else None)
