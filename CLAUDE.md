# Prose

A native macOS Typst writing app with three views of one source file: Code, Writing (rendered blocks) and Focus. Forked from LeftBlank on 2026-11-08 at commit `38ba0fb`. The spec is `docs/prose-spec.md`. Read it before any structural change.

## Repository

- `origin` is `tehrandavis/prose` (public, a GitHub fork of `leftblank-app/leftblank`; renamed from `tehrandavis/leftbank` on 2026-11-08). `upstream` is `leftblank-app/leftblank`. `main` and `prose` both carry Prose. GitHub Actions is disabled on the repository: the inherited workflows publish signed Preview builds and run nightly, and need secrets Prose does not have yet.
- Everything under `docs/` other than `prose-spec.md` describes LeftBlank as inherited. Treat those docs as accurate for the inherited code until Prose changes it, then update them.
- LeftBlank's brand policy (`BRAND_POLICY.md`) excludes its names, logo and icons from the MIT licence. Phase 0 removed them. Keep the "based on LeftBlank" attribution in `README.md` and `Resources/ThirdParty.txt`.
- Bundle id `com.tehrandavis.prose`. Icons come from `Brand/Prose/icon-1024.png` through `scripts/make-app-icon.py`.
- The Preview channel has no Sparkle key yet. Generate one before publishing a Preview build.
- Build and test with `scripts/build.sh release` and `PROSE_DISTRIBUTION=preview scripts/test.sh` (the coverage gate needs the Preview distribution). Run `scripts/build-syntax.sh` once before a plain `swift build`. Xcode 26 or later (verified on Xcode 27.0 beta, Swift 6.4), Rust 1.92.0 through rustup. The first build compiles Tinymist and takes about 15 minutes.
- Coverage gate is 80 percent of production Swift lines. Keep it.

## Rules inherited from LeftBlank that stay

- Phosphor icons only. SwiftLint rejects SF Symbols in app sources.
- TextKit 2 only. One `layoutManager` access switches a view to TextKit 1 for good; tests fail on it.
- The text storage always holds the full source. No hidden characters, attachments or substituted display text. Writing mode renders in the layout layer (`NSTextLayoutFragment` subclass), never in the storage. See `docs/visual-editing.md` for why the first attempt was removed.
- Resources load through `CoreResources.bundle`, never `Bundle.module`.

## Design tokens

Colours, type, radius and spacing come from Intent (`~/dev/Cadence/Cadence/Theme/ThingsLook.swift`, `Theme.swift`, `PanelCard.swift`). The values are copied into Section 4 of the spec. Accent is dusk violet `#7C2494` light, `#B784E0` dark. Sidebar `#F5F5F7` / `#1A1A1A`, page white / `#262626`.

## Phases

| Phase | Scope | State |
|-|-|-|
| 0 | Rename bundle and module to Prose, replace icon and brand assets, swap Nano palette for Intent tokens | Done 2026-11-08 |
| 1 | Project model, sidebar tree with nested outline, title row with breadcrumb and status dot, mode control (Code only), preview page cards | Not started |
| 2 | `Engine/RenderBridge` Rust crate: per-block render with document context, cache, SVG with glyph rectangles | Not started |
| 3 | Writing mode in the editor, with selection, undo, IME and VoiceOver acceptance tests before it is on by default | Not started |
| 4 | Focus mode, floating toolbar, syntax-aware spell check | Not started |
| 5 | Info popover, export sheet, per-document mode memory, screenshots, writing guide | Not started |

Phase 3 has a kill switch: if the acceptance tests cannot pass, Writing mode ships read-only.

## Working agreements

- Use `td` for task tracking: `td usage --new-session` at start, `td handoff` before stopping.
- Write a design note in `docs/plans/YYYY-MM-DD-<topic>.md` before a phase starts, as Intent does.
- Keep `docs/prose-spec.md` accurate. When a decision changes, change the spec in the same commit.
- Log work to `_work_log.md` at the end of a session.
