# Quiet home window: the app opens on a blank page

Date: 2026-11-15
Status: Accepted 2026-11-15, with every recommendation (see "Answers"). Every decision that is a choice and not a fact is marked **Choice** so it can be reversed.
Spec: `docs/prose-spec.md`, Sections 3.3, 3.4, 4 and 8. Builds on "Fixes after Phase 5" in `docs/plans/2026-11-09-citations.md` (the home window's close button).

## Goal

Tehran asked for this on 2026-11-15:

> I think the home window could probably stand to be quieter. I like the idea of just opening it up and having a blank page in front of me. I think all the templating that's in the home window should maybe still be there, but it's something that I select. Maybe a small, inconspicuous button up near the title bar. Also, when I hover over or select a project in that home window, it needs to be highlighted. There's really nothing that tells me ... that the thing that I'm clicking is clickable or openable.

Three changes follow.

1. **The app opens on a blank page.** The writer can type at once. The template gallery and the document list no longer fill the window.
2. **Templates are something the writer selects.** One small button in the toolbar opens the gallery that exists today (built-in templates, the sample book, Typst Universe). Nothing is removed.
3. **Every row that opens something says so.** It highlights under the pointer, shows the pointing hand, shows a selection, opens with one click, and works from the keyboard and with VoiceOver.

He said this in answer to "Should `⌘W` on the home window keep quitting the app?", so the note also decides what `⌘W` and the red close button do.

The hard rules hold: the text storage keeps the full source, nothing touches `layoutManager`, icons are Phosphor, the interface is English only, and colours, radius and spacing come from Section 4 of the spec.

## Terms

| Term | Meaning |
|-|-|
| Home state | Today's `Workspace.isLibraryHome`: no document is open and the window shows the document list or the template gallery in place of the editor |
| Blank page | A library document titled "Untitled" whose text is still `DocumentTemplate.blank.source`, open in the editor and ready for typing |
| Untouched | A blank page the writer has not changed: same text, same title, no added files |
| Kept | A blank page stops being untouched at the first edit or rename. From then on it is an ordinary library document |
| Recents | Recent folders (`ProjectStore.recent()`) and recent library documents (`LibraryController.reopenableRecentIDs`, then the rest by date) |
| Gallery | `UniverseBrowser` in `.templates` mode: Blank page, Welcome, the SICP sample and the Universe templates |
| "Your writing…" sheet | `LibraryBrowser` shown as a sheet (`libraryOpen`): search, folders, documents, Trash, import, iCloud state |
| Open row | Any row that opens a document, folder, file or heading when clicked |

## What the existing code gives

- **One window that never closes.** `AppDelegate.windowShouldClose` always returns false. On a document it calls `Workspace.closeDocument()`; in the home state it calls `terminateApplication`. File › Close Document (`⌘W`) is `performClose` with a nil target, so it also closes Settings and other windows, and on the writing window it reaches the same delegate method as the red button. The two cannot be told apart today.
- **What launch shows.** `Workspace.init` reads `recovery.json` and restores the last document, or the home state if the snapshot says `libraryHome`. A first launch has no snapshot and opens the Welcome guide in split layout; `LibraryController.start()` then adopts it into the library.
- **How the home state is reached.** `closeDocument()` first steps back inside the project (navigation history, then the main entry). With nothing left it calls `closeToRecentDocument()`, which reopens the library document opened before this one, "like closing a tab". When there is none it calls `showLibraryHome()` and `openDiscovery(.templates)`, so the gallery fills the window. Trashing the open document (`LibraryController.moveToTrash`, `agentFinishMetadataChange`) and a document found trashed at start also call `showLibraryHome()`.
- **The home state disables most of the app.** About 30 guards read `isLibraryHome` (save, service start, spell check, hover, toolbar items, print). `ContentView` swaps the whole editor for `LibraryBrowser`.
- **`⌘N` opens the gallery.** `newDocument()` is `openDiscovery(.templates)`. The gallery's "Blank page" button calls `library.create(builtIn: .blank)`, which makes a library document and opens it. Each press makes a new document; nothing removes one that was never used.
- **The gallery and the list already work as a sheet.** With a document open, `openDiscovery` and `openLibrary` set `libraryOpen`, and `ContentView` shows `LibraryBrowser` as a sheet. `LibraryBrowser` shows `UniverseBrowser` when `discoveryMode` is set. Phase 7 needs no new presentation code.
- **The toolbar's left group** (`DocumentTitle` in `WindowToolbar.swift`) has the sidebar button, the "Your writing" button (`files`, `⌘O`) and the title. `QuietButton` already draws a hover wash and help text.
- **The sidebar draws selection and no hover.** `ProjectSidebar.fileRow` fills the open file's row with `Theme.sidebarSelection` and opens on one click. Nothing changes under the pointer, and heading rows have no fill at all. The list in `LibraryBrowser` is weaker: a folder row opens on one click, a document row renames on a click of its title and opens on a double click, and neither shows hover, selection or a pointing hand. The only mark is a 2 pt capsule beside the open document.
- **Theme tokens.** `Theme.sidebarSelection` exists (violet at 10 and 22 percent, composed on the sidebar colour). There is no hover token; `QuietControlStyle` uses secondary text at 8 percent. The spec's hover is black at 4 percent and white at 5 percent.
- **No permanent delete for one document.** `DocumentLibrary` has `trash`, `restore` and `emptyTrash`. An unused blank page can only be trashed today, and Trash would fill with empty documents.
- **A buffer with no file exists** (`fileURL == nil`, "Local Draft"), but it is only used for the first launch, and adoption into the library goes through `open()`, which reloads the editor and moves the caret to the start.
- **Tests that hold today's behaviour.** `WindowCloseFlowTests` (five tests), `TemplateStartFlowTests` (three), parts of `LibraryFlowTests`, `PackageSourceFlowTests` and `ProjectFlowTests` expect the home state after a close. `closeCommandUsesTheWindowResponder` needs `⌘W` to close Settings and other windows. Tests ask the window delegate directly, because `performClose` on a refusing delegate ends the test host's run loop.

## Decisions

### 1. What launch shows

**Choice:** Prose opens on a blank page at every launch. Tehran's words were "just opening it up and having a blank page in front of me". The last document is one click away in the sidebar (decision 4) and in File › Open Recent (decision 6).

Two exceptions:

- **Unsaved work.** If `recovery.json` holds text that differs from the saved text (a crash or a failed save), Prose restores that document, as today. A blank page must never hide unsaved work.
- **First launch.** With no `recovery.json`, Prose opens the Welcome guide, as today. **Choice:** a new install should see the guide once; it affects no one who has run Prose before.

**Choice:** Settings gets one picker, "When Prose opens: Blank page / Last document", default Blank page. A thesis writer may want the last document every time, and the second value is today's behaviour, so it costs one stored value and one branch.

A file opened from Finder (`application(_:openFiles:)`) opens that file, as today.

### 2. What a blank page is and where it lives

**Choice:** a blank page is a real library document, made by the same path as the gallery's "Blank page" button, with one rule added: **there is never more than one untouched blank page.**

- The library stores the id of the untouched blank page in `blank-page.json` in the state directory.
- A request for a blank page (launch, `⌘N`, `⌘W` on a document, trashing the open document) first looks for that id. If the document still exists and is still untouched, Prose opens it. If not, Prose creates one and stores its id.
- The first edit or rename makes the page kept: the id is cleared and the document is an ordinary "Untitled" document from then on.
- When the writer leaves an untouched blank page for another document or folder, Prose deletes it for good (not to Trash). A new method, `DocumentLibrary.discardUntouched(_:expecting:)`, deletes only if the text on disk still equals the blank source and the folder holds no file beyond the source and `document.json`. A page that fails the check is left alone and becomes kept.
- At quit, an untouched blank page stays, and the next launch opens it again with no wait.
- While untouched, the page is left out of recents, the "Your writing…" list and Open Recent, so the writer never sees a row named "Untitled · Empty document".

Why a real document and not a buffer with no file: every path the editor has (autosave, history, Tinymist, Writing mode, the preview) expects a file, and each is tested with one. A buffer with no file would have to become a document at the first key, and the only code that does that today reloads the editor and moves the caret. The cost of the choice is the bookkeeping above.

The blank page's text stays `DocumentTemplate.blank.source` (two `#set` lines, then an empty line). The caret starts on the empty line.

**Choice:** a blank page opens in Writing mode, where the two `#set` lines fold into one "Document setup" row (Phase 6), so the page looks blank. Other documents open as they do today; per-document mode memory is Phase 9.

### 3. The home state after this phase

The writer no longer reaches the home state in normal use. Every place that calls `showLibraryHome()` for the writer calls a new `Workspace.showBlankPage()` instead: it clears the old document as `showLibraryHome()` does, then opens the blank page.

The home state stays in the code as the fallback for one case: the library cannot give a blank page (iCloud failed to resume, the disk is full). Then the window shows `LibraryBrowser` in place, with its error line, as today. This keeps the 30 guards and their tests, and it keeps a safe place to stand when no document can open. In that state the gallery does not open by itself any more.

### 4. Where recents go: the sidebar of a blank page

Today a library document's sidebar shows its own folder. For an untouched blank page that is one row, `main.typ`, which tells the writer nothing.

**Choice:** while the open document is an untouched blank page, the sidebar shows recents in place of the file tree:

- A "Folders" group: up to 5 recent folders, each with a folder icon and its name; the parent path shows as hover help.
- A "Documents" group: up to 8 recent documents by title.
- A last row, "All writing…", that opens the "Your writing…" sheet.
- The search field stays hidden, as it is for a document with no project.

The rows are 26 pt high and use the row style of decision 5. One click opens, as a file row does. When the page becomes kept, the sidebar shows the document's own folder, as for any library document. The change happens at the first key, while the writer looks at the page; it is named in Risks.

`⌘0` still hides the sidebar, for a window that is only a page.

### 5. Open rows: hover, selection, pointer, click, keyboard, VoiceOver

One shared style, `OpenRowStyle` (a view modifier in `Theme.swift`), for every open row:

| Property | Value |
|-|-|
| Hover fill | New token `Theme.hover`: black at 4 percent light, white at 5 percent dark (`ThingsLook.hover`) |
| Selection fill | Violet at 10 percent light, 22 percent dark (`ThingsLook.selection`); `Theme.sidebarSelection` in the sidebar, a new `Theme.selection` on the page colour in the sheet |
| Shape | Rounded rectangle, radius 6 in the sidebar (as now), 8 in the sheet |
| Pointer | Pointing hand over the row |
| Click | One click opens. **Choice:** this matches the sidebar and the folder rows; the document rows' "click the title to rename, double-click to open" goes away in the list |
| VoiceOver | Each row is one element with the button trait, a label ("Thesis, folder" or "Notes, document, edited 2 hours ago") and the selected trait when selected |

It applies to:

- the recents rows on a blank page (decision 4);
- the sidebar's file rows and heading rows, which gain hover and the pointing hand (their selection is unchanged);
- the folder rows and document rows of the "Your writing…" sheet.

**Rename in the sheet** moves to the context menu ("Rename…", which exists) and stays on the toolbar title. The trash button on a document row stays; it shows only while the row is hovered or selected, so the list is quieter.

**Keyboard in the sheet.** The search field keeps the focus. Down and Up move a selection through folder rows and document rows; Return opens the selected row; Escape closes the sheet. With no selection, Down selects the first row. The open document's row is selected when the sheet opens. The 2 pt capsule goes away, because the selection fill now carries that meaning.

**Keyboard in the sidebar recents.** Full Keyboard Access reaches the rows as buttons. Arrow-key movement in the sidebar is not in this phase: the file tree does not have it, and the two lists should gain it together.

**Hover in tests.** `OpenRowStyle` reads its hover from a small observable object, `RowHover`, with a `set(_ id:)` entry point, as `FocusChrome` exposes its state. Tests set the hovered row through it and read the fill from the drawn pixels; no test posts mouse-moved events.

### 6. Templates, samples and Universe: one toolbar button

- A `QuietButton` in the toolbar's left group, after "Your writing": icon `grid-four` (the icon the "Browse templates" button uses today, already in `Resources/Icons`), help "Templates", shortcut `⌘⇧N`, identifier `toolbar.templates`. It calls `openDiscovery(.templates)`, which shows the gallery as a sheet, as it does today from a document.
- **Choice:** `⌘N` makes a blank page (the reuse rule of decision 2 means repeated presses make nothing). The menu item is "New Document". A new item, "New from Template…" (`⌘⇧N`), opens the gallery. The `⌘J` command `new` keeps its path and opens the gallery, with the title "New from Template"; a command `newBlank` is added beside it.
- The gallery keeps everything: Blank page, Welcome, the SICP sample, Universe templates, the Packages tab, and "Your writing" as its back button.
- The "Browse templates" text button in the "Your writing…" header becomes the same icon button, so there is one way to draw it.

**File › Open Recent.** A new submenu under the Documents menu lists up to 5 recent folders, a separator, and up to 10 recent documents. It gives recents a keyboard and VoiceOver route that needs no sheet.

### 7. `⌘W`, the red button and `⌘Q`

| Action | On a document | On an untouched blank page |
|-|-|-|
| `⌘W` (Close Document) | Steps back inside the project as today (navigation history, then the main entry). With nothing left, saves and shows a blank page | **Choice:** quits, as `⌘W` on the home window does today |
| Red close button | **Choice:** saves and quits | Quits |
| `⌘Q` | Quits | Quits |

- `⌘W` no longer returns to the library document opened before ("like closing a tab"). **Choice:** close means close; the earlier document is in recents.
- Quit always goes through `terminateApplication`, so `applicationShouldTerminate` saves and drains history.
- To tell `⌘W` from the red button, the menu item gets its own action, `AppDelegate.closeFront(_:)`: if the key window is the writing window it calls `workspace.closeDocument()` (or quits on an untouched blank page); for any other window it calls `performClose`, so Settings and other windows close as before. `windowShouldClose` then serves only the red button and always quits.

### 8. What stays reachable

| Thing | Where |
|-|-|
| Open Folder (`⌘⌥O`) | Documents menu; the menu in the "Your writing…" header |
| "Your writing…" (`⌘O`) | Documents menu; the `files` toolbar button; "All writing…" in the blank page's sidebar |
| Import a document (`⌘⇧O`), import a project folder | Documents menu; the menu in the "Your writing…" header |
| Trash, Empty Trash | The menu and footer of the "Your writing…" sheet |
| iCloud state | Under the "Your writing" title in the sheet; Settings |
| Templates, samples, Universe | The new toolbar button; `⌘⇧N`; `⌘J` |
| Recover Draft Copy, Open external file | Documents menu and `⌘J`, unchanged |

## Steps

Each step is built by one Opus subagent and checked once by the main session: `bash scripts/lint.sh`, `scripts/build.sh release`, `PROSE_DISTRIBUTION=preview scripts/test.sh` with the 80 percent coverage gate, and the test report read for the "Test run with N tests in 2 suites" line. No step changes the editor's drawing, layout or scrolling, so the book benchmark runs only in the gate run at the end. Each step is committed with an outcome section in this note and pushed.

| Step | Scope | Checks beyond the full check |
|-|-|-|
| A | Open rows. `Theme.hover`, `Theme.selection`, `OpenRowStyle`, `RowHover`. Applied to the sidebar's file and heading rows and to the "Your writing…" rows; one click opens; rename by context menu; arrows and Return in the sheet; the trash button shows on hover or selection | Acceptance tests 1 to 4. `titleClickRenamesAndDoubleClickOpensLibraryWithoutChangingWriting` is rewritten for the new rule and its change is listed in the outcome |
| B | The blank page. `blank-page.json`, the reuse rule, `discardUntouched`, the kept transition, `showBlankPage()`, hiding the untouched page from lists. `⌘N` makes a blank page; "New from Template…" and the toolbar button open the gallery | Acceptance tests 5 to 8. A core test for `discardUntouched`: it refuses changed text, an added file and a renamed document |
| C | Close and launch. `closeFront(_:)`, the table of decision 7, launch on a blank page with the two exceptions, the Settings picker, the home state as fallback only | Acceptance tests 9 to 12. The five `WindowCloseFlowTests` and three `TemplateStartFlowTests` are rewritten; each change is listed in the outcome. Launch to an editable blank page is timed on a local and an iCloud library |
| D | Recents. The blank page's sidebar, File › Open Recent | Acceptance tests 13 and 14 |
| E | Spec Sections 3.3, 3.4 and 8, `CLAUDE.md`, `docs/` pages that describe the home window, the work log; the gate run | One gate run: the full check and `scripts/benchmark-books.sh` |

Step A comes first because it is the part Tehran can see and judge without any change to documents, and steps B to D reuse its row style.

## Acceptance tests

All are `extension WritingFlowTests`; every window goes through `placeOnTestScreen`; none posts events, shows a real file panel or calls `performClose` on the writing window.

1. `openRowsHighlightUnderThePointerAndWhenSelected`: with `RowHover` set to a sidebar file row, the row's pixels match `Theme.hover` on the sidebar colour in light and dark; the open file's row matches the selection fill; no other row changes.
2. `yourWritingRowsOpenOnOneClick`: one click on a document row opens it and closes the sheet; one click on a folder row opens the folder; a click on a title does not start a rename.
3. `yourWritingRowsWorkFromTheKeyboard`: Down and Up move the selection across folders and documents, the selected row draws the selection fill, Return opens it, and typing still goes to the search field.
4. `openRowsAreButtonsForVoiceOver`: each sidebar row, recents row and sheet row is one accessibility element with the button trait and a label that names its kind; the selected row has the selected trait.
5. `newDocumentReusesTheUntouchedBlankPage`: `⌘N` three times leaves one document in the library; after typing, `⌘N` makes a second one and the first keeps its text.
6. `leavingAnUntouchedBlankPageDeletesIt`: opening another document from a blank page leaves no "Untitled" document in the library or in Trash.
7. `aBlankPageThatWasTypedInIsKept`: one typed word, then another document opened: the page is in the library with its text, and it is listed in "Your writing…".
8. `theUntouchedBlankPageIsHiddenFromEveryList`: it is in none of the sidebar recents, the "Your writing…" rows, the document count and Open Recent.
9. `closeCommandOnADocumentShowsABlankPage`: `closeFront` on the writing window with a document saves it and opens a blank page; with Settings as the key window it closes Settings and leaves the document open.
10. `closeCommandOnABlankPageAndTheCloseButtonQuit`: `closeFront` on an untouched blank page calls the injected terminator once; `windowShouldClose` on a document with unsaved text calls it once, and `applicationShouldTerminate` saves the text.
11. `launchOpensABlankPageUnlessWorkIsUnsaved`: a workspace made from a state directory whose snapshot names a saved document opens a blank page; one whose snapshot has unsaved text opens that document with the text; with the setting on "Last document" it opens the last document; with no snapshot it opens the Welcome guide.
12. `aLibraryThatCannotMakeABlankPageShowsTheListInPlace`: with a store that fails to create, the window shows the home state with the error and no gallery, and the close button quits.
13. `aBlankPageListsRecentsInTheSidebar`: folders and documents show in order with "All writing…" last; one click on a document opens it and the sidebar shows that document's folder; after one typed word on a blank page the sidebar shows the page's own folder.
14. `openRecentMenuListsFoldersAndDocuments`: the submenu's items match recents, and an item's action opens its document.

## Risks

- **The sidebar changes at the first key.** Recents give way to the document's folder when the page becomes kept. If it distracts, the fallback is to keep recents until the document is closed or renamed; the switch is one condition.
- **Launch waits for the library.** A blank page needs `LibraryController.start()` when the last session did not end on one, and on an iCloud library that includes the resume. Until then the window shows an empty page that cannot be typed in. Step C times it. If it is over about 300 ms, the fallback is to make the next blank page at quit, so launch can open it from `recovery.json` with no wait.
- **A delete path for documents is new.** `discardUntouched` is the first code that deletes a library document without Trash. It checks the bytes on disk and the folder's contents and has its own core tests. If the check fails for any reason, the document is kept.
- **An untouched blank page syncs.** On an iCloud library, another Mac shows it as an empty "Untitled" document until this Mac leaves the page. The id file is local to one Mac.
- **Tests that hold the old behaviour.** About 12 tests expect the home state after a close. Each rewrite is listed in a step outcome, so a lost check is visible.
- **`closeFront` and the responder chain.** `⌘W` must still close a sheet's parent correctly, Settings and auxiliary windows. `closeCommandUsesTheWindowResponder` keeps those cases.
- **Agents.** `agentFinishMetadataChange` and the agent's document creation move the window between documents; they must leave an untouched blank page through the same discard path. `agentDocumentCreationRespectsNativeLibraryTransitions` covers it.

## Open questions for Tehran

1. **Launch.** A blank page at every launch, with a Settings picker for "Last document"? Or the last document by default and a blank page only when there is none? (Recommended: blank page by default, with the picker.)
2. **`⌘W` on a blank page.** Quit, or do nothing? (Recommended: quit, as the home window does today.)
3. **The red close button.** Save and quit from any document, or keep today's rule (close the document first, quit only from the blank page)? (Recommended: save and quit.)
4. **`⌘W` on a document.** Always a blank page, or back to the document opened before it, as today? (Recommended: a blank page.)
5. **Recents on the blank page.** In the sidebar, as decision 4 describes? Or no list at all on the blank page, with recents only in "Your writing…" (`⌘O`) and Open Recent? (Recommended: the sidebar.)
6. **One click to open in "Your writing…".** This removes "click the title to rename" from the list; rename stays in the context menu and on the toolbar title. Accept? (Recommended: yes.)
7. **`⌘N`.** A blank page, with templates on `⌘⇧N` and the toolbar button? (Recommended: yes.)
8. **Mode.** Should a blank page open in Writing mode? (Recommended: yes; other documents are unchanged until Phase 9.)

## Answers (2026-11-15)

Tehran accepted the note and every recommendation.

1. Launch: a blank page at every launch, with the Settings picker for "Last document".
2. `⌘W` on a blank page quits.
3. The red close button saves and quits from any document.
4. `⌘W` on a document always shows a blank page.
5. Recents show in the sidebar of a blank page.
6. One click opens a row in "Your writing…"; rename is in the context menu and on the toolbar title.
7. `⌘N` makes a blank page; templates are on `⌘⇧N` and the toolbar button.
8. A blank page opens in Writing mode.

## Step A outcome (2026-11-15)

Open rows are built as decision 5 describes.

### What was built

- `Sources/Prose/OpenRows.swift` (new). `RowHover` holds the hovered row's id; rows set it from `.onHover` and tests call `set(_:)`. `OpenRowStyle` (`.openRow(...)`) draws the hover or selection fill, selection first, and puts an AppKit view behind the row that shows the pointing hand and takes no clicks. A row that leaves the list while hovered clears its own hover. `LibraryRow` and `LibraryRowSelection` hold the sheet's rows and its keyboard selection.
- `Theme.hover` is black at 4 percent in light and white at 5 percent in dark. The page-colour selection already existed as an `NSColor` named `Theme.selection`, used for selected text in the editor; it is now `Theme.nativeSelection`, and `Theme.selection` is its SwiftUI colour.
- Sidebar: file rows and heading rows gain hover and the pointing hand. Clicks are unchanged. The current heading keeps its accent text and gets no fill, because the open file's row above it has the selection fill.
- "Your writing…" sheet: one click anywhere on a document row opens it; the inline title field and the 2 pt capsule are gone; the open document's row is selected when the sheet opens. The trash or restore button shows only on the hovered or selected row. Down, Up and Return work with the focus in the search field (`PaletteTextField.onCommand`); the selection stops at both ends, and Up with no selection picks the last row. In Trash, rows do not open.
- VoiceOver: a folder row is "Thesis, folder", a document row is "Notes, document, edited 2 hours ago", a sidebar row is "name, file" or "name, folder" with "Main Document" as its value, and a heading row is "Title, heading". Each is one button with the selected trait when selected. The trash or restore button is an accessibility action of its row.

### Tests

Acceptance tests 1 to 4 are in `Tests/ProseAppTests/OpenRowFlowTests.swift`. Test 1 reads the drawn pixels of sidebar rows in light and dark. Test 4 turns on the accessibility tree with the private `AXEnhancedUserInterface` attribute, as VoiceOver does, because SwiftUI builds no tree until an assistive app asks.

Existing tests changed: `titleClickRenamesAndDoubleClickOpensLibraryWithoutChangingWriting` is now `toolbarTitleClickRenamesAndDoubleClickOpensLibraryWithoutChangingWriting` (it always tested the toolbar title; it now also checks that the sheet has no title field). One line in `WritingKeyboardFlowTests.swift` follows the `nativeSelection` rename. The identifier `library-title-<id>` is gone and a document row is `library.document.<uuid>`.

### Checks (main session, load average 8 to 10)

Lint clean. Release build clean. 318 core tests and 232 app tests passed; coverage 90.32 percent. In the subagent's own run, `writingModeOpensTheCaretsBlockAtOnceAndClosesItAfterARender` failed once at load 10.7 and passed alone; it passed in the main session's run.

### Open

- No test checks the pointing hand or hover from a real pointer. Both need one look in the running app.

## Step B outcome (2026-11-15)

The blank page, `⌘N` and the templates button are built as decisions 2 and 6 describe.

### What was built

- `DocumentLibrary.isUntouched` and `discardUntouched`. A page is untouched only if it is not trashed, its title is "Untitled", its source is one file and not a link, neither file has an iCloud conflict, the source bytes equal the blank source, and the folder holds only the source and `document.json` (`.DS_Store` is ignored). `discardUntouched` repeats the checks inside one coordinated delete and deletes nothing if one fails.
- `LibraryController`: `blankPageID` (stored in `blank-page.json`), `openBlankPage()` (reuse, or create), `keepBlankPage()`, `leaveBlankPage(_:)`, `isUntouchedBlankPage(_:)` and `listedDocuments`. A blank page opens in Writing mode with the caret on its empty last line. The gallery's "Blank page" button follows the same reuse rule.
- `Workspace`: `newDocument()` (`⌘N`) makes a blank page; `newFromTemplate()` opens the gallery; `showBlankPage()` clears the document and opens a blank page, and stays in the home state with the error if the library cannot give one. `edited()` keeps the page at the first edit with one comparison of an optional id. `open(_:)` compares document ids before and after, and calls `leaveBlankPage` when the writer left the page, so every route is covered.
- Trashing the open document, by the writer or by an agent, now shows a blank page. A rename by the writer or an agent keeps the page.
- Menu: "New from Template…" (`⌘⇧N`). Toolbar: `toolbar.templates` (`grid-four`), and the title's width reserve grew by 38 pt. The "Browse templates" text button in the "Your writing…" header is the same icon button. `⌘J`: `new` is "New from Template" (`f n`, `⌘⇧N`) and `newBlank` is "New Blank Page" (`f b`, `⌘N`).
- The untouched page is in no row of "Your writing…", not in its count and not in the reopenable recents.

### Decision details settled in the build

- "Leaving" is decided by document id, not by URL: the iCloud switch gives the same document a new URL, and a URL check would have deleted the page there.
- A folder with no main entry opens no file, so the page stays open and is not deleted.
- Save As from an untouched page leaves the page hidden in the library; the next blank page reuses it.
- The discard runs in a task after the id is cleared. If the app quits in that moment, the page stays as an ordinary empty "Untitled" document. The other order could reopen a page while it is deleted, so this order is kept.

### Tests

`Tests/ProseAppTests/BlankPageFlowTests.swift` holds acceptance tests 5 to 8 and tests for the toolbar button, `⌘⇧N`, reuse across a restart, trash of the open document and of the page, and an agent's trash and rename. `discardUntouchedDeletesOnlyAnUntouchedPage` is in `LibraryTests.swift`.

Existing tests changed: `newDocumentDiscoversTemplates…` is `newFromTemplateDiscoversTemplatesWithoutCreatingOrReplacingWriting` (it presses `⌘⇧N`; every check is kept). `trashActiveDocumentSelectsRemainingWriting…` is `trashActiveDocumentShowsABlankPageAndEmptyLibrarySurvivesRestart` (a blank page replaces "the next recent under the sheet"; the checks on the trashed text and on the log's privacy are kept). In `WritingFlowTests`: the shortcut count is 34, the native menu test chooses both items, and two `newDocument()` calls are `newFromTemplate()`. `toolbarLearningHints…` counts 10 help anchors and 9 shortcuts. `libraryCreateRename…` reads the editor again after a layout.

### Checks (main session, load average 25 to 50 from other apps)

Lint clean. Release build clean. Coverage 90.38 percent. The full run was not clean at this load: 1 of 319 core tests and 2 of 240 app tests failed on a time limit (`httpSourceSaysNotRunningAtOnceWhenNothingListens`, `previewCoversBlankPaneUntilFirstPaintAndAgainAfterReopen`, `writingFoldAccessibilityFramesAndMarkedText`), and each passed alone. The subagent's run at load 16 to 43 failed four other timing tests, which also passed alone. No blank-page test failed in either run. The gate run in step E must be clean on a quiet machine.
