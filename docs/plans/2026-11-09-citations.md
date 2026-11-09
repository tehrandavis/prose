# Citations: bibliography files, a citation picker and Zotero

Date: 2026-11-09
Status: accepted 2026-11-09 as Phase 5 (answers at the end). Choices still open to review are marked **Choice**.
Place in the roadmap: Phase 5, before the polish work, which becomes Phase 6. The polish phase's screenshots and writing-guide update then cover citations too.
Spec: `docs/prose-spec.md` Sections 3.3, 5 and 7. Builds on Phases 3 and 4 (`docs/plans/2026-11-08-phase-3-writing-mode.md`, `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`).

## Goal

At the end of this phase:

1. A change to a bibliography file on disk (a Better BibTeX export, a `git pull`, an edit in another app) reaches both engines without an edit in the document. The preview, the PDF and Writing mode show the new or changed references within about 2 s.
2. A citation picker in the `⌘J` panel lists every entry in the project's bibliography files, searchable by author, title, year and key, and inserts a Typst citation at the caret.
3. If the spike in step D passes: the picker has a second source, the Zotero library on this Mac. Choosing a Zotero item writes its entry into a project file and inserts the citation.
4. The `.typ` and `.bib` files on disk stay the only truth. Nothing Prose builds needs Zotero to compile, preview or export.

## Terms

| Term | Meaning |
|-|-|
| Bibliography file | A BibLaTeX (`.bib`) or Hayagriva (`.yml`, `.yaml`) file in the project |
| Entry | One reference in a bibliography file, with a key |
| Key | The name a citation uses: `smith2020` in `@smith2020` |
| Citation | `@key`, `@key[p. 4]` or `#cite(<key>)` in the source |
| Picker | The citation search in the `⌘J` panel |
| Zotero source | The Zotero library on this Mac, read through Better BibTeX or Zotero's local API |
| Better BibTeX | The Zotero plugin that gives stable keys and can keep a `.bib` file exported automatically |
| External change | A change to a project file by anything other than Prose's editor buffer |

## The reload defect: what happens today

Each engine was checked in the code on 2026-11-09.

**Prose's file watcher.** `ProjectWatcher` (FSEvents, `WorkspaceProject.swift`) reports every changed path in the project folder. `Workspace.projectFilesChanged(_:)` (`WorkspaceWriting.swift`) then drops every file that is not `.typ`, and sends the `.typ` files to the block engine through `setText`. A changed `.bib` goes nowhere.

**The block engine (Writing and Focus modes).** It reads files that are not editor buffers through Typst's `FileStore` (`Engine/RenderBridge/src/world.rs`, `Shared.files`). `FileStore` loads a file once and serves the same bytes until `FileStore::reset()` is called. The engine never calls `reset()`. So a `.bib` read once stays as it was for the life of the engine, which lasts until the project changes or the window closes. Passing the change through `setText` would not be right either: `setText` makes an editor buffer, which then wins over the disk for good.

**No refresh after an external change.** Phase 3 left this open: a change from disk reaches the engine but does not trigger `refresh()`. Citation texts, the bibliography and counters come from the full compile, so they stay old until the next edit.

**Tinymist (preview and PDF export).** Tinymist watches each file its last compile read, with its own watcher (`crates/tinymist-project/src/watch.rs` in the pinned source, using the `notify` crate). So the preview probably already updates when a `.bib` changes. This is not confirmed: no test covers it, and editors that write a file by replacing it (as Better BibTeX may) can defeat a watcher that watches single files.

So "make any edit" in the writing guide is true for Writing and Focus modes, and probably not needed for the preview.

## Decisions

### 1. The reload fix

- **Engine (C ABI version 3).** A new call `files_changed(paths)`: it calls `FileStore::reset()` and gives each changed file a new version number. `reset()` marks every loaded file stale, and the next access reloads it from disk; source files are edited in place, so incremental compilation still works. The new version makes every cached block render whose recorded dependencies include that file miss the cache (`Engine/RenderBridge/src/cache.rs` already keys dependencies by file and version). `FileStore` has no reset for one file, so all files reload once, lazily. Step A measures what that costs on SICP; the expectation is a few milliseconds, because only files a compile reads are loaded again.
- **Swift.** `projectFilesChanged` sends every changed file under the project root that is not open in the editor:
  - `.typ` files through `setText`, as now.
  - Every other file through `files_changed`: bibliography files, CSV and JSON data, images.
  - A changed file that is open in the editor follows the existing conflict rules for the open document.
- **Refresh.** After an external change the engine runs `refresh()`, debounced by 300 ms so that a burst of writes counts as one change. Then Writing mode re-renders the blocks in view whose render depended on a changed file, or whose citation texts changed. The cache decides which ones actually compile again.
- **Tinymist.** Step A first tests whether the preview updates after a `.bib` changes on disk, both when the file is written in place and when it is replaced by a rename. If either case fails, Prose sends `workspace/didChangeWatchedFiles` for the changed files. Step A checks that the pinned Tinymist handles that notification. If it does not, Prose sends `didChange` for the main document with its unchanged text, which makes Tinymist compile again. **Choice:** the fallback is used only if the test shows Tinymist needs it.
- The writing guide's "make any edit" sentence goes when the fix ships.

### 2. Source-first

All citation data lives in project files. The picker reads them. The Zotero source writes into them. The document compiles, previews and exports the same with Zotero closed or uninstalled.

### 3. The entry index

- A new engine call parses bibliography files with Hayagriva, the parser Typst itself uses. It is already in the engine's dependency tree. For each entry it returns the key, type, title, authors, year, container title, DOI, the source file, and any parse errors. A key the picker shows is therefore a key Typst accepts.
- Results are cached by file and version, so the reload fix also refreshes the index.
- Which files the index reads: the files named in the project's `#bibliography(...)` calls, found through the syntax tree. If there is none, it reads every `.bib`, `.yml` and `.yaml` file in the project and marks them as not yet linked.

### 4. The picker

- It is a new entry in the `⌘J` References group: "Cite a Source". The existing `citation` command, which asks for a key as free text, stays for keys the index does not know.
- The picker uses the command panel's search state. Typing filters entries by author, title, year and key. Each result shows the first author, the year, the title and the key.
- Return inserts `@key`. With a selection of citations already at the caret, it adds the new one after them. **Choice:** `⌥Return` opens one field for a supplement (a page or section) and inserts `@key[p. 4]`.
- It inserts only in markup, using the existing insertion-context check: never inside math, code or raw text.
- If the document has no `#bibliography` call, the first insertion offers to add one for the file the entry came from, at the end of the main file. That uses the existing `bibliography` command.
- In Writing mode a new citation shows its final text after the next refresh, which the insertion asks for at once. Until then, its block shows source.
- Tinymist already completes `@` keys while you type. The picker adds search and browsing; it does not replace completion.

### 5. Zotero (steps D and E)

- **Two possible sources, both to be confirmed by the spike:**
  - Better BibTeX's JSON-RPC endpoint (`http://127.0.0.1:23119/better-bibtex/json-rpc`, with methods to search items and export them as BibLaTeX).
  - Zotero 7's local API (`http://127.0.0.1:23119/api/`, read-only). It must be turned on in Zotero's settings.
- **Choice:** prefer Better BibTeX when it answers. Its keys are the same keys its auto-export writes, so a citation inserted from Zotero matches the exported file. Use the local API otherwise.
- Zotero must be running. If it is not, the Zotero tab says so and the project tab still works.
- The App Store edition is sandboxed, but its entitlements already include `com.apple.security.network.client`. The spike still checks a loopback request from a sandboxed build.
- **Linked export, per project (Tehran's answer, 2026-11-09).** Tehran uses Better BibTeX with an auto-exported `.bib`. Each project can link one of its bibliography files as a Better BibTeX auto-export, with the Zotero collection behind it when the spike finds a way to read it. Prose stores the link with the project's other settings in `Application Support/Prose/Projects/recent.json`, never in the project folder (spec Section 3.4). Prose proposes the link itself when a project `.bib` is a Better BibTeX export (step D finds how to tell: the file's header, or Better BibTeX's own list of auto-exports). With a link, the Zotero tab searches that collection first and the rest of the library after it, and Prose never writes into the linked file.
- **Where a Zotero entry is written.** If the target `.bib` is a Better BibTeX auto-export, anything Prose appends is lost at the next export. The proposal:
  - When the item's key is already in a project bibliography file, Prose inserts the citation only.
  - Otherwise Prose appends the entry to a Prose-owned file, `references-prose.bib`, and adds that file to the `#bibliography` call (Typst accepts an array of files).
  - Whenever another bibliography file gains a key that `references-prose.bib` also has (the next auto-export picked it up), Prose removes the duplicate from its own file, because Typst rejects a key defined twice.
  - The other way is to always append to the one `.bib` file, which is simpler but wrong for auto-exported files.

### 6. Out of scope

Citation styles (`#bibliography(style:)` already has a command), editing entries inside Prose, PDF attachments, notes and annotations from Zotero, and Zotero's word-processor plugin protocol.

## Steps

As in Phases 3 and 4: one Opus subagent per step, in this checkout, one at a time. The main session reviews each diff, reruns lint, the release build and the full suite, plus the book benchmark when a step touches drawing, layout or the engine. It commits each step with an outcome section in this note and pushes.

| Step | Builds | Checks |
|-|-|-|
| A. Reload fix | Decision 1: ABI version 3 with `files_changed`; the Swift path for files that are not `.typ`; refresh after external changes; the Tinymist test and its fallback if needed | Acceptance tests 1 to 3; `cargo test --release`; the benchmark, since engine paths change |
| B. Entry index | Decision 3: the Hayagriva call, a Swift wrapper, the cache by version, the list of linked files | Acceptance test 4; parse every entry of a large real `.bib` (a Zotero export of more than 1,000 entries, if Tehran provides one; otherwise a generated file) in under 200 ms |
| C. Picker | Decision 4 | Acceptance tests 5 to 7 |
| D. Zotero spike | No product code. Answers: does each source exist and answer on this Mac; the exact methods and parameters; key agreement between search results and the auto-export; speed of a search over the real library; access from a sandboxed build | A short report in this note. If both sources fail, step E is dropped and the Zotero guide text stays the answer |
| E. Zotero source | Decision 5, after Tehran answers the question there | Acceptance tests 8 and 9 |
| F. Gate and documents | Three full runs of the suite and the benchmark; spec, architecture, writing guide, `CLAUDE.md`, work log | All acceptance tests pass three runs in a row |

## Acceptance tests

UI tests are `extension WritingFlowTests`. Each one checks that the storage equals the source, that no attachment exists, and that TextKit 2 is still on.

**Reload**

1. A project with `#bibliography("refs.bib")` and `@a` in Writing mode: rewrite `refs.bib` on disk with a new title for `a`, and add an entry `b` that the text already cites. Within 2 s and with no edit, the rendered bibliography block and the citation of `b` show the new texts. Do it twice: once writing the file in place, once by writing a temporary file and renaming it over `refs.bib`.
2. The same change with Tinymist: an export of the PDF after the change, with no edit, contains the new title and the reference `b`.
3. A burst of ten writes within 200 ms causes one refresh. A change to a file the document does not read re-renders no block.

**Index and picker**

4. The index of a fixture with BibLaTeX and Hayagriva files returns every key with author, year and title. A malformed entry is reported with its file and line, and the rest still load.
5. In the picker, typing part of an author name, a year or a key finds the entry. Return inserts `@key` at the caret in markup, as one undoable edit. In math or raw text the command is refused with the existing message.
6. `⌥Return` inserts `@key[p. 4]`. In a document with no `#bibliography` call, the first insertion offers to add one, and accepting it adds the call in the main file.
7. In Writing mode the block with the new citation shows the final citation text after the refresh, with no question marks.

**Zotero (only if step E runs)**

8. With a scripted local server that answers like the Zotero source: a search returns items, and choosing one whose key is already in `refs.bib` inserts only the citation, with no file change.
9. Choosing a new item appends it to `references-prose.bib` and adds that file to the `#bibliography` call. When `refs.bib` then gains the same key on disk, the duplicate leaves `references-prose.bib`, and the document compiles with no duplicate-key error. With no server, the Zotero tab says that Zotero is not running.

**Performance**

10. The book benchmark passes in all three modes. A `files_changed` on SICP's project costs under 50 ms on the engine thread, and nothing on the main thread beyond scheduling.

## Risks

- **Tinymist's watcher and replaced files.** If Better BibTeX replaces the file and Tinymist's watcher loses track of it, the fallback in decision 1 applies. Test 1 covers both kinds of write.
- **Reset reloads everything.** `FileStore::reset()` marks every file stale, not only the changed one. Step A measures the cost on a book.
- **Two writers to one file.** Prose never writes a bibliography file that another program exports. Decision 5 keeps Prose's additions in its own file.
- **Zotero endpoints.** The method names and paths in decision 5 come from memory and are not confirmed. The spike exists to confirm them before any product code depends on them.
- **Key mismatch.** Zotero's own BibTeX export makes keys differently from Better BibTeX. A citation inserted with one kind of key will not match a file exported with the other. Preferring Better BibTeX avoids this when it is installed.

## Answers (2026-11-09)

1. Citations is Phase 5; polish moves to Phase 6.
2. Tehran uses Better BibTeX with an auto-exported `.bib`. Decision 5 now links that file per project and never writes into it. The spike also checks whether Better BibTeX can add an item to the exported collection; if it can, choosing an item outside the collection adds it there and waits for the export, and `references-prose.bib` is only the fallback.
3. The step D spike may search Tehran's real Zotero library on this Mac, read-only.
