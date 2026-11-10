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
- Step H, enabling (`bd893bf`): the hidden default `WritingModeEnabled` is removed; the Writing segment works for everyone, and documents still open in Code mode. Spec Sections 3.2, 5.3, 5.4 and 8, `docs/architecture.md`, `docs/visual-editing.md`, the writing guide and the design note's Phase 3 outcome are updated.
- Costs: the app peaks near 1 GB on a book in Writing mode (block engine 650 to 710 MiB, against about 250 MB in Code mode); typing main-thread CPU 15 to 25 percent higher; scroll and draw p95 up to 43.5 ms in War and Peace (no gate); entering Writing mode on a book takes up to 1.8 s.

Open items (full list in the design note's Phase 3 outcome):

- Engine memory; scroll draw time; role lookups per fragment read grow with paragraphs built.
- Table rules stay black in dark appearance; an external file change triggers no refresh; undo does not bring the caret back to the changed block.
- Real key, mouse, input method and VoiceOver events in the running app are untested; live-resize centering is untested.
- One preview test (`previewClicksOnFunctionTextJumpToTheCallArgument`) timed out once under load and passed on rerun.

## 2026-11-09: Phase 4 (Focus mode, floating toolbar, spell check); English only

- Tehran approved pushing `prose` and dropping the Simplified Chinese interface, then gave permission to build overnight. The design note (`docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`) was accepted by delegation; choices are marked **Choice** in it.
- Built by Opus subagents one step at a time; the main session reviewed each diff, reran lint, the release build, the full suite and the book benchmark, committed and pushed.
- Step A (`50fda8f`): English only. zh-Hans resources, the language picker, Chinese keywords and the 17 MB NotoSansSC font are gone; both engines draw CJK text with the system fonts (tests guard it).
- Step B (`d166592`): Focus view state (panes saved and restored, title row and status bar on hover, Esc as last owner, column 467 pt, scale 1.4625).
- Step C (`4cb5b17`): dimming at 45 percent per block in the fragment; typewriter scrolling at 40 percent.
- Step D (`003508b`): Focus benchmark run with a typewriter gate (p95 < 33 ms); pixel-exact image drawing, per-fragment role cache and dimmed image copies cut Writing-mode scroll and draw p95 in War and Peace from about 44 ms to 7 to 17 ms.
- Step E (`bf30fd6`): floating toolbar (five `⌘J` actions, AppKit buttons that keep the editor first responder).
- Steps F and G (`9dc6d4d`, `99a4a5a`): spell check: syntax-aware ranges, NSSpellChecker, native `.spellingState` underline in source, matching dotted underline in rendered blocks, context menu, Check Document Now (`⌘;`), AXMisspelled.
- Step H: docs updated; three gate runs in a row passed (269 core and 190 app tests, coverage 89.38 to 89.42 percent, all benchmark gates in all three modes).

Open items (full list in the design note's Phase 4 outcome):

- Benchmark numbers vary two to three times with machine load (`mediaanalysisd` overnight); a step E run failed the typewriter gate under load and passed on a quiet machine.
- A changed `.bib` on disk is not passed to the engines; settle in the proposed Citations phase.
- Recommended next: a Citations phase (picker over project `.bib` files through Hayagriva in the Rust bridge, Better BibTeX auto-export guidance, then a Zotero local API spike) before Phase 5. Not started; awaits Tehran.

## 2026-11-09 (afternoon): Phase 5, Citations

- Tehran accepted Citations as Phase 5 (polish moves to Phase 6), said he uses Better BibTeX with an auto-exported `.bib` and wants the link per project, and allowed a read-only spike against his Zotero library.
- Step A (`19bf763`): `.bib` changes on disk reach both engines (ABI 3 `files_changed`, refresh after a 300 ms pause). Tinymist already followed the file on its own. Defect found and fixed: citations never rendered in Writing mode (`??`); a citing block now carries a hidden copy of the document's citations and bibliography.
- Step B (`71d1256`): bibliography entry index through Hayagriva (ABI 4, JSON), `BibliographyIndex` search.
- Step C (`487d305`): "Cite a Source" (`⌘J R S`) picker; `⌥Return` adds a page; offer to add a `#bibliography` call.
- Step D (`0e0adfa`): Zotero spike on the real library: Better BibTeX search and export work, keys agree, no way to list auto-exports or add to a collection, raw control characters in JSON.
- Step E (`cb922de`): Zotero tab, per-project link in `recent.json`, new entries in `references-prose.bib` with "Show in Zotero", deduplication after the next auto-export.
- Step F: opt-in real-library test (`PROSE_REAL_ZOTERO=1`) passed; docs updated; three gate runs passed after two test-race fixes.
- Also: test windows open in the bottom-right corner of the main screen (`95a313f`); `PROSE_TEST_SCREEN` picks another, but pixel tests assume 2x.

Open items (full list in the note's Phase 5 outcome): the `style: "ieee"` default of the bibliography command; citations with the bibliography call in another folder show `??` in Writing mode; a sandboxed run against Zotero; `#bibliography` edits only in the open buffer.

## 2026-11-09 (evening): fixes after Phase 5

- Dark appearance in Writing and Focus modes: the engine renders with the document's own colours and then remaps every paint except images in OKLab (black ink to `#E8E4DE`, white fills to the page `#262626`, hues kept). C ABI version 5 replaces the default text colour with a dark flag. A document that sets its own dark ink (the welcome guide) is now readable, and table rules are light. Open: a mid grey such as the guide's muted text reaches only 3.4:1.
- The home window's close button now quits through the normal termination path; `⌘W` on the home window quits too. `⌘Q` already worked.
- Results: lint, release build, 291 core and 209 app tests (coverage 89.72 percent).

## 2026-11-09 (night): Quiet Writing mode, design note

- Tehran approved making the code parts of Typst less visible in Writing and Focus modes, as Overleaf's visual editor does, and asked for a new session to start it.
- Wrote the design note `docs/plans/2026-11-09-quiet-writing-mode.md` (draft, not accepted): setup lines and comments fold into one row or a margin mark; the open block draws in the document's font with faint markers; typing in the rendered paragraph gets a spike only, with pass marks and end conditions.
- No code yet. `td-e987b5` tracks the phase.

Open: nine questions at the end of the note (phase number, arrow keys over a fold, no-ink blocks and `#include`, equations, the faint colour, and the four questions left from Phase 5).
