# Phase 3: Writing mode in the editor

Date: 2026-11-08
Status: accepted 2026-11-08. Step A (spike) done; see "Spike results" and "Changes after the spike" at the end.
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
| B. Engine | `blocks` covers the whole file: context lines and `#include` lines become blocks of kind `context`, raw blocks become `raw`, lists `list`; empty or comment-only blocks are marked. `render` takes a default text colour for dark appearance and can return a PNG bitmap through `typst-render` at a given scale. The page is transparent, and the bounds include hanging punctuation. ABI version bump | `cargo test --release`; `render-spike` on SICP renders every block, 0 failures; `BlockRendererTests` pass |
| C. Layout model | `ProseCore/WritingLayout.swift`: a main-actor model with no AppKit drawing. It holds the block list, rebases it across edits, resolves the active block from the selection and marked text, decides each block's state (source, rendered, failed, pill), and schedules renders for the viewport | Unit tests in `ProseCoreTests`, including seeded random edits that must match a fresh block list. Coverage of the new file 90 percent or more |
| D. Drawing | `Sources/Prose/WritingFragments.swift`: the layout manager delegate, the rendered fragment, the pill, the stale bar. `setMode(.writing)` enabled behind a hidden default. Engine lifecycle per project. Scale 1.3, dark appearance, resize | UI tests: switching modes leaves the storage, selection and undo stack identical; rendered heights match the engine; TextKit 2 stays on; no attachments in the storage |
| E. Pointer and selection | Click mapping through glyph boxes, double-click, shift-click, drag across rendered blocks, selection drawing over rendered fragments, copy | Selection acceptance tests (below) |
| F. Keyboard and undo | Arrow, page and line navigation across rendered blocks; undo and redo of edits in blocks that are rendered by the time of the undo | Undo acceptance tests (below) |
| G. Input methods and VoiceOver | No swap while text is marked; accessibility value, frames for ranges, and the text under the VoiceOver cursor for rendered blocks | IME and VoiceOver acceptance tests (below) |
| H. Gate and documents | Book benchmark in Writing mode; the decision on the default; spec Sections 5.3, 5.4 and 8, `docs/architecture.md`, `docs/visual-editing.md`, `CLAUDE.md` phase table, work log | All acceptance tests pass three runs in a row, or the kill switch is applied and documented |

Steps B and C were planned to run in parallel. They run one after the other instead (B, then C): two agents building in one checkout would break each other's builds, and a second checkout means copying about 9 GB of Rust build output. C also uses B's new block kinds. D needs both. E, F and G each need D and can run one after another in any order.

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
3. A drag that starts in a rendered block is handled by Prose and is driven directly by the test: it ends with a source range whose ends lie at the points the drag passed, or at block boundaries if decision 6's fallback applies. A drag that starts in a source block stays with AppKit and is tested through the selection navigation calls AppKit's mouse tracking makes, because posted mouse events end the test process (see "Spike results").
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

## Spike results (2026-11-08)

Step A ran on the branch `phase-3-spike`. The spike code is `Sources/Prose/WritingSpike.swift`; only tests install it, and Code mode is unchanged. The measurements are `Tests/ProseAppTests/WritingSpikeFlowTests.swift`, three tests in `WritingFlowTests`. Each test prints its numbers with the prefix `SPIKE`. Measured on Xcode 27.0 beta, macOS 27, debug Swift build, window 1220 by 820, column 854 pt, render width 657 pt.

### Pass marks

| Question | Pass mark | Measured | Result |
|-|-|-|-|
| Custom height | Rendered fragment reports the engine's height; `usageBoundsForTextContainer`, view frame and scroller agree within 1 pt | Each rendered fragment's frame has the engine height times 1.3, to 0.01 pt. Every next fragment starts at the previous one's bottom, to 0.01 pt. Usage height 2647.57 pt, expected 2647.57 pt (Code mode 2782 pt). View frame 2732.0 pt, usage plus insets 2731.57 pt. Scrolled to the end: clip bottom 2732.0 pt, knob proportion 0.2990 against 0.2990, last line visible | PASS |
| Swapping | Invalidating the block's range makes TextKit ask the delegate again, both ways, in one pass, no stale fragment drawn | `invalidateLayout(for:)` does not ask the delegate. TextKit keeps the old fragment object and lays it out again. `recordEditAction(in:newTextRange:)` with the same range, inside `performEditingTransaction`, does: in the window's next layout pass TextKit asked for exactly the block's three paragraphs, both ways. It built no new paragraphs. The replaced fragment's draw count did not change; the new one drew on the next draw | PASS with `recordEditAction`. FAIL with `invalidateLayout(for:)` alone |
| Neighbours | Caret rectangles, `character(at:)` round trips and drag selection in the next source block behave as in Code mode | 136 caret rectangles equal Code mode after one constant shift of -78.82 pt (x and height to 0.5 pt). Round trips: 0 failures of 136, both modes. Drag from character 2 to character 60: {348, 58} in both modes, which is the expected range | PASS, with the drag caveat below |
| SVG | `NSImage(data:)` draws SICP's ten largest blocks without missing glyphs, and one screen in under 8 ms | Drawing is correct: 0 of 30,798 glyph boxes without ink, and the PNGs match the source by eye. Speed fails: one viewport of SICP (4 blocks, 943 pt, 299 KB of SVG) takes 16.9 ms to decode and 20.9 ms to draw the first time, 37.5 ms in all; drawing it again takes 6.3 ms. The plan's 20 blocks (3159 pt, 1.5 MB) take 184 ms cold and 23 ms again | Correctness PASS. Speed FAIL |
| TextKit 1 | `switchedToTextKit1` stays false | False at the end of all three tests, and in `WritingFixture.close` | PASS |
| Book | Opening SICP in the spike's Writing mode builds under 5,000 paragraphs | With every block rendered: 11,110. With blocks of more than 400 source lines left as source: 945 | FAIL as planned. PASS with the cap |

### Custom height: the mechanism

An `NSTextLayoutFragment` subclass, returned from `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`, overrides:

- `layoutFragmentFrame`: returns `super.layoutFragmentFrame` with the height replaced by the block's drawn height. TextKit stacks the next fragment at this frame's bottom, and `usageBoundsForTextContainer`, the view frame and the scroller follow it.
- `renderingSurfaceBounds`: the block's drawn rectangle.
- `draw(at:in:)`: draws the SVG through `NSImage` into an `NSGraphicsContext(cgContext:flipped: true)`.

The block's later paragraphs get a fragment whose `layoutFragmentFrame` height is 0, whose `renderingSurfaceBounds` is empty and which draws nothing. No other hook was needed. The content storage fallback (paragraph styles from `textContentStorage(_:textParagraphWith:)`) was not needed and was not built.

`NSTextView` does not set a layout manager delegate of its own (it was nil before the spike set one).

### Swapping: the mechanism

`invalidateLayout(for:)` never makes TextKit ask the delegate; it lays out the same fragment objects again. Two ways work:

1. Replace the fragments. Call `textContentManager.performEditingTransaction { recordEditAction(in: range, newTextRange: range) }` with the block's range. Nothing in the storage changes. The view marks itself for layout, and in its next layout pass TextKit asks the delegate for each paragraph of the range. `SourceStyler.paragraphsBuilt` did not change, so the text elements are reused. The storage, the workspace revision, the selection and the undo stack stayed the same. Switching all 99 paragraphs of the test document this way also built no paragraphs. (`NSTextStorage.edited(.editedAttributes, …)` works too, but it runs the storage's editing machinery, so the spike does not use it.)
2. One fragment class for every paragraph. The fragment reads the block state each time TextKit reads its frame or draws, and `invalidateLayout(for:)` alone swaps it. Heights switched both ways (37.77, 0, 0 to 52, 52, 27 and back), the next fragment moved from 86.97 pt to 180.21 pt and back, and the delegate was not asked. The spike did not check this way's drawing.

In the test harness the window's own display pass draws no fragments, so draws were checked with `cacheDisplay(in:to:)`. The delegate calls happened in the window's `layoutIfNeeded` pass.

### What NSTextView does inside rendered and collapsed fragments (recorded only)

Test block: a paragraph of three source lines starting at offset 17 (lines start at 17, 120 and 225). Its rendered fragment is 37.77 pt tall at y 49.21; in Code mode the three lines take 52, 52 and 27 pt.

- **Layout inside.** TextKit still lays out the source lines. The rendered fragment's `textLineFragments` are the first source line's lines (it wraps to two). The collapsed fragments keep their source lines too, placed at the rendered block's bottom.
- **Caret.** In the first source line, the caret sits at the source x position (offset 57 at x 395.6), 18 pt tall, inside the rendered fragment. In the second and third source lines, the caret sits at y 93.97, the block's bottom plus line spacing, at the source x. It is drawn over the paragraph after the block.
- **Selection highlight.** Selection segments are the source lines' rectangles. Inside the rendered fragment they are hidden, because the SVG's page is opaque white and is drawn over them. The collapsed lines' segments lie below the block and show as grey bands over the blank line after it (`editor-selection.png`). With a transparent page they would show through the rendered text in the wrong places.
- **Hit testing.** A point in the rendered fragment maps through the source layout of the first source line: x 20 and 300 near the top give offsets 19 and 47, near the bottom 106 and 119. The second and third source lines can never be hit. `TextKit2Geometry.character(at:)` returns nil in the top 7 pt (the line spacing). A click through selection navigation at the fragment's middle gives offset 29, a source position, not the glyph under the pointer.
- **Up and down arrows.** They step through every source line, the collapsed ones included, at the source x. Up from the paragraph below the first equation: 345, 312, 311, 225, 206, 120. Down from the heading: 16, 17, 104, 120, 206, 225. End of line from offset 20 goes to 104, the end of the first source line's first wrapped line in source layout.
- **Drag from source into a rendered block.** From the paragraph below the equation up to the first line of the rendered paragraph gives {57, 291}: a plain source range, ending at the source position under the point.

### SVG drawing

- `NSImage(data:)` draws Typst's SVG correctly: `<symbol>` and `<use>` glyphs, inline and display math, footnotes, italics, monospace, tables and shaded code blocks. PNGs of the ten largest SICP blocks were checked by eye against their source (the index table, the factorial compilation listing, the amb evaluator paragraph and others). A pixel check found ink in all 30,798 glyph boxes that should have it.
- The engine's SVG page is opaque white. That hid NSTextView's selection inside rendered fragments, and it would be wrong in dark appearance.
- 69 punctuation marks at line ends hang past the right edge of the block's page (Typst's overhang) and are clipped by the SVG `viewBox`. The engine should widen the `viewBox` or the page to the ink bounds.
- Speed is the problem. Decoding and drawing cost about 0.12 ms per KB of SVG on the main thread, and SICP's SVG averages 54 KB per block (198 MB for the whole book). A first draw of one viewport takes about 38 ms. A second draw of the same `NSImage` objects takes about 6 ms, just inside 8 ms. The fallback in this note applies: engine PNG output through `typst-render`, or rasterizing the SVG to a `CGImage` off the main thread and drawing the cached image. Either way the main thread should only draw bitmaps.

### Other findings

- **Huge blocks.** SICP's index is one table of 43,081 characters on about 10,500 source lines. Jumping into it made the viewport lay out every zero-height paragraph after the caret: 10,500 paragraphs and 244 to 291 ms for one jump. With blocks of more than 400 source lines left as source, the whole run built 945 paragraphs and the slowest jump took 84 ms.
- **Rendering the whole book.** 3,671 blocks, 0 failures, 3.4 s, 198 MB of SVG. Switching all fragments took 80 ms and built 53 paragraphs.
- **Every block starts at a line start** in SICP, as the shape in decision 2 needs.
- **Test harness.** `NSApp.postEvent` calls `CFRunLoopStop` on the main run loop. Under `swift test` the main actor runs inside that loop, and its return exits the test process with status 0 and no report. The spike's drags therefore use `textSelectionNavigation.textSelections(interactingAt:…, anchors:, modifiers: [.extend], selecting: true, …)`, the calls NSTextView's mouse tracking makes, instead of posted mouse events. A real event drag over a rendered block is still unverified. Steps E and F need another way to drive mouse tracking, for example a nested run loop around the posted events, or an XCUITest target.

### What this changes in the decisions

- **Decision 2 (one fragment draws the block)** holds, with two changes. Blocks longer than a limit (400 source lines in the spike) stay source, or the engine splits them; without that, one large table breaks the paragraph gate. And because collapsed paragraphs keep their source lines, every piece of geometry inside a rendered block (caret, selection, hit testing, accessibility frames) must come from the glyph boxes, not from TextKit.
- **Decision 5 (caret entry and exit)**: a swap is not `invalidateLayout(for:)`. Use either `recordEditAction` on the block's range, or one fragment class whose state changes and `invalidateLayout(for:)`. I recommend the second for step D: it does not simulate an edit, so nothing observing edits can react. Its drawing must be checked first. Arrow keys already move through collapsed lines one source line at a time, so the swap on caret entry must happen in `textViewDidChangeSelection` before the next draw.
- **Decision 6 (pointer)**: NSTextView maps clicks inside a rendered fragment through the source layout of the first source line, and the other lines cannot be reached. `mouseDown` must map rendered fragments through glyph boxes itself, as planned. The drag fallback (whole blocks) may still be needed; the spike could not test real drags.
- **Decision 7 (selection drawing)**: NSTextView draws the collapsed lines' selection below the block, over the next paragraph. Suppressing NSTextView's selection inside rendered blocks is required, not optional.
- **Decision 4 and the engine (step B)**: drawing SVG on the main thread is too slow for first display. Step B should add bitmap output (or step D should rasterize off the main thread), keep SVG or bitmaps only for blocks near the viewport, emit a transparent page, and include hanging punctuation in the page bounds.

## Changes after the spike (approved 2026-11-08)

1. **Bitmaps, not SVG, on the main thread.** Step B adds PNG output through `typst-render` at the screen's backing scale. The main thread draws only cached bitmaps. The engine's page is transparent, and its bounds include hanging punctuation.
2. **Large blocks stay source.** A block of more than 400 source lines stays source in version one. SICP's index (about 10,500 lines) otherwise breaks the 5,000-paragraph gate.
3. **Swaps change fragment state.** Each fragment reads its block's state (rendered, source, pill), and `invalidateLayout(for:)` swaps it. Step D checks drawing for this method first. `recordEditAction(in:newTextRange:)` on the block's range is the backup.
4. **Drag tests.** Acceptance test 3 is split as written above: Prose handles drags that start in rendered blocks, and tests drive them directly; drags that start in source stay with AppKit.

## Step B outcome (2026-11-08)

- ABI version 2. `blocks` covers the whole file with five new kinds: `context`, `include`, `raw`, `list` and `comment`. A loose list stays one block, as Typst groups it, so numbering matches the full document.
- `render` takes options: a default text colour and a bitmap scale. Bitmaps are premultiplied RGBA8, built from the cached vector result after the engine lock is released, and are not cached in the engine; the editor keeps the images it draws. Pages are transparent, and the drawn area covers hanging punctuation.
- SICP: 3,651 blocks, 0 failures. Rasterizing at scale 2.6 takes 0.69 ms median, 4.2 ms p95 and 84 ms at most (the index table). The executable grew by 1.6 MB.
- Known limits for step D: the text colour does not change default strokes (table rules stay black in dark appearance), and selection drawing should use the union of the drawn area and the glyph boxes.

## Step C outcome (2026-11-08)

- `WritingLayout` (`Sources/ProseCore/WritingLayout.swift`, `WritingLayoutTypes.swift`): a main-actor model behind the `WritingRenderer` protocol, which `BlockRenderer` conforms to. The view forwards edits, the caret, marked text, the visible range and the appearance. The layout delegate asks `role(forParagraph:)` and gets `source`, `rendered`, `collapsed` or `pill`; `onChange` names the ranges whose roles changed, and nothing is reported while text is marked.
- Timing is injected through `WritingTiming` (settle 150 ms, refresh pause 1.5 s); tests await `idle()`.
- Results: 236 core and 149 app tests pass; coverage 88.12 percent overall, `WritingLayout.swift` 99.2 percent, `WritingLayoutTypes.swift` 92.5 percent. Lint and the release build pass.

## Step D outcome (2026-11-08)

- Writing mode draws in the editor when the hidden default `WritingModeEnabled` is set. `WritingFragments.swift` holds the layout manager delegate and one fragment class that reads its paragraph's role on every frame read and draw; `invalidateLayout(for:)` swaps changed ranges. On first entry, TextKit's existing fragments are replaced once with `recordEditAction(in:newTextRange:)` over the whole text, which changes no characters.
- `WritingController` (`WritingMode.swift`) forwards edits, the caret's moving end (the selection end that is not its anchor), marked text, the visible range and the appearance, and keeps the top line or the caret line in place across swaps.
- `WorkspaceWriting.swift` keeps one `BlockRenderer` per project root and main entry, created on first entry. `ProjectWatcher` now reports changed paths, and changed project files reach the engine through `setText`.
- Results: 236 core and 156 app tests pass, coverage 88.22 percent; lint and the release build pass. Drawing was checked with `cacheDisplay`, because the test window's display pass draws no fragments.
- Open for steps E to H: NSTextView still draws its own selection and caret inside rendered blocks; clicks map through source layout; live-resize centering has no test; an external file change does not trigger a refresh.

## Step E outcome (2026-11-08)

- Acceptance tests 1 to 5 pass (`Tests/ProseAppTests/WritingSelectionFlowTests.swift`). Clicking every glyph box in three rendered blocks gives its source offset (233 boxes, 0 mismatches). Per-glyph dragging works, so the whole-block fallback is not used.
- Native selection: NSTextView draws its highlight from `enumerateTextSegments(in:type: .selection, ...)` in `_updateTextLayoutManagerSelectionLayers`. The editor's `NSTextLayoutManager` subclass (`ManuscriptLayoutManager`) drops rendered and pill paragraphs from non-empty selection enumerations while Writing mode runs. The editor draws the highlight for those blocks in `drawBackground(in:)`, under the transparent images, with geometry from the glyph boxes (`WritingGlyphMap`). Fragment redraws could not be forced reliably through public API, so the highlight is not drawn inside the fragment.
- AppKit drags from source: a replacement `textSelectionNavigation` (`WritingSelectionNavigation`) answers points in rendered fragments and pills with glyph-mapped offsets, or the block boundary in the direction of the drag. Drags that start in a rendered block run Prose's own tracking loop, whose event source tests script.
- Decision change: a non-empty selection made with the pointer (shift-click, drag, double- and triple-click) opens no block, so text does not move under the pointer. Empty selections and keyboard selections keep decision 5.
- Results: 239 core and 161 app tests pass, coverage 88.36 percent; lint and the release build pass.
- Open for step F: in a window that is not key, source lines use NSTextView's inactive grey but rendered blocks keep `Theme.selection`; match the native inactive colour and redraw on key changes. Not tested: dragging a selection out of a rendered block (`dragSelection`), autoscroll during Prose's tracking loop, and real mouse events in the running app.

## Step F outcome (2026-11-08)

- Keys with an empty selection already land where Code mode puts them. TextKit's selection navigation steps through line fragments, and a rendered block keeps its source line fragments, so the destination equals Code mode's and the block it lands in opens at once (decision 5). Measured over the selection fixture: 12,996 moves (16 commands from every offset of the first 609 characters, 14 shift commands from every third offset, and up and down runs through the whole file), 752 of them into blocks drawn rendered or as pills; 0 differ from Code mode, and every caret ends in a source paragraph inside the view. Writing mode leaves these moves to TextKit.
- Decision change: a selection the pointer made still opens no block while the keyboard extends it (shift-arrows, shift-page). Before, the first shift-arrow after a shift-click or drag opened the block under the moving end, and NSTextView moved the selection's fixed end when the drag had gone upward. Writing mode now moves the moving end itself (`WritingSelectionNavigation.destinationSelection`, `WritingKeyboard.swift`): up and down step through the drawn lines of rendered blocks (`WritingGlyphMap.sourceLines`) at the run's x, line start and end use the drawn line, paragraph start and end the block's ends; other keys are TextKit's from the moving end. Selections made from a caret with shift keep decision 5.
- Page up and down (`pageDown:`, `pageUp:` and their shift forms) move the caret about one viewport of drawn content and scroll by the same distance; past the text's ends they go to them. With TextKit 2, NSTextView's own page commands moved neither the caret nor the view in the test harness, in Code mode too; Code mode keeps them. `scrollPageDown:` (the Page Down key) is NSTextView's.
- Undo (acceptance tests 6 to 8 pass). NSTextView does not move the selection on undo or redo of typing: the caret stays where it was, moved by the change, in Code mode as in Writing mode. So after "type in A, move to B, undo", A draws source at once because its render is dropped, then renders the restored text; it does not open as the active block unless the caret is in it. Renders kept across edits are compared with a fresh engine's by glyph boxes and sources relative to the block.
- An undo that removes a blank line between two blocks that are not active leaves both old renders drawn until the engine's new list arrives (the 150 ms settle), as decision 3 rebases the list locally; then the merged block renders once.
- Selection colour: `-[NSTextView _selectionBackgroundColor]` returns the background of `selectedTextAttributes` when the window has key appearance (`-[NSWindow hasKeyAppearance]`: the window is key, or a child window that shares its key state is) and the text view is the window's first responder, and `NSColor.unemphasizedSelectedTextBackgroundColor` otherwise (found by disassembling AppKit). The rendered-block highlight now uses the same rule, with the public part of key appearance (the window or a child window is key), and redraws on window key changes and on first responder changes. In the harness both draw sRGB 226,226,226 inactive and 243,237,245 active.
- Results: 240 core and 168 app tests pass, coverage 88.46 percent (main-session rerun); lint and the release build pass.
- Open for steps G and H: undo does not bring the caret back to the changed block (NSTextView's own behaviour); a key-state change in a child window that does not share its parent's key state would differ from NSTextView (Prose has none); real key events in the running app are untested.

## Step G outcome (2026-11-08)

- Acceptance tests 9 to 13 pass (`Tests/ProseAppTests/WritingInputFlowTests.swift`, six tests in `WritingFlowTests`; test 9 has a second test for the defect below). Compositions are Pinyin `zhong'wen` typed letter by letter through `setMarkedText(_:selectedRange:replacementRange:)` and committed as 中文 through `insertText(_:replacementRange:)` and `unmarkText()`.
- Input methods: decision 5 already held end to end. The heading's render was in flight when the composition began; it arrived while text was marked and waited. Caret moves, `viewportDidChange`, `selectionDidChange` and `flush` then swapped nothing: 0 swaps, every fragment's role and frame unchanged, no text sent to the engine. After the commit the held render swapped in (1 swap), and 中文 was in the storage once. A composition in the block at the viewport's bottom edge survived three scrolls (to the top edge, out of view, back) that brought 29 rendered blocks into view, with 0 swaps and no engine call. The candidate window rectangle lay on the caret's line in all 27 composition states checked (three places, nine letters each): between rendered blocks, on the second source line of a three-line block, and further down after scrolling.
- Defect found and fixed: a composition that replaces a selection the pointer made inside a rendered block (step E: such a selection opens no block) left the block rendered while text was marked. NSTextView put the marked text in the hidden source lines, where nothing draws it. **Decision change (decision 5):** while text is marked, a block whose text the composition itself changes opens at once (`WritingLayout.openComposing`) and counts as active until the composition ends. Render results, caret moves and viewport changes still swap nothing. `setMarkedText` lays the swap out before it returns, so the input method's next geometry question sees source.
- VoiceOver before step G: the value, the strings for ranges, the lines (`accessibilityLine(for:)`, `accessibilityRange(forLine:)`) and the insertion point line number were already the source and equal to Code mode's, because TextKit keeps every rendered block's source layout. Geometry was wrong. `accessibilityFrame(for:)` and AXBoundsForRange answered a zero-size rectangle for every range in a rendered block, because they read the selection segments that `ManuscriptLayoutManager` drops there. `firstRect(forCharacterRange:actualRange:)` answered the hidden source line: the first source line inside the fragment at its source x, the later ones near the block's bottom. `accessibilityRange(for:)` and `characterIndex(for:)` answered offset 0, and AXRangeForPosition answered hidden source positions (for example 131 for the glyph of 148).
- After step G (`Sources/Prose/WritingAccessibility.swift`): a range's frame is the union of its characters' glyph boxes; a character with no glyph (markup, spaces, line ends) gets the caret's place on its drawn line; a pill's frame is the pill; parts in source keep NSTextView's frames. `firstRect` is the first drawn line of the range's glyphs. The range and character index for a point map through the glyph boxes, as clicks do. Measured over three rendered blocks: 266 characters, 232 with glyphs, 0 problems (each frame inside its glyph boxes and on a drawn line of the fragment, AXBoundsForRange equal to it; range, AXRangeForPosition and character index at every glyph box's centre equal to that glyph's character).
- Assistive apps ask through `accessibilityAttributeValue(_:forParameter:)`. NSTextView answers AXBoundsForRange and AXRangeForPosition through its own `accessibilityBoundsForRangeAttributeForParameter:` and `accessibilityRangeForPositionAttributeForParameter:`, which do not call the protocol methods (found by listing its methods at run time; overriding `accessibilityFrame(for:)` alone left these answers zero). The editor overrides those two selectors for ranges and points in rendered blocks and pills, and calls NSTextView's implementation otherwise. Code mode's answers are unchanged.
- **Decision (recorded):** an accessibility line is a line of the source layout, as in Code mode, not a source paragraph. A source line that wraps in the source layout reads as consecutive pieces. In test 13, four source lines read as seven lines, in order, contiguous, none empty, identical to Code mode's. Line numbers do not change when a block swaps, so the insertion point line number agrees whether the block is open or rendered. Each line's frame lies on the rendered fragment's glyphs.
- Test harness: `editor.string as NSString` can be the storage's live string and changes with later edits; tests snapshot with `NSString(string:)`. `firstRect` answers a zero rectangle for marked text scrolled out of view; test 10 checks the candidate window only while it is in view.
- Results: 241 core and 174 app tests pass, coverage 88.50 percent (main-session rerun) (`WritingAccessibility.swift` 92.6 percent, `WritingLayout.swift` 99.4 percent); lint and the release build pass.
- Open for step H: no test drives a real input method or the accessibility server in the running app. AXVisibleCharacterRange, AXStyleRangeForIndex and AXRTFForRange answer from the source as before and were not changed. `firstRect` for a range that starts in a rendered block reports only its first drawn line, so a lookup panel over a multi-line range follows that line. A composition over a pointer selection that spans several blocks opens each block it edits, but only a selection inside one block is tested.
