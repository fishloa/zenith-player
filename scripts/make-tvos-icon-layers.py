#!/usr/bin/env python3
# usage: scripts/make-tvos-icon-layers.py <brandassets dir> <preview.png>
# Build tvOS layered app icon (Back/Middle/Front) from the Zenith design
# (navy field, green beacon with glow, grey horizon arc). Coordinates are in
# the 1024 iPad icon's units, scaled to the TV canvas height.
import sys, math
from PIL import Image, ImageDraw, ImageFilter
root = sys.argv[1]
NAVY_C, NAVY_E = (27, 37, 52), (20, 27, 39)
def canvas(w, h, s):
    return w, h, h / 1024.0 * s
def back(w, h):
    im = Image.new("RGB", (w, h))
    cx, cy = w / 2, h * 0.45
    r = math.hypot(w / 2, h / 2)
    px = im.load()
    for y in range(h):
        for x in range(w):
            t = min(1, math.hypot(x - cx, y - cy) / r)
            px[x, y] = tuple(int(NAVY_C[i] + (NAVY_E[i] - NAVY_C[i]) * t) for i in range(3))
    return im
def middle(w, h, k):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = w / 2
    # arc through (250,745) (512,620) (772,745) in icon units -> circle
    R = 420 * k; cy = (620 + 420) * k - 1024 * k * 0.0
    top = 620 * k + (h - 1024 * k) / 2
    box = [cx - R, top, cx + R, top + 2 * R]
    d.arc(box, start=215, end=325, fill=(52, 63, 80, 255), width=max(2, int(30 * k)))
    return im
def front(w, h, k):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cx, cy = w / 2, (214 * k) + (h - 1024 * k) / 2
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    gr = 170 * k
    g.ellipse([cx - gr, cy - gr, cx + gr, cy + gr], fill=(60, 170, 110, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(gr * 0.45))
    im = Image.alpha_composite(im, glow)
    d = ImageDraw.Draw(im)
    r1, r2 = 22 * k, 7 * k
    d.ellipse([cx - r1, cy - r1, cx + r1, cy + r1], fill=(84, 214, 128, 255))
    d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=(225, 245, 232, 255))
    return im
for stack, (bw, bh) in [("App Icon - Small", (400, 240)), ("App Icon - Large", (1280, 768))]:
    for scale, suffix in [(1, "1x"), (2, "2x")]:
        w, h = bw * scale, bh * scale
        k = h / 1024.0 * 0.95          # the iPad composition, inside tvOS's ~10% focus crop
        base = f"{root}/{stack}.imagestack"
        back(w, h).save(f"{base}/Back.imagestacklayer/Content.imageset/icon-{suffix}.png")
        middle(w, h, k).save(f"{base}/Middle.imagestacklayer/Content.imageset/icon-{suffix}.png")
        front(w, h, k).save(f"{base}/Front.imagestacklayer/Content.imageset/icon-{suffix}.png")
        if stack == "App Icon - Small" and scale == 2:
            prev = back(w, h).convert("RGBA")
            prev = Image.alpha_composite(Image.alpha_composite(prev, middle(w, h, k)), front(w, h, k))
            prev.save(sys.argv[2])
