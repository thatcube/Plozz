#!/usr/bin/env python3
"""Generate tvOS Brand Assets (layered app icon + Top Shelf images) for Plozz.

Source art is the Plozz pixel-art logo (a smiling TV in Jellyfin blue). The
background is a smooth radial gradient — a dark off-black grey with a subtle
(~5%) glow of the brand light blue (#00A4DC) blooming from the centre — with the
colour logo floating on top. The icon is composed as three parallax layers — the
gradient back, plus two identical logo layers (Middle and Front) that the Apple
TV separates on focus for a parallax depth effect. Top Shelf images use the same
gradient banner with the centered logo. (The earlier pixel-art "static" texture
has been removed and must not be reintroduced.)

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

# Brand background: a smooth, premium radial gradient. The surface is a dark
# off-black grey with a subtle (~5%) glow of Plozz's brand light blue
# (#00A4DC, matching ThemePalette.brandBlue) blooming from the centre and
# fading to the flat dark base at the corners. There is deliberately NO pixel
# texture — the previous pixel-art "static" background is gone and must not be
# reintroduced (see the module docstring).
BASE_GRAY = (28, 28, 30)     # off-black dark grey base (#1C1C1E)
ACCENT_BLUE = (0, 164, 220)  # brand "light blue" (#00A4DC) — the radial glow hue
GLOW_STRENGTH = 0.09         # peak blend toward ACCENT_BLUE at the centre

# Logo size as a fraction of the shorter side. Bumped ~15% larger than the
# prior 0.688 so the TV mark reads bigger on the tvOS home row.
ICON_LOGO_FRAC = 0.79
TOPSHELF_LOGO_FRAC = 0.635


def render_logo(px: int) -> Image.Image:
    """Rasterise the logo SVG to a square RGBA image of side `px`."""
    png = cairosvg.svg2png(url=LOGO_SVG, output_width=px, output_height=px)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def radial_background(w: int, h: int) -> Image.Image:
    """A smooth radial gradient: dark off-black grey with a faint brand-blue glow.

    The centre blends ``GLOW_STRENGTH`` (~5%) toward ``ACCENT_BLUE`` and falls off
    smoothly (raised-cosine) to the flat ``BASE_GRAY`` at the corners, giving a
    subtle, premium depth with no banding and — deliberately — no pixel texture.
    """
    base = np.array(BASE_GRAY, np.float32)
    accent = np.array(ACCENT_BLUE, np.float32)

    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    dx = (xx - cx) / max(cx, 1.0)
    dy = (yy - cy) / max(cy, 1.0)
    r = np.clip(np.sqrt(dx * dx + dy * dy) / np.sqrt(2.0), 0.0, 1.0)
    glow = 0.5 * (1.0 + np.cos(np.pi * r))          # 1 at centre -> 0 at corners

    rgb = base + GLOW_STRENGTH * glow[..., None] * (accent - base)
    out = np.clip(rgb, 0, 255).astype(np.uint8)
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

    The Back is the radial-gradient background, and both the Middle and Front
    parallax layers are the same colour logo (no white tile), so the Apple TV's
    focus parallax gives the logo subtle depth.
    """
    back = radial_background(w, h)
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
    """Write a 2-scale Top Shelf imageset (radial-gradient banner + centered logo)."""
    images = []
    for s in (1, 2):
        bg = radial_background(w * s, h * s)
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
