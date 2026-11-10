# Quiet Writing mode: fewer code parts in Writing and Focus

Date: 2026-11-09
Status: Accepted 2026-11-09, with every recommendation (see "Answers"). Every decision that is a choice and not a fact is marked **Choice** so it can be reversed.
Spec: `docs/prose-spec.md`, Sections 5.3, 5.4, 6 and 8. Builds on `docs/plans/2026-11-08-phase-3-writing-mode.md` and `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`.

## Goal

Tehran approved the direction on 2026-11-09: Writing and Focus modes should show less Typst code, as Overleaf's visual editor shows less LaTeX. Three things look like code today, and this phase takes them in order.

1. **Setup lines and comments fold.** A run of `#import`, `#let`, `#set` and `#show` lines and comments draws as one quiet row, for example "Document setup · 16 lines", that opens on a click. A comment between paragraphs draws as a small mark in the margin. In Focus, the row takes no space unless the caret is in it.
2. **The open block is quiet.** The block that holds the caret draws in the document's own font and size, so it looks like the paragraph it replaces. Markers (`*`, `_`, `=`, `#emph[`, `@key`) stay in place and draw in a faint colour. The words keep full contrast.
3. **Typing in the rendered paragraph: a spike only.** The paragraph would stay typeset while the writer types plain words. This phase measures whether that can work and builds nothing of it. Tehran decides from the numbers.

The text storage holds the full source through all of it. Nothing here adds an attachment, a hidden character or substituted text, and nothing touches `layoutManager`.

## Terms

Earlier terms keep their meaning (block, active block, rendered fragment, pill, focus block, dimmed). New terms:

| Term | Meaning |
|-|-|
| Quiet block | A block that would draw as a pill today: kind `context` or `comment`, or a block whose render has no ink (`#v(7mm)`, `#pagebreak()`, `#codly(...)`) |
| Fold | A run of quiet blocks with only blank lines between them, drawn as one unit |
| Setup row | How a fold with one or more `context` blocks draws when closed: one line with a label and a count |
| Margin mark | How a fold with no `context` block draws when closed: a small icon in the left margin that takes no height |
| Open, closed | A fold's two states. An open fold draws its lines as source, as Code mode does |
| Resting position | The first character of a closed fold. The caret can stand there without opening the fold |
| Marker | A character that is markup syntax and not the writer's words: `*`, `_`, `=`, list markers, `#name[` and its `]`, `@`, a label's `<` and `>` |
| Open block | The active block in its new look: document font, faint markers |
| Typeset typing | Step 3's idea: the active block stays rendered while the writer types plain words |

## What the existing code gives

- **Block kinds.** The engine's block list (`Engine/RenderBridge/src/outline.rs`) marks `context`, `include` and `comment` blocks. `WritingLayout.desiredState` turns each one into a pill, and turns a render with no ink into a muted pill. Step 1 needs no engine change.
- **Roles.** `WritingLayout.role(forParagraph:)` answers `source`, `rendered`, `collapsed` or `pill` for a TextKit paragraph. One fragment class, `WritingFragment`, reads the role and keeps it until `roleRevision` changes. `invalidateLayout(for:)` over a changed range swaps the look, with the top line (or, in Focus, the caret line) kept in place. A fold is one more thing that the same machinery draws.
- **Blank lines between blocks belong to no block.** They are `source` paragraphs, each one an empty line of the editor font. Today 14 pills with blank lines between them take 14 pill heights and the blank lines. A fold must collapse the blank lines inside it too.
- **Pill paths.** The pointer (`WritingPointer.swift`), the selection highlight, the keyboard's drawn-line steps (`WritingKeyboard.swift`) and accessibility frames (`WritingAccessibility.swift`) already treat a pill as a rectangle with no glyphs: a press gives the block's start, a selected pill is highlighted whole, and its accessibility frame is the pill's rectangle. A setup row can use every one of these paths.
- **Margin.** The column has 36 pt or more on each side (`ManuscriptLayout.minimumInset`). The amber stale bar already draws there, 9 pt left of the column, through `renderingSurfaceBounds`.
- **Fonts are storage attributes.** `SourceStyler` writes one font per style (plain, heading level, strong, emphasis, raw) into the storage, with the key `ProseSourceStyle` beside it, and writes them for the whole text in `open()`. A book takes about 0.1 s to parse there, and TextKit then estimates every paragraph again. Phase 4 left source at the editor's size in Focus for that reason.
- **Colours are rendering attributes.** `RenderingAttributes` keeps a mirror and writes only changed spans. Tinymist's semantic colours go in through `setColors`, which compares the whole document; `setSpelling(_:in:value:)` shows how to write one range only. `.spellingState` is a separate key, so a colour change never touches a spelling underline.
- **The syntax tree.** `SyntaxTree.nodes(in:)` returns node kinds for a window of the text, with `headingMarker`, `listMarker`, `enumMarker`, `termMarker`, `star`, `underscore`, `hash`, `leftBracket`, `rightBracket`, `refMarker`, `label` and the rest. `SpellCheckRanges` is a pure function over these nodes, and marker ranges can be one too.
- **The content storage delegate.** `SourceStyler` is already the `NSTextContentStorageDelegate`. Its `textContentStorage(_:textParagraphWith:)` counts paragraphs and returns nil. Phase 3's fallback, which Tehran accepted as inside the rule on 2026-11-08, was to return a paragraph with the same characters and other display attributes. It was never needed, so it was never built or measured.
- **What the engine knows about fonts.** The glyph walk in `geometry.rs` reads each text item's font and size already; neither is reported. The engine loads Typst's embedded fonts (Libertinus Serif, New Computer Modern), which macOS does not have, then the system fonts.
- **The glyph map.** `WritingGlyphMap` gives hit tests, drawn lines and caret positions inside a rendered block. Selection, the typewriter line and accessibility use it today. Step 3 would put the live caret on it.
- **Engine timing.** A block compiles in about 0.5 ms. The path around it is slower by design: `WritingLayout` waits 150 ms after the last edit before it sends the text, and it sends the whole file each time.

## Decisions

### 1. What folds

- A fold is a maximal run of quiet blocks with nothing but blank lines between them. Its range runs from the first block's first paragraph to the last block's last paragraph.
- A fold with one or more `context` blocks draws as a setup row. Comments and no-ink blocks inside the run fold with it. In the welcome guide, lines 1 to 17 (two comments, two imports, three `#let` lines, eight `#set` and `#show` lines, and `#codly(...)`) become one row.
- A fold with no `context` block draws as a margin mark. That covers a comment between paragraphs and also a lone `#v(7mm)` or `#pagebreak()`. **Choice:** no-ink blocks get the mark too. Tehran named setup lines and comments; the welcome guide also shows `#v(9mm)`, `#v(7mm)`, `#v(3mm)` and `#pagebreak()` as muted pills between its paragraphs, and they look like code as much as a comment does.
- **Choice:** an `#include` line is not quiet. It stays a pill on its own, because it stands for a chapter of the document, and a thesis's main file is mostly a list of them.
- A block is known to have no ink only after its render arrives. Until then it draws source for a moment, as today, and joins the fold when the render comes. The fold is computed from block states, so it follows them with no state of its own to go stale.
- The row's label is "Document setup · N lines" for a fold that starts before the file's first rendered block, and "Setup · N lines" for a later one. N counts the fold's source lines that are not blank. The label is English only.

### 2. How a fold draws

Everything is in the layout layer: `WritingLayout` decides, `WritingFragment` draws.

- **Closed setup row.** The fold's first paragraph draws the row: a Phosphor `caret-right` icon and the label, 12 pt, in the muted text colour, with no fill. It takes the height a pill takes today (36 pt with its spacing). Every other paragraph of the fold, blank lines included, is `collapsed`.
- **Closed margin mark.** Every paragraph of the fold is `collapsed`, and so are the blank lines after it up to the next block, so the two paragraphs around a comment keep one normal gap. The fold's first paragraph draws a 12 pt Phosphor icon in the margin, left of the column, level with that gap: `chat-teardrop` for comments, `code-simple` for a no-ink call. **Choice** of icons.
- **Open fold.** Its paragraphs are `source`, drawn exactly as Code mode draws them, monospace. Setup lines are code, so they keep the code look; step 2's quiet look does not apply to them. The first paragraph also draws a `caret-down` icon in the margin, and a click on it closes the fold.
- The model gains the fold as a value on the pill (`WritingPill` gets a style: pill, setup row with its line count, or mark), so the pointer, highlight and accessibility code that handles pills handles rows with no new case. A margin mark has no height, so the pointer finds it by its rectangle in the margin, which the controller keeps for the marks in view.

### 3. When a fold opens and closes

A fold is closed unless one of these opened it.

| What happens | Result |
|-|-|
| A click on the row or the mark | Opens. Stays open until a click on the `caret-down` icon |
| The caret lands inside the fold, past its first character | Opens. Closes when the caret leaves the fold |
| An edit changes text inside it (undo, redo, replace, an agent tool) | Opens, so the writer sees what changed. Stays open until a click on the icon |
| The caret is at the resting position | Stays closed |
| A selection made with the pointer covers it | Stays closed, as a pill does today. The row is highlighted whole. Copy gives the source |
| Text is marked | Nothing opens or closes until the composition ends (Phase 3 rule) |
| The file changes, or Writing mode starts again | Every fold starts closed |

The resting position solves the first screen. A new document's caret is at offset 0, which is the first character of the welcome guide's fold. Without the rule, entering Writing mode would open the fold at once.

**Choice: arrow keys step over a closed fold.** Down from the line above lands on the row, at the resting position, and the caret draws at the row's left edge. Down again lands on the first line after the fold. Up does the same in reverse. Right from the resting position, or Left from the line after the fold, goes inside and opens it. A character typed at the resting position is an edit inside the fold, so the fold opens with the new character in it. The other choice is to open the fold whenever an arrow key enters it; that moves 16 lines of code in and out of view each time the caret passes, so I recommend the step.

Mechanism: the editor overrides `moveUp(_:)` and `moveDown(_:)`, as it already overrides `pageUp(_:)` and `pageDown(_:)` for Writing mode. When TextKit's step from an empty selection would land inside a closed fold, the controller puts the caret at the resting position or at the first position after the fold. Every other move stays TextKit's.

- **Find.** The find bar selects its match. A match inside a closed fold puts the selection's moving end inside it, so the fold opens and the match shows. Matches in closed folds are not marked until they are selected.
- **Undo** is in the table: the fold opens. The storage and the undo stack work as in Code mode.
- **VoiceOver.** The editor's value, lines and strings are the source, as in every mode, so VoiceOver reads the setup lines one by one. The frame of a range inside a closed fold is the row's rectangle, or the mark's. The row has no accessibility element of its own. This matches how pills behave since Phase 3.
- **Spell check.** A closed fold shows no underline, as a pill shows none. Setup lines and comments are not checkable ranges anyway.

### 4. Folds in Focus

- A closed setup row takes no height in Focus: all its paragraphs are `collapsed`. It shows as a row while the caret is at its resting position, so the caret is never on a hidden line, and it draws open while the caret is inside.
- In Focus, Up and Down pass a hidden fold in one step, from the line before it to the line after it.
- Margin marks stay, dimmed to 45 percent like every block outside the focus blocks. **Choice.** Hiding them too is one line.
- The typewriter line needs no change: the caret line comes from the row or from source, as for a pill today.

### 5. The open block's font, with no restyle of the storage

The open block must draw in another font, and the storage's fonts are `SourceStyler`'s. Two mechanisms can do it.

**Choice: paragraphs from the content storage delegate (first), block-range attributes in the storage (second).**

1. **Layout-layer paragraphs.** `textContentStorage(_:textParagraphWith:)` returns, for a paragraph of the open block, an `NSTextParagraph` whose string has the same characters as the storage and the document's fonts in place of the editor's. It maps each run through its `ProseSourceStyle` value: plain to the block's font, strong to its bold face, emphasis to its italic face, heading to the block's own font (the engine reports a heading's font and size as it renders them), raw to the editor's monospace font. The storage's attributes never change, so Code mode, the styler's replies and every test that compares storage attributes are untouched. This is the mechanism Tehran accepted in Phase 3's answer 1.
2. **Block-range attributes.** If mechanism 1 fails its check, `SourceStyler` writes the document's fonts into the storage for the open block's range only (an attribute-only edit of one block, no undo record) and writes the editor's fonts back when the block closes. It works with machinery that exists, but the storage's fonts then differ between modes while a block is open, and the styler's replies must know which font set applies where.

Mechanism 1 has one unknown: how to make TextKit ask the delegate again for a block's paragraphs when the block opens or closes. Phase 3's spike showed that `recordEditAction(in:newTextRange:)` builds new fragments but reuses the paragraphs. Step D starts with a check, with these pass marks, before anything else is built:

| Question | Pass mark |
|-|-|
| Rebuild | A call that changes no character and no attribute makes TextKit ask the delegate for exactly the open block's paragraphs, in one layout pass |
| Nothing else moves | The storage's string and attributes, the selection, the undo count and the workspace revision are the same before and after. No observer sees a character edit |
| Geometry | Caret rectangles, hit tests and line fragments in the block come from the new fonts. A caret in the next block is where Code mode puts it, after one constant shift |
| Typing | A character typed in the open block draws in the document's font at once, and CJK and emoji text gets its fallback fonts |
| TextKit 1 | `switchedToTextKit1` stays false |
| Cost | Opening a ten-line paragraph costs under 2 ms on the main thread |

If any mark fails after one targeted retry, step D uses mechanism 2 and the note records why.

Either way, a caret move costs work in two blocks: the one that closes and the one that opens. Nothing walks the whole storage.

### 6. Where the document's font comes from

- **The engine reports it (C ABI version 6).** Each render result gains the block's text font: the font and size of the text item that holds the most of the block's own glyphs, and the distance between its first two baselines when it has two lines. A new call returns a font's bytes and face index, and another finds the bold and italic faces of the same family through Typst's font book.
- **Swift registers the bytes for the process** (`CTFontManagerCreateFontDescriptorsFromData`), never as an installed font, and keeps one `NSFont` per face and size. This is needed because Libertinus Serif and New Computer Modern exist only inside the engine.
- On screen the size is the engine's size times the scale: 1.3 in Writing mode, 1.4625 in Focus. This ends Phase 4's choice that source keeps the editor's size in Focus, for the open block only.
- Line spacing comes from the reported baseline distance, or 1.4 times the size for a one-line block. The open block wraps at the column width, which is the render width times the scale, so its line breaks are close to the render's. They are not equal: source has markers, and it is not justified or hyphenated.
- A block with no render yet (a paragraph just started) uses the font of the nearest rendered paragraph above it, or the editor's font when the file has none.

### 7. Which blocks get the quiet look

| Block | Look when it holds the caret |
|-|-|
| Paragraph, heading, list | Open block: document font, faint markers |
| Display equation | Code look, as today. **Choice:** an equation's source is all code, and math in a text font reads worse than in monospace |
| Raw block, a block over 400 lines, a block whose render failed | Code look, as today |
| An open fold | Code look (decision 2) |

Inside an open block there are three kinds of character:

- **Words** draw in the document's font and the editor's text colour, at full contrast.
- **Markers** draw in the document's font and the faint colour.
- **Code and math inside the paragraph** (`$x^2$`, the arguments of `#figure(...)`, a string) keep the editor's monospace font and Tinymist's semantic colours, at the document font's size. They are not words and not single markers, and a writer who edits them needs to read them.

### 8. Faint markers

- A pure function in ProseCore, `MarkerRanges`, walks the syntax nodes of a block and returns its marker ranges: `headingMarker`, `listMarker`, `enumMarker`, `termMarker`, the `star` and `underscore` of `strong` and `emph`, the `hash`, name and brackets of a call that has a content block (`#emph[` and `]`), `refMarker` (`@key`, key included, since a citation key is not the writer's prose), and `label`. It follows `SpellCheckRanges` in shape and in tests.
- The editor writes the faint colour as `.foregroundColor` through `RenderingAttributes`, with a new call that covers one range, as `setSpelling(_:in:value:)` does. For the open block it writes the text colour over the block (which clears semantic colours from words), then the faint colour over the markers, then the semantic colours of code and math. When the block closes it writes the block's semantic colours back. A semantic colour reply from Tinymist while a block is open goes through the same merge.
- **Choice:** the faint colour is the text colour at 35 percent opacity, in both appearances. Step D measures its contrast against the page in light and dark and records it. It must stay findable, so the floor is 2:1.
- **Spell check.** `.spellingState` is its own key, and markers are never checkable ranges, so underlines are unchanged.
- **Focus.** The open block is the focus block and is never dimmed. A block that draws the quiet look is always the active block, so faint and dimmed never combine.
- **Dark appearance.** The colours are the editor's, not the document's, so the engine's colour mapping is not involved.
- **Input methods.** While text is marked, no colour or font change is applied; it waits, as the styler's replies do.

### 9. Step 3: the spike for typeset typing

The idea: while the caret is in plain words, the active block stays rendered. Each key changes the storage as now, the block renders again, and the caret draws on the new glyph boxes. The block opens (as the open block of step 2) when the caret touches a marker, math or a call.

This is a risk of Phase 3's kind, so it gets a spike with pass marks, on the branch `quiet-writing-spike`, in code that only tests install. The questions:

| Question | Pass mark |
|-|-|
| Latency | From `insertText` to the new image drawn: p95 under 16.7 ms on the welcome guide and on a 20-page paper, p95 under 33 ms on SICP and War and Peace, in the instrumented debug build on a quiet machine. The spike sends each edit to the engine at once, with no 150 ms wait, and records what the whole-file `setText` costs on a book |
| Caret | In a scripted run of 2,000 keys over the fixture paragraphs, the caret is at the typed character's trailing edge after every key: 0 errors. The run covers a space at a line end, a trailing space, a ligature (`fi`), smart quotes, a word that moves to the next line, a hyphenated word, and an empty paragraph |
| Between key and render | Until the new render arrives, the old image stays and the caret holds its place. No frame draws source, and no frame draws the caret on the wrong line |
| Edges of the block | Return splits the paragraph and Backspace at its start joins two; the block list rebases, and both blocks are typeset within one render |
| Opening | The block opens exactly when the caret is next to a marker, in math or in a call, and when a typed character (`*`, `$`, `#`, `@`, `[`) starts one. The swap keeps the caret's line in place within 1 pt |
| Undo | Undo and redo group as in Code mode, and the caret is on the right glyph after each |
| Input methods | With the rule "a block that holds marked text opens", a Pinyin composition in a typeset block commits once, and Phase 3's tests 9 to 11 pass. The candidate rectangle is on the caret's line |
| VoiceOver | The insertion point's frame is the caret's rectangle on the glyphs. The value and the typed-character echo are the source |
| Focus | The typewriter step stays under its 33 ms gate with typeset typing on |
| Rules | The storage equals the source, no attachment exists, and TextKit 2 stays on, through every test |

What would end the idea, after one targeted retry each:

- Latency above the pass mark on the welcome guide. A writer would feel every key.
- Any caret error that the glyph boxes cannot fix. The engine can report more per glyph (baseline, advance, cluster) if that is what is missing; if spaces and line ends still cannot be placed, the idea ends.
- A frame of source or a misplaced caret between key and render that cannot be removed.

A failed input-method mark does not end it by itself, because the fallback (source while text is marked) already exists; the spike records what a Chinese or Japanese writer would see.

The spike's result goes into this note as "Spike results", in the form of Phase 3's. Then the work stops and Tehran decides. Nothing of step 3 ships in this phase.

### 10. Phase number

**Choice, for Tehran to confirm:** this work is Phase 6, "Quiet Writing mode", and polish (info popover, export sheet, per-document mode memory, screenshots, writing guide) becomes Phase 7, as Citations pushed polish from 5 to 6.

## Steps

The main session briefs each step to one Opus subagent with explicit checks, reviews the diff, reruns `bash scripts/lint.sh`, `scripts/build.sh release` and `PROSE_DISTRIBUTION=preview scripts/test.sh`, `cargo test --release` when the engine changes, and `scripts/benchmark-books.sh` when the step touches drawing, layout or scrolling. It reverts the Sparkle pin in `Package.resolved`, commits with an outcome section in this note, and pushes `prose`. Agents run one at a time in this checkout.

| Step | Builds | Checks |
|-|-|-|
| A. Fold model | Decisions 1 and 3 in `WritingLayout`: folds from block states, the pill's style, open and closed state, labels and line counts, roles for every paragraph of a fold | Unit tests in `ProseCoreTests`, with seeded random edits that must match a fresh model. Coverage of the changed files 90 percent or more. The app looks as before, because the fragment does not draw the new styles yet |
| B. Fold drawing and input | Decisions 2, 3 and 4: the row, the mark, the margin icons, the pointer, the arrow-key step, the highlight, accessibility frames, Focus | Acceptance tests 1 to 7. Book benchmark in all three modes |
| C. Engine fonts | Decision 6: C ABI version 6, the block's text font and baseline distance, font bytes, bold and italic faces; `BlockRenderer` and a font cache in Swift | `cargo test --release`; `BlockRendererTests`; a test that draws a line in the registered Libertinus Serif and finds no fallback font in it |
| D. The open block | The check of decision 5 first, then decisions 5, 7 and 8 | The check's pass marks, written into this note. Acceptance tests 8 to 13. Book benchmark in all three modes |
| E. Spike | Decision 9, on `quiet-writing-spike` | "Spike results" in this note, each pass mark with its number. Then stop for Tehran |
| F. Earlier answers | Answers 6 to 8: the `bibliography` command gets a style field with APA as the default; the dark mapping brightens mid greys to 4.5:1 or better against the page; spell check skips "Typst" | Tests for each; `cargo test --release`; spec Sections 5.2, 5.3 and 5.5 |
| G. Gate and documents | Three full runs of the suite and the benchmark; spec Sections 5.3, 5.4, 6 and 8, `docs/architecture.md`, `docs/visual-editing.md`, the `CLAUDE.md` phase table, the writing guide, the work log | Every acceptance test passes three runs in a row |

## Acceptance tests

UI tests are `extension WritingFlowTests`, on the real window, editor and engine, and every test window goes through `placeOnTestScreen`. Each test also checks that the storage equals the source, that no attachment exists, that the undo stack is unchanged unless the test edits, and that TextKit 2 is still on.

**Folds**

1. The welcome guide in Writing mode draws one setup row labelled "Document setup · 16 lines" above its first rendered block, and no pill. The row takes one pill's height. With the caret at offset 0 the fold is closed.
2. A click on the row opens the fold as source, and a click on the `caret-down` icon closes it. Ten round trips leave the storage, its attributes, the selection and the undo count identical, and the first line below the fold stays in place on screen.
3. Arrow keys: Down from the line above rests on the row, and Down again lands on the first line after the fold; Up reverses both. Right from the resting position opens the fold, and it closes when the caret leaves. A character typed at the resting position lands at the fold's first offset and the fold opens.
4. A pointer selection across a closed fold highlights the whole row and copies the source. Selecting a find match inside a closed fold opens it. An undo that changes text inside a closed fold opens it.
5. A comment between two paragraphs, and a `#v(7mm)` between two paragraphs, each draw a margin mark and no pill. The gap between the two paragraphs is within 1 pt of the gap between two paragraphs with one blank line. A click on the mark opens the fold.
6. In Focus, a closed setup row takes no height, shows while the caret is at its resting position, and Up and Down pass it in one step. A margin mark draws at 45 percent.
7. The frame of a range inside a closed fold is the row's rectangle. With marked text, a render that would change a fold changes nothing until the composition ends.

**The open block**

8. An open paragraph's line fragments use the font the engine reported, at its size times the scale, in Writing and in Focus; an open heading uses the heading's font. Opening and closing a block ten times leaves the storage's attributes equal to Code mode's (mechanism 1), or equal after the block closes (mechanism 2).
9. With `cacheDisplay`, the ink of `*`, `_`, `=`, `-`, `#emph[`, `]` and `@key` in an open block has the faint colour, and the ink of the words has the text colour, in light and dark. The measured contrasts are recorded.
10. The caret moves through 200 blocks of SICP with no write to the storage's attributes outside the open block and no rendering-attribute write outside the two blocks that change. The typewriter step gate holds.
11. A misspelled word in an open block keeps its underline. In Focus the open block draws at full contrast with faint markers.
12. A Pinyin composition in an open block keeps the document's font, and Phase 3's tests 9 to 11 pass unchanged.
13. A document set in Libertinus Serif, which macOS does not have, draws its open block in Libertinus Serif. Inline math and call arguments in the block draw in the monospace font.

**Performance**

14. The book benchmark runs in Code, Writing and Focus on SICP and War and Peace and passes every existing gate.

**Spike**

15. "Spike results" in this note has a measured number against every pass mark of decision 9.

## Risks

- **The rebuild in decision 5 is undocumented TextKit 2 behaviour.** The check comes before any other code of step D, and mechanism 2 is ready if it fails.
- **Swap jumps.** The open block's height now differs from the render's by less than before, but a fold that opens moves many lines. Every swap goes through the existing anchor (the top line, or the caret line in Focus), and test 2 holds the line below the fold in place.
- **Arrow keys.** The step over a fold changes where a key lands. It is limited to vertical moves of an empty selection into a closed fold; test 3 covers it, and the book benchmark's jumps and line-drift check run with folds on.
- **Folds that change under the caret.** A no-ink block joins a fold only when its render arrives. If that render arrives while the caret rests on the row, the row's label changes and nothing else.
- **Font registration.** A font registered from bytes may differ from an installed font of the same name. The cache keys fonts by the engine's font identity, never by name alone.
- **A paragraph that mixes fonts.** The engine reports the font of the largest text item. A paragraph set in two fonts opens in one of them.
- **Cost per caret move.** Two blocks are restyled and recoloured on each move between blocks. Test 10 and the typewriter gate bound it.
- **Step 3 may end at the spike.** That is a result. Steps 1 and 2 stand without it.
- **Test load.** Tests that failed once under heavy load and passed on a rerun are listed in the Phase 5 note. A second failure of the same test is a defect to find.

## Open questions for Tehran

1. Is this Phase 6, with polish as Phase 7 (decision 10)?
2. Do arrow keys step over a closed fold, with the resting position on the row (decision 3)? The other choice opens the fold whenever the caret enters.
3. Do no-ink blocks (`#v(7mm)`, `#pagebreak()`) become margin marks, and do `#include` lines stay pills (decision 1)?
4. Do display equations keep the code look when open, and does inline math keep monospace inside an open block (decision 7)?
5. Is the faint colour the text colour at 35 percent, to be tuned by eye after step D (decision 8)?

Waiting from earlier phases:

6. The bibliography command writes `style: "ieee"`. Give it a style field with APA as the default, or write the bare call?
7. In dark appearance a document's mid-grey text reaches 3.4:1. Brighten mid greys in the mapping?
8. "Typst" is underlined as misspelled. Skip it by default?
9. `⌘W` on the home window quits the app, as the close button does. Keep that?

## Answers (2026-11-09)

Tehran accepted the note and every recommendation:

1. This is Phase 6, "Quiet Writing mode". Polish is Phase 7.
2. Arrow keys step over a closed fold, with the resting position on the row.
3. No-ink blocks become margin marks. `#include` lines stay pills.
4. An open display equation keeps the code look. Inline math keeps monospace inside an open block.
5. The faint colour is the text colour at 35 percent opacity, tuned by eye after step D, with a contrast floor of 2:1.
6. The `bibliography` command gets a style field with APA as the default.
7. The dark mapping brightens mid greys to 4.5:1 or better.
8. Spell check skips "Typst" by default.
9. `⌘W` on the home window keeps quitting the app.

Answers 6 to 8 are step F.

## Step A outcome (2026-11-09)

The fold model is in `WritingLayout`, behind `foldsEnabled`, which is off until step B draws folds. With it off, every role is what it was, and no existing test changed.

- `WritingPill` has a style: plain, setup row (line count, and whether it is the document setup) or mark (comment or code). `WritingFold` describes one fold now: its span, whether it is open, its pill, and whether Focus hides it. `WritingSourceReason.fold` marks the blocks of an open fold.
- Calls for step B: `fold(holding:)`, `folds(intersecting:)`, `setFold(open:at:)`, `toggleFold(at:)`, and the property `hidesSetupRows` for Focus. `drawnSpans(intersecting:)` returns a closed fold's whole span once; `spans(intersecting:)` returns a fold's whole span, open or closed.
- Choices the step made:
  - A fold holds the caret from its first character through the end of its last line's text.
  - Open state is a pin on the fold (set by the pointer or an edit) plus the state of the one fold that holds the caret. A pin follows the fold's blocks across edits and its text across a new block list. A split fold pins both parts.
  - An edit pins a closed fold when it removes or replaces characters in it, or inserts from the resting position through the end of its last line. An edit before the fold only moves it.
  - A fold closed by the pointer with the caret inside stays closed until the caret leaves and comes back.
  - A no-ink block that is edited stays in its fold until a render shows ink, so the fold does not split while it waits.
  - A mark's trailing blank lines stop at the first line that is not blank.
  - While text is marked, folds are not rebuilt and the pointer calls do nothing; a composition inside a closed fold opens and pins it at once.
- Cost: caret moves, role reads and the pointer calls use binary searches over the folds; edits and renders rebuild only the folds near the change. On 4,000 blocks in the debug build a caret move takes 11 to 15 µs.
- Checks (main session): lint and the release build pass; 303 core and 210 app tests pass; coverage 89.85 percent (`WritingLayout.swift` 99.4 percent, `WritingLayoutTypes.swift` 95.5 percent, the subagent's figures). New tests: `Tests/ProseCoreTests/WritingFoldTests.swift` (12), with a seeded random run of edits, caret moves and pointer calls compared against a fresh model.

## Step B outcome (2026-11-09)

Folds draw and respond in Writing and Focus mode, for everyone. Acceptance tests 1 to 7 pass (`Tests/ProseAppTests/WritingFoldFlowTests.swift`, with an `#include`-stays-a-pill test and a metrics test). Tests 1 and 2 use the real welcome guide and the real engine: the row reads "Document setup · 16 lines" once the `#codly` render arrives.

- Built: the row, the mark and the closing icon in `WritingFragment`; the controller's fold logic in the new `Sources/Prose/WritingFolds.swift`; `moveUp(_:)` and `moveDown(_:)` overrides in `ManuscriptTextView`; the caret rectangle at a resting position through `ManuscriptLayoutManager`; row and mark rectangles for the pointer, the highlight and accessibility; `hidesSetupRows` and the fold as one focus span in Focus.
- Choices the step made:
  - Icons: `caret-right` and `code-simple` are bundled. `chat-teardrop` is not, so comments draw `chat-text`. `caret-down` is `caret-right` turned 90 degrees.
  - The margin icon sits 30 to 18 pt left of the column, centred on the middle of the blank line above the fold.
  - The caret at a resting position: on a row, at the row's left edge, 15 pt tall; on a mark, at the column's left edge, level with the mark.
  - The first click opens a fold and leaves the caret alone. A second click on a row selects the word at the fold's first character and a third selects the fold's source, as for a pill.
  - The goal column is not kept across a fold: Down from a row goes to the start of the line after the fold, and Up past a mark or a hidden row goes to the end of the line before it.
  - Up and Down pass a closed mark in one step in every mode.
  - The top-line anchor is unchanged; when the fold is the top paragraph in view its top stays at the same place on screen.
- A character typed at a resting position lands at the fold's first offset. That line is then no longer a setup line, so it leaves the fold, and the rest of the fold opens and stays open.
- Existing tests changed because pills became folds: `writingModeRenderedHeightsFollowTheEngine`, `writingModeDrawsRendersPillsAndSource`, `writingModeDragsExtendThroughGlyphBoxesFromRenderedAndSourceBlocks`, `writingModeKeysWithACaretLandWhereTheyLandInCodeMode` (Up and Down moves that meet a closed fold must never land inside it; every other move must still match Code mode), `writingModePageKeysMoveTheCaretAboutOneViewportAndScrollWithIt` (more filler text), `writingModeAcceptance12AccessibilityValueIsTheSourceAndFramesLieOnTheGlyphs`, `focusModeDimsEveryBlockButTheFocusBlocks` (the measured pill is an `#include` line, compared by its strongest ink) and the helper `expectCaretInSource`.
- Checks (main session, load average 6 to 14): lint and the release build pass; 303 core and 219 app tests pass, no rerun; coverage 89.99 percent. Book benchmark, every gate passes: typing p95 in Writing mode 7.08 ms (War and Peace) and 5.61 ms (SICP), in Focus 14.20 and 8.44 ms; typewriter step p95 22.15 and 18.33 ms; paragraphs built at most 1,503; peak memory 1,025 to 1,117 MiB in Writing and Focus.
- Not tested: rows and marks in dark appearance, a mark at the very top of a file, and real pointer and key events in the running app.
