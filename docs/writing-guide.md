# Writing with Prose

Prose is a development preview for Macs with an Apple M-series chip, running macOS 14 or later.

Open Prose from your Applications folder. The app includes its typesetting service; no separate installation of Typst, Rust or Homebrew is needed to use it. Try the [welcome document](../Examples/Welcome.typ).

The interface is in English. Your documents can be in any language: Prose draws Chinese, Japanese, Korean and other scripts with the fonts that come with macOS.

| Action | Shortcut |
|---|---|
| Discover commands | `⌘J`, configurable as `⌘K` |
| Browse categories | `i` Insert, `s` Text Style, `p` Page Setup, `m` Mathematics, `l` Typesetting, `r` References, `c` Editing & Code, `v` Workspace, `f` Documents |
| Search commands | `/` inside the command panel |
| Go back or dismiss | `Esc` |
| Move between inserted placeholders | `Tab` / `⇧Tab`; `Esc` to finish |
| Code / Writing / Focus mode | `⌘1` / `⌘2` / `⌘3`; `Esc` leaves Focus |
| Next misspelled word | `⌘;` |
| Show or hide the preview / read the preview | `⇧⌘P` / `⌥⌘P` |
| Sidebar / document checks | `⌘0` / `⌘5` |
| New / library / save | `⌘N` / `⌘O` / `⌘S` |
| Open a folder / import a document | `⌥⌘O` / `⇧⌘O` |
| Save as / export PDF | `⇧⌘S` / `⇧⌘E` |
| Completion / find | `⌃.` / `⌘F` |
| Go to definition | `⌘`-click, `F12` (or `fn-F12`), or `⌃⌘J` |
| Return to previous source position | `⌃⌘[` |
| Universe packages | `⇧⌘U` |

For example, `⌘J → i → t` opens the table form. Choose the row and column counts, insert, then move between cells with Tab. Select text and press `⌘J → s → b` to make it bold. Each insertion is one undoable edit. You can always write Typst directly.

**Writing mode** (`⌘2`) shows your document typeset, block by block, with the document's own fonts. The paragraph that holds the caret shows its source, so you always edit the real text.

**Focus mode** (`⌘3`) is Writing mode with nothing else on screen. The sidebar and the preview hide, the text is a little larger in a narrower column, and the paragraph you are in stays at full contrast while the others fade. The line you are typing stays 40 percent of the way down the window, as on a typewriter; scroll freely to read, and the next key brings you back. The title row shows only the breadcrumb and the status dot until you move the pointer over it, and the status bar appears when the pointer nears the bottom edge. Press `Esc` or `⌘2` to return to Writing mode. Showing the sidebar or the preview also leaves Focus.

In Writing and Focus mode a small toolbar floats at the bottom of the text: Text Style, Table, Equation, Image and Insert. Each button does what its `⌘J` path does (hover over it to see the path), at the caret or on the selected text, and the keyboard stays in the text. In Focus mode it fades while you type and comes back when you move the pointer.

The command catalog has 110 discoverable commands, including 74 insertion actions. Mathematics has nested categories for basic operations, equation structures and symbols. `⌘J → m → b → f` inserts a fraction, using the appropriate syntax inside an existing equation. Commands show their purpose, example, direct shortcut, discovery path and official reference.

Frequent actions have direct shortcuts as well as discoverable paths. `⌘]` / `⌘[` indent and outdent, `⌘/` toggles comments, and `⌥⇧F` formats the source. Hovering a toolbar button shows a compact action name and shortcut.

Command-click a variable, function, module member, label reference, or the path in an `import` / `include` to go to its definition. **Go to Definition** is also in the editor's context menu and **Editing & Code** commands. Navigation uses Typst's language service, including local modules, import aliases and external packages. Built-in functions without Typst source show contextual help instead.

Rest the pointer on a function or symbol for 400 ms to see its signature and available documentation. The compact card follows the app's light/dark appearance and never moves the caret or takes keyboard focus. Move into the card to scroll longer explanations; move away, type, scroll the editor or press Esc to dismiss it. Built-in types that only provide an official documentation link show that link. Symbols with no help produce no popup. Hover also works in read-only package source; `⌃⌥H` still opens explicit help at the caret.

When documentation includes a Typst example, the hover card opens an **Example** tab with code above its rendered result; **Explanation** shows the signature and full description. An embedded SVG or PNG is preferred. Otherwise the first example is compiled separately, including hidden documentation setup lines. The paper preview stays white in both themes. Results are cached, rendering is cancelled when the card closes, and examples never change the manuscript's preview. Examples that require unavailable files or context keep their source and a documentation link. Preview compilation uses an isolated directory, cached packages only, a three-second limit and the first output page. Longer examples and explanations stay scrollable.

**Go Back** restores the previous file and caret, including nested jumps. `⌘W` closes the current file and returns to the previous document; `⌘Q` quits the app. The original document remains the compilation entry while you inspect dependencies. Your own modules stay editable; package sources display a lock and **Read-only** badge and cannot be overwritten.

**File → Open Folder** opens a folder of Typst files, such as a thesis, and edits the files where they are. Nothing is copied into the library, so Git, Dropbox and iCloud Drive keep working on the folder. The sidebar (`⌘0`) lists the folder's files, folders first, and nests the open file's headings under it. Click a heading to go to it. The search field filters files by name. The `+` button adds a Typst file or a folder, and each item's context menu offers Rename, Reveal in Finder, Set as Main Document and Move to Trash. A pin marks the main document: preview and export always compile it, whichever file is open. Other files, such as PDFs, images and `.bib` files, open in Quick Look. Recent folders appear on the library home and reopen after relaunch.

If you keep references in Zotero, the Better BibTeX plugin can export a collection to a `.bib` file and keep it up to date automatically. Point its automatic export at a file in your project folder, such as `refs.bib`, and cite it with `#bibliography("refs.bib")`. You never copy the file by hand. Prose picks up changes to the `.bib` file automatically: within a second or two of the export, the preview, the PDF and Writing mode show the new and changed references, with no edit in the document.

To cite a source, press `⌘J`, then `R` and `S` (**References → Cite a Source**). The panel lists every entry in the bibliography files your `#bibliography` call names, or, if the document has no such call yet, every `.bib`, `.yml` and `.yaml` file in the project. Each row shows the first author, the year, the title and the key. Type part of an author's family name, a year, a title word or the key to narrow the list; `↑` and `↓` choose an entry. `Return` inserts `@key` at the caret, with a space before it when the caret follows a word or another citation, so `See @a` becomes `See @a @b`. `⌥Return` asks for a page or section first and inserts what you type inside the brackets: `p. 4` gives `@key[p. 4]`. A citation goes only in body text; in an equation, code or raw text the panel says so and leaves your text unchanged. One `⌘Z` removes it.

If the document has no `#bibliography` call, the first citation offers to add one for the file the entry came from, at the end of the main file. `Return` adds the call and the citation as two edits, so `⌘Z` removes the call first; `N` inserts only the citation and Prose does not ask again for that document. Prose makes this offer only while the open file is the main file. In a chapter that the main file includes, it inserts the citation only, and you add the call to the main file yourself. If an entry in a linked file cannot be read, the panel names the file and line under the list; the other entries stay available. In Writing mode a new citation shows its final text, such as `[2]`, as soon as the caret leaves its paragraph. If a key is not in any file yet, **References → Citation** still inserts `#cite(<key>)` for a key you type, and Typst's completion offers keys while you type `@`.

The title row shows the file and its folder, a breadcrumb of the headings around the caret, and a status dot. Green means the preview matches your text, amber means it is typesetting, red means the document needs attention, and a hollow grey dot means the typesetting service is not running. Click the dot to see the checks.

Without the sidebar, the outline appears in the left margin without moving the text. Hover to explore headings; its sidebar button opens the full sidebar. The command panel keeps a stable height through searching, selection and parameter entry; its guide stays in the same place.

## Spelling

Prose checks the spelling of your prose as you write, in every mode. It reads only text: it leaves code, math, raw text, labels, references, links and comments alone, and it checks footnotes and captions. A misspelled word gets a red dotted underline, in source and in typeset text. A word you are still typing is not marked until the caret leaves it.

Right-click a marked word to see suggestions; choose one to replace the word (one undoable edit). **Ignore Spelling** stops marking the word in this file until you close it, and **Learn Spelling** adds it to your Mac's dictionary. Press `⌘;` (**Edit → Spelling and Grammar → Check Document Now**) to go to the next misspelled word. Turn checking off or on with **Edit → Spelling and Grammar → Check Spelling While Typing** or in the Writing tab of Settings; the choice covers all documents on this Mac. The spelling language follows your Mac's spelling setting.

## Completion and existing objects

Code completion appears after a short pause while you type. The editor keeps
focus. Use the arrow keys and Tab to accept a candidate. Escape dismisses the suggestions. Function calls also show parameter
help, including calls that span multiple lines. Completion preserves snippet
placeholders and creates one undo step. Chinese input composition defers these
suggestions until composition finishes. Manual completion remains available.

Place the cursor inside a table or image and choose **Edit Table or Image…**
(`⌘J → c → e`). Tables support cells, rows, columns, a header row, cell alignment, and
rectangular tab-separated data. Image editing supports existing document
resources, a path, a numeric width, a plain caption, and alignment. Apply changes
only the selected object and creates one undo step. Cancel leaves the source
unchanged. A draft cannot overwrite a newer document revision.

This form supports literal objects, including those inserted by Prose.
Generated tables, merged cells, expression-based dimensions, rich captions,
and unsupported options stay in source editing. The form does not convert
arbitrary Typst programs into visual objects.

## Images and document resources

Use `⌘J → i → i` to choose an existing image from **Document Resources** or **Import File…** to bring in a new one. Add a caption and insert. You can also drop one or more image files at a position in the editor, or paste a screenshot with `⌘V`. Ordinary text paste and text dragging keep their normal behavior.

Prose saves its own copy with the document and inserts the reference for you. Moving or deleting the original file does not break the image. Images travel with the library document, iCloud sync and source-project export. Undo removes the insertion; the resource remains available for redo, document history and reuse.

PNG, JPEG, GIF, SVG, PDF and WebP keep their original format. Other macOS-readable image formats, such as HEIC and TIFF, are converted to PNG. Audio and video are not embedded in typeset pages; dropping them shows an explanation and leaves the text unchanged.

Bibliography, Include Document and Import Local Module use the same resource picker. You can also drop or paste bibliography files and self-contained `.typ` documents. For a Typst document with relative dependencies, import its whole project through the library first.

To assemble a book, open a library document, choose **Include Document → Library Documents**, and select a chapter. Prose inserts a standard Typst `#include` pointing to the original article. The chapter keeps its own images and modules; changes to it appear in the book, and renaming its library title preserves the reference. **Import Local Module → Library Documents** works the same way for shared Typst definitions. Each insertion is undoable.

PDF export compiles the whole book. Source-project export currently exports only the selected article's directory; it does not bundle other library articles referenced by the book.

## Writing and preview

Editor styling gently emphasizes headings, bold, italics and inline code. Moving the caret into a paragraph reveals its full source. Copying, saving and undo always use the original text. Change editor styling in Settings.

The preview shows real typeset pages. Double-click a page to reveal the source; source selection can locate the corresponding preview position. Zoom is relative to the preview pane's fitted width. Dark preview changes screen colors only; images retain their colors and exported PDFs are unchanged.

**Follow Writing** and **Return to Reading** sit beside the preview controls. Follow Writing tracks the caret in side-by-side mode after a
short pause. Scrolling the preview pauses it. A preview-to-source jump remembers
your reading position; Return to Reading restores it. Zoom, window resizing and
preview reloads preserve a page-relative position. This geometric anchor does
not guarantee the same paragraph after substantial document reflow.

While syntax is incomplete or invalid, Prose retains the last successful preview and marks it as out of date. Rendering only visible page regions reduces display work; it does not mean every invalid document can compile partially. Export fails on a compilation error instead of silently exporting an old PDF.

**Universe** searches the official package index by name, purpose and category. Browse drawing or diagram packages, check their documentation, and insert a pinned version. The index is cached for 24 hours and remains available offline. Packages that need a newer typesetting engine cannot be imported through the browser.

The library presents document titles and searchable content without requiring you to manage source filenames. Import a document or an entire project folder, rename it, or move it to the recoverable Trash. Source projects remain exportable. Command-N opens Templates, with an offline blank page and an original Prose guide featuring equations, a diagram, a table and numbered code. The guide’s pinned packages are included; code is displayed, not executed. New writing and existing files autosave after a short pause and retain a local recovery copy. Prose preserves the current draft before switching documents, and refuses to silently overwrite a file changed by another application. **Documents → Recover Draft Copy** reopens preserved drafts.

**Documents → Document History** compares and restores the latest seven source snapshots. Edited documents create checkpoints hourly by default, or daily in Settings; unchanged documents create none. Restoration first preserves current writing and remains undoable. History stays on this Mac and covers the current source file. See [document history](document-history.md).

iCloud support is under development. It requires a properly provisioned release and an iCloud Drive account; local development builds clearly report when unavailable. Real two-Mac delivery and conflict recovery remain release checks. See [sync status and limitations](library-and-sync.md).

## Diagnostic logs

Use **View → Open Diagnostic Logs** or `⌘J → v → g` to reveal `~/Library/Application Support/Prose/Logs/events.jsonl`. The current log rotates at about 1 MiB and retains three archives.

Logs record sessions, versions, event order, command/navigation keys, insertion and save/export outcomes, selection ranges and service failures. Ordinary typing is recorded only as a `text` event. Document text, clipboard contents, search terms and field values are not logged. System error messages may contain file paths. Logs stay on the Mac; keep them alongside a macOS crash report when investigating a problem.
