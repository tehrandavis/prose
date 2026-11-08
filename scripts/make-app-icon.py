#!/usr/bin/env python3
"""Build every Prose icon from Brand/Prose/icon-1024.png.

The source is an opaque square PNG: a white rounded tile on a black surround.
This script cuts the tile out of the surround, scales it to the macOS icon grid
(an 824-pixel tile on a 1024-pixel canvas) and writes:

- Resources/AppIcon.icns and Resources/AppIconLight.icns (Dock, dark and light)
- iPad/Assets.xcassets/AppIcon.appiconset/icon.png and icon-dark.png
- Brand/Prose/icon-macos-1024.png (transparent master)
- the welcome-guide mark, prose-mark.png, in the templates and Examples/

Requires Pillow, numpy, scipy and macOS iconutil. The app build uses the committed
outputs and does not run this script.
"""
from pathlib import Path
import shutil
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
    icns(master, ROOT / 'Resources/AppIcon.icns')
    shutil.copyfile(ROOT / 'Resources/AppIcon.icns', ROOT / 'Resources/AppIconLight.icns')
    # iPadOS masks the icon itself and rejects transparency: use the full tile.
    tile = cut_tile(Image.open(SOURCE))
    inset = round(tile.width * 0.09)  # crop inside the rounded corners
    square = tile.crop((inset, inset, tile.width - inset, tile.width - inset))
    paper = Image.new('RGBA', square.size, (244, 243, 247, 255))
    square = Image.alpha_composite(paper, square).convert('RGB')
    square = square.resize((1024, 1024), Image.LANCZOS)
    for name in ('icon.png', 'icon-dark.png'):
        square.save(ROOT / 'iPad/Assets.xcassets/AppIcon.appiconset' / name)
    mark = master.resize((256, 256), Image.LANCZOS)
    for destination in (ROOT / 'Sources/ProseCore/Resources/Templates/prose-mark.png', ROOT / 'Examples/prose-mark.png'):
        mark.save(destination, optimize=True)
    print('icons written')


if __name__ == '__main__':
    sys.exit(main())
