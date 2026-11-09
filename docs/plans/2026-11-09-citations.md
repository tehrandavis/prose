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

## Step A outcome (2026-11-09)

- Engine, C ABI version 3. `files_changed(paths, count)` calls `FileStore::reset()`, gives each changed file under the root a new version (editor buffers keep theirs and keep winning), ignores paths outside the root, and returns how many of the files the main file, the last refresh or any render read. Render results also carry the block's plain text (`text`, `text_length`; `RenderedBlock.text`, `WritingRendering.text`), so tests read what a block shows instead of pixels. `PRRenderAPI` is 128 bytes, `PRRenderResult` 184. Swift: `BlockRenderer.filesChanged(_ urls: [URL]) -> Int`.
- Deviation: citations never rendered in Writing mode before this step. A citation showed `??` (the stub-label method cannot find a citation's target, which is a bibliography entry at a derived location), and the bibliography block showed only its title. Test 1 needs both, so the block document now gets, for a block that cites or holds the bibliography, every key the full compile cites, in order, and the document's `bibliography(...)` call, inside `#place(hide[...])` with `#set bibliography(title: none)`. Citation numbers and entries then match the whole document, and the block's dependencies include the `.bib` file. Cite keys get no stub label. The hidden call is used only when the bibliography call is in the same folder as the block's file; otherwise citations show `??` as before.
- Swift. `projectFilesChanged` collects changed paths under the project root and waits for the burst to pause for 300 ms (`projectChangeDelay`). Then Typst files other than the open one go in through `setText`, every changed file goes to `filesChanged`, and when the document read any of them `WritingLayout.filesChangedOnDisk()` asks for a refresh at once. A refresh after a change on disk starts a new render epoch even when the compile fails, so every block in view asks for its render again; the engine's cache answers for blocks whose block document and files are unchanged. A change to a file the document does not read is reported but refreshes and re-renders nothing. FSEvents latency went from 0.3 s to 0.1 s, so a burst's callbacks arrive closer together than the 300 ms pause.
- Tinymist needed no fallback. A real Tinymist export after the `.bib` changed, with no edit, held the new title and the newly cited entry within about 0.22 to 0.24 s, written in place, then replaced by a rename (a new inode), then in place again. The pinned server has no `workspace/didChangeWatchedFiles` handler; its own `notify` watcher handles both kinds of write.
- Acceptance tests 1 to 3 (`Tests/ProseAppTests/BibliographyReloadFlowTests.swift`): Writing mode shows the new title, entry `b` and the citation `[2]` about 0.35 s after the write, for both kinds of write; ten writes within 200 ms cause one report and one refresh; a change to `notes.txt` re-renders no block and leaves the cache counters unchanged.
- Acceptance test 10: on SICP, `files_changed` takes 0.07 to 0.09 ms on the engine thread. Reading the files again adds about 27 to 33 ms to the next refresh (61 to 71 ms against 33 to 38 ms unchanged). The main thread only normalizes paths and schedules tasks.
- Old plan files and the work log list "an external file change triggers no refresh" as open; no current document did, so nothing else changed there.
- Results: `cargo test --release` passes (36 tests, 6 new in `tests/reload.rs`); rustfmt and clippy (`-D warnings`) are clean; 271 core and 194 app tests pass, coverage 89.45 percent; lint and the release build pass. The book benchmark passes in Code, Writing and Focus (load average 6.8 / 27 / 32 at the start; Writing typing median 6.67 ms War and Peace, 4.34 ms SICP; Writing engine 640 to 704 MiB).
- Main-session rerun: 36 engine tests (`cargo test --release`), lint (0 violations) and the release build pass; 271 core and 194 app tests pass with no failure, coverage 89.39 percent. Book benchmark, all gates pass in Code, Writing and Focus (load average 5 to 11); typewriter step p95 21.29 ms (War and Peace) and 21.63 ms (SICP).
- **Open item, to measure in step C.** Every block that cites now compiles the document's bibliography with it. The book fixtures cite nothing, so the cost on a citation-heavy document (a thesis chapter with a few hundred citations and a 1,000-entry `.bib`) is unmeasured. Step C adds such a fixture and records first-render and typing times in Writing mode.

## Step B outcome (2026-11-09)

- Engine, C ABI version 4. Two calls return JSON, released with `string_free`: `bibliography_files(engine)` and `bibliography_entries(engine, paths, count)`. JSON keeps the ABI to two function pointers for nested, variable data (author lists, optional fields); the cost is about 9 to 11 ms to encode 2,000 entries (553 KB) on the engine thread. `PRRenderAPI` is 144 bytes; nothing else changed size. Swift: `BlockRenderer.bibliographyFiles() -> [String]` and `BlockRenderer.bibliography(_ files: [String]) -> BibliographyContents`, which decodes inside the actor. Hayagriva 0.10.1, biblatex 0.12.0 and serde_json 1.0.154 are now direct dependencies at the versions Typst already pins; `Cargo.lock` gains no new package.
- Entry fields: key, type (Hayagriva's, kebab case: a BibLaTeX `inproceedings` is `article`), title, authors (family name with its prefix, given names with any suffix; the editors when there are no authors; Swift `Author.display` gives "Smith, J."), year (the entry's date, else a parent's), container (the first parent's title: journal, book, proceedings), DOI, URL, file (relative to the root) and line. Errors carry file, line (0 when there is none, as for a missing file) and message. Each file reports its entry count and whether Typst accepts it.
- Parsing follows Typst's `decode_library`: the extension chooses BibLaTeX or Hayagriva YAML. For BibLaTeX the engine runs Hayagriva's own two steps (`biblatex::Bibliography` parse, then `hayagriva::Entry::try_from` for each entry) with the raw parse in between to read each entry's line.
- Malformed entries, as Hayagriva behaves:
  - A BibLaTeX syntax error (an unclosed brace, a key twice in one file) stops the parser. The file lists no entries and reports one error with its line. Malformed YAML is the same.
  - A field Hayagriva cannot convert (found: `year = {abc}`; a bad `date`, `urldate`, `pages` or `month` converts without error) fails only that entry's conversion, but `from_biblatex_str` and therefore Typst reject the whole file. The index lists the file's other entries, reports the bad entry with its line, and marks the file `accepted: false`, so the picker can say the document will not compile until the entry is fixed. This is the "rest still load" of acceptance test 4; it is not a recovery Typst makes.
  - A key in two files is listed once, from the first, and reported in the second as a duplicate, since Typst rejects it. A missing file, a file that is not UTF-8 and an unknown extension are reported with line 0.
- Reading and cache: files are read through the engine's world (an editor buffer from `set_text` wins; otherwise `FileStore`), so step A's `files_changed` makes a changed file read again. Each file's parse is cached by its version; an unchanged file is not parsed again even after `FileStore::reset()`. Reading for the index does not count as a document read for `files_changed`.
- Where file discovery lives: the engine finds linked files from syntax trees, not from the full compile, so a document whose compile fails (often because of the bibliography) still names its files. It walks the main file and every file reached through `include` with a string literal, depth first, from current texts, and takes `bibliography("a.bib")` and `bibliography(("a.bib", "b.yml"))`, paths relative to the calling file (`/x.bib` from the root); a non-literal argument names nothing. The fallback lives in Swift: when the engine names no file, `BibliographyIndex.load` lists every `.bib`, `.yml` and `.yaml` in the project with `ProjectTree.bibliographyFiles(in:)` (hidden files and symbolic links skipped, off the main thread) and marks each `BibliographyFile.linked = false`. A `.yml` that is not a bibliography then shows as a file error from an unlinked file; the picker can ignore those.
- `BibliographyIndex` (ProseCore, main actor): `contents` (entries, errors, files), `isLinked`, `revision` (moves only when the contents change), `reload(using:root:)` (engine calls and the search table built off the main thread), `update(_:)`, and `search(_:limit:)`. Search folds case, diacritics and width; every query word must match; ranking is by the weakest word: key prefix, then author family or year prefix, then title word prefix, then anywhere in key, authors, title, container, DOI or year, ties in file order. All entries' folded text sits in one UTF-8 buffer, so a word is one `memmem` pass plus a closer look at the entries it hits.
- Tests. Rust `tests/bibliography.rs` (9): every field from BibLaTeX and YAML fixtures; both formats in one call, and Typst compiles every listed key; malformed entries (field error, syntax error, malformed YAML, missing file, unknown extension); a duplicate key across files; `files_changed` then a new entry, and the unchanged file's cached parse; an editor buffer over the disk; discovery for one path, an array with a root path, calls in included files with relative paths, a nested include, an include cycle, non-literal calls, the main file's buffer; 2,000 generated entries. `tests/ffi.rs` gains the layout and a JSON round trip. Swift `BibliographyIndexTests` (7): acceptance test 4 through `BlockRenderer`; the unlinked fallback; reload after `filesChanged` and with a buffer; ranking and diacritics; the revision; author initials; 2,000 entries.
- Performance, 2,000 generated BibLaTeX entries (703 KB): the engine parses them in 31 to 36 ms in `cargo test --release` (target 200 ms); a cached call takes about 0.7 ms plus JSON. Through `BlockRenderer` in the debug Swift test build, the engine call with decoding takes 53 to 90 ms alone and up to 400 ms during the full parallel suite; building the search table takes 110 to 160 ms (debug, off the main thread in `reload`). Search, 100 queries on the main thread: mean 0.8 to 1.5 ms, slowest 1.7 to 2.0 ms of thread CPU time. The test asserts CPU time under 5 ms per search and wall time under 5 ms on average: in the first full-suite run one search took 50 ms of wall time while the rest of the suite held the CPU, which is scheduling, not search work. No real Zotero export was found under the repository, so none was measured.
- Results: `cargo test --release` passes (46 tests); rustfmt and clippy (`-D warnings`, 1.92.0) are clean; lint 0 violations (SwiftFormat changed only layout in the new files); the release build passes. Full suite: run 1 failed only the wall-clock search assertion above (changed to CPU time); run 2 failed only `focusModeDimsEveryBlockButTheFocusBlocks` (light: equation dimmed at 0.35 against 0.45 ± 0.03; this step changes no drawing); run 3 passed with 278 core and 194 app tests, coverage 89.55 percent. Book benchmark under load average 23 / 27 / 45 at the start: every gate passed except the War and Peace typewriter step p95, 33.30 ms against 33 ms; a rerun at load 17 / 22 / 39 passed every gate (typewriter p95 32.69 ms War and Peace, 31.79 ms SICP; Writing engine 661 to 748 MiB). This step adds no work to the editor's paths.
- Open items for step C: nothing calls `BibliographyIndex.reload` yet. The picker should reload when it opens, after `filesChanged` reports a bibliography file, and after an edit that may change a `#bibliography` call. Showing errors from unlinked `.yml` files is the picker's choice.
- Main-session rerun (load average 17 to 33 from Spotlight indexing): all engine tests, lint (0 violations) and the release build pass; 278 core and 194 app tests pass with no failure, coverage 89.51 percent. The benchmark was not rerun: step B changes no editor path, and under this load its numbers would not measure Prose. It runs at the phase gate.
- **Open item (seen once).** `focusModeDimsEveryBlockButTheFocusBlocks` failed in one subagent run under heavy load (an equation measured 0.35 against 0.45 ± 0.03); it passed in the next two full runs. If it fails again, look for a draw that happens before the dimmed copy is ready.
