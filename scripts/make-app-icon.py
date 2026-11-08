#!/usr/bin/env python3
"""Build every Prose icon from Brand/Prose/icon-1024.png.

The source is an opaque square PNG: a white rounded tile on a black surround.
This script cuts the tile out of the surround, scales it to the macOS icon grid
(an 824-pixel tile on a 1024-pixel canvas) and writes:

- Resources/AppIconLight.icns, the source artwork, and Resources/AppIcon.icns,
  a dark variant with dark paper and a light letter (Dock, light and dark)
- Brand/Prose/icon-macos-1024.png and icon-macos-dark-1024.png (transparent masters)
- the welcome-guide mark, prose-mark.png, in the templates and Examples/

Requires Pillow, numpy, scipy and macOS iconutil. The app build uses the committed
outputs and does not run this script.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Brand/Prose/icon-1024.png'
CANVAS = 1024
TILE = 824


def cut_tile(source):
    rgb = np.asarray(source.convert('RGB')).astype(np.int16)
    dark = rgb.max(axis=2) < 48
    # The surround is the dark region connected to the image border. Dark
    # pixels inside the tile (the letter) are not connected to it.
    labels, _ = ndimage.label(dark)
    border = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))) - {0}
    surround = np.isin(labels, list(border))
    tile = ~surround
    # Drop the one-pixel dark fringe, then soften the edge for antialiasing.
    tile = ndimage.binary_erosion(tile, iterations=2)
    alpha = Image.fromarray((tile * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.0))
    rgba = source.convert('RGBA')
    rgba.putalpha(alpha)
    return rgba.crop(rgba.getbbox())


def place(tile):
    scale = TILE / max(tile.size)
    size = (round(tile.width * scale), round(tile.height * scale))
    tile = tile.resize(size, Image.LANCZOS)
    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(tile, ((CANVAS - size[0]) // 2, (CANVAS - size[1]) // 2), tile)
    return canvas


def darken(image):
    """Swap the neutral paper and ink; keep the saturated caret and wave."""
    rgba = np.asarray(image.convert('RGBA')).astype(np.float64) / 255
    rgb, alpha = rgba[..., :3], rgba[..., 3:]
    # Chroma, not saturation: the dark navy letter has little chroma but a
    # high saturation ratio, and it must swap with the paper.
    chroma = rgb.max(axis=2, keepdims=True) - rgb.min(axis=2, keepdims=True)
    neutral = np.clip(1 - (chroma - 0.12) / 0.14, 0, 1)
    luminance = rgb @ np.array([0.2126, 0.7152, 0.0722])
    paper = np.array([0x2A, 0x2A, 0x2E]) / 255
    ink = np.array([0xEE, 0xEC, 0xF2]) / 255
    swapped = paper + (ink - paper) * (1 - luminance[..., None])
    result = rgb * (1 - neutral) + swapped * neutral
    return Image.fromarray((np.concatenate([result, alpha], axis=2) * 255).round().astype(np.uint8), 'RGBA')


def icns(master, destination):
    with tempfile.TemporaryDirectory() as directory:
        iconset = Path(directory) / 'AppIcon.iconset'
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                name = f'icon_{points}x{points}' + ('@2x' if scale == 2 else '') + '.png'
                master.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)


def main():
    master = place(cut_tile(Image.open(SOURCE)))
    master.save(ROOT / 'Brand/Prose/icon-macos-1024.png')
    dark = darken(master)
    dark.save(ROOT / 'Brand/Prose/icon-macos-dark-1024.png')
    icns(master, ROOT / 'Resources/AppIconLight.icns')
    icns(dark, ROOT / 'Resources/AppIcon.icns')
    mark = master.resize((256, 256), Image.LANCZOS)
    for destination in (ROOT / 'Sources/ProseCore/Resources/Templates/prose-mark.png', ROOT / 'Examples/prose-mark.png'):
        mark.save(destination, optimize=True)
    print('icons written')


if __name__ == '__main__':
    sys.exit(main())
