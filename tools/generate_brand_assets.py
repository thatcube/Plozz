#!/usr/bin/env python3
"""Generate tvOS Brand Assets (layered app icon + Top Shelf images) for Plozz.

Source art is the Plozz pixel-art logo (a smiling TV in Jellyfin blue). The
visual style matches the sibling Twozz app: a mid-grey background (luminance
"center 72") given a very subtle chromatic cast sampled from the logo's own
blues, rendered as a gentle vertical gradient between two icon-derived shades
with a logo-pixel-sized texture (echoing the pixelated logo), and the colour logo
floating on top. The icon is composed as three parallax layers — the textured
back, plus two identical logo layers (Middle and Front) that the Apple TV
separates on focus for a parallax depth effect. Top Shelf images use the same
textured banner with the centered logo.

Run from the repo root:  python3 tools/generate_brand_assets.py
"""
import io
import json
import os
import sys

import cairosvg
import numpy as np
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGO_SVG = os.path.join(REPO, "App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg")
BRAND = os.path.join(REPO, "App/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

# Brand background: the converged mid grey (luminance "center 72") given a very
# subtle chromatic cast pulled from the Plozz icon's OWN palette (the pixel logo
# is painted in Jellyfin blues). Only a faint, zero-luminance blue tint is added,
# so the grey's brightness is preserved — it still reads as a dark, premium tvOS
# brand surface and the black antenna/outline stay legible — but the surface is
# no longer flat "static": it carries a gentle top->bottom hue shift between two
# icon-derived shades plus a faint per-cell colour shimmer toward the icon blues.
# The sibling Twozz app applies the SAME technique to ITS own icon palette, so the
# two apps look like siblings while each keeps its own hue.
GREY_TOP = (80, 80, 80)      # luminance anchors (neutral); tinted toward the icon below
GREY_BOTTOM = (64, 64, 64)
TINT_STRENGTH = 0.06         # how far the gradient endpoints lean toward the icon hue
CHROMA_JITTER = 0.045        # max per-cell signed nudge toward an icon-palette hue

# Pixel-art background texture: a grid of square "pixels" whose size matches the
# logo's own pixels (the logo SVG is a LOGO_GRID x LOGO_GRID pixel-art grid), each
# nudged +/- PIXEL_JITTER in brightness (kept low / toned down) plus the colour
# shimmer above. Seeded so regeneration is reproducible; the cell size is derived
# from the rendered logo so it scales with the output resolution.
LOGO_GRID = 32
PIXEL_JITTER = 3
PIXEL_SEED = 0x504C5A  # "PLZ"

# Logo size as a fraction of the shorter side, matched to the sibling Twozz app.
ICON_LOGO_FRAC = 0.688
TOPSHELF_LOGO_FRAC = 0.635


def render_logo(px: int) -> Image.Image:
    """Rasterise the logo SVG to a square RGBA image of side `px`."""
    png = cairosvg.svg2png(url=LOGO_SVG, output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def _luminance(c) -> float:
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def _chroma_dir(c) -> np.ndarray:
    """Zero-luminance chroma vector of colour `c`.

    Adding a multiple of this to a grey shifts its hue toward `c` *without*
    changing its perceived brightness, so the background keeps its center-72
    luminance while gaining a faint chromatic cast.
    """
    L = _luminance(c)
    return np.array([c[0] - L, c[1] - L, c[2] - L], dtype=np.float32)


_PALETTE = None


def icon_palette():
    """Sample the icon's own dominant accent colours from the rendered logo.

    Returns ``(accent, light, dark)`` RGB tuples: the most common saturated
    colour plus the lightest and darkest of the icon's distinct accent shades.
    Pure black/white/transparent and low-saturation pixels are ignored, so this
    picks up the logo's actual paint (the Jellyfin blues) and nothing else. The
    result is memoised so repeated calls don't re-render the SVG.
    """
    global _PALETTE
    if _PALETTE is not None:
        return _PALETTE
    a = np.asarray(render_logo(256)).astype(np.float32)
    rgb, alpha = a[..., :3], a[..., 3]
    mx, mn = rgb.max(-1), rgb.min(-1)
    mask = (alpha > 200) & ((mx - mn) > 40)
    px = rgb[mask]
    quant = (np.round(px / 8) * 8).astype(int).reshape(-1, 3)
    colours, counts = np.unique(quant, axis=0, return_counts=True)
    top = colours[np.argsort(counts)[::-1][:3]]      # 3 most common distinct shades
    lum = top @ np.array([0.299, 0.587, 0.114])
    accent = tuple(int(v) for v in top[0])           # most frequent
    light = tuple(int(v) for v in top[int(np.argmax(lum))])
    dark = tuple(int(v) for v in top[int(np.argmin(lum))])
    _PALETTE = (accent, light, dark)
    return _PALETTE


def pixel_background(w: int, h: int, logo_frac: float) -> Image.Image:
    """Icon-tinted vertical gradient overlaid with a logo-pixel-sized texture.

    The gradient runs between two icon-derived shades — the neutral grey
    luminance anchors nudged toward the icon's light/dark accent hues — and each
    texture cell gets a faint brightness nudge plus a faint *signed* chroma nudge
    toward one of the icon-palette hues. The surface therefore gently shimmers in
    the icon's own colours instead of reading as flat grey, while its luminance
    stays in the center-72 family so the black logo outline keeps its contrast.

    Each background "pixel" is sized to one logo pixel: the logo is drawn at
    `logo_frac` of the shorter side over a LOGO_GRID-cell art grid, so the cell
    spans `min(w, h) * logo_frac / LOGO_GRID`. Because that scales with the output
    resolution, an icon's @1x and @2x renders share the same grid dimensions (and,
    via `PIXEL_SEED`, the identical pattern).
    """
    accent, light, dark = icon_palette()
    chroma = np.stack([_chroma_dir(accent), _chroma_dir(light), _chroma_dir(dark)])

    c_top = np.array(GREY_TOP, np.float32) + TINT_STRENGTH * _chroma_dir(light)
    c_bottom = np.array(GREY_BOTTOM, np.float32) + TINT_STRENGTH * _chroma_dir(dark)

    t = (np.mgrid[0:h, 0:w][0].astype(np.float32) / max(h - 1, 1))[..., None]
    base = c_top * (1.0 - t) + c_bottom * t          # (h, w, 3) tinted gradient

    cell = max(1.0, min(w, h) * logo_frac / LOGO_GRID)
    cols = max(1, round(w / cell))
    rows = max(1, round(h / cell))
    rng = np.random.default_rng(PIXEL_SEED)
    bright = rng.integers(-PIXEL_JITTER, PIXEL_JITTER + 1, size=(rows, cols)).astype(np.float32)
    pick = rng.integers(0, 3, size=(rows, cols))
    factor = rng.uniform(-CHROMA_JITTER, CHROMA_JITTER, size=(rows, cols)).astype(np.float32)
    cell_offset = bright[..., None] + factor[..., None] * chroma[pick]    # (rows, cols, 3)

    yi = (np.arange(h) * rows // h).clip(0, rows - 1)
    xi = (np.arange(w) * cols // w).clip(0, cols - 1)
    tile = cell_offset[np.ix_(yi, xi)]

    out = np.clip(base + tile, 0, 255).astype(np.uint8)
    alpha = np.full((h, w, 1), 255, dtype=np.uint8)
    return Image.fromarray(np.concatenate([out, alpha], axis=2), "RGBA")


def centered_logo(w: int, h: int, logo_frac: float) -> Image.Image:
    """Logo scaled to `logo_frac` of the shorter side, centered, transparent bg."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    side = int(min(w, h) * logo_frac)
    logo = render_logo(side)
    img.alpha_composite(logo, ((w - side) // 2, (h - side) // 2))
    return img


def save_png(img: Image.Image, *path_parts):
    out = os.path.join(BRAND, *path_parts)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    print("wrote", os.path.relpath(out, REPO), img.size)


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def icon_layers(w: int, h: int):
    """Return (front, middle, back) layers, ordered to match layer_names.

    Matches the Twozz style: the Back is the pixel-textured grey background, and
    both the Middle and Front parallax layers are the same colour logo (no white
    tile), so the Apple TV's focus parallax gives the logo subtle depth.
    """
    back = pixel_background(w, h, ICON_LOGO_FRAC)
    logo = centered_logo(w, h, logo_frac=ICON_LOGO_FRAC)
    return logo.copy(), logo.copy(), back


def write_imagestack(stack_name: str, base_w: int, base_h: int, scales):
    """Write a 3-layer .imagestack with Front/Middle/Back at the given scales."""
    layer_names = ["Front", "Middle", "Back"]
    save_json(os.path.join(BRAND, stack_name, "Contents.json"), {
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": f"{n}.imagestacklayer"} for n in layer_names],
    })
    rendered = {s: icon_layers(base_w * s, base_h * s) for s in scales}
    multi = len(scales) > 1
    for idx, name in enumerate(layer_names):
        layer_rel = os.path.join(stack_name, f"{name}.imagestacklayer")
        save_json(os.path.join(BRAND, layer_rel, "Contents.json"),
                  {"info": {"author": "xcode", "version": 1}})
        images = []
        for s in scales:
            fname = f"{name.lower()}@{s}x.png"
            save_png(rendered[s][idx], layer_rel, "Content.imageset", fname)
            entry = {"filename": fname, "idiom": "tv"}
            if multi:
                entry["scale"] = f"{s}x"
            images.append(entry)
        save_json(os.path.join(BRAND, layer_rel, "Content.imageset", "Contents.json"),
                  {"images": images, "info": {"author": "xcode", "version": 1}})


def write_top_shelf(name: str, w: int, h: int, file_prefix: str):
    """Write a 2-scale Top Shelf imageset (pixel-textured banner + centered logo)."""
    images = []
    for s in (1, 2):
        bg = pixel_background(w * s, h * s, TOPSHELF_LOGO_FRAC)
        bg.alpha_composite(centered_logo(w * s, h * s, logo_frac=TOPSHELF_LOGO_FRAC))
        fname = f"{file_prefix}@{s}x.png"
        save_png(bg, f"{name}.imageset", fname)
        images.append({"filename": fname, "idiom": "tv", "scale": f"{s}x"})
    save_json(os.path.join(BRAND, f"{name}.imageset", "Contents.json"),
              {"images": images, "info": {"author": "xcode", "version": 1}})


def main():
    if not os.path.exists(LOGO_SVG):
        sys.exit(f"logo not found: {LOGO_SVG}")
    os.makedirs(BRAND, exist_ok=True)

    save_json(os.path.join(BRAND, "Contents.json"), {
        "assets": [
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
             "role": "top-shelf-image-wide", "size": "2320x720"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv",
             "role": "top-shelf-image", "size": "1920x720"},
        ],
        "info": {"author": "xcode", "version": 1},
    })

    write_imagestack("App Icon.imagestack", 400, 240, scales=(1, 2))
    write_imagestack("App Icon - App Store.imagestack", 1280, 768, scales=(1,))
    write_top_shelf("Top Shelf Image", 1920, 720, "top")
    write_top_shelf("Top Shelf Image Wide", 2320, 720, "wide")
    print("done")


if __name__ == "__main__":
    main()
