# Prose work log

## 2026-11-08: Phase 0

- Scripts now run from any checkout. LeftBlank's scripts required its author's external SSD at `/Volumes/SSD/Developer`. Temporary files, Cargo caches and fixtures now live under `.tools/` in the checkout (`d7d6c32`).
- Installed rustup in `~/.cargo/bin` with Rust 1.92.0 (pinned) and stable (default). Homebrew's `rust` is still installed but no longer first on the PATH.
- Wrote the Phase 0 design note, `docs/plans/2026-11-08-phase-0-rename-and-brand.md`.
- Renamed LeftBlank to Prose throughout. 228 paths moved with `git mv`. Modules, crates, helpers, env vars and plist keys use the Prose name. The bundle id is `com.tehrandavis.prose`. LeftBlank's Sparkle key was removed.
- Restored ordinary Chinese uses of 留白 (padding, margins, spacing) that the bulk rename had changed.
- Swapped the Nano palette for the Intent tokens in the Mac and iPad themes and the preview canvas. Syntax colours are unchanged.
- Replaced LeftBlank artwork with the Prose icon. `scripts/make-app-icon.py` builds the light and derived dark ICNS, the iPad icons and the welcome mark. Welcome thumbnails regenerated.
- Results: `scripts/build.sh release` passed. `PROSE_DISTRIBUTION=preview scripts/test.sh`: 196 core tests and 142 app tests passed, coverage 88.04 percent against the 80 percent gate.

Open items:

- The iPad target is renamed but was not built.
- The spec's compile green and red are low-contrast as text on white. Phase 1 should add text variants.
- The Preview channel needs a new Sparkle EdDSA key.
- The derived dark icon has a speckled fade where the wave meets the paper. A hand-drawn dark icon would be better.

## 2026-11-08: Phase 1

- Design note `docs/plans/2026-11-08-phase-1-shell.md`; Tehran chose option A, folders opened in place.
- Project model in ProseCore: `ProjectTree`, `ProjectStore`, `CompileStatus`, `OutlineNavigation.ancestry`. Fixed an inherited bug in `ProjectSources.list` (files after a symbolic link were skipped).
- Sidebar (`⌘0`) with the folder tree, the open file's headings, file search, create, rename, trash, set main document, Quick Look for other files, FSEvents refresh. Open Folder (`⌥⌘O`); recent folders on the library home; folders restore after relaunch.
- Title row: file and folder name, breadcrumb, status dot, Code/Writing/Focus control (Code only), export, preview toggle (`⇧⌘P`); `⌥⌘P` reads the preview. Darker red and green text colours.
- Preview pages as rounded cards with a shadow and a side gutter; current page in the pane header (Tinymist's page gap is too small for per-card numbers).
- Test fixes: project tests joined the serialized UI suite (a separate suite made preview tests flaky); the preview click test now lets late jumps settle.
- Results: `scripts/build.sh release` passed. Last three full runs of `PROSE_DISTRIBUTION=preview scripts/test.sh`: two clean (206 core, 149 app tests, coverage 87.50 percent), one with a single preview reload timeout that passes alone.

Open items:

- One preview test still times out occasionally under load (about one run in three); not reproduced alone.
- Writing and Focus modes are placeholders until Phases 3 and 4.
- `.bib` files open in Quick Look; editing them needs a non-Typst buffer.

## 2026-11-08: Phase 2 engine spike

- Spike note and results: `docs/plans/2026-11-08-phase-2-engine-spike.md`. New crate `Engine/RenderBridge` (`prose-render`) with the `render-spike` command and a fixture test; not linked into the app.
- Every pass mark met. SICP: all 3,671 blocks render, median 0.9 ms, p95 4.9 ms, no failures, 100 percent of typed glyphs map back to source. War and Peace sample: median 0.6 ms. Thesis fixture: heading and equation numbers and reference texts match the full document.
- Three fixes found on the way: references to outside labels use stubs filled with text read from the full document's links; an invisible element before each block keeps a leading label off the stubs; small vertical margins stop descenders clipping.
- Fixed a Phase 0 slip: `scripts/make-app-icon.py` was not classified in the CI path table.

Next: Phase 2 proper (C ABI, cache, background rendering), using the spike's findings.

## 2026-11-08: Phase 2

- Design note `docs/plans/2026-11-08-phase-2-render-bridge.md`. Built by Opus subagents in steps; the main session reviewed each diff, reran the checks and committed.
- Step A: `Engine/RenderBridge` became the engine library with a C ABI (`prose_render_api`), cache, ink bounds, baselines and UTF-16 glyph offsets. The agent found and fixed a cache bug that gave identical blocks the wrong offsets.
- Step B: the Mac app links one combined Rust library (render plus syntax). Executable 10.8 MB to 52.7 MB.
- Lint: `scripts/lint.sh` passes again (rename import order, Phase 1 violations, a stray editor index cache).
- Step C: `BlockRenderer` actor in ProseCore with 12 tests (98.8 percent covered); memo-cache eviction keeps long sessions bounded (heap near 415 MB instead of past 4 GB).
- Decided: Prose is Mac only; the iPad code is unmaintained.
- Results: full suite 220 core and 149 app tests pass, coverage 87.56 percent; lint clean; SICP renders every block, median 0.48 ms.

Open items: peak memory about 1 GB on a 450-page book; counters for a file with no prior headings; files changed by other apps; duplicated embedded fonts (18.5 MB). Optional cleanup: delete the iPad code.

- Removed the inherited iPad code (d3f4364). Full suite and lint pass.

## 2026-11-08: Phase 3, steps A to E

- Design note `docs/plans/2026-11-08-phase-3-writing-mode.md`; Tehran accepted it and its three recommendations (the paragraph-style fallback is inside the rule, a hidden default during the phase, block-granularity drags as a fallback).
- Step A, spike (branch `phase-3-spike`, `e7162f5`, not merged): a layout fragment subclass can take a rendered block's height (`layoutFragmentFrame`). `invalidateLayout(for:)` alone does not swap fragments. SVG drawing on the main thread was too slow (38 ms a viewport), and SICP's 10,500-line index broke the paragraph gate. Tehran approved four changes: bitmaps, a 400-line cap, fragments that read their state, and split drag tests.
- Step B (`4237b83`): engine ABI 2, blocks cover the whole file (context, include, raw, list, comment kinds; loose lists stay one block), text colour option, premultiplied RGBA bitmaps, transparent pages, hanging punctuation inside the drawn area.
- Step C (`fb36bf8`): `WritingLayout` model in ProseCore, 99 percent covered.
- Step D (`e8d85b7`): Writing mode draws in the editor behind `defaults write com.tehrandavis.prose WritingModeEnabled -bool YES`; pills, stale bar, dark appearance, engine per project.
- Step E (`d90dcea`): click, double- and triple-click, shift-click and drag map through glyph boxes; native selection is hidden in rendered blocks and drawn from glyph boxes. Acceptance tests 1 to 5 pass.
- Results after step E: 239 core and 161 app tests pass, coverage 88.36 percent; lint and the release build pass.
- Two subagents stopped while waiting on their own test runs; the main session ran their checks.

Open items:

- Steps F (keyboard and undo), G (input methods and VoiceOver) and H (book benchmark, gate, documents) remain; acceptance tests 6 to 14 are not written.
- Inactive-window selection colour in rendered blocks; table rules stay black in dark appearance; an external file change does not trigger a refresh.
- Tehran asked about the inherited Chinese interface; the proposal to remove `zh-Hans` and the 17 MB NotoSansSC font after Phase 3 awaits his answer.

## 2026-11-09: Phase 3, steps F to H; Phase 3 done

- Built by Opus subagents one step at a time; the main session reviewed each diff, reran lint, the release build and the full suite, and committed.
- Step F (`d115a61`): keys from a caret already land where Code mode puts them (12,996 moves compared, 0 differences). Keyboard extensions of pointer selections step through drawn lines and open no block; page up and down move by drawn content; the rendered-block highlight follows NSTextView's selection colour rule, found by disassembling `-[NSTextView _selectionBackgroundColor]`. Acceptance tests 6 to 8 pass.
- Step G (`9b0a81c`): accessibility frames, ranges for points and the candidate window map through glyph boxes; the value, strings and lines stay the source. NSTextView answers AXBoundsForRange and AXRangeForPosition through private selectors, which the editor overrides; test 12 goes through the public entry point, so a rename would fail it. Decision change: a composition that edits a rendered block opens it. Acceptance tests 9 to 13 pass.
- Step H (`8a582e7`): the book benchmark runs in Writing mode; acceptance test 14 passes on SICP and War and Peace. Three full runs of the suite and the benchmark passed in a row (coverage 88.48, 88.54, 88.51 percent).
- Step H, enabling: the hidden default `WritingModeEnabled` is removed; the Writing segment works for everyone, and documents still open in Code mode. Spec Sections 3.2, 5.3, 5.4 and 8, `docs/architecture.md`, `docs/visual-editing.md`, the writing guide and the design note's Phase 3 outcome are updated.
- Costs: the app peaks near 1 GB on a book in Writing mode (block engine 650 to 710 MiB, against about 250 MB in Code mode); typing main-thread CPU 15 to 25 percent higher; scroll and draw p95 up to 43.5 ms in War and Peace (no gate); entering Writing mode on a book takes up to 1.8 s.

Open items (full list in the design note's Phase 3 outcome):

- Engine memory; scroll draw time; role lookups per fragment read grow with paragraphs built.
- Table rules stay black in dark appearance; an external file change triggers no refresh; undo does not bring the caret back to the changed block.
- Real key, mouse, input method and VoiceOver events in the running app are untested; live-resize centering is untested.
- One preview test (`previewClicksOnFunctionTextJumpToTheCallArgument`) timed out once under load and passed on rerun.
