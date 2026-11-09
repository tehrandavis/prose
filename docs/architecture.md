# Prose architecture

The architecture prioritizes native input, maintainability, offline writing and reuse of Tinymist. Integrations follow the observed behavior of pinned versions rather than assumptions about undocumented protocols.

## Platform and packaging

- Swift 6.2 or later (Xcode 26 or later) and macOS 14 or later, with arm64 builds.
- Swift Package Manager separates core logic, the importable app library and a thin launcher so tests exercise production app code.
- AppKit owns windows, menus, dialogs and text editing; SwiftUI composes layouts, lists and command interfaces.
- Tinymist **0.15.8** is built from its pinned upstream commit with Prose's checked-in patches (macOS native TLS and a VFS revision fix) and bundled with every Mac edition. It contains Typst 0.15.1.
- typst-syntax 0.15.1 (the same Typst fork) is linked into the app as a static library behind a small C ABI ([parser bridge](visual-editing.md#parser-typst-syntax-through-a-c-abi)), carried by the engine library (`Engine/RenderBridge`).
- Prose is Mac only. The inherited iPad target was removed on 2026-11-08.
- The running app needs no Rust toolchain, Homebrew or separate Typst installation. Uncached external packages may require a network download; cached packages work offline.
- A small local set of Phosphor icons is bundled with its license.

## Data flow

```mermaid
flowchart LR
  User[Keyboard and command discovery] --> Editor[AppKit text editing]
  Editor --> Document[Document state and UTF-16 positions]
  Document --> Files[Atomic save and recovery]
  Document --> LSP[Swift LSP client]
  LSP <--> Tinymist[Tinymist child process]
  Tinymist --> Feedback[Diagnostics, completion and outline]
  Tinymist --> Preview[Local web preview]
  Preview --> WebView[WKWebView]
  Tinymist --> PDF[PDF export]
  Feedback --> Editor
```

## Document state and storage

There is one active editing buffer. Navigating from the main document into an included file preserves the main compilation entry; the child buffer is opened before the main file when synchronizing with Tinymist. Explicit opening or saving under a new name establishes a new entry.

Document state includes file URL, main URL, source, monotonic revision, selection, saved baseline and diagnostics. Untitled documents use an app-managed draft location. Changing location updates the resource root and LSP document identity.

Asynchronous results are checked against document revision, selection and service session. Compilation state comes from Tinymist notifications. Versioned diagnostics are filtered; some notifications in the pinned server omit a revision, so fast typing can briefly show the previous round's feedback. Diagnostics are not claimed to be perfectly synchronized with each keystroke.

Writes are atomic. Autosave checks the on-disk baseline first and stops when another application changed the file. Local work remains recoverable, with reload and save-as available. Shutdown flushes recovery data; unsaved text must not exist only in a view.

## Native editing

`NSTextView` and `NSScrollView` send small editing events to the workspace. Ordinary typing does not rebuild the view, replace the whole buffer or steal first responder.

Positions use Foundation `NSString` / `NSRange` UTF-16 units, consistent with the negotiated LSP encoding. Tests cover Chinese, emoji, combining characters, CRLF and end-of-document positions.

Full-buffer replacement is reserved for opening, external reload and deliberate formatting. Highlighting changes attributes without creating undo operations. Marked text delays styling and completion application. Insertion uses `NSTextView.insertText(_:replacementRange:)` and a single undo group. Because AppKit may create its undo manager only after the first edit, observation attaches at edit time and synchronizes workspace state after undo/redo completes.

Both editors are TextKit 2 views styled by one `SourceStyler` from `ProseCore` ([editor styles](visual-editing.md#the-editor-now)). `SourceStyleEngine`, an actor, mirrors the buffer in `SyntaxTree` (typst-syntax, incremental) and returns the heading, strong, emphasis and raw runs of the paragraphs each batch of edits reparsed; the main thread sets them as fonts on the text storage and never waits for it. The laid-out text is the source itself: no hidden characters, attachments or substituted display text (a visual layer that did that was removed on 2026-10-09). Semantic colours are rendering attributes, so a reply never re-lays out text.

Indentation and comments use text-range transformations. Formatting uses the real LSP response with revision, session and range validation.

## Project folders and the window shell

A project is a folder opened in place (`Workspace.openFolder`). `ProjectStore` remembers recent folders in `Application Support/Prose/Projects/recent.json`: path, bookmark (security-scoped when sandboxed), main entry and expanded folders. Nothing is written into the folder. `ProjectTree` lists children (folders first, Finder order, no hidden files or links), searches names and creates, renames and trashes items without leaving the root; trash uses `FileManager.trashItem`. When a project is open, `Workspace.open` sets the compilation entry to the project's main entry, so preview and export compile the whole document from any file. A file reopened after relaunch finds its folder in the recent list. `ProjectWatcher` refreshes the sidebar through FSEvents (0.1 s latency) and passes the changed paths to `Workspace.projectFilesChanged`, which feeds the block engine (below). A library document shows its own folder, with the library's `document.json` hidden and its entry fixed.

The sidebar (`ProjectSidebar`) is a column left of the editor, 240 to 320 points wide, stored per device. It lists the tree and nests the open file's headings from `OutlineNavigation`; without a folder it holds only the outline. The floating margin outline is shown only while the sidebar is hidden. The toolbar holds the sidebar button, the file and folder names, a breadcrumb from `OutlineNavigation.ancestry`, a status dot from `CompileStatus`, the Code, Writing and Focus control (`EditorMode`; a document opens in Code mode until per-document mode memory arrives in Phase 6), Export and the preview toggle. Preview pages are styled as cards from the injected stylesheet; the pane header shows the current page from `PreviewReadingSession.currentPage`.

## Render bridge

The Mac app links one Rust static library, `ProseEngine.xcframework`, built from `Engine/RenderBridge` by `scripts/build-render.sh`. It contains Typst 0.15.1 (the same fork and tag as Tinymist) and re-exports the syntax bridge's `lb_syntax_api`, so the app carries one Rust runtime. Its C ABI is the function table `prose_render_api()`; every entry point that does work catches panics.

`BlockRenderer` (ProseCore, an actor) owns one engine per document. `setText` replaces a file's text in memory; `refresh` runs a full compile of the main file with a small probe that records every heading's and equation's counter value, and reads what each reference displays from the links in the output. `blocks` lists every top-level piece of a file in order, so the blocks cover all text other than whitespace between them. Each block has a kind: heading, equation, paragraph, raw (one fenced raw block), list (only list items), context (a `#set`, `#show`, `#let` or `#import` line), include (an `#include` line) or comment (only comments). Context, include and comment blocks are pills in Writing mode and are not rendered. `render` builds a block document (an optional default text colour, the file's context lines, a transparent page as wide as the measure, counter updates, stub labels with the full document's reference text, then the block; a block that cites or holds the bibliography also gets every key the full document cites, in order, and the document's `bibliography(...)` call, placed and hidden, so Typst formats its citations and entries as in the whole document), compiles it, and returns SVG, size, first baseline, ink bounds, the drawn area and glyph boxes with UTF-16 source offsets. The drawn area is the page together with any ink outside it, such as punctuation that hangs past the measure; the SVG and bitmap cover it. On request, `render` also returns a premultiplied RGBA bitmap of the drawn area at a given scale (`typst-render`), which `BlockRenderer` wraps in a `CGImage` inside the actor. Results are cached in an LRU with a byte budget (64 MB by default), keyed by the block document (so by the text colour) and width and checked against the edit version of every file the compile read. A cache entry keeps the laid-out page, so a cached block can be rasterized without compiling; bitmaps themselves are not cached, because a viewport of them at scale 2.6 would fill most of the budget. Typst's own memo caches are evicted after each refresh and every 128 compiled renders. `filesChanged` (C ABI version 3, Phase 5 step A) reports files changed on disk: the engine calls `FileStore::reset()`, so every file it loaded from disk is read again on its next use, and gives each changed file a new version, so cached renders that read it miss. Editor buffers set with `setText` keep their text, and paths outside the root are ignored. It returns how many of the files the main file, the last refresh or any render read; 0 means nothing shown can have changed. On SICP the call takes under 0.1 ms, and reading the files again adds about 30 ms to the next refresh. Render results also carry the block's plain text, for tests. The C ABI is version 3. Writing mode (below) is the editor's only client.

## Writing mode

Writing mode draws the open file as typeset blocks in the same `ManuscriptTextView`. It works only in the TextKit 2 layout layer: entering, leaving, a swap and a render result change nothing in the text storage, the selection or the undo stack ([why](visual-editing.md#writing-mode-in-prose-the-rule-kept)). Design, decisions and measurements are in `docs/plans/2026-11-08-phase-3-writing-mode.md`; Focus mode, the floating toolbar and spell check are in `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`.

```mermaid
flowchart LR
  Workspace[Workspace.setMode and WorkspaceWriting] -->|engine per project| Renderer[BlockRenderer actor]
  Workspace --> Controller[WritingController]
  Editor[ManuscriptTextView] -->|edits, caret, marked text, viewport, appearance| Controller
  Controller --> Model[WritingLayout]
  Model <-->|blocks, renders, refresh| Renderer
  Model -->|roles, changed ranges| Controller
  Controller -->|invalidateLayout| Manager[ManuscriptLayoutManager]
  Manager -->|delegate| Fragment[WritingFragment]
  Fragment -->|role on each frame read and draw| Model
```

| Part | What it does |
|-|-|
| `WritingLayout` (ProseCore) | The main-actor model for one open file, with no AppKit drawing. It holds the engine's block list and rebases it across native edits; after edits settle (150 ms) it sends the text to the engine and takes the engine's list, and it asks for `refresh()` after a 1.5 s pause, and at once after `filesChangedOnDisk()`. A refresh that succeeds, and any refresh after a change on disk, starts a new render epoch, so every block in view asks for its render again; the engine's cache answers for blocks whose block document and files are unchanged, and a render with the same picture keeps the image shown. It resolves the active block from the caret's moving end and the marked text, decides each block's state (source with a reason, rendered, or pill) and schedules renders near the viewport, nearest first. `role(forParagraph:)` answers `source`, `rendered`, `collapsed` or `pill` for one TextKit paragraph; `onChange` names the ranges whose roles changed. While text is marked nothing changes, except that a block the composition edits opens. The renderer is the `WritingRenderer` protocol, which `BlockRenderer` conforms to, and timing is injected (`WritingTiming`), so tests script both. |
| `WritingController` (`WritingMode.swift`) | One per editor (`editor.writing`). It starts and stops the model for the open file, forwards the editor's edits, the selection's moving end, marked text, the visible range and the appearance (column width, 1.3 times scale, bitmap scale, dark text colour), and applies role changes: `invalidateLayout(for:)` of the changed ranges, with the top line, or the caret's line when its block opens, kept in place. Entry holds swaps for up to 100 ms until the viewport's renders arrive. It remembers selections the pointer made, which open no block. |
| `WritingFragment` and the layout manager delegate (`WritingFragments.swift`) | The controller is the layout manager's delegate and gives every paragraph a `WritingFragment`. The fragment reads its role on a frame read or draw and keeps it until `WritingLayout.roleRevision` changes (every change of the blocks, every edit, start and stop), because TextKit reads several thousand frames per scrolled frame. An image whose pixel size matches its rectangle on the device draws at exactly that size with its top-left corner on a device pixel and no interpolation (`imageTarget`); any other image is resampled. By role: a rendered first paragraph reports the block's drawn height and draws its bitmap, collapsed paragraphs take no height, a pill draws its label, and a stale render draws an amber bar in the margin. On first entry TextKit's existing fragments are replaced once by `recordEditAction(in:newTextRange:)` over the whole text, which changes no characters. |
| `ManuscriptLayoutManager` (`ManuscriptTextSystem.swift`) | The editor's `NSTextLayoutManager` subclass. In Writing mode it leaves rendered and pill paragraphs out of non-empty selection segments, because NSTextView draws its highlight from them and would draw the hidden source lines. The editor draws the highlight there itself from the glyph boxes, in `drawBackground(in:)`, under the transparent images, in NSTextView's active or inactive colour. |
| `WritingGlyphMap` (ProseCore) | A rendered block's glyph boxes where its fragment draws them, with source offsets in today's text. It answers hit tests (glyph, generated text or miss), selection rectangles, the drawn lines and caret positions on them. Every position inside a rendered block comes from it, never from TextKit, whose lines there are the source lines. |
| `WritingSelectionNavigation` and the pointer (`WritingPointer.swift`) | A press in a rendered block or a pill runs Prose's tracking loop (`trackWritingPointer`), which maps points through the glyph map; clicks, double- and triple-clicks and shift-clicks map the same way. A drag that starts in source stays with AppKit, whose tracking asks the layout manager's `textSelectionNavigation`; the replacement `WritingSelectionNavigation` answers points in rendered blocks and pills with glyph-mapped offsets or the block boundary. |
| Keyboard (`WritingKeyboard.swift`) | Keys from an empty selection are TextKit's and land where Code mode puts them. While the keyboard extends a pointer selection, the controller moves its moving end itself through the drawn lines (`WritingSelectionNavigation.destinationSelection`), so the selection still opens no block. Page up and page down move the caret about one viewport of drawn content. |
| Accessibility (`WritingAccessibility.swift`) | The value, strings, lines and insertion point stay NSTextView's, read from the source. For ranges and points in rendered blocks and pills the editor answers `accessibilityFrame(for:)`, `firstRect(forCharacterRange:actualRange:)`, `accessibilityRange(for:)`, `characterIndex(for:)` and NSTextView's own AXBoundsForRange and AXRangeForPosition selectors from the glyph boxes; it passes everything else to NSTextView. |
| Focus mode (`FocusMode.swift`, `FocusTypewriter.swift`) | Focus is Writing mode plus view state. Panes: a `didSet` on `Workspace.editorMode` saves `FocusPanes` (sidebar, layout) on entry, hides both and restores them on exit; a pane change while Focus is on ends Focus for Writing mode. Chrome: `FocusChrome` holds whether the title items, the status bar and the toolbar show; `FocusPointerTracker` puts a tracking area on the window's frame view only while Focus is on, and `FocusTitleItem` hides the title and action items unless the pointer is over the title row. The status bar shows within 34 pt of the bottom edge and hides 1 s after the pointer leaves. Scale and column: `WritingMetrics.focusScale` (1.4625) and `ManuscriptLayout.focusColumnWidth` (467 pt); a change of scale makes blocks draw source until they render again. Dimming: the controller keeps the focus blocks (`focusSpans`: the active block, or every block a non-empty selection touches) and the fragment draws any other paragraph at 45 percent opacity, a rendered image through a dimmed copy from `DimmedImageCache` (ProseCore, the 32 most recently used), source and pills inside a transparency layer; when they change, `flush()` lays out again only the paragraphs whose first character changed sides (`WritingFocus` in ProseCore), as a swap does. Typewriter: a caret change with an empty selection asks for a scroll (`TypewriterScroll`), which `flush()` makes once the edit and its swaps are laid out, in the same event (a click over 0.2 s); swaps keep the caret's line in place instead of the top line. The text has 60 percent of the visible height above and below it, so the first and last lines reach the typewriter line. When the visible height changes (a window resize, the command panel opening or closing) with the caret's line in view, the caret line goes back to the typewriter line instead of the top line staying. `Esc`: `ManuscriptTextView.cancelOperation(_:)` is the last owner; in Focus without marked text it returns to Writing mode. |
| Floating toolbar (`FloatingToolbar.swift`) | Five buttons at the bottom center of the editor pane in Writing and Focus mode (not in Code mode, not with the editor pane hidden): Text style, Table, Equation, Image and Insert. Each is a step of the `⌘J` panel, through `Workspace.performToolbarAction(_:)`: open the panel if closed, `enterGroup` (`style` or `insert`), then `selectCommand` for `table`, `equation` or `image`. The buttons are AppKit views (`ToolbarButtonView`) that refuse first responder, so a click leaves the editor its focus and selection; they carry the accessibility label, identifier (`toolbar.style` and so on) and help, and the hover help shows the panel's key path. In Focus mode the toolbar fades out while the user types and returns when the pointer moves (`FocusChrome.toolbarHidden`), and sits above the status bar while that shows. The editor keeps 64 pt below the text in Writing and Focus mode (`ManuscriptTextView.bottomInset`; `textContainerOrigin` keeps 42 pt above it), so the last line can scroll above the toolbar. |
| Spell check (`SpellCheckRanges`, `SpellCheckModel`, `SpellChecker` and `SpellingUnderline` in ProseCore; `SpellCheck.swift`) | `SpellCheckRanges` is a pure function over the syntax tree that returns the checkable ranges: markup text, including headings, list items, strong, emphasis and content blocks of calls; never raw text, math, code, strings, labels, references, links, comments or context lines. `SpellCheckModel` (main actor, one per workspace) mirrors the text, moves misspellings across native edits, and checks the viewport and, 300 ms after typing pauses, the edited paragraphs; it caches results per paragraph and hides the misspelling that holds the caret (`shownMisspellings`). The parse for checkable ranges runs on the `SpellCheckSource` actor. `SystemSpellChecker` calls `NSSpellChecker`'s asynchronous request from the main actor, `.spelling` only, with one spell document tag per open file; tests inject a scripted checker. Drawing: in source the editor writes `.spellingState` through `RenderingAttributes.setSpelling`, so a restyle keeps it and TextKit 2 draws the system underline; in a rendered block `WritingFragment` asks the controller for the block's misspellings at each draw and draws `SpellingUnderline`'s copy of the system pattern under the range's glyph boxes (`WritingGlyphMap.underlines(for:)`). `ManuscriptTextView.menu(for:)` puts guesses, Learn Spelling and Ignore Spelling first for a misspelled word; Check Document Now (`⌘;`) calls `Workspace.checkDocumentNow()`; the accessibility attributed strings carry `AXMisspelled` and `AXMarkedMisspelled`. The setting `checkSpellingWhileTyping` (`SpellCheckPreference`) is local to the Mac. |
| `WorkspaceWriting.swift` | One `BlockRenderer` per project root and main entry (`WritingEngineKey`), created off the main thread the first time Writing mode is entered, kept across files of the project, freed when the project changes, the library home opens or the window closes. The open file's buffer reaches the engine through the model. Project files that change on disk (`projectFilesChanged`) wait until the burst pauses for 300 ms (`projectChangeDelay`); then Typst files other than the open one go in through `setText`, every changed file goes to `filesChanged`, and when the document read any of them the model refreshes (`filesChangedOnDisk`). A change to a file the document does not read refreshes and re-renders nothing. The open file follows the editor's own rules for changes on disk. A failed engine start returns to Code mode with a message. |

`Workspace.setMode(_:)` switches between Code, Writing and Focus and calls `updateWritingMode()`. The same call runs when the editor loads new text and when the service starts for a file, so Writing mode follows file and project changes.

## Command discovery

One registry holds stable IDs, English labels, English keywords, groups, group keys, help, parameters, direct shortcuts and actions. Browsing and search share this registry. Labels resolve through `L10n` (English only); the normalized search index covers titles, keywords, descriptions and shortcuts.

The panel has closed, category, search and parameter-entry states. `⌘J` toggles it, letters enter categories, `/` begins search and `Esc` returns through levels. Ordinary spaces and input-method candidate keys are not intercepted during editing.

| Group | Key | Examples |
|---|---|---|
| Insert | i | Headings, images, tables, equations, code, links, notes |
| Text Style | s | Bold, italic, highlight, selection wrappers |
| Page Setup | p | Paper, margins, fonts, page numbers |
| Mathematics | m | Basic operations b, structures s, symbols y |
| Typesetting | l | Columns, grids, alignment, containers, spacing |
| References | r | Bibliography, citations, contents |
| Editing & Code | c | Editing, modules, variables, Universe, formatting |
| Workspace | v | Writing, split, preview, outline, checks, text size |
| Documents | f | Create, open, save, save as, PDF export |

Commands produce explicit text transformations and placeholder ranges. They do not independently write files or refresh preview. String parameters are escaped; numbers and enumerations are validated. Real Typst compilation verifies the insertion catalog.

Insertion queries Tinymist for both selection endpoints. Math helpers accept one mathematical region and omit outer `$` delimiters there; body commands reject math, code and raw-text positions. Explicit inline/block/preamble metadata controls placement. Document settings follow contiguous `#set` rules at the start of a file, without rewriting arbitrary functions or `#show` scopes; later rules can still override them.

`WritingWindow.sendEvent` uses AppKit's normal dispatch path and responder chain. There is no application-wide `NSEvent` monitor or `MainActor.assumeIsolated` shortcut. File dialogs suspend main-window command handling.

## Logging and package discovery

`ActionLog` writes local JSONL with a lock protecting the file handle, sequence and rotation. Files rotate at about 1 MiB, retaining three archives. Each launch has a session ID. Logs record actions and control keys; ordinary typing is only `text`. Source, clipboard, queries and parameter values are excluded. Logging failure never blocks editing or saving.

`UniverseCatalogStore` reads metadata from `packages.typst.org/preview/index.json`. Numeric semantic-version comparison chooses each package's latest version; names and versions are validated before generating pinned imports. An atomic JSON cache has a 24-hour TTL, offline fallback and explicit refresh. Packages requiring a newer compiler display the requirement and cannot be imported through the browser. Browsing does not execute packages; Tinymist resolves them after an explicit import. Injected transport and state let tests use fixed indexes without depending on network availability.

## Tinymist lifecycle

Foundation `Process` launches the bundled executable. stdin/stdout carry framed LSP JSON-RPC; stderr is drained separately without persisting document logs. The client handles Content-Length framing, fragments, multiple frames, request IDs, initialization ordering, timeouts and process cleanup.

After `initialized`, `didOpen` and `didChange` synchronize buffers. File switches and reconnects end the old independent process session before opening the current documents. Full-text sync favors correctness; short debouncing limits work, and save/export flush the latest revision. The app integrates diagnostics, completion, document symbols, contextual help and go-to-definition. On Mac, Command-click, F12 and the definition command share `textDocument/definition`; the client advertises location-link support. Pending navigation is invalidated by selection changes, edits, document switches or a newer assistance request. Definition navigation retains the compilation entry and return positions, and package source remains read-only.

A workspace command starts preview on loopback with random ports. Actual commands, returned fields and synchronization channels are verified against the pinned server. Preview lifetime follows document lifetime. A crash keeps the buffer intact and offers reconnect; there is no unbounded automatic retry.

## Preview and export

`WKWebView` hosts Tinymist's bundled Web/SVG renderer. Local preview navigation stays constrained; external links open in the system browser. The page receives no unrestricted native bridge.

Writing, resizable side-by-side and full preview share the main file, resource root and fonts. Zoom changes the preview page container width and triggers layout; percentages are relative to fit-to-pane width. Preview failure does not cover the editor.

`--partial-rendering=true` renders visible regions. Tinymist repaints them only 500 ms after scrolling stops, so the injected adapter paints documents of up to 20 pages completely; longer documents paint one viewport ahead on each side and repaint while scrolling, no more than once per 100 ms and never sooner than twice the last render time. Because each repaint renews Tinymist's 600 ms resize anchor, the adapter drops that anchor once the reader has scrolled away from it, so dragging a scroll bar right after a resize is not pulled back. Invalid source preserves the previous successful pages and marks them stale; a first failed compilation has no page to preserve. Dark reading uses the pinned frontend's `invert-colors` and `normal-image` classes, maintaining the preference through server-driven class changes. It affects neither compilation input nor PDF export. Real WebKit tests verify retention, recovery, zoom and color state.

Source/preview navigation uses `tinymist.scrollPreview` and LSP `window/showDocument`. The returned file and range determine navigation, including included documents. Preview jumps count columns in Unicode scalars, unlike LSP results. A string value has no source span, so text a function displays from a parameter jumps to that parameter in the function body. The shared preview script reports the clicked text run and its line; when the jump lands on a parameter, `PreviewCallSite` moves it to the argument of the call in the same file whose string or content literal contains that text, or to the only call. Ambiguous or unmatched clicks keep Tinymist's location.

Export flushes the latest main-document buffer, waits for a valid result and copies it to the chosen destination. Compilation failure cannot report an old PDF as new. The exported revision is tracked; if editing continues during export, the result identifies the version captured when export began.

## Visual and performance conventions

Appearance defaults to **Match System**, with persistent **Light** and **Dark** choices in Settings. Interface colours are the Intent tokens in Section 4.1 of the [Prose spec](prose-spec.md). Light uses a white page (`#FFFFFF`), a pale sidebar and panel (`#F5F5F7`), warm ink (`#1A1918`), secondary text `#68635E`, muted text `#716B65`, hairlines `#E5E2DD` and a dusk-violet accent (`#7C2494`). Muted text is not in the spec; it is chosen to keep 4.5:1 contrast on the page and the sidebar. Selection is the accent at 10 percent on the page (`#F2E9F4`). The preview canvas uses the sidebar colour.

Native dynamic `NSColor` values serve SwiftUI surfaces, AppKit controls and TextKit's existing syntax runs. System appearance changes repaint in place; no text replacement, syntax rescan, layout rebuild or undo entry is needed. The app-level choice also covers settings, toolbar, popovers and the preview canvas. The preview document's independent Light/Dark control still leaves PDF output unchanged. The small preference joins existing iCloud reconciliation.

Dark uses page `#262626`, sidebar, panel and preview canvas `#1A1A1A`, hairlines `#464646`, text `#E8E4DE`, secondary `#9C968D`, muted `#948E85`, accent `#B784E0` and selection `#463B4F` (the accent at 22 percent). Compile success and error are `#5CB85C` and `#E25555` in both appearances. Code-mode syntax colours keep the Nano-derived set inherited from LeftBlank.

Use system interface fonts, monospaced shortcuts and source, and system CJK fallback. Text begins at 16 pt with adjustable size and a comfortable centered line width. Native `NSToolbar.unifiedCompact` keeps system traffic lights, document title and actions in one row. The status bar is about 30 pt high; command discovery uses a fixed 320 pt bottom panel. Compact hover hints size to their content. Phosphor Regular actions use consistent 16–18 pt icons.

The outline overlays the margin without changing manuscript geometry. Direct shortcuts and discovery paths share metadata. Document metrics cache a UTF-16 line index per revision. Source/readable-style snapshots update only the old and new active paragraphs when the caret moves; source or style changes rebuild them. Icons, normalized search, result sets, examples and key paths are cached. See [measured results](interaction.md).

## Tests and delivery

Functional tests use production windows, text views, workspace, WebKit and Tinymist together. They cover command discovery, insertion/undo/redo, files, conflicts, recovery, diagnostics, preview and PDF contents. Boundary tests complement those flows with UTF-16, framing and parameter validation. Tests need no database or container.

Coverage merges test-bundle profiles and deduplicates LCOV file/line records. All first-party production Swift must be accounted for; missing files fail the report, and overall coverage must reach 80%. Raw LLVM JSON, LCOV, file summaries and HTML remain available. Coverage does not replace behavioral assertions or real visual checks.

Local scripts keep downloads, build outputs and test data inside the checkout. `build/Prose.app` has a development signature. Release scripts import a Developer ID identity into a temporary keychain, sign helpers and the app, notarize, staple and validate with Gatekeeper. Release commits must already belong to main, and version tags must match `Info.plist`. Missing credentials or failed validation stop publication. See [signing](signing.md).

GitHub Actions uses macOS 15 arm64 runners, pinned action commits and pinned dependency checksums. PR/main jobs run functional tests, coverage and release builds. Version tags rerun verification, produce an arm64 ZIP plus SHA-256, and publish a GitHub Release. Permissions are limited to each job's needs.

## Risks and references

The preview protocol includes extension APIs, so pinning and real integration tests matter. AppKit/SwiftUI synchronization must preserve input methods, focus and undo. Main-file identity must remain explicit across included documents. External packages, images and fonts depend on real filesystem context shared by preview and export.

References: [Tinymist preview](https://myriad-dreamin.github.io/tinymist/feature/preview.html), [Tinymist source](https://github.com/Myriad-Dreamin/tinymist), [NSTextView](https://developer.apple.com/documentation/appkit/nstextview), [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [Nano Emacs](https://github.com/rougier/nano-emacs) (syntax colours), [Phosphor](https://github.com/phosphor-icons/core), [CotEditor testing](https://github.com/coteditor/CotEditor/blob/main/.github/workflows/test.yml), [CodeEdit testing](https://github.com/CodeEditApp/CodeEdit/blob/main/.github/workflows/tests.yml), [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Library and localization (0.4)

The library actor owns UUID-based folders and coordinated filesystem operations; LibraryController connects navigation to the live Workspace. UI titles are metadata, while source and assets retain stable relative paths. A conservative background three-way diff incorporates non-overlapping remote edits through native undo. Native iCloud conflicts block overwrites. See [library and sync](library-and-sync.md) and [merge evaluation](merge-evaluation.md).

The interface is English only (Phase 4 step A): `L10n` is a thin lookup in `en.lproj`, with no language setting ([localization](localization.md)). Explicit package imports in the [Code notes template](code-notes.md) keep exported source portable.

### Book-length WebKit preview

The pinned Tinymist 0.15.8 frontend combines partial SVG pages with an optional
canvas fallback inside SVG foreignObjects. With SICP this creates hundreds of
canvas surfaces under a root SVG over a million CSS pixels tall at wide-window
zoom. Real-window acceptance exposed incorrect/blank composition. Prose disables
that optional `feat$canvas` mixin on registered preview documents and retains
Tinymist's viewport-driven SVG patches, source mapping and continuous scrolling.
This is a version-specific frontend adapter; the complete-book preview integration
test checks the pinned DOM contract, zero canvas fallback surfaces, distant-page
SVG content and WebKit snapshots. Revalidate the adapter on engine upgrades. A terminated WebKit content process
gets one automatic reload; a repeat failure displays a reconnect message.
