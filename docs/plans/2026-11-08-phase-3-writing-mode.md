# Phase 3: Writing mode in the editor

Date: 2026-11-08
Status: accepted 2026-11-08. Step A (spike) next.
Spec: `docs/prose-spec.md`, Sections 5.3, 5.4 and 8. Builds on `docs/plans/2026-11-08-phase-2-render-bridge.md`.

## Goal

At the end of Phase 3, the Writing segment of the mode control works. The center column draws every block of the open file as a typeset fragment from `BlockRenderer`, except the block that holds the caret, which lays out as styled source exactly as in Code mode. Native selection, copy, undo, input methods and VoiceOver behave as they do in Code mode, and acceptance tests prove it. Writing mode becomes the default choice of the control only when those tests pass. If they cannot pass, Writing mode ships read-only (spec Section 8).

Focus mode, the floating toolbar and spell check stay in Phase 4.

## Terms

These words mean one thing each in this note and in the code.

| Term | Meaning |
|-|-|
| Block | One entry from `BlockRenderer.blocks(in:)`: a UTF-16 range of the file and its kind. A block can span several source lines, and so several TextKit paragraphs |
| Context line | A top-level `#set`, `#show`, `#let`, `#import` or `#include` line. Today the engine lists these separately and does not return them as blocks |
| Active block | The block that holds the caret, or every block the selection touches while text is marked |
| Rendered fragment | The `NSTextLayoutFragment` subclass that draws a block's SVG in place of its source lines |
| Source fragment | TextKit's default fragment, which draws the styled source |
| Pill | The collapsed grey label that stands for a context line (spec Section 5.4) |

## What the inherited code gives us

- `ManuscriptTextView` (`Sources/Prose/ManuscriptView.swift`, `ManuscriptTextSystem.swift`) builds its own TextKit 2 stack: one `NSTextContentStorage`, one `NSTextLayoutManager`, one container. No layout manager delegate is set yet, and no code subclasses `NSTextLayoutFragment`.
- `SourceStyler` writes fonts into the storage and semantic colours as rendering attributes. It already rebases replies across later edits, waits while text is marked, and keeps the top line in place when text above the viewport changes height. Writing mode keeps all of it: the active block is styled source.
- `TextKit2Geometry` answers caret, segment, hit-test and reveal questions without `layoutManager`. Every jump goes through it.
- `Workspace.editorMode` and `setMode(_:)` exist. `setMode` refuses everything except `.code` with the message "Writing and Focus modes arrive in a later version of Prose."
- `BlockRenderer` (an actor) gives blocks, renders with glyph boxes mapped to UTF-16 offsets, a cache, and `refresh()` for counters and reference texts. It is not created anywhere in the app yet.
- The serialized UI suite `WritingFlowTests` already holds pointer round-trip, composition, TextKit 1 fallback and book benchmark tests. Every Phase 3 UI test extends it.

## The central risk, and why the first step is a spike

A Typst block spans several TextKit paragraphs, because `NSTextContentStorage` makes one text element per source line. Typst reflows a paragraph, so the rendered lines do not correspond to source lines. A rendered fragment therefore cannot be one fragment per source line. The likely shape is: the fragment for the block's first paragraph draws the whole SVG at the block's rendered height, and the fragments for its other paragraphs take no height and draw nothing.

Nobody in this code base has done that yet, and the TextKit 2 documentation does not promise several things it needs:

1. That a fragment subclass can report a height that differs from its laid-out source lines, and that the viewport, scrolling and `usageBoundsForTextContainer` respect it.
2. That `invalidateLayout(for:)` makes TextKit ask the delegate again, so a block can switch between rendered and source fragments.
3. That NSTextView's caret, selection drawing, hit testing and keyboard navigation stay sane next to fragments of zero height.
4. That `NSImage` draws Typst's SVG (glyphs as `<symbol>` and `<use>` paths) correctly and fast enough at 1.3 times scale.
5. That none of this makes AppKit touch `layoutManager`.

LeftBlank's first visual layer failed on mechanics of exactly this kind. So step A answers these five questions with pass marks before any production code exists. If the spike fails, I come back to you with the results before going further.

## How the work is split

As in Phase 2, the main session writes this note, briefs each step to an Opus subagent with explicit checks, reviews the diff, reruns `scripts/build.sh release`, `PROSE_DISTRIBUTION=preview scripts/test.sh` and `bash scripts/lint.sh`, and commits. Each step ends usable, with the coverage gate at 80 percent or more.

| Step | Builds | Checks it must pass |
|-|-|-|
| A. Spike | A throwaway test target, or a test inside `WritingFlowTests`, with a fragment subclass over a three-line block, on a scratch branch. Answers the five questions above | The pass marks in "Spike pass marks" below. Results written into this note |
| B. Engine | `blocks` covers the whole file: context lines and `#include` lines become blocks of kind `context`, raw blocks become `raw`, lists `list`; empty or comment-only blocks are marked. `render` takes a default text colour for dark appearance. ABI version bump | `cargo test --release`; `render-spike` on SICP renders every block, 0 failures; `BlockRendererTests` pass |
| C. Layout model | `ProseCore/WritingLayout.swift`: a main-actor model with no AppKit drawing. It holds the block list, rebases it across edits, resolves the active block from the selection and marked text, decides each block's state (source, rendered, failed, pill), and schedules renders for the viewport | Unit tests in `ProseCoreTests`, including seeded random edits that must match a fresh block list. Coverage of the new file 90 percent or more |
| D. Drawing | `Sources/Prose/WritingFragments.swift`: the layout manager delegate, the rendered fragment, the pill, the stale bar. `setMode(.writing)` enabled behind a hidden default. Engine lifecycle per project. Scale 1.3, dark appearance, resize | UI tests: switching modes leaves the storage, selection and undo stack identical; rendered heights match the engine; TextKit 2 stays on; no attachments in the storage |
| E. Pointer and selection | Click mapping through glyph boxes, double-click, shift-click, drag across rendered blocks, selection drawing over rendered fragments, copy | Selection acceptance tests (below) |
| F. Keyboard and undo | Arrow, page and line navigation across rendered blocks; undo and redo of edits in blocks that are rendered by the time of the undo | Undo acceptance tests (below) |
| G. Input methods and VoiceOver | No swap while text is marked; accessibility value, frames for ranges, and the text under the VoiceOver cursor for rendered blocks | IME and VoiceOver acceptance tests (below) |
| H. Gate and documents | Book benchmark in Writing mode; the decision on the default; spec Sections 5.3, 5.4 and 8, `docs/architecture.md`, `docs/visual-editing.md`, `CLAUDE.md` phase table, work log | All acceptance tests pass three runs in a row, or the kill switch is applied and documented |

Steps B and C are independent of each other and can run in parallel after the spike. D needs both. E, F and G each need D and can run one after another in any order.

## Spike pass marks

| Question | Pass mark |
|-|-|
| Custom height | A rendered fragment over a three-line block reports the engine's height. `usageBoundsForTextContainer`, the view frame and the scroller agree with it within 1 pt |
| Swapping | Invalidating the block's range makes TextKit ask the delegate again, in both directions, within one layout pass. No stale fragment is drawn |
| Neighbours | In the source block after a rendered block, caret rectangles, `TextKit2Geometry.character(at:)` round trips and drag selection behave as in Code mode |
| SVG | `NSImage(data:)` draws SICP's ten largest blocks without missing glyphs, compared by eye against the preview, and draws one screen of blocks in under 8 ms |
| TextKit 1 | `switchedToTextKit1` stays false through all of the above |
| Book | Opening SICP in the spike's Writing mode builds under 5,000 paragraphs, as the existing gate requires |

If custom height fails, the spike tries the fallback in this order before reporting:

1. The content storage delegate returns, for each source line of a rendered block, a paragraph with the same characters and a paragraph style that sets the line height (the first line to the block height, the rest to zero). The storage itself is untouched. **Flag:** this keeps the characters identical but gives TextKit display attributes that differ from the storage. I read that as within the rule "no substituted display text", because no text is substituted, but you should decide.
2. If neither works, the kill switch applies from the start: Writing mode becomes a read-only rendered view outside the text view, and Phase 3 is replanned.

If SVG drawing fails or is slow, the engine adds a PNG output through `typst-render` at the screen's backing scale, cached by scale and appearance.

## Decisions

### 1. The text storage never changes for Writing mode

No step writes to the storage, the undo stack or the selection when the mode changes, a block swaps, or a render arrives. Fonts and colours stay `SourceStyler`'s. Rendered fragments and pills exist only in the layout layer. Tests compare the storage, the selection and `undoManager` state before and after every swap.

### 2. One fragment draws the block

The block's first TextKit paragraph gets the rendered fragment, which draws the SVG and takes the block's height. The block's other paragraphs get fragments with no height that draw nothing. If the spike finds a better shape, this decision changes with it.

### 3. The block list comes from the engine and is rebased locally

Block boundaries come from the Rust splitter (`Engine/RenderBridge/src/outline.rs`), so Writing mode and the renderer never disagree about where a block starts. The main thread keeps the last list and moves its ranges across each native edit, as `SourceStyler` moves style runs. After edits settle (about 150 ms), the model sends the text to the engine and replaces the list with the engine's. An edit that adds or removes a blank line only changes the active block until the new list arrives, because the active block is source anyway.

### 4. When things render

- On entering Writing mode, the blocks in and near the viewport render before the mode switch is drawn, so the switch does not flash source. A viewport is about 20 blocks, which took 10 to 50 ms in Phase 2's measurements. If that takes longer than 100 ms, the switch draws source and swaps blocks as results arrive, keeping the top line in place.
- While writing, only the active block's neighbours and the viewport render. Off-screen blocks render when TextKit lays them out.
- `refresh()` runs in the background on opening, and after edits pause for about 1.5 seconds, so heading numbers, equation numbers and references stay current. Typing never waits for it.
- Tinymist still compiles for the preview and the status dot. Writing mode adds a second compile of the same text. That doubles compile CPU for the session but keeps the two engines independent, as Phase 2 decided.

### 5. Caret entry and exit

- Moving the caret into a rendered block swaps it to source at once, in the same event, with the top line kept in place.
- Moving the caret out swaps the old block back to rendered only after its render result exists. Until then it stays source.
- While text is marked, nothing swaps and no render result is applied anywhere. Results that arrive then wait until the composition ends.
- A selection that spans blocks does not open them. The block that holds the selection's moving end is the active block.

### 6. Pointer

- A click in a rendered fragment maps the point to the nearest glyph box, puts the caret at that box's source offset, and opens the block. A point with no box nearby, or a box of generated text (a number, a reference), puts the caret at the block's start.
- A double-click selects the word at the mapped offset. A triple-click selects the block's source.
- Shift-click extends the selection to the mapped offset without opening the block.
- A drag that crosses a rendered block extends the selection through glyph boxes as it goes. If the spike shows that AppKit's own mouse tracking cannot be steered there, a drag selects whole blocks while it is over a rendered one. Both outcomes keep the selection a plain source range.
- Copy, cut and drag-and-drop write the source of the selected range. Nothing rendered ever reaches the pasteboard.

### 7. Selection drawing

A rendered fragment draws the system selection colour over the glyph boxes of selected characters, and over the whole fragment when the selection covers the block. NSTextView's own selection drawing is suppressed inside rendered fragments only.

### 8. Appearance and scale

- Blocks render at `column width ÷ 1.3` points and draw at 1.3 times, as decision 2 of the spec says. Phase 3 measures the result against the 65 to 72 character measure and reports it; changing the factor is your call.
- In dark appearance, the engine sets a default text colour (`#E8E4DE`) before the document's own rules, so a document that sets its own colours keeps them. The colour is part of the cache key.
- During a live resize, existing fragments keep their old width, centered. Blocks re-render at the new width when the resize ends.

### 9. What does not render

- Raw blocks draw as source with Highlight.js colours, as in Code mode (spec Section 5.4).
- Context lines draw as pills with their first 60 characters. A click opens the line as source. They never take blank space.
- A block that is only comments, or renders with no ink, draws as a muted pill with its first line.
- A block whose render fails stays source, with the existing error styling. A failed full compile draws a thin amber bar at the left edge of every rendered fragment and leaves them visible.

### 10. The engine's life

One `BlockRenderer` per open project, created the first time Writing mode is used (the font scan takes about 180 ms, off the main thread). It is created for the project root and main entry, and the open file's buffer goes in through `setText`, so an included chapter renders with the thesis's rules and numbers. Switching files in the same project keeps the engine. Switching projects or closing the window frees it. When `Workspace` detects that a project file changed on disk, it passes the new text to `setText`; this closes one of the gaps Phase 2 carried over.

### 11. Turning it on

Until step H, Writing mode is behind a hidden default, `defaults write com.tehrandavis.prose WritingModeEnabled -bool YES`, and the control keeps its "arrives later" message without it. UI tests set the default. When every acceptance test passes three full runs in a row, the default is removed and the Writing segment works for everyone. Code stays the mode a new document opens in; per-document mode memory is Phase 5.

## Acceptance tests

All in `Tests/ProseAppTests/WritingModeFlowTests.swift` as `extension WritingFlowTests`, on the real window, editor and engine. Each test also checks that the storage equals the source, that no attachment exists, and that TextKit 2 is still on.

**Selection**

1. Clicking at every glyph box's center in three rendered blocks (a paragraph with inline math, a numbered heading, a display equation) puts the caret at that glyph's source offset, and the block opens.
2. Shift-arrow and shift-click selections across three rendered blocks produce the expected source range and draw a highlight over each fragment.
3. A drag from a source block across two rendered blocks ends with a source range whose ends lie at the points the drag passed, or at block boundaries if decision 6's fallback applies.
4. Select All, then copy, puts exactly the source on the pasteboard. Copying a range inside a rendered block puts that source range on it.
5. Double-click selects the word under the pointer in a rendered paragraph; triple-click selects the block.

**Undo**

6. Type in block A, move to block B so A renders, then undo: the text and selection are restored, A opens as source, and the rendered fragments equal a fresh render of the restored text. Redo returns the edit.
7. Mode switches, swaps and render results add no undo records: the undo stack has the same count before and after ten swaps.
8. An undo that changes the block list (removing a blank line merges two blocks) leaves the list equal to the engine's list for the new text.

**Input methods**

9. With Pinyin marked text in the active block, moving render results in and asking for a swap changes no fragment. After `unmarkText`, the block swaps and the committed text is in the storage once.
10. Marked text in a block at the edge of the viewport survives a scroll that lays out new rendered blocks.
11. The candidate window rectangle (`firstRect(forCharacterRange:)`) lies on the caret's line.

**VoiceOver**

12. The editor's accessibility value equals the source. For a character in a rendered block, the accessibility frame for its range lies inside that glyph's box on screen, not on a zero-height line.
13. Reading by line through a rendered block reads its source lines in order.

**Performance**

14. The book benchmark (`LargeDocumentBenchmark`) runs in Writing mode on SICP and War and Peace and stays within the existing gates: typing p95 100 ms, any key 250 ms, any jump 200 ms, under 5,000 paragraphs built.

## The kill switch

Any of tests 1 to 13 that cannot pass, after the step that owns it has had a full attempt and one targeted retry, triggers the kill switch. Writing mode then ships as a read-only rendered view: the text view is not editable while in Writing mode, a click maps through glyph boxes and switches to Code mode with the caret at the mapped offset, and selection and copy still give source. Phase 4's toolbar still works, because its actions are `⌘J` commands. I will not apply the kill switch on my own: I report which test failed and why, and you decide.

## Risks

- **TextKit 2 behaviour is undocumented here.** That is what step A is for. The spike can end the plan early, and that is a result, not a failure.
- **Memory.** A book in Writing mode adds the engine's working set (about 415 MB of heap, peaks near 1 GB during a full compile) to Tinymist's. The engine exists only after Writing mode is first used. Step H records the app's peak on SICP.
- **Two compiles.** Writing mode and Tinymist both compile the document. Step H records CPU while typing in a book.
- **Jumps after swaps.** Every swap changes heights. All swaps go through the existing top-line anchor (`keepAtTop`), and the benchmark's line-drift check runs in Writing mode.
- **Counter gap.** A file whose last good compile had no headings or equations gets no counter updates until the next good refresh (carried from Phase 2). Phase 3 does not fix it; a heading added to such a file shows its number after the next refresh.

## Answers (2026-11-08)

Tehran accepted the note and all three recommendations:

1. The spike's fallback is inside the rule. The content storage delegate may return paragraphs with the same characters and a different paragraph style; the storage itself never changes.
2. Writing mode stays behind the hidden default `WritingModeEnabled` until step H.
3. If per-glyph dragging over rendered text is not reachable, a drag selects whole blocks in version one.
