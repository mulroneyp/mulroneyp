#!/usr/bin/env python3
"""Generate Handy Field Guide AppIcon assets from source art.

Authoritative raster source:
  design/app-icon/source-1024.png

Editable vector sketch of the same composition:
  design/app-icon/source.svg

This script resizes the 1024 master into every slot under
HandyFieldGuide/Assets.xcassets/AppIcon.appiconset/ and writes Contents.json.

Requires: Pillow (pip install Pillow)

Usage (from HandyFieldGuide/ project root):
  python3 scripts/generate_app_icon.py
  python3 scripts/generate_app_icon.py --out-dir /tmp/icons
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required. Install with: pip install Pillow") from exc


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "design" / "app-icon" / "source-1024.png"
DEFAULT_OUT = ROOT / "HandyFieldGuide" / "Assets.xcassets" / "AppIcon.appiconset"
DEFAULT_PREVIEW = ROOT / "design" / "app-icon" / "preview-1024.png"

# Filenames written into the asset catalog.
SIZES = [
    ("icon-1024.png", 1024),  # App Store / universal single-size
    ("icon-180.png", 180),    # iPhone app 60pt @3x
    ("icon-120.png", 120),    # iPhone app 60pt @2x / Spotlight 40pt @3x
    ("icon-167.png", 167),    # iPad Pro app 83.5pt @2x
    ("icon-152.png", 152),    # iPad app 76pt @2x
    ("icon-87.png", 87),      # Settings 29pt @3x
    ("icon-80.png", 80),      # Spotlight 40pt @2x
    ("icon-76.png", 76),      # iPad app 76pt @1x
    ("icon-60.png", 60),      # Notification 20pt @3x
    ("icon-58.png", 58),      # Settings 29pt @2x
    ("icon-40.png", 40),      # Notification 20pt @2x / Spotlight 20pt @2x
    ("icon-29.png", 29),      # Settings 29pt @1x
    ("icon-20.png", 20),      # Notification 20pt @1x
]


def contents_json() -> str:
    """Universal 1024 entry (modern Xcode) plus explicit legacy slots."""
    images: list[dict] = [
        {
            "filename": "icon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ]
    legacy = [
        ("iphone", "20x20", "2x", "icon-40.png"),
        ("iphone", "20x20", "3x", "icon-60.png"),
        ("iphone", "29x29", "2x", "icon-58.png"),
        ("iphone", "29x29", "3x", "icon-87.png"),
        ("iphone", "40x40", "2x", "icon-80.png"),
        ("iphone", "40x40", "3x", "icon-120.png"),
        ("iphone", "60x60", "2x", "icon-120.png"),
        ("iphone", "60x60", "3x", "icon-180.png"),
        ("ipad", "20x20", "1x", "icon-20.png"),
        ("ipad", "20x20", "2x", "icon-40.png"),
        ("ipad", "29x29", "1x", "icon-29.png"),
        ("ipad", "29x29", "2x", "icon-58.png"),
        ("ipad", "40x40", "1x", "icon-40.png"),
        ("ipad", "40x40", "2x", "icon-80.png"),
        ("ipad", "76x76", "1x", "icon-76.png"),
        ("ipad", "76x76", "2x", "icon-152.png"),
        ("ipad", "83.5x83.5", "2x", "icon-167.png"),
        ("ios-marketing", "1024x1024", "1x", "icon-1024.png"),
    ]
    for idiom, size, scale, filename in legacy:
        images.append(
            {
                "filename": filename,
                "idiom": idiom,
                "scale": scale,
                "size": size,
            }
        )
    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"


def load_master(path: Path) -> Image.Image:
    if not path.is_file():
        raise SystemExit(
            f"Missing source art: {path}\n"
            "Place a 1024×1024 RGB PNG there, then re-run this script."
        )
    img = Image.open(path).convert("RGB")
    if img.size != (1024, 1024):
        img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    return img


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--preview", type=Path, default=DEFAULT_PREVIEW)
    args = parser.parse_args()

    master = load_master(args.source)
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    for name, size in SIZES:
        frame = master if size == 1024 else master.resize((size, size), Image.Resampling.LANCZOS)
        frame.save(out_dir / name, format="PNG", optimize=True)

    (out_dir / "Contents.json").write_text(contents_json(), encoding="utf-8")

    preview: Path = args.preview
    preview.parent.mkdir(parents=True, exist_ok=True)
    master.save(preview, format="PNG", optimize=True)

    print(f"Source:  {args.source}")
    print(f"Wrote {len(SIZES)} PNGs + Contents.json → {out_dir}")
    print(f"Preview: {preview}")


if __name__ == "__main__":
    main()
