# Prose

A native macOS Typst writing app with three views of one source file: Code, Writing (rendered blocks) and Focus. Forked from LeftBlank on 2026-11-08 at commit `38ba0fb`. The spec is `docs/prose-spec.md`. Read it before any structural change.

## Repository

- `leftbank` remote: `tehrandavis/leftbank`, the fork this started from. `upstream` remote: `leftblank-app/leftblank`. There is no `origin` yet; create a `tehrandavis/prose` repository before the first push.
- Everything under `docs/` other than `prose-spec.md` describes LeftBlank as inherited. Treat those docs as accurate for the inherited code until Prose changes it, then update them.
- LeftBlank's brand policy (`BRAND_POLICY.md`) excludes its names, logo and icons from the MIT licence. Phase 0 replaces them. Until then, do not ship a build.
- Build and test as LeftBlank does: `scripts/build.sh release`, `scripts/test.sh`. Run `scripts/build-syntax.sh` once before a plain `swift build`. Xcode 26, Swift 6.2, Rust 1.92.0. The first build compiles Tinymist and takes about 15 minutes.
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
| 0 | Rename bundle and module to Prose, replace icon and brand assets, swap Nano palette for Intent tokens | Not started |
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
