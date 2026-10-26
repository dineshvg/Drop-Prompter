#!/usr/bin/env python3
"""Draws Shade's app icon (Resources/AppIcon.png and Resources/AppIcon.icns).

A window with a frosted shade pulled halfway down over it, a pull handle, and a few lines of
text on the shade. Run from the repository root: python3 scripts/make_icon.py (needs Pillow).
"""
from PIL import Image, ImageDraw, ImageFilter

SCALE = 2           # draw at 2048 px, then downsample for smooth edges
SIZE = 1024 * SCALE


def s(value):
    return int(value * SCALE)


def vertical_gradient(size, top, bottom):
    gradient = Image.new("RGBA", size)
    draw = ImageDraw.Draw(gradient)
    width, height = size
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4))
        draw.line([(0, y), (width, y)], fill=color)
    return gradient


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Squircle-ish body on Apple's icon grid (824 px inside 1024), with a soft drop shadow.
body = (s(100), s(100), s(924), s(924))
shadow = Image.new("RGBA", icon.size, (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(
    (body[0], body[1] + s(14), body[2], body[3] + s(14)), radius=s(185), fill=(0, 0, 0, 110))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(18))))

background = vertical_gradient(icon.size, (36, 42, 120, 255), (12, 16, 48, 255))
icon.paste(background, (0, 0), rounded_mask(icon.size, body, s(185)))

# The window behind the shade: a lighter card with a title bar and soft "content".
window = (s(210), s(250), s(814), s(800))
ImageDraw.Draw(icon).rounded_rectangle(window, radius=s(48), fill=(232, 236, 250, 255))
draw = ImageDraw.Draw(icon)
for i, color in enumerate([(255, 95, 87, 255), (254, 188, 46, 255), (40, 200, 64, 255)]):
    cx, cy = s(262 + i * 46), s(292)
    draw.ellipse((cx - s(14), cy - s(14), cx + s(14), cy + s(14)), fill=color)
for i, width in enumerate([420, 340, 460, 300]):
    y = s(620 + i * 44)
    draw.rounded_rectangle((s(262), y, s(262 + width), y + s(18)), radius=s(9), fill=(196, 202, 228, 255))

# The shade: frosted, translucent panel pulled down from the top of the window.
shade_box = (window[0], window[1], window[2], s(560))
shade = vertical_gradient(icon.size, (120, 140, 255, 235), (70, 86, 210, 225))
shade_mask = rounded_mask(icon.size, shade_box, s(48))
# Square top corners: the shade hangs from the top edge.
ImageDraw.Draw(shade_mask).rectangle((shade_box[0], shade_box[1], shade_box[2], shade_box[1] + s(60)), fill=255)
window_mask = rounded_mask(icon.size, window, s(48))
# Clip the shade to the window's rounded corners.
icon.paste(shade, (0, 0), Image.composite(shade_mask, Image.new("L", icon.size, 0), window_mask))

draw = ImageDraw.Draw(icon)
# Lines of notes on the shade, one in an accent color like highlighted code.
for i, (width, color) in enumerate([(380, (255, 255, 255, 235)), (290, (255, 214, 110, 240)), (440, (255, 255, 255, 200))]):
    y = s(360 + i * 52)
    draw.rounded_rectangle((s(262), y, s(262 + width), y + s(22)), radius=s(11), fill=color)

# Bottom edge highlight and pull handle.
draw.line((shade_box[0] + s(30), shade_box[3] - s(2), shade_box[2] - s(30), shade_box[3] - s(2)),
          fill=(255, 255, 255, 120), width=s(4))
handle_w, handle_h = s(120), s(24)
cx = (window[0] + window[2]) // 2
draw.rounded_rectangle((cx - handle_w // 2, shade_box[3] + s(14), cx + handle_w // 2, shade_box[3] + s(14) + handle_h),
                       radius=handle_h // 2, fill=(255, 255, 255, 245))

final = icon.resize((1024, 1024), Image.LANCZOS)
final.save("Resources/AppIcon.png")
final.save("Resources/AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")
