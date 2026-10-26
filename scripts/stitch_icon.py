#!/usr/bin/env python3
"""Turns the Google Stitch render (Resources/IconSources/stitch-app-icon-light.jpg) into Shade's app icon.

Cuts the squircle out of its solid background, scales it to Apple's icon grid (an 824 px body on a 1024 px
canvas) with a soft drop shadow, and writes Resources/AppIcon.png and Resources/AppIcon.icns.
Run from the repository root: python3 scripts/stitch_icon.py (needs Pillow).
"""
from PIL import Image, ImageDraw, ImageFilter

SOURCE = "Resources/IconSources/stitch-app-icon-light.jpg"
# Squircle edges in the 512 px source, measured against its flat background.
LEFT, TOP, SIDE = 63, 67, 386
BODY, CANVAS = 824, 1024
RADIUS = 0.2237  # Apple's corner radius relative to the icon body
SUPERSAMPLE = 4


def squircle_mask(size):
    big = Image.new("L", (size * SUPERSAMPLE, size * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * SUPERSAMPLE - 1, size * SUPERSAMPLE - 1), radius=int(size * SUPERSAMPLE * RADIUS), fill=255)
    return big.resize((size, size), Image.LANCZOS)


source = Image.open(SOURCE).convert("RGB")
body = source.crop((LEFT, TOP, LEFT + SIDE, TOP + SIDE)).resize((BODY, BODY), Image.LANCZOS).convert("RGBA")
# Trim a hair inside the rim, so none of the source background shows at the edge.
inset = 6
mask = Image.new("L", (BODY, BODY), 0)
mask.paste(squircle_mask(BODY - 2 * inset), (inset, inset))
body.putalpha(mask)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
offset = (CANVAS - BODY) // 2
shadow = Image.new("RGBA", icon.size, (0, 0, 0, 0))
shadow_mask = Image.new("L", icon.size, 0)
shadow_mask.paste(mask, (offset, offset + 10))
shadow.putalpha(shadow_mask.point(lambda value: value * 90 // 255))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
icon.alpha_composite(body, (offset, offset))

icon.save("Resources/AppIcon.png")
icon.save("Resources/AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")
