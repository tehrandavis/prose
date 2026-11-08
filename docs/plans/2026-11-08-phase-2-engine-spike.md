# Phase 2 spike: can one block render quickly, in context?

Date: 2026-11-08
Status: done 2026-11-08. Every pass mark met; Phase 2 can proceed as specified.
Spec: `docs/prose-spec.md`, Section 5.2

## Question

Writing mode (spec Section 5) draws each top-level block of the source as a typeset fragment from the real Typst engine. Before building `Engine/RenderBridge` in full, measure whether that is feasible on the pinned Typst 0.15.1 (`Myriad-Dreamin/typst`, tag `tinymist/v0.15.1`, the same source Tinymist and the syntax bridge use).

## What the spike measures

| Question | Pass mark |
|-|-|
| Full compile time of SICP (1.4 MB) and War and Peace (3.2 MB), cold and after a one-paragraph edit | Recorded; no mark |
| Time to render one block with its document context, warm | Median under 50 ms, 95th percentile under 150 ms on SICP |
| Blocks that fail to render alone, and why | Recorded by cause |
| Heading and equation numbers in a rendered block match the full compile | All match on the thesis fixture |
| Glyphs in a rendered block whose span maps back into the block's source | Over 95 percent of text glyphs |

## Method

A Rust crate, `Engine/RenderBridge`, with a library and a `render-spike` command. It is not linked into the app yet.

- **World.** Project files from the document's folder, packages from `Resources/Packages` and the user's Typst package cache (no downloads), fonts embedded in `typst-assets` plus system fonts. One extra in-memory file holds the block document.
- **Blocks.** The syntax tree's top-level markup, split at paragraph breaks. `#set`, `#show`, `#let` and `#import` lines are context, not blocks.
- **Context.** A block document is the main file's top-level context lines, the block's own file's context lines before it, a page rule (`width` fixed, `height: auto`, no margins, no header or footer), counter updates, then the block.
- **Counters.** The full compile carries a small probe at the end of the main file: a `#context` that queries every heading and block equation and stores its counter value in a `metadata` element. Rust zips those values with the same elements from the introspector, which carry source spans, and so knows the counter state just before any block.
- **Glyphs.** Walk the block's frames, accumulate glyph positions, and map each glyph's span back to the original file offset.

## Out of scope

The C ABI, the cache, background rendering, and anything in Swift. These come in Phase 2 proper if the spike passes.

## Results

Measured on this Mac (Apple silicon, release build, Rust 1.92.0), measure 450 pt, with `Engine/RenderBridge/target/release/render-spike`.

| Measure | SICP (1.4 MB, 448 pages) | War and Peace (3.2 MB, 906 pages) | Thesis fixture |
|-|-|-|-|
| Engine creation (fonts) | 180 ms | 180 ms | 1,010 ms (first run, cold font scan) |
| Full compile, cold | 1,880 to 1,990 ms | 2,210 ms | 13 ms |
| Full compile, first edit after cold | 1,890 ms | 1,790 ms | 1 ms |
| Full compile, later edits | 280 to 290 ms | 210 ms | 1 ms |
| Blocks rendered | 3,671 of 3,671 | 1,000 sampled of 12,285 | 17 of 17 |
| Block render, median | 0.9 ms | 0.6 ms | 0.4 ms |
| Block render, 95th percentile | 4.9 ms | 1.9 ms | 0.6 ms |
| Block render, slowest | 322 ms (a 43 KB table) | 4.4 ms | 0.6 ms |
| Blocks that failed | 0 | 0 | 0 |
| Typed glyphs mapped into their block | 100 percent of 1,221,839 | 100 percent of 255,324 | 100 percent |
| SVG per block, average | 55 KB | 45 KB | 12 KB |

The thesis fixture's headings render as 1, 2, 2.1, 2.2, 2.2.1, 2.2.2 and 3 and its equations as (1) to (3), the same as the full document. Its references render as "Section 2", "Section 2.2.2", "Equation 1" and "Equation 2". `cargo test` in `Engine/RenderBridge` checks all of this.

## Findings for Phase 2

1. **References need the full document.** A block rendered alone cannot resolve `@label` or `link(<label>)` to a label outside it; that was every failure in the first runs. The fix: read each reference's displayed text from the full compile, where a reference is a link to its target's location and the text inside the link's rectangle is what it shows; then give the block document a `metadata` stub for each outside label and a `show ref.where(target: ...)` rule with that text. Glyph spans are no help here: reference text has detached spans.
2. **A label at the start of a block attaches to the element before it.** In the block document that was the last stub, which renamed the stub's label. An invisible `#metadata(none)` before the block fixes it.
3. **Blocks need vertical margins.** With `height: auto` and no margin, the page ends at the last line's text box and clips descenders. A margin of 0.25 em above and 0.4 em below fixes it. Phase 2 should report the block's real ink bounds and first baseline from the frame rather than rely on the margin.
4. **The full compile is the slow part, and it is needed only for structure.** Counters and reference texts come from it. Typing inside a paragraph changes neither, so Phase 2 should keep the last full compile's counters and references, re-render only the edited block (about 1 ms), and refresh the full compile in the background (about 0.3 s on a book once warm; the first edit after opening costs about 2 s).
5. **Render what is visible, and bound the cache.** All of SICP as SVG is about 200 MB. Phase 2 should render blocks near the viewport and keep a bounded cache, as the spec's cache key already allows.
6. **Large tables and figures are slow but rare.** One block in SICP took 322 ms. Background rendering keeps the editor responsive; such blocks stay as source until their fragment arrives, as the spec says for failures.

## Not yet tested

- Citations with a bibliography (no fixture has one). The reference-text method should cover them, because a citation is also a link.
- A block in an included file whose main-file context lines use relative paths from a different folder. The thesis fixture's main context has no imports.
- Show rules and counter updates that are not top-level lines. Counter values come from the full compile, so numbering stays right; a show rule inside content is not copied into the block document.
- The C ABI and the cost of moving SVG and glyph boxes into Swift.
