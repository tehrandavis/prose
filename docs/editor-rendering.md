# Editor styling and faithful previews

Prose keeps the original Typst source in NSTextView. Display attributes never change saved text, clipboard contents or undo records. The page preview runs the real Typst engine through Tinymist.

## Shipped in 0.4.0 (8)

- Typst colors come from Tinymist's `textDocument/semanticTokens/full` response and the legend negotiated during initialization. UTF-16 offsets are checked against the exact requested buffer, including emoji and line terminators. At most one request is in flight; responses for an old revision or document are discarded. A small local styling fallback remains available while the service is connecting.
- Fenced code blocks use the pinned Highlight.js 11.11.1 common grammar bundle plus its pinned Scheme grammar. This covers Python, Swift, Rust, JavaScript and other common languages without maintaining language-specific rules in Swift. JavaScriptCore runs the highlighter on a separate actor; manuscript text is passed as data, never evaluated. There is no network access or language autodetection. Unknown languages remain readable plain text.
- Code-block results are cached by language and content. A pass is bounded to 2,048 blocks, 32,000 UTF-16 units per block and 1,048,576 units in total. Oversized blocks remain plain text. An unfinished fence can still receive highlighting.
- Headings, emphasis and inline code retain the existing conservative reading decorations. Moving the caret into a paragraph reveals its markers. IME composition defers all style application; typing, selection and undo remain native.
- Equations such as `$alpha + beta = gamma$` render in the page preview. They remain source text in the editor. Syntax coloring is not equation typesetting, and this build does not claim inline equation widgets.

## Inline equation direction

Use the Typst engine for equation layout and glyphs. Do not translate Typst into LaTeX for KaTeX, or maintain a table that replaces names with Unicode symbols: both lose package functions, macros, fonts and contextual styles.

Tinymist's LSP tokens identify syntax and its preview service renders documents. Neither is a ready-made AppKit inline equation control. Its hover periscope implementation crops the compiled document around a source position; it is not a stable API returning the exact bounds and baseline of an arbitrary equation. The upstream introduction currently lists limitations for the VS Code periscope renderer.

A future source-preserving inline layer needs engine-derived equation spans and rendered fragments with document context, baseline and geometry. Cache them by revision and relevant style context, render visible spans in the background, and reveal the original source on caret entry. A syntax error should leave the source editable and keep any older rendered fragment clearly marked as stale. Selection, accessibility, copying, IME, undo and fast document switching must be acceptance tests before enabling the feature by default.

The current paragraph decorations can remain lightweight native attributes. Any richer equation or diagram preview should share the page compiler's semantics rather than growing a second approximate parser and renderer.

Sources: [Tinymist semantic tokens](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/analysis/semantic_tokens.rs), [Tinymist hover rendering](https://github.com/Myriad-Dreamin/tinymist/blob/v0.15.8/crates/tinymist-query/src/hover.rs), [Tinymist introduction](https://myriad-dreamin.github.io/tinymist/), [Highlight.js](https://github.com/highlightjs/highlight.js/tree/11.11.1).

## Pointer geometry and native selection

Reading attributes can change glyph widths and line heights. Prose resolves the visible TextKit layout after a metric change and before mouse-down, so hit testing and displayed glyphs use the same geometry. Syntax colors use temporary layout attributes and never trigger a forced layout pass. It postpones reading/source restyling until native mouse tracking ends, preserving word selection and dragging. Cursor rectangles are invalidated after layout changes and editable text uses the native I-beam. This does not replace AppKit selection or IME handling.

The pointer regression scenarios cover source/reading transitions, single/split layouts, three window widths, wrapped paragraphs, Chinese and emoji. Character rectangles must round-trip to their original insertion offsets, and the real window hit-test must route those points to the editor.

## Stable typing

Semantic colors remain visible while an updated response is pending. The small regex fallback is used before semantic colors arrive; it no longer replaces an entire semantic palette after each key. Only changed temporary color runs are applied, and asynchronous token replies cannot change fonts or paragraph metrics.

Reading analysis runs on a serial actor and applies only to its exact source snapshot. Font changes are diffed independently of colors. The active paragraph's source attributes are included in that comparison, avoiding a hide/reveal cycle in each pass. Native CJK and emoji font substitutions remain intact. Temporary attributes are applied after text-storage edit batches have closed because their display invalidation can request glyph generation.

See [Editor foundations](editor-foundations.md) for the component evaluation, memory model, regression gates and remaining work on incremental edits and persistence.
