# Phase 2: the render bridge

Date: 2026-11-08
Status: done 2026-11-08. See "Outcome" at the end.
Spec: `docs/prose-spec.md`, Section 5.2. Builds on `docs/plans/2026-11-08-phase-2-engine-spike.md`.

## Goal

At the end of Phase 2, Swift can ask for any block of the open document and get back a typeset fragment: SVG, its size, its first baseline, and a rectangle for each glyph with the source offset it came from. Rendering runs off the main thread, results are cached within a memory budget, and failures come back as messages, never crashes. Nothing in the editor draws fragments yet; that is Phase 3.

## How the work is split

The main session writes this note, briefs each step, reviews every diff, reruns the checks and commits. Opus subagents write the code. Each step ends with its checks passing and its own commit.

| Step | Builds | Checks it must pass |
|-|-|-|
| A. Engine library | `Engine/RenderBridge`: engine state, UTF-16 block list, render with cache, ink bounds and baseline, C ABI, Rust tests | `cargo test --release`; `render-spike` on SICP still renders every block with 0 failures |
| B. Linking | One combined Rust static library for the Mac app (render bridge plus the syntax bridge), its build script, `Package.swift`, licences, CI path table | `scripts/build.sh release`; `scripts/test-package-graphs.py`; `scripts/test-ci-policy.py`; `nm` shows both function tables once |
| C. Swift wrapper | `ProseCore/BlockRenderer.swift` (an actor), tests in `ProseCoreTests` | `PROSE_DISTRIBUTION=preview scripts/test.sh`, coverage at least 80 percent |
| D. Documents | Spec Section 5.2, `docs/architecture.md`, `CLAUDE.md` phase table, work log | Read-through |

## Decisions

### 1. One Rust library in the Mac app

Two Rust static libraries in one binary each carry the Rust standard library and clash at link time. The iPad engine already solves this: `Engine/TinymistBridge` depends on `Engine/SyntaxBridge` as an `rlib` and re-exports its function table, so the app links one library. The Mac app does the same: `Engine/RenderBridge` becomes a `staticlib` that depends on `prose-syntax` and re-exports `lb_syntax_api`. `scripts/build-render.sh` builds it into `Engine/RenderBridge/target/ProseEngine.xcframework`, and `Package.swift`'s binary target points there instead of at the syntax bridge's own framework. `scripts/build-syntax.sh` stays for the iPad and for `cargo test` of the syntax crate. Both crates pin typst-syntax to the same fork tag, so Cargo builds one copy.

### 2. The C ABI is one function table, like the syntax bridge

`prose_render_api()` returns a `PRRenderAPI` table with an ABI version and struct sizes, following `ProseSyntax.h`. All offsets are UTF-16 code units, as `NSString` uses. The calls:

| Call | Does |
|-|-|
| `engine_create(root, main, package_dirs, font_dirs)` | Builds fonts and the file loader. Returns an engine or NULL with an error string |
| `engine_free(engine)` | |
| `set_text(engine, path, utf8, length)` | Replaces a file's text in memory (the editor buffer). Cheap; marks the document dirty |
| `refresh(engine)` | Full compile of the main file with the counter probe. Updates counters, reference texts and diagnostics count. Slow (0.3 to 2 s on a book); the caller runs it in the background |
| `blocks(engine, path, count)` | The file's blocks: UTF-16 range and kind. Release with `blocks_free` |
| `render(engine, path, utf16_start, utf16_end, width_pt)` | Renders one block with the latest refreshed context. Returns a result: SVG bytes, width, height, first baseline, ink bounds, glyph boxes, or an error message. Cached. Release with `result_free` |
| `cache_stats(engine)` | Entries, bytes, hits, misses, for tests and tuning |

The engine is internally locked, so calls from several threads are safe but serialized. Swift calls it from one actor.

### 3. Context comes from the last refresh

Following the spike's finding 4: counters and reference texts come from the most recent `refresh`. Typing inside a paragraph changes neither, so `render` does not wait for a full compile. A block whose context lines changed is rendered with the new lines immediately, because context lines are read from the current text at render time.

### 4. Cache

Keyed by a hash of the complete block document text plus the width. The block document already contains the context lines, counter state and reference stubs, so any change that matters changes the key. An LRU with a byte budget, 64 MB by default, settable at creation. A hit returns the stored result without compiling.

### 5. Geometry

The result reports the block's ink bounds from its frames, not just the page size, and the first line's baseline (spike finding 3). Glyph boxes are in points relative to the block's top-left, with the UTF-16 offset in the original file, or -1 for generated text (numbers, reference text).

### 6. Failures

A Typst error returns a result with the first diagnostic's message and no SVG. A Rust panic is caught at every C entry point and returns an error result. Nothing aborts the app.

### 7. Packages and fonts

Package directories: the app's bundled `Packages` folder and the user's Typst package cache, read only; no downloads in Phase 2. Fonts: Typst's embedded fonts, system fonts and the app's bundled fonts directory. Engine creation scans fonts once (about 180 ms).

### 8. Mac only

Prose is a Mac app; Tehran does not intend to build for iPad (2026-11-08). The render bridge is linked into the Mac app only, and Phase 2 does not keep the inherited iPad project (`iPad/`, `Sources/Package.swift`, `Engine/TinymistBridge`) building. Removing that code is a separate cleanup.

## Risks

- **App size.** Typst linked into the app adds to the executable, on top of the Tinymist helper. Step B records the size before and after.
- **Build time.** A clean build of the render bridge takes about 2 minutes on top of Tinymist. The build script reuses the output when inputs have not changed, as `build-syntax.sh` does.
- **Two Typst copies.** Tinymist (a separate process) and the app now both run Typst 0.15.1 from the same tag, so preview and Writing mode agree on layout. A Tinymist upgrade must upgrade the render bridge in the same commit.

## Outcome

Built in four commits by Opus subagents, each reviewed and re-tested by the main session before it was committed: step A `b515439`, step B `adb3b7a`, a lint cleanup `a2d9f94`, step C `066be54`.

| Measure (SICP, 448 pages, on a loaded Mac) | Result |
|-|-|
| Blocks rendered | 3,671 of 3,671, no failures |
| First render, median and 95th percentile | 0.48 ms and 2.7 ms |
| Cache hit, median | 0.003 ms |
| Refresh: cold, after an edit | 0.8 to 1.0 s, 0.17 s |
| Peak resident memory | about 1 GB |
| Heap over 20 edits and three passes | flat near 415 MB (it grew past 4 GB before eviction) |
| App executable | 10.8 MB to 52.7 MB |

Differences from this note:

- **Memory target.** The working set of one full compile of SICP is about 775 MB, and stock `typst compile` peaks at 907 MB on the same book, so the 600 MB target was not reachable without changing Typst. The engine instead keeps memory bounded: it evicts Typst's memo caches after each refresh and after every 128 compiled renders. The trade-off: a refresh after a long scroll with no edits starts cold (about 0.8 s, in the background).
- **Cache correctness.** Blocks with identical text share a cache entry, so glyph offsets are stored relative to the block and moved to the block's place on each render. Each entry also records the edit version of every file its compile read, so an edited template or import never serves a stale block.
- **Counters while typing.** Counter positions from the last refresh are mapped onto the current text by its unchanged start and end, so a heading keeps its number while text above it is edited.
- **Swift API.** `BlockRenderer`'s init is `async` so the font scan runs off the main thread, and the default package directories include Tinymist's package cache, so blocks see the packages the preview downloaded.
- **Lint.** `scripts/lint.sh` had been failing since the Phase 0 rename (import order) and Phase 1 (five violations), and an editor index cache in `Sources/.build` added hundreds of false reports. It passes again.

Known gaps carried into Phase 3:

- A file whose last good compile had no headings or equations gets no counter updates until the next successful refresh.
- Files changed on disk by another app are not seen until the engine is recreated; `setText` is the only way in.
- About 18.5 MB of the executable is Typst's embedded fonts, which the Tinymist helper also carries.
