# Document history

Prose keeps the latest seven snapshots of each source document on this Mac. Open
**Documents → Document History**, or discover it with **⌘J → f → h** (⌘K when
configured). History does not add a button to the writing toolbar.

The first edited autosave batch preserves the source that existed before the
edit. Later edited batches preserve another version only when at least one hour
has elapsed since the latest snapshot. **Settings → Writing → Keep edited
versions** can change that interval to one day. Opening, scrolling, unchanged
saves and idle time do not create snapshots. An edit followed by Undo before
autosave also creates none.

Select a date to compare its source with current writing. The comparison shows
the changed span and nearby context in two selectable columns. Whole-book
comparisons run away from the main actor, trim shared context and cap each column
at 24 KB. The UI labels abbreviated output. Restoration always uses the complete,
verified source, regardless of the displayed excerpt. Removed text has a muted
red background and a strike-through; additions have a muted green background.
Each column also has a text label, so color is not the only distinction.

Highlighting uses Swift's `CollectionDifference` on at most 512 excerpt lines.
Small one-line replacements get grapheme-level detail (1,024 UTF-16 units per
pair, 8,192 units total); larger replacements retain line-level highlights.
Larger line counts use a linear prefix/suffix scan. These limits keep full
rewrites bounded as well as small edits in large books. No diff runs on the
main actor or in the typing path. See [the TextDiffing evaluation](text-diff-evaluation.md).

Restoring first writes a safety snapshot of current writing, then replaces the
editor contents as one undoable edit. If that safety write fails, the current
writing is not changed. The restoration safety snapshot also counts toward the
seven-version limit. The original selected revision is loaded before retention
runs, so restoring the oldest retained revision is safe. Autosave continues after
restoration. A snapshot failure during normal editing is reported without
preventing the document from saving.

## Scope and storage

- Snapshots cover the **currently open source file**, not images, other project
  files, exported PDFs, application settings or project metadata.
- History is local to this Mac and is not copied through iCloud. The interval
  preference follows the application's existing preference sync.
- Managed documents use the stable library UUID and the source path relative to
  the compilation entry directory. Renaming a library title or moving the library
  between local and iCloud storage retains the same history identity. External
  documents use their canonical file URL; moving an external file starts a new
  history identity.
- Storage is `Application Support/Prose/History/<SHA-256 of identity>/`. Snapshot
  source files and the seven-entry JSON index are written atomically. Source
  SHA-256 hashes are verified before comparison or restoration. The index is
  committed before obsolete payloads are removed. Orphans from an interrupted
  cleanup are removed on the next snapshot write.
- Editing only retains one copy-on-write baseline per autosave batch. The history
  actor performs hashing, encoding and file operations; it never runs this work
  on each keypress. Quitting waits for the final queued checkpoint.

This is a bounded local revision history, not a substitute for a complete backup
of the library and its project assets. Clearing document trash does not erase
history immediately; the history remains private in application support.

## Validation

Functional tests cover native-editor edits and autosave, unchanged-save gating,
restoration plus Undo, document switching, managed identities, preference
persistence, failed history writes and failed safety snapshots. Actor tests use
real temporary files and controlled dates to validate hourly/daily cadence,
seven-item retention, process restart, corrupt-source detection and comparison
of a 30,000-line book. No network service or cloud account is needed by the new
history tests.
