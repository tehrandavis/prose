# Phase 4: Focus mode, the floating toolbar and spell check

Date: 2026-11-09
Status: accepted by delegation 2026-11-09. Tehran gave permission to build overnight without a separate review of this note. Every decision below that is a choice rather than a fact is marked **Choice** so it can be reversed.
Spec: `docs/prose-spec.md`, Sections 3.2, 3.3, 4, 5.3 (spell check paragraph), 6 and 8. Builds on `docs/plans/2026-11-08-phase-3-writing-mode.md`.

## Goal

At the end of Phase 4:

1. The Focus segment of the mode control works. Focus is Writing mode with the sidebar and preview hidden, a narrower measure at a larger scale, the current block at full contrast and the other blocks dimmed, and typewriter scrolling that keeps the caret line at 40 percent of the view height.
2. A floating toolbar with five actions sits above the bottom edge of the editor in Writing and Focus modes. Each action is a `⌘J` command from the existing registry.
3. Spell check marks misspelled words in prose only, in every mode. It skips code, math, raw text, labels, references, URLs and strings through the syntax tree. In source the word gets the native red underline; in a rendered block the underline is drawn under the engine's glyph boxes.
4. The inherited Simplified Chinese interface is gone (Tehran's decision, 2026-11-09). The app is English only.

Per-document mode memory, the info popover and the export sheet stay in Phase 5.

## Terms

Phase 3's terms keep their meaning (block, active block, rendered fragment, source fragment, pill). New terms:

| Term | Meaning |
|-|-|
| Focus block | The block drawn at full contrast in Focus mode: the active block, or, while a selection made with the pointer exists, every block the selection touches |
| Dimmed | Drawn at 45 percent opacity by the fragment. Nothing in the storage or the rendering attributes changes |
| Typewriter line | The horizontal line at 40 percent of the visible height where Focus keeps the caret line |
| Focus scale | The factor that converts engine points to view points in Focus mode: Writing's 1.3 times 18/16, so 1.4625 |
| Checkable range | A UTF-16 range of prose that spell check reads: text nodes in markup, including markup inside content blocks (`[...]`) of function calls |
| Misspelling | A range that `NSSpellChecker` reported as misspelled inside a checkable range, kept against today's text |
| Toolbar | The floating toolbar of spec Section 3.3 |

## What the inherited code gives us

- `EditorMode` has `.focus` already, and `EditorMode.isAvailable` refuses it. `Workspace.setMode(_:)` shows "Focus mode arrives in a later version of Prose." The segment, `⌘3`, the View menu item and the `modeFocus` command all reach `setMode(.focus)`.
- Writing mode (Phase 3) does all block work. Focus inherits every Phase 3 mechanism: the layout model `WritingLayout`, the one fragment class `WritingFragment` that reads its role on each frame read and draw, `invalidateLayout(for:)` swaps with the top line kept in place, glyph maps, pointer, keyboard, IME and accessibility.
- `WritingAppearance` carries the column width and the scale, and both are part of the render cache key. A different width or scale in Focus is a new render, not a new mechanism.
- The window layout (`ContentView.writing`) already hides the sidebar (`workspace.sidebarVisible`) and the preview (`workspace.layout`, whose value `.writing` means "editor only"; it is not `EditorMode.writing`). The status bar is `ContentView.footer`.
- The command panel has groups (`style` key `s`, `insert` key `i`) and commands `table`, `equation`, `math` and `image`. `Workspace.enterGroup(_:)` opens a group, `selectCommand(_:)` runs a command or opens its parameter form. The toolbar needs no new command logic.
- `SyntaxTree` (ProseCore, through `Engine/SyntaxBridge`) gives node kinds for the whole file, including `text`, `raw`, `equation`, `math`, `code`, `funcCall`, `contentBlock`, `str`, `label`, `ref` and `link`. `SourceStyler` already walks it for colours and rebases its runs across edits.
- `ManuscriptView` turns off NSTextView's own spell checking (`isContinuousSpellCheckingEnabled = false`), because NSTextView would check code and math. That stays off; Prose runs its own checker.
- `RenderingAttributes` (`ProseCore/TextKit`) owns the editor's rendering attributes and clears them with `setRenderingAttributes([:], for: documentRange)` on a full restyle. Any spelling attribute must go through it, or a restyle erases the underlines.
- The book benchmark runs in Writing mode with `PROSE_WRITING_MODE=1`.

## Decisions

### 1. English only (step A)

Remove `Sources/ProseCore/Resources/zh-Hans.lproj`, `Resources/zh-Hans.lproj`, the Chinese welcome template and its cover, `Examples/Prose.zh-Hans.typ`, the interface language picker and its preference, the Chinese keywords in the command registry, and the tests of Chinese labels and Chinese command search. Keep the `L10n` calls as a thin English lookup, so the change does not touch hundreds of call sites. Keep CJK, Pinyin and emoji text inside editor tests: the IME tests need it.

`NotoSansSC.ttf` (17 MB) goes too, **if** CJK text in a document still renders in the preview and in Writing mode through system fonts. The block engine already scans system fonts; step A checks Tinymist's font settings and the Phase 3 IME tests. If CJK text would draw as missing glyphs without the bundled font, the font stays and the note records why.

Spell check and command search then work in English only. The spell checker's language follows the system's spelling setting, as in other Mac apps.

**Step A outcome (2026-11-09): the font went.** Both engines search the system fonts: the block engine scans them (`fonts::system()` in `Engine/RenderBridge/src/engine.rs`), and Tinymist keeps its default `systemFonts: true`, because Prose sets neither `systemFonts` nor `--ignore-system-fonts`. macOS ships Simplified Chinese faces in the base system (`Songti.ttc` in `/System/Library/Fonts/Supplemental`, plus `Hiragino Sans GB.ttc` and `STHeiti` in `/System/Library/Fonts`). A Tinymist 0.15.8 export of `= 中文标题` and a Chinese paragraph, with no font path, embeds `STSong` and extracts the text intact. The same export with the Noto path added also picks `STSong`, so the bundled font was not even used when the system fonts were on. Only with `--ignore-system-fonts` does the CJK text fall back to Libertinus (missing glyphs), and Noto then appears as `NotoSansSC-Thin`, the variable font's default instance. Two tests now guard this: `blockRendererDrawsCJKTextWithSystemFontsAlone` (the block engine, no font directories: `中文` and `中中` draw different shapes, while with `fallback: false` they draw identical missing-glyph boxes) and `realTinymistRoundTrip` (the exported PDF embeds a non-Latin font). `PingFang SC` and `Noto Sans SC` left the welcome guide's and blank template's font lists. Typst's font search never found PingFang (it already warned "unknown font family: pingfang sc"), and Noto is no longer bundled; each family it cannot find adds that warning. `WelcomeTemplateTests` now fails on any such warning.

### 2. Focus is Writing mode plus view state

- `EditorMode.focus` becomes available. Entering Focus from Code enters Writing first, then applies the Focus state. The layout model, the engine and the fragments are the same objects.
- Entering Focus saves `sidebarVisible` and `layout`, hides the sidebar, and sets `layout` to `.writing` (editor only). Leaving Focus restores both exactly. The window keeps its size.
- **Choice.** `⌘0` (sidebar) and `⌘⇧P` (preview) in Focus leave Focus for Writing mode and then show the pane. Focus means nothing else is on screen; a pane next to it is Writing mode.
- `Esc` leaves Focus for Writing, but only when nothing else uses the key: no marked text, no open command panel, no completion or hover panel, no placeholder run, no checks popup. Those owners keep `Esc` as they have it now, and the editor's `cancelOperation(_:)` is the last stop.
- The title row shows only the breadcrumb and the status dot. **Choice:** the file name, the mode control and the buttons come back while the pointer is over the title row, so Focus can be left with the mouse.
- The status bar hides. It comes back while the pointer is within 34 pt of the window's bottom edge and hides again 1 s after the pointer leaves.

### 3. Measure and scale

- The spec asks for a 60-character measure and an 18 pt body. Writing mode draws the document's own font at 1.3 times its size, so "18 pt" cannot be literal for every document. **Choice:** Focus draws at the Focus scale, 1.3 times 18/16 = 1.4625, so text is 12.5 percent larger than in Writing mode. The Focus column is 60 times the average character width of New York at 18 pt, measured once from the font, and never wider than the pane minus 36 pt on each side. The engine renders at column width divided by the Focus scale. Step B records how many characters per line the two book fixtures get.
- Source (the active block and blocks that stay source) keeps the editor's text size. Changing it would restyle the whole storage, which on a book costs a full styling pass on each switch. **Choice**, open to review.
- Entering or leaving Focus changes the width and scale, so the viewport re-renders. The entry path is Writing's: hold swaps up to 100 ms for the viewport's renders, otherwise draw source and swap blocks in as they arrive, keeping the top line. Renders at Writing's width stay in the engine's cache, so switching back is quick.

### 4. The focus block and dimming

- The focus block is the active block, which Phase 3 already resolves from the caret's moving end and from marked text. While a selection made with the pointer exists, every block it touches is a focus block, so selected text is never dimmed.
- **Choice:** the unit is the block, not the sentence. A Typst paragraph is one block, so this is "the current paragraph" of spec Section 6. A list is one block. Sentence focus stays a later option, as the spec says.
- Dimming draws in the fragment. In Focus, `WritingFragment.draw(at:in:)` sets `context.setAlpha(0.45)` before it draws a paragraph that is not in a focus block, for every role: a rendered image, a pill, and source through `super.draw`. Nothing is written to the storage, the rendering attributes or the selection. Collapsed paragraphs draw nothing anyway.
- When the focus block changes, the controller calls `invalidateLayout(for:)` on the old and new focus blocks' ranges, the same call that swaps blocks. In Writing mode this already happens for rendered blocks, because the old block renders and the new one opens. Focus adds it for blocks that stay source (raw blocks, blocks over 400 lines, failed renders) and for pills. Phase 3 found that forcing a fragment to redraw without a layout invalidation is not reliable through public API, so dimming does not try that.
- The selection highlight in `drawBackground(in:)` is not dimmed. The caret is not dimmed.
- In dark appearance the same 45 percent applies to the light text colour; step C measures both appearances.

### 5. Typewriter scrolling

- In Focus, the editor keeps the caret line's vertical middle on the typewriter line, at 40 percent of the visible height from the top.
- The caret line comes from `TextKit2Geometry` in source, and from the glyph map's drawn lines inside a rendered block (Phase 3 rule: never TextKit's hidden lines there).
- It scrolls after every change of an empty selection that moves the caret line: typing, deleting, arrow keys, page keys, undo, and the `⌘J` and toolbar commands. A non-empty selection does not scroll the view, so the selection does not move under the pointer.
- **Choice:** a click scrolls the clicked line to the typewriter line with a 0.2 s animation. Keys and typing scroll at once, with no animation, in the same event as the change.
- Scrolling by the trackpad or the scroller is free. The next caret change brings the caret line back to the typewriter line.
- To let the first and last lines reach the typewriter line, Focus adds space above and below the text: the text container inset becomes 60 percent of the visible height top and bottom while Focus is on. Inset changes move the container, not its width, so no block re-renders.
- Every typewriter scroll keeps Phase 3's rule: swaps keep the top line in place. In Focus, the anchor is the caret line instead of the top line, so a swap above the caret does not move it off the typewriter line.

### 6. The floating toolbar

- A SwiftUI overlay at the bottom center of the editor pane, 16 pt above the bottom edge, radius 8 pt (spec Section 4.3), the panel colour with a hairline border, Phosphor Regular icons at 16 pt. It appears in Writing and Focus modes, never in Code mode or when the editor pane is hidden.
- Five actions, each the same call the `⌘J` panel makes:

| Button | Icon | Action |
|-|-|-|
| Text style | `text-aa` | Opens the command panel at the Text Style group (`enterGroup("style")`) |
| Table | `table` | `selectCommand` for `table`, which opens its parameter form |
| Equation | `function` | `selectCommand` for `equation` |
| Image | `image` | `selectCommand` for `image`, which opens its resource picker |
| Insert | `plus` | Opens the command panel at the Insert group (`enterGroup("insert")`) |

- The buttons never take keyboard focus. The editor stays first responder and the command uses the editor's selection at the moment of the click.
- Each button has an accessibility label and the same hover help as the panel entry, with its key path (for example `⌘J I T`).
- **Choice:** in Focus, the toolbar fades out while the user types and comes back when the pointer moves. In Writing mode it stays visible.
- The toolbar must not cover text: in Writing and Focus the text container gets 64 pt of bottom inset (Focus's typewriter inset is larger and covers it).

### 7. Spell check: what is checked

- A pure function in ProseCore, `SpellCheckRanges`, walks the syntax tree over a range and returns the checkable ranges. It keeps `text` nodes in markup, including markup inside headings, list items, `strong`, `emph`, and content blocks of function calls (`#footnote[...]`, `#emph[...]`, a figure caption in `[...]`).
- It skips raw text, equations and math, code (everything after `#` that is not a content block), strings, labels, references, links and URLs, comments, escapes, shorthands, and `#set`, `#show`, `#let`, `#import` and `#include` lines.
- **Choice, a change to the spec's wording.** Spec Section 5.3 says spell check skips "function call ranges". Skipping whole calls would skip footnotes and captions, which are prose. Phase 4 skips the code parts of a call (name, arguments, strings) and checks the markup in its content blocks. The spec changes with this step.
- Words with a digit, all-caps words of up to five letters, and words with an internal capital (camelCase) are not reported, as NSTextView's checker does by default.

### 8. Spell check: when it runs and where results live

- A main-actor model in ProseCore, `SpellCheckModel`, holds the misspellings for the open file, rebases them across each native edit (as `SourceStyler` rebases its runs), and asks a checker for the paragraphs that need it. The checker is a protocol; the app's implementation calls `NSSpellChecker.shared.requestChecking(of:range:types:options:inSpellDocumentWithTag:completionHandler:)` with `.spelling` only, off the main thread. Tests inject a scripted checker and timing.
- What runs: the paragraphs in and near the viewport when a file opens or the view scrolls, and the edited paragraph 300 ms after typing pauses. A misspelling that the caret is inside is not shown until the caret leaves the word, so a half-typed word is not marked.
- Results are cached per paragraph by the hash of its text, so scrolling back does not recheck.
- The whole book is never checked at once. **Choice:** "Check Document Now" (`⌘;` goes to the next misspelling) checks paragraphs forward from the caret until it finds one, in the background, and moves the selection to it.
- One spell document tag per open file, so "Ignore Spelling" lasts for that file's session, as in other Mac apps. "Learn Spelling" goes to the system dictionary.
- A setting, Edit › Spelling and Grammar › Check Spelling While Typing, turns it on and off for all documents. Default on.
- IME: while text is marked, no result is applied, as in Phase 3.

### 9. Spell check: how it draws

- In source (Code mode, the active block and blocks that stay source), the misspelled range gets the rendering attribute `.spellingState` with the spelling flag, through `RenderingAttributes`, so a full restyle keeps it. TextKit 2 draws the system's red underline for it. The storage does not change.
- **Risk to check first in step F.** That TextKit 2 draws `.spellingState` set as a rendering attribute by the app. If it does not, the fragment draws the underline for source too, from the line fragments' character positions, and Code mode installs the same fragment class.
- In a rendered block, the fragment draws the underline after the image, under the union of the misspelled characters' glyph boxes on each drawn line, at the bottom of the line's boxes. The pattern copies the system's dotted red underline at the fragment's scale. When a block's misspellings change, the controller calls `invalidateLayout(for:)` on the block's range.
- Dimmed blocks dim their underlines with them.
- Right-click on a misspelled word, in source or in a rendered block (mapped through the glyph boxes), puts the suggestions at the top of the editor's context menu, then "Learn Spelling" and "Ignore Spelling". A suggestion replaces the word through `insertText(_:replacementRange:)`, so it is one ordinary undoable edit.
- Accessibility: `accessibilityAttributedString(for:)` marks misspelled ranges with `NSAccessibility.AttributedStringKey.misspelled` (and the marked-misspelled key), so VoiceOver can announce them. The text it returns is still the source.

### 10. Performance and a scroll gate

What is known: Phase 3's book benchmark measures "scroll and draw" by scrolling 80 pt and then drawing the whole visible rectangle with `cacheDisplay(in:to:)`. In Writing mode on War and Peace that p95 is 43 to 54 ms against 3 to 13 ms in Code mode, because every frame redraws all bitmaps in view at high interpolation quality. A real frame with layer-backed text drawing may redraw only what changed, so the benchmark number is an upper bound, but no measurement says by how much.

Typewriter scrolling moves the view on every line change, so Focus makes scroll cost visible while typing. Phase 4 therefore:

- **Adds a measurement and a gate.** The book benchmark gets a Focus run (`PROSE_FOCUS_MODE=1`, which implies Writing). It times a *typewriter step*: one down-arrow or one Return, the typewriter scroll, layout and the draw of what the scroll exposed and changed, 60 times on each book. **Gate:** typewriter step p95 under 33 ms (two 60 Hz frames) in the instrumented debug build, with 16.7 ms recorded as the target. The existing typing, jump and paragraph gates apply to Focus as well.
- **Looks for the cost before fixing it.** Step D profiles the Writing-mode full-viewport draw. Candidates, in order: draw images with interpolation quality that matches their scale (they are already rasterized at 1.3 times the backing scale), keep a `CGImage` whose pixel data is already in the screen's format so drawing does not convert it, and cache each fragment's role (Phase 3 open item: `WritingLayout.role(forParagraph:)` costs grow with paragraphs built). No hard gate on the full-viewport draw; the goal is to halve it, and the result is recorded.
- Spell check must not break the typing gates: with spell check on, the typing p95, max and main-thread CPU gates hold in all three modes.

## How the work is split

As in Phase 3: the main session briefs each step to one Opus subagent with explicit checks, reviews the diff, reruns `bash scripts/lint.sh`, `scripts/build.sh release` and `PROSE_DISTRIBUTION=preview scripts/test.sh`, plus `scripts/benchmark-books.sh` when the step touches drawing, layout or scrolling, reverts the Sparkle pin in `Package.resolved`, commits with an outcome section in this note, and pushes `prose`. Agents run one at a time in this checkout.

| Step | Builds | Checks |
|-|-|-|
| A. English only | Decision 1 | All checks pass; no `zh-Hans` file, language picker or Chinese keyword remains (`git grep` over `Sources`, `Resources`, `Examples`, `scripts`); CJK text in a document still renders in Writing mode and in the preview, or the font stays with a recorded reason; IME tests still pass |
| B. Focus view state | Decisions 2 and 3: `setMode(.focus)`, pane save and restore, title row, status bar on hover, `Esc`, measure and scale, entry through Writing's path | Acceptance tests 1, 2, 5 and 6 |
| C. Dimming and typewriter | Decisions 4 and 5 | Acceptance tests 3 and 4 |
| D. Performance | Decision 10: Focus benchmark run with the typewriter gate; profile and fix the full-viewport draw; role cache | Acceptance test 15; benchmark on both books in Code, Writing and Focus |
| E. Toolbar | Decision 6 | Acceptance tests 7 and 8 |
| F. Spell check model | Decisions 7 and 8: `SpellCheckRanges`, `SpellCheckModel`, the checker protocol and the `NSSpellChecker` implementation, the setting; first, a check that TextKit 2 draws `.spellingState` set by the app | Acceptance tests 9 and 14; coverage of the new ProseCore files 90 percent or more |
| G. Spell check drawing and menu | Decision 9: source attribute, rendered underline, context menu, `⌘;`, accessibility | Acceptance tests 10 to 13; benchmark with spell check on |
| H. Gate and documents | Three full runs of the suite and the benchmark; spec Sections 3.2, 3.3, 5.3, 6 and 8, `docs/architecture.md`, `CLAUDE.md` phase table, writing guide, work log | All acceptance tests pass three runs in a row |

## Acceptance tests

UI tests are `extension WritingFlowTests`, on the real window, editor and engine. Each one also checks that the storage equals the source, that no attachment exists, that the undo stack is unchanged unless the test edits, and that TextKit 2 is still on.

**Focus**

1. `⌘3`, the Focus segment and the `modeFocus` command each enter Focus from Code and from Writing. The sidebar and preview hide, the window size does not change, and the column has the Focus width. Leaving with `⌘2` or `Esc` restores the sidebar and the layout that were there before, for all four combinations of sidebar shown or hidden and preview shown or hidden.
2. Entering and leaving Focus ten times leaves the storage, its attributes, the selection and the undo count identical. Rendered blocks in Focus have heights equal to the engine's height times the Focus scale.
3. Dimming: with `cacheDisplay`, the ink of a rendered block that is not the focus block, of a pill and of a source block that cannot render (a raw block) has 45 percent of the focus block's contrast against the page, within 3 percent, in light and dark appearance. Moving the caret into another block, including a raw block, moves the full contrast with it in the next draw. A pointer selection across three blocks draws all three at full contrast.
4. Typewriter: after each of 40 caret changes (down and up arrows through rendered and source blocks, Return, typing, delete, page down, undo, a toolbar command and a click), the caret line's middle is within 1 pt of 40 percent of the visible height, at the first and last lines of the file too. A trackpad scroll moves the view freely, and the next key brings the caret line back. Marked text does not trigger a swap during a typewriter scroll (Phase 3 rule).
5. `Esc` leaves Focus when nothing else owns it. With marked text, an open command panel, an open completion panel or an active placeholder, `Esc` does what it does now and Focus stays.
6. In Focus the title row shows the breadcrumb and the status dot; the mode control appears while the pointer is over the title row. The status bar is hidden and appears when the pointer is near the bottom edge.

**Toolbar**

7. The toolbar exists in Writing and Focus modes and not in Code mode. Each of the five buttons does what the same `⌘J` path does: the same `command.execute` or `enterGroup` record, and for `equation` and `table` (with the default parameters) the same text and selection as running the command from the panel.
8. After a click on a toolbar button the editor is still first responder, and with a selection, `Text style › Bold` wraps the selection. Each button has an accessibility label and help.

**Spell check**

9. `SpellCheckRanges` over a fixture with every skipped kind reports no range inside raw text, math, code, strings, labels, references, URLs, comments or context lines, and reports words in headings, list items, emphasis, strong text, footnotes and captions. Seeded random edits rebase misspellings to the same result as a fresh check.
10. A misspelled word in a source block gets the spelling underline (rendering attribute or fragment drawing, whichever step F chooses), and no characters or storage attributes change.
11. A misspelled word in a rendered block is underlined: red ink appears below its glyph boxes in `cacheDisplay`, and nowhere under correctly spelled words.
12. Right-click on a misspelled word in a source block and in a rendered block gives suggestions first. Choosing one replaces the word as one undoable edit; undo restores it. "Ignore Spelling" removes the underline for the file's session.
13. The accessibility attributed string of a range with a misspelling marks it as misspelled, and its string equals the source.
14. Typing before a misspelling moves its underline with it; correcting the word removes the underline after the pause; a half-typed word under the caret is not underlined.

**Performance**

15. The book benchmark runs in Focus mode on SICP and War and Peace and passes the existing gates and the typewriter step gate (p95 under 33 ms), with spell check on, as do the Code and Writing runs.

## Risks

- **`.spellingState` in TextKit 2.** Unknown whether TextKit 2 draws it when the app sets it as a rendering attribute. Step F checks this first; the fallback is drawing in the fragment.
- **Scroll cost.** Typewriter scrolling may expose the draw cost that Phase 3 measured only as an upper bound. Step D comes before the toolbar and spell check, so a fix is in place before more drawing is added. If the 33 ms gate cannot pass after a full attempt and one retry, I record the numbers and keep typewriter scrolling, with the gate recorded as missed, for Tehran to decide.
- **Width change on entry.** Entering Focus re-renders the viewport at a new width and scale. On a book the first entry may exceed the 100 ms budget and draw source first, as Writing's first entry does.
- **Memory.** A second width doubles the engine's cached vector results for blocks rendered at both widths. Step D records the app's peak in the Focus run.
- **`Esc` ownership.** Several parts of the app use `Esc`. Test 5 covers each owner.
- **Spell check on books.** `NSSpellChecker` on a 3 MB file is slow if run at once. Decision 8 checks the viewport and edits only.
- **Removing the font.** If CJK text in documents depends on `NotoSansSC.ttf`, removing it would break documents, not only the interface. Step A checks before it deletes.

## Step A outcome (2026-11-09)

- The Simplified Chinese interface is gone: both `zh-Hans.lproj` folders, the Chinese welcome template, cover and example, `AppLocalization.swift`, the language picker in Settings (the General tab now starts with Appearance), `AppLanguage` and its notification, the `language` field of synced preferences (old saved preferences that still carry it load without error), and every Chinese keyword in the command registry, Universe discovery, template and sample-book search, and the authoring guide catalog. `L10n.text` and `L10n.format` stay as an English lookup in `en.lproj`, so no call site changed.
- Two Chinese strings outside the interface files were translated: the MCP setup prompt (`MCPConnection.swift`) and one edit-range error (`TextEditing.swift`).
- `NotoSansSC.ttf` and its licence are removed, with the evidence in decision 1. `PingFang SC` and `Noto Sans SC` left the welcome guide's and blank template's font lists; `WelcomeTemplateTests` now fails on any "unknown font family" warning.
- Packaging and release scripts expect English only (`CFBundleLocalizations` is `en`; release notes have one `## en-US` section).
- Kept on purpose: the xiaohei authoring guide's Chinese example scenes (a guide for outside agents, not the interface), `docs/mcp-design.md` (a design record written in Chinese), CJK text in editor tests and in the War and Peace fixture.
- An incremental build kept a stale `zh-Hans.lproj` inside `.build/out/Products/*/Prose_ProseCore.bundle`. On another checkout, delete that bundle folder before building.
- Results (main-session rerun): 243 core and 173 app tests pass, coverage 88.59 percent; lint (0 violations) and the release build pass.

## Step B outcome (2026-11-09)

- Focus works. The segment, `⌘3`, the View menu item and the `modeFocus` command all enter it from Code or from Writing; from Code it goes through Writing mode's start, so the model, the engine and the fragments are the same objects. `EditorMode.isAvailable`, its "Arrives in a later version" help and the message "Focus mode arrives in a later version of Prose." are gone; the `modeFocus` command text lost its last sentence, and spec Section 3.2 lost its sentence about Focus arriving later.
- Panes (`Sources/Prose/FocusMode.swift`). A `didSet` on `Workspace.editorMode` saves `FocusPanes` (sidebar, layout) on entry, hides the sidebar and sets `layout` to `.writing`, and restores both exactly on exit, whatever ends Focus (a mode change or an engine failure). A change to `sidebarVisible` or `layout` while Focus is on ends Focus for Writing mode: the change stands and the other pane comes back as it was saved. Because this hooks the properties, it covers `⌘0`, `⌘⇧P`, the menu items, the `split`, `preview` and `outline` commands and any other code that shows a pane (a click in the preview, opening a folder project). Setting a pane to the value it already has (the `writing` command in Focus) keeps Focus. The window keeps its size in every case tested.
- **Addition.** The floating outline button (shown when the sidebar is hidden) also hides in Focus. It is a pane control, and a click on it would show the sidebar and end Focus.
- `Esc`. NSTextView has no `cancelOperation:`. Its `doCommandBySelector:` sends the command up the responder chain and beeps when nothing there performs it (checked with a scratch program and a breakpoint on `NSBeep`), so the brief's "NSTextView maps Esc to `complete:`" does not hold on this system. `ManuscriptTextView.cancelOperation(_:)` is now the last stop: in Focus without marked text it calls `setMode(.writing)`; otherwise it forwards up the responder chain and beeps, as before. The owners before it are unchanged: `WritingWindow.sendEvent` (the command panel through `handlePaletteKey`, the assistance popup, the checks popup), `ManuscriptTextView.keyDown` (hover, the completion panel through `handleTypingKey`, placeholders) and the input context for marked text. An override of `doCommand(by:)` would have kept NSTextView's dispatch, but SwiftLint's `prohibited_super_call` rejects its `super` call.
- Title row. `FocusTitleItem` hides the document title item and the actions item (mode control, export, preview toggle) with opacity 0, no hit testing and no accessibility while Focus is on and the pointer is not over the title row. The breadcrumb and status dot item is untouched. The toolbar is not rebuilt.
- Status bar. Outside Focus it sits below the panes as before. In Focus it is drawn over the bottom of the panes only while shown, so the text does not move when it appears. The message bar and the command panel stay in the window's column and work in Focus.
- Pointer. `FocusChrome` holds the state; `FocusPointerTracker` puts a tracking area (`.mouseMoved`, `.mouseEnteredAndExited`, `.activeAlways`, `.inVisibleRect`) on the window's frame view (the content view's superview) only while Focus is on, so the title row is covered. The title items show while the pointer's y is at or above `contentLayoutRect.maxY`. The status bar shows within 34 pt of the bottom edge and hides `hideDelay` (1 s; tests inject 150 ms) after the pointer leaves that strip or the window; coming back in time cancels the hide.
- Scale. `WritingMetrics.focusScale` = 1.3 × 18/16 = 1.4625. `WritingController.currentAppearance()` uses it for `scale` and `bitmapScale` (still capped by `RenderOptions.maximumBitmapScale`) while `focused`.
- Column. `ManuscriptLayout.focusColumnWidth` = 60 × the average character width of New York 18 pt (`.NewYork-Regular` through the `.serif` design), measured once from a sentence of running English (Dickens, spaces and punctuation included): 7.78 pt, so 467 pt. `horizontalInset(for:focus:)` gives that column, never wider than the pane less 36 pt on each side. The window's minimum width (820 pt) means the clamp never binds in Focus, where the editor fills the window. `ManuscriptTextView.focusColumn` sets the inset and keeps the top line as a resize does. The engine renders at 467 / 1.4625 = 319 pt. The source keeps the editor's text size; the storage is not restyled.
- Characters per line in Focus (window 1220 pt, glyph maps of rendered paragraph blocks, full lines only, a paragraph's last line excluded): **War and Peace 68 to 69** (medians at 30, 50 and 70 percent of the book; range 62 to 74); **SICP about 75** (medians 73 to 79 where the sample is mostly prose; SICP's paragraphs with inline code and footnotes make some samples noisy). Writing mode in the same window without the sidebar gives 143 and about 160. Both books get more than 60 because their body fonts are narrower than New York at 18 pt; the measure is fixed in points, not per document.
- Entry path. `WritingController.setFocus(_:)` begins an entry (keeping any swaps an unfinished entry was holding) and sends the new appearance. **Decision change (small).** `WritingLayout.setAppearance` now restates every block when the scale changes, and a block whose render has another scale draws source (`.source(.waiting)`) until it renders again; a new width or colour still keeps the old image until the new one arrives, as in Phase 3. Without this, a Writing image drawn at 1.3 would hang far outside the Focus column. `viewportReady()` now also requires renders made for today's appearance: SwiftUI lays out the panes on a later run-loop turn, so a Focus switch can change the column twice (leaving Focus with a sidebar in a 1220 pt window: 854 pt at full width, then 740 pt), and the hold waits for the final width. Changing the inset relays out the column at once, so in practice entry shows source for the blocks in view until their renders arrive (within the 100 ms hold on the test document), as Writing mode's first entry does.
- Tests. `Tests/ProseAppTests/FocusModeFlowTests.swift`, all `extension WritingFlowTests`: acceptance test 1 (eight runs: the three routes from Code and from Writing, the four pane combinations, leaving with `⌘2` and with `Esc`; window size, Focus column, render scale and width, heights within 0.5 pt of engine height × 1.4625), pane changes in Focus (`⌘0`, `⌘⇧P`, `preview`, `outline`, `writing`), acceptance test 2 (ten trips: text, attributed storage, selection, undo state, revision; two undos then remove both earlier edits and leave nothing to undo), acceptance test 5 (marked text, command panel, completion panel, placeholder and checks popup keep `Esc`; `Esc` in Writing mode keeps Writing mode) and acceptance test 6 (title row and status bar through the tracker's handlers, the tracking area added and removed). `writingLayoutDrawsSourceUntilANewScaleRenders` covers the model change. `newDocumentStartsInCodeAndTheWritingSegmentWorksWithoutADefault`, `nativeMenusDispatchToTheSameWritingWorkspace` and the project flow test now expect Focus to work.
- Results: 244 core and 178 app tests pass, coverage 88.70 percent; lint (0 violations) and the release build pass. The first full run had one failure in `lazyPagesRestoreBeforePaintingAndScrollingSupersedesRestoration` (the preview web view's page state timed out, in the parallel preview suite); it passed alone twice, and the full rerun passed. Book benchmark (Code / Writing): War and Peace typing p95 13.83 / 17.28 ms, scroll and draw p95 4.50 / 44.59 ms, peak 239 / 980 MiB; SICP typing p95 10.84 / 7.80 ms, scroll and draw p95 5.01 / 22.84 ms, peak 247 / 1,007 MiB; all gates pass.
- Open items: no Focus run in the book benchmark yet (step D adds it with the typewriter gate). Entry time and memory on a book in Focus are not measured. The title items' hiding is tested as `FocusChrome` state, not as pixels: SwiftUI applies a published change on a later turn, and the toolbar's hosting views are not drawn by `cacheDisplay`. Real pointer events are not tested (posted events end the test process). Spec Section 6 still says "Measure narrows to 60 characters. Body size rises to 18 pt"; step H rewords it along decision 3.
- Main-session rerun: lint (0 violations) and the release build pass; 244 core and 178 app tests pass, coverage 88.69 percent, except `lazyPagesRestoreBeforePaintingAndScrollingSupersedesRestoration`, which failed once more in the parallel preview suite (its page reported `visibility: hidden`, as an occluded window does) and passed alone three times and in two more full runs. So it failed in 2 of 4 full runs after step B, and passed in every Phase 3 gate run and in step A. **Open item:** if it fails again in a later step, find whether a `WritingFlowTests` window covers the preview test's window. Book benchmark, all gates pass (Code / Writing): War and Peace typing p95 14.73 / 12.40 ms, scroll and draw p95 9.00 / 43.67 ms, peak 240 / 976 MiB; SICP typing p95 6.46 / 7.51 ms, scroll and draw p95 4.95 / 17.69 ms, peak 249 / 1,027 MiB.
