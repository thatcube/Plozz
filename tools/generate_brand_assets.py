#!/usr/bin/env python3
"""Generate tvOS Brand Assets (layered app icon + Top Shelf images) for Plozz.

Source art is the Plozz pixel-art logo (a smiling TV in Jellyfin blue). The
visual style matches the sibling Twozz app: a mid-grey background rendered as a
subtle vertical gradient with a pixel-block texture (echoing the pixelated logo),
with the colour logo floating on top. The icon is composed as three parallax
layers — the textured back, plus two identical logo layers (Middle and Front)
that the Apple TV separates on focus for a parallax depth effect. Top Shelf
images use the same textured banner with the centered logo.

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

# Brand background: a mid grey (#515151) rendered as a subtle vertical gradient
# overlaid with a deterministic pixel-block texture that echoes the pixelated
# logo. The shade sits between the original dark and the lighter revision so the
# logo's black antenna/outline stay clearly visible against it.
BRAND_DARK = (81, 81, 81)  # #515151
BG_TOP = (89, 89, 89)
BG_BOTTOM = (73, 73, 73)

# Pixel-art background texture: a grid of `PIXEL_COLS` square "pixels" across the
# width, each nudged +/- PIXEL_JITTER in brightness. Seeded so regeneration is
# reproducible; rows are derived from the aspect ratio so the cells stay square.
PIXEL_COLS = 24
PIXEL_JITTER = 10
PIXEL_SEED = 0x504C5A  # "PLZ"


def render_logo(px: int) -> Image.Image:
    """Rasterise the logo SVG to a square RGBA image of side `px`."""
    png = cairosvg.svg2png(url=LOGO_SVG, output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def pixel_background(w: int, h: int, c_top, c_bottom) -> Image.Image:
    """Vertical gradient (c_top -> c_bottom) overlaid with a pixel-block texture.

    The same `PIXEL_SEED` and aspect-derived grid are used regardless of output
    resolution, so an icon's @1x and @2x renders show the identical pattern.
    """
    t = np.mgrid[0:h, 0:w][0].astype(np.float32) / max(h - 1, 1)
    base = np.zeros((h, w, 3), dtype=np.float32)
    for i in range(3):
        base[..., i] = c_top[i] + (c_bottom[i] - c_top[i]) * t

    cols = PIXEL_COLS
    rows = max(1, round(cols * h / w))
    rng = np.random.default_rng(PIXEL_SEED)
    offsets = rng.integers(-PIXEL_JITTER, PIXEL_JITTER + 1, size=(rows, cols)).astype(np.float32)
    yi = (np.arange(h) * rows // h).clip(0, rows - 1)
    xi = (np.arange(w) * cols // w).clip(0, cols - 1)
    tile = offsets[np.ix_(yi, xi)]

    out = np.clip(base + tile[..., None], 0, 255).astype(np.uint8)
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
    back = pixel_background(w, h, BG_TOP, BG_BOTTOM)
    logo = centered_logo(w, h, logo_frac=0.688)
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
        bg = pixel_background(w * s, h * s, BG_TOP, BG_BOTTOM)
        bg.alpha_composite(centered_logo(w * s, h * s, logo_frac=0.635))
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
