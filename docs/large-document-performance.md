# Real-book editor performance

Measured on 2026-10-09, Apple M4 Pro, macOS 27.0, the TextKit 2 editor with
attribute-only styles ([editor styles](visual-editing.md#the-editor-now)),
Tinymist 0.15.8 / Typst 0.15.1. These are instrumented debug test runs, not a
release-mode FPS claim. Both fixture sources, licenses and generators are in
[Examples/Books](../Examples/Books/README.md).

## Workload and results

The 3.3 MB War and Peace fixture preserves the downloaded novel and adds 39
small, distributed Python/math/Unicode blocks. SICP is the complete original
Scheme second edition: 1.45 MB of manuscript, 1,098 Scheme blocks, 1,356 math
expressions and 84 SVG figures. It imports its own local typography module.
Neither book is repeated to manufacture a larger buffer.

| Book | Source bytes | Open (s) | Typing median / p95 / max (ms) | Navigate + draw median / max (ms) | Scroll + draw p95 (ms) |
|---|---:|---:|---:|---:|---:|
| war-and-peace | 3,302,718 | 0.57 | 5.26 / 5.77 / 6.78 | 6.52 / 10.45 | 2.68 |
| sicp | 1,446,633 | 0.39 | 3.50 / 4.01 / 4.40 | 10.73 / 15.14 | 2.69 |

Both books land all six jumps in the viewport with zero hit-test error, and a
line returns to the same place in the viewport after scrolling three screens
away and back. TextKit builds about 1,250 of War and Peace's 67,963
paragraphs and 970 of SICP's 20,512 over the whole run; the benchmark fails
above 5,000, because every edit walks the elements built after it. On CI's
macOS 15 runners the run with the removed visual layer typed at 11.8 / 38.4 /
103.5 ms in War and Peace and 10.6 / 26.2 / 67.1 ms in SICP (median / p95 /
max); see
[editor styles](visual-editing.md#large-documents-measured). The previous TextKit 1 editor (2026-10-01) opened War and Peace
in 4.09 s and SICP in 3.32 s, typed at 9.29 / 52.23 and 6.70 / 10.88 ms
(median / max), navigated in 4.20 and 6.07 ms median, and scrolled at 5.04 and
3.89 ms p95.

SICP exported to **448 pages** in 0.21 seconds after engine startup.
The test/editor process ended at 216.9 MiB for War and Peace and
210.8 MiB for SICP (290.7 and 287.8 with TextKit 1). These are process physical-footprint snapshots,
not peak memory and not total application memory: Tinymist and WebKit are separate
processes. Each current report comes from its own fresh test process.

The earlier War and Peace run had a 619.3 ms median / 628.1 ms maximum synchronous
typing path. The current run measures 9.29 / 52.23 ms. Opening the
buffer increased from 1.37 to 4.09 seconds because contiguous layout was
restored for reliable pointer geometry. The earlier run failed distant pointer
round-trip checks; current checks pass. Its scrolling measurement only included
layout, so it is not directly comparable to the new draw measurement.

Raw reports: [War and Peace](benchmarks/war-and-peace.json) and
[SICP](benchmarks/sicp.json) on TextKit 2; [War and Peace](benchmarks/war-and-peace-textkit1.json)
and [SICP](benchmarks/sicp-textkit1.json) on TextKit 1; and the
[earliest War and Peace run](benchmarks/war-and-peace-before.json).
Absolute timings vary with hardware, instrumentation, caches and background load.

## What changed

- Native text-storage edits carry a replacement range into the document metrics.
  Grapheme counts and UTF-16 line positions rescan neighboring lines and shift
  later offsets. Emoji, combining marks and CRLF boundaries are checked against
  full recomputation over 240 deterministic edit transactions.
- Swift strings backed by AppKit UTF-16 storage are materialized once for full
  grapheme scans. Frequent styling and UI reconciliation compare revisions,
  avoiding repeated multi-megabyte String equality on the UI thread.
- Semantic-token decoding runs off the main actor. Embedded-language analysis is
  cached and bounded; the offline Scheme grammar covers the real book's code.
  Nested highlight spans keep their specificity when their ranges coincide.
- TextKit 2 lays out only the viewport, so opening no longer lays out the
  whole book (TextKit 1 needed contiguous layout for reliable pointer
  geometry). Its estimated geometry is handled explicitly: jumps reveal their
  target precisely, the restored caret is revealed after the first layout pass
  (before it, TextKit lays out every paragraph above it and each keystroke pays
  for them), and the first visual plan is computed before layout, so it never
  invalidates a laid-out book.

The native text storage remains authoritative; we did not introduce a second
rope buffer or a terminal editor with another selection/undo model. These fixes
address measured costs. Line-index suffix shifts are still O(number of lines),
not a claim of constant-time edits or unlimited document size. Full-document
semantic snapshots, synchronous save boundaries and background analysis can
still consume time and memory; see [editor foundations](editor-foundations.md).

## Reproduce and interpret

```sh
scripts/test.sh
scripts/benchmark-books.sh
```

The second script reuses the instrumented test binary. It runs on each PR in CI
and uploads `build/benchmarks` plus a job summary. No fixture download is required.
It runs each book three times: in Code mode (`war-and-peace.json`, `sicp.json`);
with `PROSE_WRITING_MODE=1`, in Prose's Writing mode (`war-and-peace-writing.json`,
`sicp-writing.json`; see the "Step H benchmark" section of the
[Phase 3 note](plans/2026-11-08-phase-3-writing-mode.md)); and with
`PROSE_FOCUS_MODE=1`, in Focus mode (`war-and-peace-focus.json`,
`sicp-focus.json`; see [Writing and Focus modes](#writing-and-focus-modes)).
Every run is held to the same gates, and the Focus runs add the typewriter step gate.
Each scenario uses production Workspace, NSTextView and real Tinymist:

1. Open a complete source and wait for semantic highlighting; assert a known
   built-in inside a fenced code block has the embedded-language color. Settle
   the pending native layout and paint the initial viewport before interaction
   timing starts; report this separately as `initial_presentation_ms` and the
   total opening-to-ready time as `editor_ready_seconds`. Then wait for
   Tinymist's first compile and until its processes are idle
   (`engine_settle_seconds`). That one-time compile and preview of the whole
   book keeps several Tinymist threads busy. The app's main thread runs at
   foreground priority above them, but this command-line test process runs it
   at the same priority. On CI's three cores the compile then preempted
   whichever jump overlapped it: one SICP jump took 200 ms of wall time for
   about 40 ms of main-thread work.
2. Jump among six distant offsets, apply styles, force layout and draw the
   visible region into a bitmap. Require each target's glyph inside the visible
   rect, and map it back to a native insertion point with zero error, rather
   than only checking a selection integer.
3. Search later text and scroll through 60 frames with native visible-region
   layout and bitmap painting. Scrolling three screens down and back must show
   the first visible line at the same place in the viewport (TextKit 2 moves
   the clip origin when it replaces estimated heights, so positions are
   compared within the viewport).
4. Insert 80 mixed Latin/CJK/emoji characters through the native editor, include
   metric reads, then undo and verify the original source exactly.
5. For SICP, export through Tinymist and require more than 400 PDF pages.
6. Open the 448-page book in a 1920 × 1300 pt WebKit preview. Jump to pages
   1, 224, 448 and back to 1; require visible SVG glyphs and snapshots with
   actual painted text, with no canvas fallback surfaces. CI retains page
   snapshots alongside timing reports. Real-window acceptance also covers
   scrolling from the cover to page 448 and back to page 340.

The test uses a hidden native window and CPU bitmap rendering. It does not
measure physical display refresh, GPU compositing, human typing latency,
continuous wheel/trackpad events, or the full asynchronous autosave/preview cycle.
Typing samples time the synchronous editor/Workspace/metrics path. The first
input is included, with no warm-up discard or automatic retry. For 80 inputs,
CI requires wall-time p95 below 100 ms, every input below 250 ms wall time,
and every input below 100 ms of main-thread CPU work. Navigation still has a
200 ms maximum, including drawing; each jump also reports its main-thread
CPU time (`thread_cpu_ms`). Thread CPU time helps distinguish work in
the synchronous input path from time when a shared runner does not schedule
that thread; it is not a substitute for the wall-time latency gates.

The earlier 16-input sample made p95 equal to max. Main run 36952826611 failed
on one 102.47 ms input, while its median was 12.23 ms. That report did not
record per-input CPU time, so it cannot prove the outlier was scheduler noise.
Reports now retain every input's wall, thread CPU, insert and metrics timing.
The policy rejects sustained slow input and severe individual stalls while
allowing an isolated short scheduling delay. These are instrumented-debug CI
regression budgets, not a hardware-independent performance SLA.

All book scenarios run even when one fails, and the script returns failure if
any fails. Stale reports are cleared first; the summary and artifacts retain
available evidence from the failing run. Real-window acceptance complements
these tests; it does not replace them.

## Writing and Focus modes

Measured on 2026-11-09 (Phase 4 step D), Apple M4 Pro, macOS 27.2, the same
instrumented debug build, with other processes keeping the load average at 10
to 13. Full numbers and the profile are in "Step D outcome" of the
[Phase 4 note](plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md).

| Book | Mode | Typing median / p95 / max (ms) | Navigate + draw max (ms) | Scroll + draw p95 (ms) | Typewriter step median / p95 / max (ms) | Peak memory (MiB) |
|---|---|---:|---:|---:|---:|---:|
| war-and-peace | Code | 9.61 / 14.00 / 24.81 | 22.27 | 4.70 | | 230 |
| war-and-peace | Writing | 12.02 / 12.75 / 14.18 | 13.17 | 16.97 | | 999 |
| war-and-peace | Focus | 15.70 / 16.71 / 16.86 | 13.50 | 13.77 | 22.17 / 26.31 / 27.26 | 1,033 |
| sicp | Code | 6.01 / 6.95 / 7.59 | 37.33 | 5.34 | | 247 |
| sicp | Writing | 7.51 / 9.07 / 9.44 | 24.50 | 11.97 | | 1,004 |
| sicp | Focus | 11.86 / 12.82 / 14.20 | 29.15 | 14.29 | 18.93 / 22.27 / 23.33 | 1,083 |

**Focus run.** The run enters Writing mode as before, then Focus mode
(`setMode(.focus)`), and reports the entry window (126 and 106 ms; every block in
view had its render at the Focus width and scale after 342 and 244 ms), the
footprint added by Focus (9 to 10 MiB) and the engine's share in Focus (652 to
663 MiB). It fails unless it measured Focus: the mode is still Focus at the end,
the column is Focus's 467 pt, every rendered block in view is at scale 1.4625
for that width, paragraphs drew dimmed, and the caret line stayed on the
typewriter line after every typewriter step.

**Typewriter step.** In Focus, 60 steps in prose from the typing target, a
Down arrow (`moveDown:`) and a Return (`insertNewline:`) in turn, 50 ms apart,
are each timed from the key's action to the end of three things: the action
itself (the edit or selection change, and the typewriter scroll and layout
that run inside it), AppKit's layout and display pass (`displayIfNeeded()` on
the window, which also lays out SwiftUI views), and the drawing of every layer
the step marked for display. TextKit 2 draws each fragment in its own
layer-backed view, so a scroll only moves layers; what must draw is the
fragments the scroll brought into view, the paragraphs whose role or contrast
changed, and the editor's own background. The benchmark draws exactly those by
calling `displayIfNeeded()` on each layer of the editor's tree, as Core
Animation does before a frame, because the hidden test window's own display
pass does not draw fragment layers. Renders that arrive between steps are drawn
untimed the same way. The Returns are undone afterwards and the text must equal
the source. **Gate: p95 under 33 ms** (two 60 Hz frames); 16.7 ms is the
target. Down steps meet the target (median about 10 ms); Returns do not (about
20 to 25 ms), mostly in the edit path every mode shares and in SwiftUI layout
after the selection change. For comparison, a full-viewport redraw after a step
takes 4.7 to 5.5 ms p95.

**What made Writing mode's drawing cheaper.** Scroll and draw p95 in War and
Peace's Writing mode was 43.5 to 48 ms through Phase 4 step C, against 4 to 9 ms
in Code mode; SICP's about 21 ms. A profile found two costs. TextKit reads about
8,000 fragment frames per scrolled frame (most of them in the hit tests of
`visibleCharacterRange()`), and each read asked the layout model for the
paragraph's role: about 19 ms. Each fragment now keeps its role until the
model's `roleRevision` changes. And every image draw resampled, because
fragments sit at fractional positions and the image was stretched over its
padding pixel: about 1 ms per image. Images whose pixels match the device's now
draw at their exact pixel size on whole device pixels, about 10 times faster,
and their pixels arrive as the engine drew them. In Focus mode a dimmed block
draws a copy of its image with the opacity applied, because a global alpha
blend is about 17 times slower than a copy. Pixel format and colour space made
no measurable difference. Scroll and draw p95 is now 13 to 17 ms in War and
Peace and 7 to 12 ms in SICP. The scroll measurement still redraws the whole
viewport with `cacheDisplay`, so it remains an upper bound for a real frame.

