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

The segmented control at the top right switches the center column. The sidebar and the preview pane do not change.

| Mode | What the center column is | Built from |
|-|-|-|
| Code | Plain source with LeftBlank's current styling: heading sizes, strong, emphasis, raw, semantic colours, every marker visible | Exists today in LeftBlank |
| Writing | Rendered blocks. Headings, paragraphs, lists, equations, figures and tables are drawn as typeset fragments from the real engine. The block that holds the caret shows its source. | New: Section 5 |
| Focus | Writing mode with the sidebar and preview hidden, a narrower measure, the current paragraph at full contrast and other paragraphs dimmed, a fixed typewriter scroll position | New, mostly view state |

Shortcuts: `⌘1` Code, `⌘2` Writing, `⌘3` Focus. `⌘⇧P` toggles the preview pane. `⌘0` toggles the sidebar. `⌘J` keeps command discovery. The mode is saved per document.

### 3.3 Window anatomy

Three columns, left to right, in a single `NSSplitView` under a `unifiedCompact` toolbar.

**Sidebar (240 to 320 pt, Things look).** Search field at the top. Below it, a project tree rooted at the project folder. Folders collapse. The active `.typ` file is expanded one level further to show its outline from Tinymist `documentSymbol`, indented under the file row. Clicking an outline row scrolls the editor and the preview. The main compilation entry carries a small pin mark. A `+` button at the bottom creates a file or folder. Right-click gives rename, reveal in Finder, set as main entry, delete.

**Title row.** File name in bold with the project name in muted text under it. Center: a breadcrumb built from the heading ancestors of the caret position, then a status dot. Green means the last compile succeeded and matches the buffer. Amber means compiling. Red means the last compile failed and the preview is stale. Clicking the dot opens the diagnostics list. Right: mode control, info button (word count, reading time, compile time, fonts in use), export button (PDF, and the share sheet), preview toggle.

**Center column.** The editor in one of the three modes. Measure is 65 to 72 characters at 16 pt body, centered, with the same margins LeftBlank uses now. The floating toolbar sits 16 pt above the bottom edge, centered, and only appears in Writing and Focus modes. It has five actions: text style (`Aa`), table, equation (`f(x)`), image, and `+` for the full insert catalog. Each action is a `⌘J` command, so the toolbar is a second entry point to the same registry, not a second implementation.

**Preview pane (optional, 320 pt minimum).** LeftBlank's existing `WKWebView` preview with one visual change: pages are drawn as white cards with a 14 pt radius on the Intent page-grey canvas, with 24 pt gaps and the page number under each card. Zoom and fit controls stay in the pane header.

**Status bar.** LeftBlank's existing 30 pt bar: command discovery hint on the left, save state, compile state, word count and caret position on the right.

### 3.4 Project model

LeftBlank has one active buffer and a library of single documents. The target app has a folder-based project. The change:

- A project is a folder on disk that contains at least one `.typ` file. The library gains a "Projects" section beside "Documents". Opening a folder from Finder or the Open dialog creates the project entry.
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

Caching: results are keyed by (file, block source hash, state hash, width). An edit inside one paragraph re-renders that paragraph. An edit to a `#set` line re-renders everything after it. Renders run on a background actor and the main thread never waits.

Failures: a block that fails to compile stays as source with LeftBlank's existing error styling. The rest of the document keeps rendering. A full-document compile failure marks all fragments stale (a thin amber bar at the left edge) but leaves them visible.

### 5.3 Editor integration (Swift)

The hard part is not rendering. It is keeping native selection, undo, IME and accessibility correct while most of the text is not drawn as text. LeftBlank's removed layer used `NSTextAttachment` and concealed text, and the post-mortem lists why that failed. The replacement:

- The text storage stays the full source at all times. No hidden characters, no attachments, no substituted display text. This is the invariant LeftBlank keeps now.
- Rendering happens in the TextKit 2 layout layer, not the storage. A custom `NSTextLayoutFragment` subclass draws the engine's SVG for a block and reports the engine's height. The source characters of that block still exist in the storage, so `NSRange` positions, find, undo, copy and VoiceOver's text model are unchanged.
- The block containing the caret uses the default fragment, so it lays out as styled source exactly as Code mode does. Moving the caret out of a block swaps its fragment back to the rendered one after the engine replies. Moving the caret in swaps it to source at once.
- Clicking inside a rendered fragment maps the click to a source offset through the glyph rectangles the engine returned, places the caret there, and the block opens as source. If the mapping has no rectangle at that point, the caret goes to the block's start.
- Selection across rendered blocks draws the system selection colour over the fragment's bounds. Copy produces source text.
- IME: while text is marked, the active block never swaps and no fragments are replaced.
- Accessibility: each rendered fragment exposes the block's source as its accessibility value. VoiceOver reads the source, which is readable Typst, not SVG.

Spell check uses `NSSpellChecker` on the source storage with the engine's glyph rectangles to draw the red underline under the rendered word. Spell check skips code, math, raw and function call ranges using the syntax tree.

### 5.4 What Writing mode does not do in version one

- Tables and figures render but are edited as source. No cell editing in place.
- No drag-to-reorder of blocks.
- Code blocks render as source with Highlight.js colours, the same as Code mode.
- `#set` and `#let` lines are shown as a collapsed grey pill with the first 60 characters; clicking opens them as source. They never render as blank space.

## 6. Focus mode

Focus is Writing mode plus view state:

- Sidebar and preview collapse. The window keeps its size.
- Measure narrows to 60 characters. Body size rises to 18 pt.
- The paragraph holding the caret is at full contrast. Other blocks draw at 45 percent opacity. Sentence-level focus is a later option.
- Typewriter scrolling keeps the caret line at 40 percent of the view height.
- The title row collapses to the breadcrumb only. The status bar hides and reappears on hover at the bottom edge.
- `Esc` leaves Focus mode and returns to Writing.

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
| 5. Polish | Info popover, export sheet, per-document mode memory, screenshots, writing guide update | Low |

Phase 3 has a kill switch: if the acceptance tests for selection, undo, IME or VoiceOver cannot pass, Writing mode ships as a read-only rendered view (click to jump to the source in Code mode) and the floating toolbar still works. That is still more than Edist offers, and it is honest.

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
