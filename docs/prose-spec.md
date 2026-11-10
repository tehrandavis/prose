# Prose: a WYSIWYG Typst writing app built on LeftBlank

Date: 2026-11-08
Status: accepted 2026-11-08 (decisions in Section 9)
Inputs: one Reddit screenshot of an unreleased app, the Reddit thread, the LeftBlank repository (`tehrandavis/leftbank`, mirror of `leftblank-app/leftblank`), and the Intent planner source (`~/dev/Cadence`).

## 1. Evidence boundary

No binary exists. The author says the app is "not even released." REA tools had nothing to open, so this spec is built from three kinds of evidence:

| Kind | Source | How to read it |
|-|-|-|
| Observed | The screenshot and the author's own words in the thread | Fact about the target app |
| Observed | LeftBlank docs and source at the cloned commit | Fact about our starting point |
| Observed | Intent theme files (`Theme.swift`, `ThingsLook.swift`, `PanelCard.swift`) | Fact about our design language |
| Inferred | Everything about how the target app works internally | A design proposal, not a claim |

What the author stated: standalone local Typst editor, Swift app, custom Rust engine that renders source "into a word-like document," a Focus mode that looks like iA Writer, inspiration from Bear, Lettera and iA Writer, closed source, engine may be open-sourced later.

What the screenshot shows (reading left to right):

- A light sidebar with a search field, a project tree (`Thesis_Document` with folders `Feedback`, `figures`, `sections`, `Thesis example`, and files `main.typ`, `main.pdf`, `results.pdf`, `references.bib`, `template.typ`), and the outline of the active file nested under it (`2 Method`, `2.1 Participants`, down to `2.4.2 Adaptive staircase`, which is selected and blue). A `+` button sits at the bottom.
- A title row with the file name in bold, the project name under it, a breadcrumb in the center (`Method › Procedure › 2.4.2 Adaptive staircase`) followed by a green dot, and on the right a three-way segmented control `Code | Writing | Focus`, an info button, an export button, and a blue preview-toggle button.
- A center column that is rendered prose, not source: serif body text, numbered display equations, inline math set as math, red spell-check underlines, and a small floating toolbar at the bottom edge with `Aa`, a table icon, `f(x)`, an image icon, and `+`.
- A right column of paginated preview pages drawn as white cards on a grey canvas, with page numbers.

Everything below the heading "Proposal" is inferred or chosen by us.

## 2. Why build on LeftBlank

LeftBlank already has what the target app would need underneath:

- A native AppKit `NSTextView` editor on TextKit 2 with one `SourceStyler`, incremental typst-syntax parsing through a C ABI (`Engine/SyntaxBridge`), and semantic colours from Tinymist.
- Tinymist 0.15.8 as a child process for diagnostics, completion, outline, hover, code actions and PDF export.
- A `WKWebView` preview with source-to-preview and preview-to-source navigation.
- The `⌘J` command discovery panel, atomic save, recovery, document history, a library with iCloud sync, and a test suite with an 80 percent coverage gate.

LeftBlank also tried and removed the thing the target app is selling. The visual layer (concealed markup, chips, inline typeset equations, image boxes) shipped on 2026-10-07 and was removed on 2026-10-09 because it was inconsistent, AppKit kept drawing placeholder icons over attachments, and the result was not pretty. The lesson is recorded in `docs/visual-editing.md` and `docs/editor-rendering.md`: do not build a second approximate renderer; use the real Typst engine for fragments, cache by revision, reveal source on caret entry, and gate the feature on selection, IME, undo and accessibility tests.

That record is the main design constraint for this spec. The "Writing" mode has to be built the way LeftBlank's own post-mortem says, not the way the removed layer was built.

## 3. Proposal

### 3.1 Positioning

A local, native macOS Typst editor for long academic documents (thesis, article, book) with three ways to look at the same source file. It is LeftBlank's engine and discipline with a project sidebar and a rendered writing surface. The app stays source-first: the `.typ` file on disk is always the truth, and nothing in the rendered view can produce text that is not in the source.

The app is named **Prose**. The icon is an italic serif P with a blue text caret on a white tile with a blue wave at the bottom right (`Brand/Prose/icon-1024.png`).

### 3.2 Three modes

The segmented control at the top right switches the center column. In Code and Writing mode the sidebar and the preview pane do not change. Focus hides them and restores them when it ends.

| Mode | What the center column is | Built from |
|-|-|-|
| Code | Plain source with LeftBlank's current styling: heading sizes, strong, emphasis, raw, semantic colours, every marker visible | Exists today in LeftBlank |
| Writing | Rendered blocks. Headings, paragraphs, lists, equations, figures and tables are drawn as typeset fragments from the real engine. The block that holds the caret shows its source. | New: Section 5 |
| Focus | Writing mode with the sidebar and preview hidden, a narrower column at a larger scale, the current block at full contrast and other blocks dimmed, and typewriter scrolling | Writing mode plus view state: Section 6 |

Shortcuts: `⌘1` Code, `⌘2` Writing, `⌘3` Focus. `⌘⇧P` toggles the preview pane, and `⌘⌥P` fills the window with the preview for reading. `⌘0` toggles the sidebar. `⌘J` keeps command discovery. The mode is saved per document. (Until Phase 6, every document opens in Code mode. LeftBlank's `⌘4` outline pin is gone, because the sidebar holds the outline.)

### 3.3 Window anatomy

Three columns, left to right, in a single `NSSplitView` under a `unifiedCompact` toolbar.

**Sidebar (240 to 320 pt, Things look).** Search field at the top; it filters files by name (content search is later work). Below it, a project tree rooted at the project folder. Folders collapse. The active `.typ` file is expanded one level further to show its outline from Tinymist `documentSymbol`, indented under the file row. Clicking an outline row scrolls the editor and the preview. The main compilation entry carries a small pin mark. A `+` button at the bottom creates a file or folder. Right-click gives rename, reveal in Finder, set as main entry, delete.

**Title row.** File name in 14 pt semibold (15 pt does not fit two lines in the compact toolbar) with the project name in muted text under it. Center: a breadcrumb built from the heading ancestors of the caret position, then a status dot. Green means the last compile succeeded and matches the buffer. Amber means compiling. Red means the last compile failed and the preview is stale. A hollow grey dot means Tinymist is not running. Clicking the dot opens the diagnostics list. Right: mode control, info button (word count, reading time, compile time, fonts in use), export button (PDF, and the share sheet), preview toggle.

**Center column.** The editor in one of the three modes. Measure is 65 to 72 characters at 16 pt body, centered, with the same margins LeftBlank uses now. The floating toolbar sits 16 pt above the bottom edge of the editor pane, centered, with an 8 pt radius, the panel colour, a hairline border, no shadow and Phosphor Regular icons at 16 pt. It appears only in Writing and Focus modes, never in Code mode or when the editor pane is hidden. It has five actions, and each one makes the same calls as its `⌘J` path, so the toolbar is a second entry point to the same registry, not a second implementation:

| Button | Icon | `⌘J` path | What it does |
|-|-|-|-|
| Text style (`Aa`) | `text-aa` | `⌘J → s` | Opens the command panel at the Text Style group |
| Table | `table` | `⌘J → i t` | Opens the table form |
| Equation (`f(x)`) | `function` | `⌘J → i e` | Inserts an equation at the caret or around the selection |
| Image | `image` | `⌘J → i i` | Opens the resource picker |
| Insert (`+`) | `plus` | `⌘J → i` | Opens the command panel at the Insert group |

The buttons are AppKit views that refuse first responder, so a click leaves the editor its keyboard focus and the command reads the selection as it was at the click. Each button has an accessibility label and hover help with its `⌘J` path. Full Keyboard Access does not reach the buttons; the `⌘J` paths are the keyboard route. In Focus mode the toolbar fades out while the user types and comes back when the pointer moves; in Writing mode it stays visible. So that the last line can scroll above the toolbar, the editor keeps at least 64 pt below the text in Writing and Focus modes. The toolbar still covers the text under it in the middle of a document, as any overlay does.

**Preview pane (optional, 320 pt minimum).** LeftBlank's existing `WKWebView` preview with one visual change: pages are drawn as white cards with a 14 pt radius and Intent's `PanelCard` shadow on the page-grey canvas, with 20 pt of canvas on each side. Zoom and fit controls stay in the pane header. Tinymist's renderer places pages about 7 pt apart and the gap is not configurable, so the 24 pt gaps and per-card page numbers in the first draft are not possible; the pane header shows the current page instead (decided in Phase 1, 2026-11-08).

**Status bar.** LeftBlank's existing 30 pt bar: command discovery hint on the left, save state, compile state, word count and caret position on the right.

### 3.4 Project model

LeftBlank has one active buffer and a library of single documents. The target app has a folder-based project. The change:

- A project is a folder on disk, opened in place with File → Open Folder (`⌘⌥O`). Prose never copies it into the library, so Git and folder sync keep working, and nothing is written into the folder: recent folders, their main entries, folds and Zotero links (Section 5.5) live in `Application Support/Prose/Projects/recent.json`, with security-scoped bookmarks in the sandboxed edition. The library home lists recent folders above documents. A library document shows its own folder in the same sidebar, with its main entry fixed by the library.
- The project remembers its main entry (`main.typ` by default, or the only `.typ` file). All compilation, preview and export use the main entry. Editing `sections/method.typ` previews the whole thesis, and preview-to-source jumps land in the right file. LeftBlank already preserves the main entry when navigating into included files, so this is an extension of existing behavior, not a rewrite.
- One editing buffer at a time still holds. Switching files in the sidebar saves and swaps the buffer. A tab strip is out of scope for the first version.
- `.bib`, `.pdf`, `.png`, `.svg` and other non-Typst files appear in the tree. `.bib` opens in Code mode as plain text. Images and PDFs open in Quick Look.

## 4. Design language

Take surfaces, type and spacing from Intent's current theme (`ThingsLook` for the sidebar and page, `AppTheme` for spacing and radius) and the status bar, command panel and editor conventions from LeftBlank.

### 4.1 Colours

| Role | Light | Dark | Source |
|-|-|-|-|
| Sidebar | `#F5F5F7` | `#1A1A1A` | `ThingsLook.sidebar` |
| Page (editor and preview canvas) | `#FFFFFF` | `#262626` | `ThingsLook.page` |
| Preview page card | `#FFFFFF` on canvas `#F5F5F7` | `#2F2F2F` on canvas `#1A1A1A` | Things 3 dark raised surface |
| Hairline | `#E5E2DD` | `#464646` | `AppTheme.Light.border`, Things dark hairline |
| Primary text | `#1A1918` | `#E8E4DE` | `AppTheme` |
| Secondary text | `#68635E` | `#9C968D` | `AppTheme` |
| Accent (selected sidebar row, status dot ring, links) | `#7C2494` dusk violet | `#B784E0` | `ThingsLook.Brand.violet` |
| Selected sidebar row fill | violet at 10 percent | violet at 22 percent | `ThingsLook.selection` |
| Hover | black at 4 percent | white at 5 percent | `ThingsLook.hover` |
| Compile OK, warning, error | `#5CB85C`, `#E8A838`, `#E25555` | same | `AppTheme` |
| Error and success text | `#C62828`, `#2E7D32` | `#EF7A7A`, `#6CC86C` | Derived in Phase 1: the compile colours are under 4.5:1 as text |

The screenshot's selected outline row and preview toggle are system blue. We use dusk violet instead so the app matches Intent. Syntax colours in Code mode stay LeftBlank's Nano-derived set.

### 4.2 Type

| Use | Font | Source |
|-|-|-|
| Rendered body in Writing and Focus | Whatever the document's `#set text(font:)` resolves to; fallback New York at 16 pt | The engine, not the app, chooses this |
| Code mode | System monospaced for code, system sans for prose, as LeftBlank does now | LeftBlank |
| Sidebar rows | System 13 pt | `ThingsLook.rowFont` |
| Sidebar group headers | System serif 13 pt semibold | `AppTheme.Font.subheadline` |
| Title row file name | System 15 pt semibold | new |
| Counts and shortcuts | System 11 pt medium, monospaced digits | `ThingsLook.countFont` |

The rendered writing surface uses the document's own fonts. This is the point of the mode: the text looks like the page because it is set by the same engine.

### 4.3 Shape and spacing

- Radius 14 pt for cards and preview pages, 8 pt for pills and the floating toolbar, from `AppTheme.Radius`.
- Spacing scale 6, 10, 14, 20, 28, 32 from `AppTheme.Spacing`.
- No shadows on panels except the preview page cards, which use Intent's `PanelCard` shadow (black at 4 percent, radius 8, y 2).
- Icons: Phosphor Regular at 16 to 18 pt. LeftBlank enforces this with a SwiftLint rule that rejects SF Symbols in app sources. Intent uses SF Symbols. Keep Phosphor here, because fighting the lint rule costs more than the visual gap, and Phosphor has every icon the toolbar needs.

## 5. The Writing mode engine

This is the one genuinely new piece, and the one the target app's author wrote in Rust. The design follows LeftBlank's own stated direction in `docs/editor-rendering.md`.

### 5.1 What a rendered block is

A block is one top-level markup node from the typst-syntax tree: a heading, a paragraph, a list, an equation, a raw block, a figure call, a table call, or a `#set`/`#let`/`#import` line. The engine renders each block to an SVG fragment with layout metadata. The editor shows the fragment in place of the source for every block except the one that holds the caret.

### 5.2 Engine (Rust, behind a C ABI)

A new crate `Engine/RenderBridge`, built and packaged the same way `Engine/SyntaxBridge` is, linked as a static library into the app. It links the `typst` crate at the pinned version Tinymist 0.15.8 uses (Typst 0.15.1), so Writing mode and preview agree on fonts, packages and layout.

Entry points:

| Call | Input | Output |
|-|-|-|
| `world_create` | Project root, main entry path, font directories | World handle |
| `world_update` | File path, full source text, revision | Nothing; marks dependents dirty |
| `render_blocks` | File path, revision, list of block UTF-16 ranges, measure width in pt, scale | Per block: SVG bytes, height, baseline of the first line, and a list of source spans to glyph rectangles |
| `free` | Handle | Nothing |

How a block is rendered with document context: the engine compiles the main entry once per revision to collect the `#set`, `#show`, `#let` and `#import` state in force at each block's position (the preamble up to that point, plus the enclosing file's rules). It then compiles the block alone inside a page of the requested width with that state applied, and exports the result as SVG. Heading numbers, equation numbers, figure numbers and citation keys come from the full compile's introspection, so `(2)` in the screenshot is the real equation number, not a count the editor made up.

References: a block rendered alone cannot resolve a label outside it. The engine reads what each reference displays from the full compile (the text inside the reference's link) and gives the block document a stub label and a `show ref` rule with that text. Counter values and reference texts come from the last full compile, so typing inside a paragraph re-renders that block without waiting for a new full compile (measured in the Phase 2 spike, `docs/plans/2026-11-08-phase-2-engine-spike.md`).

Built in Phase 2 (2026-11-08): `Engine/RenderBridge` exposes the table `prose_render_api()` (`Sources/ProseRenderFFI/include/ProseRender.h`), and ProseCore wraps it in the `BlockRenderer` actor. The calls are `engine_create`, `set_text`, `refresh`, `blocks`, `render` and `cache_stats`, with UTF-16 offsets throughout. On SICP a block renders in 0.48 ms (median, first time) and 0.003 ms from the cache. The engine evicts Typst's memo caches after each refresh and every 128 compiled renders, which keeps a long session near 415 MB of heap; one full compile of a 450-page book needs about 775 MB on its own. See `docs/plans/2026-11-08-phase-2-render-bridge.md`.

Extended in Phase 3 step B (C ABI version 2, `docs/plans/2026-11-08-phase-3-writing-mode.md`): `blocks` covers the whole file, with the kinds heading, equation, paragraph, raw, list, context (`#set`, `#show`, `#let`, `#import` lines), include and comment. `render` takes options: a default text colour, set before the document's own rules so a document's own colours win, and a bitmap scale (replaced in C ABI version 5, below, by a dark flag). The page is transparent. The result reports the drawn area, the page together with ink that hangs past it, and the SVG and the optional premultiplied RGBA bitmap (`typst-render`) cover that area. The engine caches the vector result and the laid-out page, not bitmaps; the editor keeps the images it draws.

Extended in Phase 5 step A (C ABI version 3, `docs/plans/2026-11-09-citations.md`): `files_changed` takes the paths of files changed on disk. The engine reads every file it loaded from disk again on its next use (`FileStore::reset()`) and gives each changed file a new version, so cached renders that read it compile again; editor buffers keep their text and paths outside the project are ignored. It returns how many of the files the document read, so the editor refreshes only when something shown can have changed. Render results carry the block's plain text. Citations render in blocks: a block that cites, or holds the bibliography, gets every key the full document cites, in order, and the document's `bibliography(...)` call, placed and hidden, so its citation numbers and entries match the whole document.

Extended in Phase 5 step B (C ABI version 4, `docs/plans/2026-11-09-citations.md`): two calls for the citation picker's index, both returning JSON released with `string_free`. `bibliography_files` lists the bibliography files the project's `bibliography(...)` calls name, found in the syntax trees of the main file and the files it includes, depth first, with each path relative to the file that holds the call; only string literals and arrays of them count, and nothing is compiled. `bibliography_entries` parses a list of files with Hayagriva, as Typst's `bibliography` does (`.bib` as BibLaTeX, `.yml` and `.yaml` as Hayagriva YAML), reading them as a compile does (editor buffers win, `files_changed` makes them read again), and caches each file's parse by its version. Each entry has key, type, title, authors (family and given names; the editors when there are no authors), year, container title, DOI, URL, file and line. Errors carry file, line and message: a syntax error yields no entries from that file; a field Hayagriva cannot read is reported for its entry while the file's other entries are listed and the file is marked as not accepted, since Typst rejects the whole file; a key already listed from an earlier file is reported as a duplicate. When no call names a file, ProseCore's `BibliographyIndex` lists every `.bib`, `.yml` and `.yaml` file in the project tree instead and marks them as not linked.

Changed after Phase 5 (C ABI version 5, 2026-11-09, `docs/plans/2026-11-09-citations.md`): `PRRenderOptions` has a `dark` flag in place of the default text colour. A block renders with the document's own colours; in dark appearance the engine then maps every paint of the laid-out page (text fills and strokes, shape fills and strokes, gradient stops; never images, and not tilings) in OKLab before it makes the SVG and the bitmap. With `L` a paint's lightness, the new lightness is `L_text + (L_page - L_text) * L`, where `L_text` is the lightness of `#E8E4DE` and `L_page` that of `#262626`; the neutral axis maps onto the line between those two colours, so black ink becomes `#E8E4DE` and a white fill fades into the page. Hue is kept, chroma is scaled by `|L_text - L_page|` (about 0.66) and reduced further only to stay in sRGB, and alpha is kept. The flag is part of the cache key.

Caching: results are keyed by (file, block source hash, state hash, width). An edit inside one paragraph re-renders that paragraph. An edit to a `#set` line re-renders everything after it. Renders run on a background actor and the main thread never waits.

Failures: a block that fails to compile stays as source with LeftBlank's existing error styling. The rest of the document keeps rendering. A full-document compile failure marks all fragments stale (a thin amber bar at the left edge) but leaves them visible.

### 5.3 Editor integration (Swift)

The hard part is not rendering. It is keeping native selection, undo, IME and accessibility correct while most of the text is not drawn as text. LeftBlank's removed layer used `NSTextAttachment` and concealed text, and the post-mortem lists why that failed. The replacement, built in Phase 3 (`docs/plans/2026-11-08-phase-3-writing-mode.md`):

- The text storage stays the full source at all times. No hidden characters, no attachments, no substituted display text. This is the invariant LeftBlank keeps now. Entering or leaving Writing mode, a swap and a render result change nothing in the storage, the selection or the undo stack.
- Rendering happens in the TextKit 2 layout layer, not the storage. One `NSTextLayoutFragment` subclass serves every paragraph. It reads its paragraph's role (source, rendered, collapsed or pill) from the layout model when TextKit reads its frame or draws, and keeps it until the model's role revision changes, which every change of the blocks, every edit, and starting or stopping does (Phase 4 step D: TextKit reads several thousand frames per scrolled frame). A rendered block's first paragraph draws the block's image and reports the engine's height times 1.3. The block's other paragraphs are collapsed: they take no height and draw nothing. A swap is `invalidateLayout(for:)` over the changed range, with the top line kept in place. The source characters of every block still exist in the storage, so `NSRange` positions, find, undo, copy and VoiceOver's text model are unchanged.
- TextKit still lays out the source lines inside a rendered block. So the caret, the selection, hit testing and accessibility geometry there come from the engine's glyph boxes, never from TextKit.
- The main thread draws only bitmaps. Blocks render at the column width divided by 1.3 and draw at 1.3 times. The engine rasterizes them through `typst-render` at 1.3 times the screen's backing scale, on a transparent page whose drawn area includes punctuation that hangs past the measure. Drawing the engine's SVG on the main thread was correct but too slow for first display (about 38 ms for one SICP viewport in the spike). Because the bitmap scale is the drawing scale times the backing scale, an image's pixels match the device's one to one: it draws at its exact pixel size with its top-left corner on a device pixel and no resampling, which Core Graphics does several times faster than a resampled draw, and its pixels arrive as the engine made them. Only an image made for another scale, such as one kept across a change of display, is resampled.
- In dark appearance, the engine maps the document's own colours onto the dark page (Section 5.2, C ABI version 5): dark ink draws light, light fills fade into the page, rules and other strokes turn light, and images keep their pixels. The welcome guide's ink `#253238` draws as `#9FA6A7`, 6.1:1 against the page; its muted grey `#66736D` draws as `#727972`, 3.4:1, since mid greys map near the middle. The preview (Tinymist's WebKit view) is not mapped; it has its own dark reading.
- The active block uses the source role, so it lays out as styled source exactly as Code mode does. The active block holds the caret, or the moving end of a selection made from the caret with the keyboard. Moving the caret into a rendered block swaps it to source at once, in the same event. Moving the caret out swaps the old block back only after its render exists.
- Entering Writing mode waits up to 100 ms for the blocks in view, so the switch does not draw source block by block. When the renders take longer, as on a book's first full compile, it draws source and swaps blocks in as results arrive.
- Clicking inside a rendered fragment maps the click to a source offset through the glyph rectangles the engine returned, places the caret there, and the block opens as source. If the mapping has no rectangle near that point, or the nearest one is generated text such as a number, the caret goes to the block's start. Double-click selects the word under the pointer, and triple-click the block's source.
- Dragging extends the selection glyph by glyph across rendered blocks; the whole-block fallback was not needed. A drag that starts in a rendered block runs Prose's own tracking loop. A drag that starts in source stays with AppKit, whose tracking asks a replacement `NSTextSelectionNavigation` for positions inside rendered blocks.
- A non-empty selection made with the pointer (shift-click, drag, double-click, triple-click) opens no block, so text does not move under the pointer. When the keyboard extends such a selection, it still opens no block: up and down step through the drawn lines of rendered blocks, and line start and end use the drawn line.
- Keys from an empty selection land where Code mode puts them, because TextKit keeps the source line fragments, and the block they land in opens. Page up and page down move the caret about one viewport of drawn content.
- Selection across rendered blocks draws the selection colour over the selected glyph boxes, under the transparent images. NSTextView's own highlight is suppressed inside rendered blocks and pills, because it would draw the hidden source lines. The colour follows NSTextView's rule: the active colour while the window has key appearance and the editor is first responder, the system's inactive colour otherwise. Copy, cut and drag-and-drop write source.
- Undo and redo work as in Code mode. NSTextView does not move the caret on undo, so a block whose text an undo changes draws source until its new render arrives, and opens only if the caret is in it.
- IME: while text is marked, no block swaps and no render result is applied; results wait until the composition ends. One exception: a block whose text the composition itself changes opens at once and stays active until the composition ends. This covers a composition that replaces a pointer selection inside a rendered block. The candidate window rectangle lies on the caret's line.
- Accessibility: the editor's value, its strings for ranges, its lines and its insertion point are the source, as in Code mode. VoiceOver reads the source, which is readable Typst. An accessibility line is a line of the source layout, so line numbers do not change when a block swaps. The frame of a range in a rendered block is the union of its glyph boxes, and a point maps to a character through the glyph boxes, as a click does.
- One block engine (`BlockRenderer`) serves each open project. It is created the first time Writing mode is used, for the project root and main entry, and the open file's buffer goes in through `setText`, so an included chapter renders with the main file's rules and numbers. Switching files in the project keeps it; switching projects or closing the window frees it. Project files that change on disk reach it once a burst of changes pauses for 300 ms: Typst files through `setText`, every file through `files_changed`, and a refresh follows when the document read any of them (Phase 5 step A). Tinymist reads changed files itself, with its own watcher, so the preview and the PDF need nothing from Prose.
- Writing mode is available to everyone from 2026-11-09. A document opens in Code mode; per-document mode memory is Phase 7.

Spell check (built in Phase 4) uses `NSSpellChecker` on the source text and works in every mode. NSTextView's own spell checking stays off, because it would check code and math.

- What it reads. Through the syntax tree it reads only prose: the text of markup, including headings, list items, strong and emphasis, and the content blocks of function calls (footnotes, `#emph[...]`, figure captions). It skips code (a call's name, arguments and strings), math, raw text, strings, labels, references, links, comments, escapes, shorthands and `#set`, `#show`, `#let`, `#import` and `#include`. The first draft of this spec skipped whole function calls; Phase 4 changed that, because footnotes and captions are prose. It does not report words with a digit, all-caps words of up to five letters, or words with a capital after a small letter, as NSTextView does. A word that markup cuts with no space, such as `#emph[un]believable`, is not checked.
- When it runs. It checks the paragraphs in and near the viewport when a file opens or the view scrolls, and the edited paragraph 300 ms after typing pauses. It never checks a whole book at once. Results are kept per paragraph by its text, so scrolling back does not check again. Misspellings move with the text across edits. A misspelling that holds the caret is not shown until the caret leaves the word, so a half-typed word is not marked. While text is marked, no result is applied. Every call to `NSSpellChecker` starts on the main thread and uses its asynchronous request; the parse that finds the checkable ranges runs off the main thread.
- How it draws in source. In Code mode and in source blocks, the misspelled range gets the rendering attribute `.spellingState` through `RenderingAttributes`, so a full restyle keeps it, and TextKit 2 draws the system's dotted red underline. The storage never holds it.
- How it draws in a rendered block. After the image, the fragment draws a copy of the system's dotted underline under the misspelled range's own glyph boxes on each drawn line, never under generated text. Its dot size, spacing and colour were sampled from the system's underline. The engine's boxes carry no baseline or font size, so the fragment estimates both from the box height. A dimmed block in Focus dims its underlines with it. A block drawn as a pill shows no underline until it opens.
- The menu. A right-click on a misspelled word, in source or in a rendered block (mapped through the glyph boxes), puts its suggestions, or "No Guesses Found", at the top of the context menu, then Learn Spelling and Ignore Spelling. In a rendered block the right-click selects the word as a pointer selection, so the block stays drawn. A suggestion replaces the word through `insertText(_:replacementRange:)`, as one undo step. Ignore Spelling lasts for the file's session (one spell document tag per open file); Learn Spelling goes to the system dictionary.
- Edit › Spelling and Grammar › Check Document Now (`⌘;`) selects the next misspelling after the selection, checking forward in the background and wrapping once. With none, it beeps. In Writing mode the word's block opens; in Focus the word's line goes to the typewriter line.
- Accessibility. The editor's attributed strings for ranges mark every misspelling with `AXMisspelled`, and the underlined ones also with `AXMarkedMisspelled`, so VoiceOver can announce them. The text is still the source.
- One setting, Edit › Spelling and Grammar › Check Spelling While Typing (also in the Writing tab of Settings), covers all documents. It is on by default and stored on this Mac, not synced. The spelling language is the system's.

### 5.4 What Writing mode does not do in version one

- Tables and figures render but are edited as source. No cell editing in place.
- No drag-to-reorder of blocks.
- Code blocks render as source with Highlight.js colours, the same as Code mode.
- Setup lines and comments fold (Phase 6, `docs/plans/2026-11-09-quiet-writing-mode.md`). A run of `#set`, `#show`, `#let` and `#import` lines, comments and calls with no ink (`#v(7mm)`, `#pagebreak()`), with only blank lines between them, is one fold. A fold with a setup line draws as one quiet row, "Document setup · 16 lines" before the document's first rendered block and "Setup · N lines" later, with no fill. A fold with none draws as a small icon in the left margin and takes no height. A click on the row or the icon opens the fold as source, and a click on the icon beside its first line closes it. The caret opens a fold when it goes inside, past the first character, and the fold closes when the caret leaves. An edit inside a closed fold (undo, replace) opens it and keeps it open. The caret can rest on a closed row's first character without opening it; Up and Down stop there and then pass the fold, and pass a margin icon in one step. A selection across a closed row highlights the row, and copy gives the source. While text is marked, no fold opens or closes.
- An `#include` line is shown as a collapsed grey pill with the first 60 characters; clicking opens it as source.
- A block of more than 400 source lines stays source. SICP's index is one table of about 10,500 source lines; rendered, it made TextKit build every collapsed paragraph after the caret on one jump and broke the 5,000-paragraph gate.
- A block whose render fails stays source. A failed full compile draws a thin amber bar at the left edge of every rendered block and leaves them visible.

### 5.5 Citations

Built in Phase 5 (`docs/plans/2026-11-09-citations.md`). The `.typ` and `.bib` files on disk stay the only truth: the document compiles, previews and exports the same with Zotero closed or not installed.

- Reload from disk (C ABI version 3, step A). A bibliography file, a data file or an image that changes on disk reaches both engines with no edit in the document. The block engine gets the change through `files_changed` (Section 5.2) once a burst of changes pauses for 300 ms, and refreshes when the document read the file. Tinymist reads the change itself through its own watcher, for a file written in place and for one replaced by a rename. Writing mode shows the new text about 0.35 s after the write, and a PDF export about 0.22 to 0.24 s after it.
- Citations in Writing mode (step A). Before Phase 5 a citation in a rendered block showed `??` and the bibliography block showed only its title. A block that cites, or holds the bibliography, now gets a hidden copy of the document's citations: every key the full compile cites, in order, and the document's `bibliography(...)` call, inside `#place(hide[...])` with the bibliography's title off. Its citation numbers and entries then match the whole document, and the block's dependencies include the bibliography file. This works only when the `bibliography(...)` call is in the same folder as the block's file; otherwise citations show `??` in Writing mode, while the preview and the PDF are correct.
- The entry index (C ABI version 4, step B). The engine lists the files the project's `bibliography(...)` calls name, from the syntax trees, and parses them with Hayagriva as Typst does, returning JSON. `BibliographyIndex` (ProseCore) holds the entries and searches them by key, author, year, title, container and DOI. With no call, it lists every `.bib`, `.yml` and `.yaml` file in the project as not linked. A file Typst would reject is marked, and its readable entries still show.
- The picker (step C). **Cite a Source** (`⌘J R S`) opens a picker in the command panel with two tabs, **This Project** (`⌘1`) and **Zotero** (`⌘2`); Tab switches. Rows show the first author, the year, the title and the key. `Return` inserts `@key` at the caret, in markup only, as one undoable edit. A space goes before it after a word or another citation, and after it when the next character would join the key. A key that `@` cannot hold is cited as `#cite(label("key"))`. `⌥Return` asks for a page or section and inserts `@key[p. 4]`. When the document has no `#bibliography` call, the open file is the main file and the entry's file is not linked, the first citation offers to add the call at the end of the main file, as a second undoable edit. In Writing mode the full compile runs at once after an insertion, so a citing block never renders with `??`.
- The Zotero tab (steps D and E). Prose talks to Better BibTeX's JSON-RPC and Zotero's read-only local API on `127.0.0.1:23119`. A search waits 250 ms, sends the query's longest word (three characters or more) to Better BibTeX, and keeps the items that match every word in an author's family name, the title, the year or the key, at most 50. Choosing an item whose key a project bibliography file already has inserts only the citation. Otherwise Prose exports the item's BibLaTeX entry from Better BibTeX, appends it to `references-prose.bib` beside the main file, inserts the citation, and adds that file to the open file's `#bibliography` call as a second undoable edit. The file change is not undone with `⌘Z`. The window's message line confirms it and offers **Show in Zotero** (`zotero://select/library/items/<key>`). If Zotero is not running, or runs without Better BibTeX, the tab says so and This Project still works.
- The per-project link (step E). Prose cannot tell which file Better BibTeX exports automatically, so the writer links each project once: **Link to Zotero…** chooses the auto-exported `.bib` and the Zotero collection behind it. The link is stored with the project in `Application Support/Prose/Projects/recent.json`, never in the project folder. With a link, items in the collection come first and are marked. Prose never writes into the linked file or any bibliography file other than `references-prose.bib`.
- Deduplication (step E). Prose cannot add an item to a Zotero collection, so `references-prose.bib` keeps an entry until the automatic export brings its key into another linked file. After every index reload, Prose removes from `references-prose.bib` each entry whose key another linked file has, because Typst rejects a key defined twice, and keeps every other byte. An emptied file stays, and stays in the call.

## 6. Focus mode

Focus is Writing mode plus view state, built in Phase 4 (`docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`). The layout model, the engine and the fragments are Writing mode's own objects. The segment, `⌘3`, the View menu item and the `modeFocus` command enter it from Code or from Writing; from Code it goes through Writing mode's start.

- Panes. Entering Focus saves the sidebar and the preview layout, hides both, and restores both exactly when Focus ends, whatever ends it. The window keeps its size. Showing a pane while Focus is on (`⌘0`, `⌘⇧P`, a menu item, a command, a click that opens the preview) ends Focus for Writing mode, and the pane change stands: Focus means nothing else is on screen. The floating outline button hides in Focus too.
- Measure and scale. A literal 18 pt body is not possible, because Writing mode draws the document's own font at 1.3 times its size. So Focus draws rendered blocks at the Focus scale, 1.3 times 18/16 = 1.4625, which is 12.5 percent larger than Writing mode. The column is 60 times the average character width of New York at 18 pt (7.78 pt, measured once from running English), so 467 pt, and never wider than the pane less 36 pt on each side. The engine renders at 467 / 1.4625 = 319 pt. The measure is fixed in points, not per document: the book fixtures get 68 to 69 characters per line (War and Peace) and about 75 (SICP), because their body fonts are narrower than New York. Source (the active block and blocks that stay source) keeps the editor's text size, so the storage is not restyled.
- Entry. Entering or leaving Focus changes the width and scale, so the viewport renders again. A block whose render has another scale draws source until its new render arrives. Entry holds swaps for up to 100 ms, as Writing mode's does; on a book the blocks in view have their Focus renders after about 250 to 350 ms. Renders at Writing mode's width stay in the engine's cache.
- Focus blocks and dimming. The focus block is the active block. While a non-empty selection exists, every block it touches is a focus block, so selected text is never dimmed; for a keyboard selection the active block is one too. The unit is the block: a paragraph or a whole list. Sentence-level focus is a later option. Every other paragraph draws at 45 percent opacity, in the fragment: nothing changes in the storage, the rendering attributes or the selection. Source text and pills draw inside a transparency layer, so overlapping marks keep exactly 45 percent of their contrast. A dimmed rendered block draws a copy of its image with the opacity already applied, kept for the 32 most recently drawn images, because Core Graphics blends an image with a global alpha about 17 times slower than it copies one. The selection highlight and the caret are not dimmed. When the focus blocks change, only the paragraphs that changed sides are laid out again, through `invalidateLayout(for:)`, as a swap is.
- Typewriter scrolling. After every change of an empty selection (typing, deleting, arrow and page keys, undo, `⌘J` and toolbar commands, a click), the caret line's middle goes to 40 percent of the visible height. Keys scroll at once, in the same event; a click scrolls over 0.2 s (at once with reduced motion). A non-empty selection does not scroll the view. Trackpad and scroller scrolling are free, and the next caret change brings the caret line back. The text has 60 percent of the visible height above and below it, so the first and last lines reach the typewriter line. Swaps keep the caret line in place instead of the top line. When the visible height changes (a window resize, the command panel opening or closing) with the caret line in view, the caret line goes back to the typewriter line. Entering Focus keeps the top line; the first caret change moves the caret line.
- Folds (Phase 6). A closed setup row takes no height in Focus. It shows as a row while the caret rests on its first character and opens while the caret is inside. Up and Down pass a hidden row in one step. Margin icons stay and dim with the other blocks. A fold dims and undims as one unit.
- Title row and status bar. The title row shows only the breadcrumb and the status dot. The file name, the mode control and the buttons come back while the pointer is over the title row, so Focus can be left with the mouse. The status bar hides; it is drawn over the bottom of the text while the pointer is within 34 pt of the window's bottom edge, and hides 1 s after the pointer leaves.
- `Esc` leaves Focus for Writing mode only when nothing else uses the key. Marked text, the command panel, the completion and hover panels, placeholders, and the assistance and checks popups keep `Esc` as before; the editor's `cancelOperation(_:)` is the last stop.

## 7. Behaviors to keep from LeftBlank unchanged

- Atomic save, autosave, external-change detection, recovery, document history.
- `⌘J` command discovery and the insertion catalog, with Tab through placeholders.
- Tinymist diagnostics, completion, hover, signature help, code actions, go to definition.
- Preview-to-source and source-to-preview navigation, extended to project files.
- PDF export that never reports a stale PDF as new.
- Light, Dark and Match System, with preview dark reading independent of PDF output.
- MCP server for agent access to authoring guides.

## 8. Delivery plan

Each phase ends with the app usable and the coverage gate green.

| Phase | Scope | Risk |
|-|-|-|
| 0. Fork | Fork LeftBlank, rename bundle, replace icon and brand assets under the brand policy, swap the Nano palette for the Intent tokens in Section 4 | Low |
| 1. Shell | Project model, sidebar with tree and nested outline, title row with breadcrumb and status dot, mode control wired to Code only, preview page cards | Low. All existing services |
| 2. Engine | `Engine/RenderBridge` crate: world, per-block render with context, cache, SVG with glyph rectangles. Command-line test harness renders the SICP and War and Peace fixtures | Medium. Typst crate API changes between versions |
| 3. Writing mode | Custom layout fragments, caret-entry swap, click mapping, selection, copy, IME and VoiceOver acceptance tests before the mode is enabled by default | High. This is where LeftBlank's first attempt failed |
| 4. Focus mode and toolbar | Focus view state, floating toolbar bound to the command registry, spell check with syntax-aware skipping | Low |
| 5. Citations | Bibliography files reload from disk in both engines, a citation picker over the project's entries, Zotero through Better BibTeX with a linked auto-export per project (`docs/plans/2026-11-09-citations.md`) | Medium. Zotero endpoints unconfirmed until the spike (confirmed in step D) |
| 6. Quiet Writing mode | Setup lines and comments fold into one row or a margin mark; the open block draws in the document's font with faint markers; a spike, with pass marks, for typing in the rendered paragraph (`docs/plans/2026-11-09-quiet-writing-mode.md`) | Medium. The open block's fonts need an unverified TextKit 2 rebuild; the spike may end step 3 |
| 7. Polish | Info popover, export sheet, per-document mode memory, screenshots, writing guide update | Low |

Phase 3 has a kill switch: if the acceptance tests for selection, undo, IME or VoiceOver cannot pass, Writing mode ships as a read-only rendered view (click to jump to the source in Code mode) and the floating toolbar still works. That is still more than Edist offers, and it is honest.

Phase 3 was done on 2026-11-09. All 14 acceptance tests passed three full runs in a row, so the kill switch was not needed, and Writing mode is editable and on for everyone. Its main cost is memory: on a book in Writing mode the app peaks at about 1 GB, and the block engine's share is 650 to 710 MiB; Tinymist's footprint does not change. Scroll and draw p95 rises to as much as 43.5 ms in War and Peace (no gate), and entering Writing mode on a book takes up to 1.8 s, mostly the first full compile. See "Phase 3 outcome" in `docs/plans/2026-11-08-phase-3-writing-mode.md`.

Phase 4 was done on 2026-11-09. All 15 acceptance tests passed three gate runs in a row (269 core and 190 app tests each time, coverage 89.38, 89.42 and 89.41 percent, every benchmark gate in Code, Writing and Focus on both books). Focus mode, the floating toolbar and spell check work as Sections 3.3, 5.3 and 6 describe, and the Simplified Chinese interface was removed, so the app is English only. Phase 4 also made Writing mode's drawing cheaper: images draw at their exact pixel size on whole device pixels and each fragment keeps its role, which cut scroll and draw p95 in War and Peace's Writing mode from about 44 ms to 7 to 17 ms, depending on machine load. Costs: Focus adds 9 to 10 MiB to Writing mode's footprint, and on a book the app peaks at about 1,020 to 1,150 MiB in Focus, with the block engine's share 650 to 665 MiB. The book benchmark has a Focus run (`PROSE_FOCUS_MODE=1`) with a gate on the typewriter step (one Down arrow or Return, its typewriter scroll, layout and drawing): p95 under 33 ms in the instrumented debug build, with 16.7 ms as the target. Outside heavy load its p95 is 19 to 26 ms; Down steps meet the target and Returns do not, mostly in the edit path every mode shares and in SwiftUI layout after the selection change. Typing in Focus costs 3 to 5 ms more per key than in Writing mode. Benchmark numbers vary by a factor of two to three with machine load. See "Phase 4 outcome" in `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`.

Phase 5 was done on 2026-11-09. All 10 acceptance tests passed three gate runs in a row (291 core and 205 app tests each time, coverage 89.71 to 89.73 percent, every benchmark gate in Code, Writing and Focus on both books). Citations work as Section 5.5 describes: bibliography files reload from disk in both engines, citations and the bibliography render in Writing mode for the first time, the picker cites from the project's files, and the Zotero tab cites from the library through Better BibTeX, writing new entries only into `references-prose.bib`. Costs: `files_changed` takes under 0.1 ms on the engine thread on SICP, and reading the files again adds about 30 ms to the next refresh. On a document with 300 citations and 1,000 entries, a citing block renders in about 20 ms (median) and typing in it costs under 3 ms per key (p95). A Better BibTeX search takes 140 to 220 ms, and Zotero's local API about three times as long. A sandboxed App Store run against Zotero is not tested. See "Phase 5 outcome" in `docs/plans/2026-11-09-citations.md`.

## 9. Decisions (2026-11-08)

1. **Name and icon.** Prose. The icon source is `Brand/Prose/icon-1024.png`, a 1254 by 1254 PNG. LeftBlank's brand policy forbids reusing its names and artwork, so every LeftBlank name, mark and icon is replaced in Phase 0. The icon's caret blue is the only blue in the app; the accent in Section 4 stays dusk violet.
2. **Rendered body fonts.** As the spec says: the document's own fonts with a screen scale factor of 1.3, tested in Phase 3.
3. **Multi-file editing.** One buffer with a file switcher in the sidebar. No tabs.
4. **Engine packaging.** Decided after Phase 2 measurements on the book fixtures. Static library is the default.
5. **Engine licence.** The `Engine/RenderBridge` crate is written so it can be published on its own under MIT.

## 10. Residual unknowns about the target app

These stay unknown because there is no binary to inspect:

- Whether its rendered view keeps source in the text storage or replaces it.
- Whether its engine uses the `typst` crate or a custom layout.
- How it handles multi-file projects beyond what the sidebar shows.
- Whether the preview pane is Tinymist's web preview, a native PDF view, or its own renderer.
- What the info button and export button open.
