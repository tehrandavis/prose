# History diff presentation

Evaluated on 2026-10-01. Prose keeps its bounded, background comparison and uses
Swift's standard-library `CollectionDifference` for highlights. TextDiffing is
not a production dependency.

## TextDiffing

[TextDiffing](https://github.com/simonbs/TextDiffing) is a small MIT-licensed Swift
package with no third-party dependencies. It produces an attributed string with
word- or character-level insertion/deletion styling. Its rendering API fits
native macOS text well. It is a presentation helper, not a snapshot store or a
virtualized multi-hunk comparison view.

The latest published tag was `1.0.3` (`1d5a2f200983591c635e9ca069a44a2dcf493d1f`).
We also tested main at `36ac380cdf34c4d9da8cf46decf2e330927a664f`, which contains
[punctuation, whitespace and repeated-insertion fixes](https://github.com/simonbs/TextDiffing/pull/5)
not yet included in that tag. Main's 31 upstream tests passed.

A deterministic 500-case check reconstructs both inputs from the diff segments.
Version 1.0.3 fails this invariant for repeated characters: the reconstructed
new text has a different order. Main passes all 500 cases. This is a display
correctness issue; our application never used the package to write source.
The seeded reproducer is committed in
[`Benchmarks/Diffing`](../Benchmarks/Diffing).

Release-mode measurements of main, using `TextDiffer.diff` with word tokenization
and explicit colors on the development Mac:

| Workload | Bytes in old input | Elapsed |
| --- | ---: | ---: |
| Replace 200 numbered words | 1,689 | 0.032 s |
| Replace 1,000 numbered words | 8,889 | 0.871 s |
| Replace 4,000 numbered words | 38,889 | 9.134 s |
| Change one word in a 40,000-line synthetic book | 1,748,890 | 14.629 s |

These are individual local measurements, not portable latency guarantees. The
public API does not provide a work budget or cancellation, so putting an
unbounded call on a background task would still consume CPU and delay results.
Pre-trimming and limiting inputs could make the package useful, but Prose still
needs those policies and its own two-column mapping. Its core algorithm already
uses `CollectionDifference`, which is available without an extra dependency.

## Decision

Reuse the standard-library algorithm for bounded line alignment and short
replacement details. Preserve each original source excerpt verbatim; annotations
only mark UTF-16 ranges aligned to whole characters. Pair changes between
unchanged line anchors, so distant edits do not become one highlighted paragraph.
Large rewrites fall back to line or span highlighting, with an explicit notice
when the excerpt is shortened. Restoring always reads the complete verified
snapshot.

TextDiffing remains worth revisiting after its correctness fixes are released,
especially for small unified prose diffs. A general list-diffing library or a
persistent branching/sync package solves a different problem and would not
remove the need for bounded text comparison.

## Reproduce

Clone TextDiffing to an SSD-backed checkout, check out one of the exact commits
above, and copy both `Benchmarks/Diffing/*Tests.swift` files into its
`Tests/TextDiffingTests` directory. Run:

```sh
swift test -c release --filter generatedEditsRoundTrip
swift test -c release --filter ProseEvaluationTests
```

The benchmark files are evaluation inputs for the upstream package, not targets
of Prose's normal test suite. Prose's own tests cover multi-edit highlighting,
Typst punctuation, Chinese/emoji/combining characters, empty inputs, bounded
book rewrites, and native history selection, restoration and Undo.
