#!/usr/bin/env python3
"""Regenerate the app icon and in-app logo from the CW&T circle.

Asset provenance
----------------
Mark:     CW&T circle
Label id: CWT_STE1DX1_2607
Color:    #96B5AB

CW&T circle spec: a solid-color circle on a transparent background, with the
diameter at 50% of the canvas width, centered. Color varies per project; this
project's is above. Nothing here is hand-drawn — rerun this script rather than
editing the PNGs, so the label id above stays the single source of truth.

Usage (from the repo root):
    python3 Tools/make-icon.py
"""
from PIL import Image, ImageDraw
import os

COLOR = (0x96, 0xB5, 0xAB, 255)   # #96B5AB
GROUND = (255, 255, 255, 255)     # iOS only — see `circle(opaque=)` below
SS = 8                            # supersample factor, for a clean edge

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "App/Assets.xcassets/AppIcon.appiconset")
LOGOSET = os.path.join(ROOT, "App/Assets.xcassets/Logo.imageset")

ICONS = {
    "mac16x16@1x.png": 16,    "mac16x16@2x.png": 32,
    "mac32x32@1x.png": 32,    "mac32x32@2x.png": 64,
    "mac128x128@1x.png": 128, "mac128x128@2x.png": 256,
    "mac256x256@1x.png": 256, "mac256x256@2x.png": 512,
    "mac512x512@1x.png": 512, "mac512x512@2x.png": 1024,
    "ios1024.png": 1024,
}
LOGOS = {"logo.png": 64, "logo@2x.png": 128, "logo@3x.png": 192}


def circle(size, opaque=False):
    """The mark, rendered at `size`px square.

    Transparent surround by default. iOS forbids alpha in app icons and
    composites anything transparent onto black, so the iOS icon gets the
    white ground the mark is designed to sit on — `opaque=True`. macOS
    icons and the in-app logo stay transparent.
    """
    big = size * SS
    img = Image.new("RGBA", (big, big), GROUND if opaque else (0, 0, 0, 0))
    r = big // 4                  # radius = 25% of width -> diameter = 50%
    c = big / 2
    ImageDraw.Draw(img).ellipse([c - r, c - r, c + r, c + r], fill=COLOR)
    img = img.resize((size, size), Image.LANCZOS)
    return img.convert("RGB") if opaque else img


if __name__ == "__main__":
    for folder, targets in ((ICONSET, ICONS), (LOGOSET, LOGOS)):
        os.makedirs(folder, exist_ok=True)
        for name, size in targets.items():
            circle(size, opaque=name.startswith("ios")).save(os.path.join(folder, name))
            print(f"{os.path.relpath(os.path.join(folder, name), ROOT)}  {size}x{size}")
