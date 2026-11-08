# Phase 1: the window shell

Date: 2026-11-08
Status: draft, awaiting review
Spec: `docs/prose-spec.md`, Sections 3.2 to 3.4 and 4

## Goal

Phase 1 builds the window around the editor. It adds a project model, a sidebar with a file tree and the active file's outline, a title row with a breadcrumb and a compile status dot, the Code, Writing and Focus mode control with only Code working, and preview pages drawn as cards. The editor itself does not change. At the end of the phase the app is usable for a multi-file thesis and the 80 percent coverage gate still passes.

## What exists today

| Spec item | Inherited code | Gap |
|-|-|-|
| Project model | A library document can be a *project*: `DocumentLibrary.importProject` copies a folder into the managed library and records its main entry. `Workspace.mainFileURL` keeps the main entry while following `#include` into child files | Projects are copies, never folders opened in place. No file tree. The library shows one title per project |
| Sidebar | None. `FloatingOutline` floats in the editor's left margin and can be pinned (`SidePanel.outline`, `⌘4`) | No file tree, no search, no persistent column |
| Title row | `WindowToolbar`: library button, editable document name, unsaved dot, then three layout buttons (Writing, Split, Preview) and Export | No project name, breadcrumb or status dot |
| Mode control | `EditorLayout` is `writing`, `split` or `preview`, on `⌘1` to `⌘3` | The spec's modes (Code, Writing, Focus) are a different axis from the layout |
| Status | `Workspace.serviceStatus`, `previewStale`, `hasSuccessfulPreview` and the checks popup (`DocumentChecks`, `⌘5`) | The state exists. It has no dot |
| Preview cards | Tinymist's web preview draws all pages in one SVG in a `WKWebView`. `PreviewScripts` already injects CSS for the canvas colour | No rounded corners, no shadow, no page numbers |

## Decisions

Items marked **Needs your call** change what gets built. The rest have a recommendation that I will follow unless you object.

### 1. Where a project lives. Needs your call

The spec says a project is a folder on disk. LeftBlank's library copies a project folder into `Application Support/Prose/Library` and edits the copy. The two give different results for a thesis kept in Git or Dropbox: the copy is invisible to Git and to collaborators.

- **A. Folders in place (recommended).** File → Open Folder (`⌘⌥O`) opens any folder and edits its files where they are. Prose remembers recent folders and each folder's main entry. Existing library projects open in the same sidebar, so one code path serves both. Recovery, autosave and history keep working because they work on any file today. iCloud sync does not apply to folders in place; the folder's own sync (Dropbox, iCloud Drive, Git) applies instead. The App Store edition is sandboxed, so folders are remembered with security-scoped bookmarks.
- **B. Library only.** The sidebar shows the tree of a library project. Opening a folder imports a copy, as today. This is less work and keeps iCloud sync, but it does not match the spec.

The rest of this note assumes A.

### 2. Layout and modes

The spec's mode control (Code, Writing, Focus) replaces the three layout buttons. The preview becomes a toggle beside it.

| Today | Phase 1 |
|-|-|
| Writing layout, `⌘1` | Preview hidden. Toggle with `⌘⇧P` or the preview button |
| Split layout, `⌘2` | Preview shown. Same toggle |
| Preview layout, `⌘3` | "Read the Preview" stays as a command (`⌘J → v`) and a button in the preview pane header, with no direct shortcut. Recommend `⌘⌥P` |
| (none) | `⌘1` Code, `⌘2` Writing, `⌘3` Focus. Writing and Focus are disabled with the help text "Arrives in a later version" |
| Pin outline, `⌘4` | Removed. `⌘0` toggles the sidebar, which holds the outline |
| Checks, `⌘5` | Unchanged. Clicking the status dot does the same |

`EditorLayout` stays as the internal state for the preview pane. A new `EditorMode` (`code`, `writing`, `focus`) is added, saved per document in Phase 5 as the spec says, and fixed to `code` in Phase 1.

### 3. The floating outline

With the sidebar open, the floating outline is redundant. Recommend: show `FloatingOutline` only while the sidebar is hidden, and drop its pin. This keeps outline navigation in a narrow window and keeps its tests. The sidebar outline reuses `OutlineNavigation`, so folding and the active-heading highlight behave the same in both.

### 4. The sidebar

- A column on the left, 240 to 320 points wide, resizable with the existing `SplitDividerHandle`. Width is stored per device. `⌘0` and a toolbar button toggle it. It is hidden for single files that are not in a project.
- **Search field.** Filters the tree by file name in Phase 1. Content search across files is later work.
- **Tree.** Folders and files under the project root, sorted as Finder sorts them, hidden files and symbolic links skipped, as `ProjectSources.list` does now. Folders collapse, and their state is remembered per project.
- **Outline under the active file.** The active `.typ` file expands one more level to show its headings, indented by level, with the current heading in the accent colour. Clicking a heading scrolls the editor and the preview, as the floating outline does now.
- **Main entry.** A small pin icon marks it. All compiling, preview and export use it, whichever file is open.
- **Opening files.** A `.typ` file opens in the editor, saving the current one first; the main entry is kept. Other files (`.bib`, `.pdf`, images) open in Quick Look in Phase 1. Editing `.bib` in Code mode needs Tinymist and editor checks for a non-Typst buffer and moves to a later phase.
- **The `+` button** creates a `.typ` file or a folder in the selected folder. The context menu offers Rename, Reveal in Finder, Set as Main Document and Move to Trash. Trash uses `FileManager.trashItem`, never a permanent delete.
- **Changes on disk.** The tree reloads after Prose's own file operations, when the app becomes active, and on FSEvents for the project folder. A file deleted elsewhere while open keeps its buffer, as LeftBlank's external-change handling does today.

The spec sizes and colours apply: sidebar `#F5F5F7` and `#1A1A1A`, 13-point rows, selection as the accent at 10 or 22 percent.

### 5. The title row

All of it stays in the one `unifiedCompact` toolbar row, as now.

- **Left:** sidebar toggle, then the file name in 15-point semibold with the project name under it in secondary text. A single file outside a project shows only its name. Library documents keep click-to-rename.
- **Centre:** the breadcrumb, built from the heading ancestors of the caret position (`OutlineNavigation` already tracks the active heading). It truncates from the left, and each part jumps to its heading. Tinymist's document symbols carry no heading numbers, so Phase 1 shows titles only, such as "Method › Procedure › Adaptive staircase". Numbers like "2.4.2" need the compiled document and arrive with the Phase 2 engine.
- **Status dot after the breadcrumb:**

| Dot | When |
|-|-|
| Green `#5CB85C` | The last compile succeeded and matches the buffer |
| Amber `#E8A838` | Compiling, or the buffer changed since the last compile |
| Red `#E25555` | The last compile failed; the preview, if any, is stale |
| Grey, hollow | Tinymist is disconnected or starting |

  The dot has an accessibility label with the same words as the checks button. Clicking it opens the checks popup. The amber token joins `Theme` here.
- **Right:** the mode control, Export, and the preview toggle. The info button belongs to Phase 5 and is not added.
- `Theme` also gains darker text variants of green and red (about 4.5:1 on white) for messages drawn as text. The dot keeps the spec colours.

### 6. Preview pages as cards

Tinymist draws every page into one SVG. Recommend styling that SVG from the injected stylesheet: `rx` and `ry` of 14 points on each page rectangle, the `PanelCard` shadow as a CSS `drop-shadow` filter, and a page number drawn as SVG text in the gap under each page. Tinymist repaints pages while scrolling, so the numbers must survive repaints. They will be added in the same observer that already restores the canvas colour.

This is the riskiest item in Phase 1. Start with a one-day spike on the SICP fixture. If corners or numbers flicker during partial rendering, ship rounded cards and shadow only, put the current page number in the preview header, and record the gap in the spec. A native PDF preview is out of scope.

### 7. Settings and storage

| What | Where |
|-|-|
| Recent folders and their bookmarks | `Application Support/Prose/Projects/recent.json` |
| Main entry and folded folders per project | `Application Support/Prose/Projects/<id>.json`, keyed by a hash of the bookmark. Nothing is written into the user's folder |
| Sidebar width and visibility | `UserDefaults`, per device, like the split fraction |

## Code changes

| Area | Change |
|-|-|
| `ProseCore` | New `ProjectFolder` (root, main entry, bookmark), `ProjectTree` (listing, sorting, filtering, rename, create, trash), `ProjectStore` (recent folders and per-project state), `CompileStatus` (maps workspace state to the four dot states), `Breadcrumb` (ancestors of the active heading). All are plain types with unit tests |
| `Workspace` | `project: ProjectFolder?`, `openFolder(_:)`, `setMainEntry(_:)`, `EditorMode`. File switching goes through `open(_:preservingMain:)` with the project's main entry |
| New views | `ProjectSidebar`, `ProjectTreeRow`, `TitleBreadcrumb`, `StatusDot`, `ModeControl` |
| Changed views | `ContentView` (sidebar column), `WindowToolbar` (title row), `FloatingOutline` (hidden with the sidebar, no pin), `ProseApp` menus (Open Folder, shortcut changes) |
| `PreviewScripts` | Card styling and page numbers |
| `Commands.swift` | Shortcut table: `⌘1` to `⌘3` to modes, `⌘⇧P` preview, `⌘⌥P` read preview, `⌘0` sidebar, `⌘4` removed. Labels in English and zh-Hans |
| Library | A "Folders" section on the library home lists recent folders beside documents |

## Tests

Each change needs tests in the existing style: real windows, the real editor and the real Tinymist process, no mocks of the editor.

- Unit tests for `ProjectTree`, `ProjectStore`, `CompileStatus` and `Breadcrumb`, including Unicode names, symbolic links, hidden files, and a main entry that is deleted or renamed.
- A functional test that opens a three-file thesis folder, switches files from the sidebar, checks that preview and export still use `main.typ`, sets another main entry, and creates, renames and trashes a file.
- A functional test for the title row: breadcrumb text follows the caret, and the dot passes through amber to green on a good edit and to red on a broken one.
- A WebKit test that the preview pages have rounded corners and that page numbers are present after scrolling the SICP fixture.
- Updated tests for the shortcut changes and the floating outline.

The coverage gate stays at 80 percent of production lines.

## Order of work

1. `ProseCore` model types and their unit tests.
2. Sidebar column, tree and outline, `⌘0`, Open Folder, library Folders section.
3. Title row: name and project, breadcrumb, status dot, mode control, shortcut changes, text colour variants.
4. Preview card spike, then cards and page numbers, or the fallback.
5. Spec, `docs/architecture.md` and `docs/writing-guide.md` updates; `CLAUDE.md` phase table.

Each step ends with `scripts/build.sh release` and `PROSE_DISTRIBUTION=preview scripts/test.sh` passing, and its own commits.

## Risks

- **Preview cards** depend on Tinymist's SVG structure, which can change between versions. The existing WebKit tests already pin that structure, and the new test extends them.
- **Sandboxed folder access.** A stale bookmark (folder moved or renamed) must fail with a clear message and drop the folder from the recent list, never crash.
- **Shortcut changes** break muscle memory from LeftBlank. Prose has no users yet, so this is the time to change them.
- **Large folders.** A thesis folder can hold thousands of files in `figures/` or `node_modules/`. Listing is lazy per folder, and folders with more than 2,000 entries show a count instead of their children until opened.
