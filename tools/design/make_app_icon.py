#!/usr/bin/env python3
# Usage: python3 tools/design/make_app_icon.py App/Resources/Assets.xcassets/AppIcon.appiconset   (needs Pillow)
# Draws the Linumic OS app icon from the Linumic mark geometry (64 grid, stroke 6, mitred joins, butt caps):
#   M14 10 V50 H54  and  M26 22 V38 H42, ink #17202C, light #EEF2F7 (Documents/Linumic-Social/Linumic-Logos/README.md).
import sys, os, json
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
SS = 4                      # supersampling
N = 1024 * SS
INK_TOP, INK_BOTTOM = (0x26, 0x34, 0x48), (0x11, 0x18, 0x22)
LIGHT = (0xEE, 0xF2, 0xF7)

# The two Ls as filled outlines of a 6-unit stroke (butt caps, mitred outer corner).
L_OUTER = [(11, 10), (17, 10), (17, 47), (54, 47), (54, 53), (11, 53)]
L_INNER = [(23, 22), (29, 22), (29, 35), (42, 35), (42, 41), (23, 41)]
MARK_CX, MARK_CY, MARK_W = 32.5, 31.5, 43.0   # bounding box x 11..54, y 10..53

def gradient(size, top, bottom):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize(size, Image.BICUBIC)

def draw_mark(img, cx, cy, width):
    s = width / MARK_W
    d = ImageDraw.Draw(img)
    for poly in (L_OUTER, L_INNER):
        d.polygon([(cx + (x - MARK_CX) * s, cy + (y - MARK_CY) * s) for x, y in poly], fill=LIGHT + (255,))

def body(size, radius):
    """The dark plate with a soft glass light from the top and a faint rim."""
    plate = gradient((size, size), INK_TOP, INK_BOTTOM).convert("RGBA")
    glass = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    for y in range(size // 2):            # light from above, fading to nothing at mid height
        a = round(34 * (1 - y / (size / 2)) ** 2)
        gd.line([(0, y), (size, y)], fill=(255, 255, 255, a))
    plate = Image.alpha_composite(plate, glass)
    mask = Image.new("L", (size, size), 0)
    if radius:
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    else:
        mask.paste(255, [0, 0, size, size])
    plate.putalpha(mask)
    if radius:
        rim = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(rim).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius,
                                              outline=(255, 255, 255, 40), width=max(2, size // 260))
        plate = Image.alpha_composite(plate, rim)
    return plate

def mac_icon():
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    inset, size = 100 * SS, 824 * SS            # macOS icon grid: 824 body on a 1024 canvas
    radius = round(size * 0.2237)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 12 * SS, inset + size, inset + size + 12 * SS],
                                             radius=radius, fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(18 * SS)))
    plate = body(size, radius)
    draw_mark(plate, size / 2, size / 2, size * 0.50)
    canvas.alpha_composite(plate, (inset, inset))
    return canvas.resize((1024, 1024), Image.LANCZOS)

def ios_icon():
    plate = body(N, 0)
    draw_mark(plate, N / 2, N / 2, N * 0.46)
    return plate.convert("RGB").resize((1024, 1024), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
mac = mac_icon()
images = []
for pts in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pts * scale
        name = f"mac-{pts}@{scale}x.png"
        mac.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pts}x{pts}"})
ios_icon().save(os.path.join(OUT, "ios-1024.png"))
images.insert(0, {"filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    f.write("\n")
