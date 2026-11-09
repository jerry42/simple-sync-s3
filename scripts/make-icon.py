#!/usr/bin/env python3
"""Regenerate Resources/AppIcon/AppIcon.icns from Resources/AppIcon/AppIcon.svg.

Only needed after editing the SVG; the .icns is committed so a normal build needs nothing.
Requires: pip install cairosvg pillow
"""
import io
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon"
svg = (ROOT / "AppIcon.svg").read_bytes()
png = cairosvg.svg2png(bytestring=svg, output_width=1024, output_height=1024)
icon = Image.open(io.BytesIO(png)).convert("RGBA")
# Pillow writes every standard size (16 to 512@2x) from the 1024 px image.
icon.save(ROOT / "AppIcon.icns", format="ICNS")
icon.save(ROOT / "AppIcon.png")
print(f"Wrote {ROOT / 'AppIcon.icns'} and {ROOT / 'AppIcon.png'}")
