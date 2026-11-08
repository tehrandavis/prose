# Prose brand assets

The Prose icon is an italic serif capital P with a blue text caret, on a white rounded tile with a blue wave at the lower right.

| Asset | Use |
|-|-|
| `Prose/icon-1024.png` | Source artwork: a 1254-pixel opaque PNG, the tile on a black surround |
| `Prose/icon-macos-1024.png` | Transparent master on the macOS icon grid: an 824-pixel tile on a 1024-pixel canvas |
| `Prose/icon-macos-dark-1024.png` | Dark master: the neutral paper and letter swap, the blue caret and wave stay. The script derives it; it is not hand-drawn |
| `../Resources/AppIconLight.icns`, `../Resources/AppIcon.icns` | macOS Dock icons for light and dark appearances, 16 to 1024 pixels. `AppIcon.icns` is also the Finder icon |
| `../Sources/ProseCore/Resources/Templates/prose-mark.png`, `../Examples/prose-mark.png` | 256-pixel mark in the header of the welcome guide |

## Regeneration

All outputs come from the source artwork. With Pillow, numpy and scipy installed, run from the repository root:

```sh
python3 scripts/make-app-icon.py
```

The script uses the system `iconutil` to package the ICNS files. Building the app uses the committed assets and does not run the script.

The welcome-guide thumbnails show the mark. Regenerate them after an icon change, as [discovery](../docs/discovery.md) describes.

## Accent colour

The caret blue belongs to the icon only. The app's accent colour is dusk violet, `#7C2494` in light mode and `#B784E0` in dark mode. See Section 4 of the [Prose spec](../docs/prose-spec.md).

## LeftBlank artwork

Prose is based on LeftBlank. LeftBlank's names, Sigma mark, logos and icons were removed in Phase 0, as its [brand policy](../BRAND_POLICY.md) requires.
