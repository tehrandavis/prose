# Three-way merge evaluation

Evaluated October 1, 2026.

## Baseline rules

The [Swift article](https://www.theswift.dev/posts/merge-a-server-refresh-without-erasing-unsaved-edits/) is useful for the baseline model: retain the immutable value the user started editing, distinguish local edits from a refreshed server value, and preserve conflicts rather than replacing the form. Field-level `Equatable` reconciliation is small enough to implement directly. A whole manuscript needs range-aware merging as well; treating a String as one form field cannot combine two independently edited paragraphs.

Prose uses Foundation `CollectionDifference` over lines. Identical changes are deduplicated; disjoint source ranges combine; overlapping ranges return a conflict. Offset mapping uses UTF-16 to match AppKit. The app calculates diffs away from the main actor and verifies document revision, selection and disk baseline again before applying a result. Updates use native undo and retain focus and scroll position. Coordinated writes compare the expected disk bytes inside the write transaction, not before it.

This is deliberately conservative, not a collaborative CRDT. It can reject edits to different words on the same line. The baseline only covers live changes since the last accepted disk snapshot. Already-saved divergent versions delivered by iCloud require native version resolution; the storage layer refuses to overwrite unresolved versions. A line diff cannot invent a missing common ancestor.

## Forked

[Forked](https://github.com/drewmccormack/Forked) provides persistent forks, model merging and a CloudKit exchange layer. Its Swift-native API and integration examples make it worth considering for a future record-based sync design. At evaluation, the newest tag was **0.6.0**, commit `63e36cb5613db27b401ea3896df310efcf8f93b9`; upstream macOS, iOS and Linux CI passed. The repository's older GitHub Release entry does not supersede that tag. Tests and release history are useful evidence, but do not prove production behavior for our document model or real two-device conflicts.

A Release-mode standalone probe compiled `Forked` and `ForkedMerge` at that tag and exercised `TextMerger`. It reconstructs mergeable arrays of characters for String merging. The following observed results rule out adopting its default text merge without a protective policy:

| Common base | Local / remote | Observed result |
| --- | --- | --- |
| `a` | `ab` / `ab` | `abb` |
| `#let x = 1` | `#let x = 20` / `#let x = 30` | `#let x = 2030` |
| Two lines | Delete the second / edit its text | Retained edited text but lost its trailing newline |
| Independent text edits | Prefix / suffix edit | Combined as intended |

Reconstructing and merging a 108 KB synthetic manuscript with sparse edits took about 1.08 seconds on the evaluation machine (10.8 KB: 0.081 seconds). These are single exploratory measurements, not general benchmarks. They do show that a text CRDT wrapper must not run synchronously on the input path.

The package's own source acknowledges duplicate concurrent insertions in array merging. A mathematically convergent result may still change the meaning of Typst code. Prose therefore does not add Forked as a dependency in this iteration. Its repository/version model and CloudKit transport remain candidates if we move to persistent semantic revisions, with explicit conflict handling for source and per-field rules for metadata. We would first test offline replay, deletion versus edit, duplicate operations, version pruning and genuine multi-device delivery.

## Acceptance checks

Tests cover identical changes, independent paragraphs, several diff hunks, Unicode, empty documents, deletion, caret mapping, live AppKit undo, focus preservation, recovery and write rejection after overlapping edits. Native iCloud conflict delivery and two-Mac reconciliation remain separate release checks. Never infer these from an injected filesystem test.
