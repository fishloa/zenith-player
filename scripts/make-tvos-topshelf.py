#!/usr/bin/env python3
# usage: scripts/make-tvos-topshelf.py <brandassets dir>
# Regenerate the tvOS Top Shelf banners (1x and 2x, regular and wide) from the
# Zenith design: navy field, green beacon with glow, grey horizon arc and the
# "Zenith Player" wordmark. The 2x images re-render the composition at double
# resolution rather than upscaling the 1x one.
import sys, math, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont
root = os.path.abspath(sys.argv[1])

NAVY_C, NAVY_E = (27, 37, 52), (20, 27, 39)
ARC = (52, 63, 80)
DOT = (84, 214, 128)
DOT_CORE = (225, 245, 232)
GLOW = (60, 170, 110, 110)
TEXT = (232, 240, 236)

BASE_H = 720

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
]


def field(w, h):
    im = Image.new("RGB", (w, h))
    cx, cy = w / 2.0, h / 2.0
    r = math.hypot(w / 2.0, h / 2.0)
    px = im.load()
    for y in range(h):
        dy = (y - cy) ** 2
        for x in range(w):
            t = min(1.0, math.sqrt((x - cx) ** 2 + dy) / r)
            t = t * t * (3 - 2 * t)
            px[x, y] = tuple(int(NAVY_C[i] + (NAVY_E[i] - NAVY_C[i]) * t) for i in range(3))
    return im


def load_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def track_width(font, text, tracking):
    return sum(font.getlength(c) for c in text) + tracking * (len(text) - 1)


def draw_tracked(d, xy, text, font, fill, tracking):
    x, y = xy
    for c in text:
        d.text((x, y), c, font=font, fill=fill)
        x += font.getlength(c) + tracking


def composition(w, h, s):
    # s = scale factor relative to the 720 pt design grid
    im = field(w, h).convert("RGBA")
    cx = w / 2.0
    cy = h / 2.0
    # horizon arc behind the beacon
    arc_r = 210 * s
    arc_cy = cy + 300 * s
    arc = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(arc).arc(
        [cx - arc_r, arc_cy - arc_r, cx + arc_r, arc_cy + arc_r],
        start=215, end=325, fill=ARC + (255,), width=max(2, int(22 * s)),
    )
    im = Image.alpha_composite(im, arc)

    # wordmark sits above the beacon; block centred on the canvas
    title_font = load_font(int(100 * s))
    title = "Zenith Player"
    tracking_t = 2 * s
    tw = track_width(title_font, title, tracking_t)
    title_y = cy - 135 * s

    glow_cx, glow_cy = cx, cy + 110 * s
    glow_r = 110 * s
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [glow_cx - glow_r, glow_cy - glow_r, glow_cx + glow_r, glow_cy + glow_r], fill=GLOW
    )
    im = Image.alpha_composite(im, glow.filter(ImageFilter.GaussianBlur(glow_r * 0.45)))

    d = ImageDraw.Draw(im)
    draw_tracked(d, (cx - tw / 2.0, title_y), title, title_font, TEXT, tracking_t)

    r1, r2 = 20 * s, 6 * s
    d.ellipse([glow_cx - r1, glow_cy - r1, glow_cx + r1, glow_cy + r1], fill=DOT + (255,))
    d.ellipse([glow_cx - r2, glow_cy - r2, glow_cx + r2, glow_cy + r2], fill=DOT_CORE + (255,))

    return im.convert("RGB")


def generate(imageset, w, h):
    for scale, suffix in [(1, "1x"), (2, "2x")]:
        im = composition(w * scale, h * scale, float(scale))
        im.save(os.path.join(root, imageset, f"img-{suffix}.png"), format="PNG", optimize=False)
        assert im.size == (w * scale, h * scale)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: scripts/make-tvos-topshelf.py <brandassets dir>")
    generate("Top Shelf Image.imageset", 1920, BASE_H)
    generate("Top Shelf Image Wide.imageset", 2320, BASE_H)


if __name__ == "__main__":
    main()
