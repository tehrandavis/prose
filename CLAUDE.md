# Prose

A native macOS Typst writing app with three views of one source file: Code, Writing (rendered blocks) and Focus. Forked from LeftBlank on 2026-11-08 at commit `38ba0fb`. The spec is `docs/prose-spec.md`. Read it before any structural change.

## Repository

- `origin` is `tehrandavis/prose` (public, a GitHub fork of `leftblank-app/leftblank`; renamed from `tehrandavis/leftbank` on 2026-11-08). `upstream` is `leftblank-app/leftblank`. `main` and `prose` both carry Prose. GitHub Actions is disabled on the repository: the inherited workflows publish signed Preview builds and run nightly, and need secrets Prose does not have yet.
- Everything under `docs/` other than `prose-spec.md` describes LeftBlank as inherited. Treat those docs as accurate for the inherited code until Prose changes it, then update them.
- LeftBlank's brand policy (`BRAND_POLICY.md`) excludes its names, logo and icons from the MIT licence. Phase 0 removed them. Keep the "based on LeftBlank" attribution in `README.md` and `Resources/ThirdParty.txt`.
- Bundle id `com.tehrandavis.prose`. Icons come from `Brand/Prose/icon-1024.png` through `scripts/make-app-icon.py`.
- The Preview channel has no Sparkle key yet. Generate one before publishing a Preview build.
- Build and test with `scripts/build.sh release` and `PROSE_DISTRIBUTION=preview scripts/test.sh` (the coverage gate needs the Preview distribution). Run `scripts/build-render.sh` once before a plain `swift build`. Xcode 26 or later (verified on Xcode 27.0 beta, Swift 6.4), Rust 1.92.0 through rustup. The first build compiles Tinymist and takes about 15 minutes.
- Coverage gate is 80 percent of production Swift lines. Keep it.
- Book benchmark: `scripts/benchmark-books.sh` after `scripts/test.sh`. It runs SICP and War and Peace in Code, Writing (`PROSE_WRITING_MODE=1`) and Focus mode (`PROSE_FOCUS_MODE=1`) and writes `build/benchmarks/summary.md`. The Focus runs add the typewriter step gate: p95 under 33 ms in the instrumented debug build (16.7 ms is the target, not a gate). Numbers vary two to three times with machine load (see "Benchmark after steps E and F" in the Phase 4 note); rerun a failure on a quiet machine before calling it a regression.
- Native UI tests extend `WritingFlowTests` (the serialized suite). A new `@Suite` runs in parallel with the windows and menus and makes preview tests flaky.
- Test windows open in the bottom-right corner of the menu bar's screen (`placeOnTestScreen` in `Tests/ProseAppTests/WritingTestSupport.swift`); create every new test window through it. `PROSE_TEST_SCREEN=2` picks another screen, but pixel tests assume 2x: on Tehran's 1x LG monitor `focusModeDimsEveryBlockButTheFocusBlocks` fails.

- Prose is Mac only (decided 2026-11-08). The inherited iPad code (`iPad/`, `Engine/TinymistBridge`, `Sources/Package.swift`, the iPad scripts and CI jobs) was removed on 2026-11-08.

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
| 1 | Project model, sidebar tree with nested outline, title row with breadcrumb and status dot, mode control (Code only), preview page cards | Done 2026-11-08 |
| 2 | `Engine/RenderBridge` Rust crate: per-block render with document context, cache, SVG with glyph rectangles | Done 2026-11-08 |
| 3 | Writing mode in the editor, with selection, undo, IME and VoiceOver acceptance tests before it is on by default | Done 2026-11-09 |
| 4 | Focus mode, floating toolbar, syntax-aware spell check | Done 2026-11-09 |
| 5 | Citations: `.bib` reload from disk, citation picker, Zotero via Better BibTeX (linked auto-export per project) | Done 2026-11-09 |
| 6 | Quiet Writing mode: setup lines and comments fold, the open block uses the document's font with faint markers, a spike for typing in the rendered paragraph (`docs/plans/2026-11-09-quiet-writing-mode.md`) | Done 2026-11-10 |
| 7 | Info popover, export sheet, per-document mode memory, screenshots, writing guide | Not started |

Phase 3 shipped editable: all 14 acceptance tests passed three full runs in a row, so the kill switch was not used. Writing mode costs about 650 to 710 MiB for the block engine on a book. The outcome and the open items are at the end of `docs/plans/2026-11-08-phase-3-writing-mode.md`.

Phase 4 shipped Focus mode, the floating toolbar and spell check, and made the app English only. All 15 acceptance tests passed three gate runs in a row. Focus is Writing mode plus view state at scale 1.4625 in a 467 pt column; it adds about 10 MiB to Writing mode. Phase 4 also cut Writing mode's scroll and draw cost (images drawn on whole device pixels, a role cache per fragment). The typewriter step meets its 33 ms gate (p95 19 to 26 ms outside heavy load) but not the 16.7 ms target for Return. The outcome, the decision changes and the open items are at the end of `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`.

Phase 5 shipped citations. All 10 acceptance tests passed three gate runs in a row. Bibliography and other files changed on disk reach both engines with no edit (C ABI version 3), and citations render in Writing mode for the first time, from a hidden copy of the document's citations in each citing block. The **Cite a Source** picker (`⌘J R S`) searches the project's entries (C ABI version 4, Hayagriva) and, in its Zotero tab, the Zotero library through Better BibTeX. The writer links each project to its auto-exported `.bib`; Prose writes new entries only into `references-prose.bib` and removes them when the export catches up. No test in the default run contacts Zotero. `PROSE_REAL_ZOTERO=1 swift test --skip-build --filter realZoteroLibraryAnswersEveryCallProseMakes` (after `source scripts/environment.sh` and `swift build --build-tests`) runs one read-only check against the real library and prints each call's time. The outcome, the decision changes and the open items are at the end of `docs/plans/2026-11-09-citations.md`.

Phase 6 shipped folds and the open block. A run of setup lines, comments and calls with no ink draws as one row or a margin icon (`WritingLayout` folds, `WritingFolds.swift`). The block that holds the caret draws in the document's own font, from the engine's font bytes (C ABI version 6), with faint markers; the storage's attributes never change (`OpenBlockStyle`, `SourceStyler.rebuildParagraphs(in:)`). Typing in the rendered paragraph was a spike only: its caret was exact, its latency failed (p95 21 to 27 ms on the welcome guide against 16.7 ms), and it is not built; the spike is on the local branch `quiet-writing-spike`. From 2026-11-10 the checks are lighter: one full check per step by the main session, the benchmark only when a step changes drawing, layout or scrolling, one gate run per phase, and timing checks only when the load average is under about 10. The outcome and the open items are at the end of `docs/plans/2026-11-09-quiet-writing-mode.md`.

## Working agreements

- Use `td` for task tracking: `td usage --new-session` at start, `td handoff` before stopping.
- Write a design note in `docs/plans/YYYY-MM-DD-<topic>.md` before a phase starts, as Intent does.
- Keep `docs/prose-spec.md` accurate. When a decision changes, change the spec in the same commit.
- Log work to `_work_log.md` at the end of a session.
