# Phase 0: rename LeftBlank to Prose, replace the brand, swap the palette

Date: 2026-11-08
Status: done 2026-11-08
Spec: `docs/prose-spec.md`, Sections 3.1, 4 and 9.1

## Goal

Prose must ship with no LeftBlank name, logo or icon, as `BRAND_POLICY.md` requires. The "based on LeftBlank" attribution stays in `README.md` and `Resources/ThirdParty.txt`. The app must still build and pass `scripts/test.sh` with 80 percent coverage. Git history is kept: paths move with `git mv`.

## Inventory and decisions

The inventory comes from `git grep -i leftblank` at commit `d7d6c32`: about 1,500 occurrences in 327 files, and 227 tracked paths with the name in them.

### Names

| Today | Prose | Where |
|-|-|-|
| `LeftBlank` | `Prose` | Swift types, strings, docs, scripts, menus |
| `leftblank` | `prose` | Crate names, helper binary, CSS variables, temporary folders, test fixtures |
| `LEFTBLANK_*` | `PROSE_*` | Environment variables (`PROSE_DISTRIBUTION`, `PROSE_INTEGRATION`, `PROSE_BUILD_NUMBER`, `PROSE_PREVIEW` define, `PROSE_IPAD_PROVISIONING_PROFILE`) |
| `留白` | `Prose` | zh-Hans strings, `InfoPlist.strings`, welcome guide. Prose has no Chinese name |
| `留白预览版` | `Prose 预览版` | Preview channel name in `scripts/package-app.py` |
| Tagline "Ink for your thoughts" and "此中有真意，欲辨已忘言" | "Write in Typst" and "用 Typst 写作" | Welcome guide title, About panel credits, template gallery, tests |

### Bundle and service identifiers

| Today | Prose | Where |
|-|-|-|
| `app.leftblank.writer` | `com.tehrandavis.prose` | `Resources/Info.plist`, iPad project, App Store and iCloud scripts |
| `app.leftblank.writer.preview` | `com.tehrandavis.prose.preview` | `Resources/Preview-Info.plist`, `scripts/preview-feed.py` |
| `iCloud.app.leftblank.writer` | `iCloud.com.tehrandavis.prose` | `Resources/Prose.iCloud.entitlements.example`, `scripts/prepare-icloud-profile.py` |
| `leftblank-app/leftblank` on GitHub | `tehrandavis/prose` | Preview feed URL, publish scripts, Codecov link, docs |
| `https://leftblank.app` | `https://github.com/tehrandavis/prose` | Preview feed, iPad storefront metadata, README |
| Sparkle `SUPublicEDKey` (LeftBlank's key) | Removed | `Resources/Preview-Info.plist`. The Preview channel needs a new EdDSA key before it can publish |
| Info.plist keys `LeftBlankDistribution`, `LeftBlankCommit` | `ProseDistribution`, `ProseCommit` | `scripts/package-app.py`, `scripts/sign-app.sh`, `AppDistribution.swift` |

### Swift package (`Package.swift`, `Sources/Package.swift`)

| Today | Prose |
|-|-|
| Package `LeftBlank` | `Prose` |
| `LeftBlankCore`, `LeftBlankApp` (path `Sources/LeftBlank`), `LeftBlankLauncher` | `ProseCore`, `ProseApp` (path `Sources/Prose`), `ProseLauncher` |
| `LeftBlankSyntaxFFI`, `LeftBlankSyntaxLibrary`, `LeftBlankSyntax.xcframework` | `ProseSyntaxFFI`, `ProseSyntaxLibrary`, `ProseSyntax.xcframework` |
| `LeftBlankTestSupport`, `LeftBlankCoreTests`, `LeftBlankAppTests` | `ProseTestSupport`, `ProseCoreTests`, `ProseAppTests` |
| Executable product `LeftBlank` | `Prose` |
| Resource bundle `LeftBlank_LeftBlankCore.bundle` | `Prose_ProseCore.bundle`. `CoreResources.swift` looks it up by name, so the rename must change both together |

### Rust crates and helpers

| Today | Prose |
|-|-|
| `Engine/SyntaxBridge` crate `leftblank-syntax`, `libleftblank_syntax.a`, header `LeftBlankSyntax.h` | `prose-syntax`, `libprose_syntax.a`, `ProseSyntax.h` |
| `Engine/TinymistBridge` (iPad) `libleftblank_tinymist.a`, header `LeftBlankTinymist.h` | `libprose_tinymist.a`, `ProseTinymist.h` |
| `Tools/MCPServer` binary `leftblank-mcp` | `prose-mcp`, in `.tools/` and `Contents/Helpers/` |

Both `Cargo.lock` files change with the crate names.

### Resources, entitlements and Info.plist files

- `Resources/Info.plist`: executable, name, display name and bundle id.
- `Resources/Preview-Info.plist`: bundle id, name, feed URL, Sparkle key.
- `Resources/LeftBlank.AppStore.entitlements`, `LeftBlank.Helper.entitlements`, `LeftBlank.iCloud.entitlements.example` become `Prose.*`. The contents only change in the iCloud example.
- `Resources/en.lproj` and `zh-Hans.lproj/InfoPlist.strings`.
- `Resources/ThirdParty.txt`: the app icon line describes the Sigma mark. It becomes the Prose icon line and gains the LeftBlank attribution.

### Brand artwork (removed under the brand policy)

| Today | Prose |
|-|-|
| `Brand/logo*.png`, `logo.svg`, `mark-*.svg`, `social-preview*` | Deleted |
| `Brand/web/` favicons and manifest | Deleted. Prose has no website yet |
| `Brand/AppStore/` (LeftBlank App Store screenshots, metadata, render tools) | Deleted |
| `design/sigma/` (the Sigma generator) | Deleted. It only produces LeftBlank artwork |
| `Resources/AppIcon.svg`, `AppIconLight.svg` | Deleted. The Prose icon has no vector source |
| `Resources/AppIcon.icns`, `AppIconLight.icns` | Built from `Brand/Prose/icon-1024.png` by `scripts/make-app-icon.py` |
| `iPad/Assets.xcassets/AppIcon.appiconset/icon.png`, `icon-dark.png` | Built by the same script |
| `Examples/leftblank-mark.svg`, `Sources/LeftBlankCore/Resources/Templates/leftblank-mark.svg` | `prose-mark.png`, a 256-pixel copy of the icon |
| `welcome-cover.png`, `welcome-cover.zh-Hans.png` (thumbnails that show the Sigma mark) | Regenerated from the new welcome guide |
| `Brand/README.md` | Rewritten for the Prose icon |

The source icon is a 1254-pixel opaque PNG: a white rounded tile on black. The script cuts the tile out of the black surround with a flood fill from the edges, softens the edge, and scales the tile to the macOS grid (an 824-pixel tile on a 1024-pixel canvas). `AppIconLight.icns` holds the source artwork. `AppIcon.icns`, the dark Dock icon, is derived: neutral pixels (paper and letter) swap lightness and the blue caret and wave stay. `DockIconController` switches between them, and a test requires the two to differ. A hand-drawn dark icon can replace the derived one later.

### Welcome guide

`Welcome.typ`, `Welcome.zh-Hans.typ` and `Examples/Welcome.typ` carry the name in comments, `#set document(author:)`, the letter-spaced header ("L E F T B L A N K / A FIELD GUIDE") and body text. All become Prose. The mark becomes `prose-mark.png`. `WelcomeDocument.markFilename` and the tests that compare the mark with `Brand/mark-dark.svg` change with it. `Examples/留白.typ` becomes `Examples/Prose.zh-Hans.typ`.

### Scripts, CI and lint

All 47 scripts that name LeftBlank change by the rules above. Paths in `scripts/ci_changes.py` and `scripts/test-ci-policy.py` follow the moved files. `.swiftlint.yml` follows the `CoreResources.swift` path. `.github/` workflows follow the renamed scripts and identifiers, but they will not run until a `tehrandavis/prose` repository exists.

### iPad target

The iPad project (`iPad/LeftBlank.xcodeproj`, sources, UI tests, storefront) is renamed by the same rules so that no LeftBlank name remains. It cannot be built on this Mac in this phase, so the iPad rename is unverified.

### What keeps the LeftBlank name

- `BRAND_POLICY.md`, unchanged, as the record of the terms Prose follows.
- `README.md` and `Resources/ThirdParty.txt`: "Prose is based on LeftBlank" with a link and its MIT licence.
- `LICENSE`: LeftBlank's copyright line stays, as MIT requires.
- `docs/prose-spec.md`, `CLAUDE.md` and this note, which describe the fork.
- `releases/0.5.0.md`, LeftBlank's own release note, kept as history.
- The SICP fixture attribution "Adapted to Typst by the LeftBlank project", which is a fact about who did the work.

## Palette

`Sources/Prose/Theme.swift` replaces the Nano palette with the Intent tokens in spec Section 4.1. Syntax colours stay as they are, as Section 4.1 says.

| Token | Light | Dark | Spec role |
|-|-|-|-|
| `background` | `#F5F5F7` | `#1A1A1A` | Sidebar |
| `editor` | `#FFFFFF` | `#262626` | Page |
| `panel` | `#F5F5F7` | `#1A1A1A` | Sidebar (status bar and command panel) |
| `border` | `#E5E2DD` | `#464646` | Hairline |
| `text` | `#1A1918` | `#E8E4DE` | Primary text |
| `secondary` | `#68635E` | `#9C968D` | Secondary text |
| `muted` | `#716B65` | `#948E85` | Not in the spec. Chosen for 4.5:1 or better on both the page and the sidebar |
| `accent` | `#7C2494` | `#B784E0` | Dusk violet |
| `green` | `#5CB85C` | `#5CB85C` | Compile OK |
| `red` | `#E25555` | `#E25555` | Compile error |
| `selection` | `#F2E9F4` | `#463B4F` | Violet at 10 percent on the page, violet at 22 percent on the dark page, flattened to opaque colours |
| `selectedText` | `#1A1918` | `#E8E4DE` | Primary text |

The preview canvas (`PreviewWebView.chromeColor`) changes from `#FAFAFA` and `#22262B` to the sidebar colours, `#F5F5F7` and `#1A1A1A`, as Section 4.1 says. The iPad theme (`TabletTheme.swift`, `TabletPreview.swift`) takes the same values, unverified. The compile warning colour `#E8A838` has no user yet and is left for the Phase 1 status dot.

The spec's compile colours are low in contrast when used for text on white: green `#5CB85C` is 2.5:1 and red `#E25555` is 3.7:1. Several error messages draw text in `Theme.red`. Phase 0 applies the spec values as written. Phase 1 should add darker text variants or use the colours only for dots and icons.

`docs/architecture.md` describes the Nano colours. Its palette paragraphs change in the same commit.

## Order of commits

1. This note.
2. Rename: paths with `git mv`, then contents, then the resource bundle name. Build and run the fast tests.
3. Brand: icon script and icons, welcome mark and covers, deletion of LeftBlank artwork, new `Brand/README.md`, README and `ThirdParty.txt` attribution.
4. Palette and the architecture doc.
5. Full `scripts/build.sh release` and `scripts/test.sh`, then the phase table in `CLAUDE.md` and `_work_log.md`.

## Risks

- The resource bundle name is a string. A missed rename passes the build and fails at run time. The cold-launch test of the packaged app covers it.
- Settings, library and recovery folders move with the bundle id, so Prose starts with an empty library. That is correct for a new app.
- Tests compare the English welcome guide with `Examples/Welcome.typ` byte for byte, so both copies must change together.
