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
