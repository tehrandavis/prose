# SICP editor fixture

SICP is a better realistic writing fixture than repeated dummy text: it combines
long prose, deep headings, Scheme programs, mathematics, diagrams, footnotes,
cross-references and an index. Use the complete original **Scheme second
edition**, not the JavaScript adaptation. Keep the separate 3.3 MB War and Peace
fixture as the larger plain-text stress case; do not repeat SICP to inflate its
size.

## Reproduce

The converter requires Python 3.9 or later and Pandoc 3.11 or later. It downloads
only a pinned archive and runs the installed converter, never downloaded build
scripts or the book's Scheme programs.

```sh
source scripts/environment.sh
python3 scripts/prepare-sicp.py --compile \
  --typst "$PWD/build/LeftBlank.app/Contents/Helpers/tinymist"
```

The `--typst` argument also accepts a normal Typst executable. Omit `--compile`
to prepare source only. The default destination is
`.tools/tmp/leftblank-sicp` in the checkout. The verified book, PDF, diagrams and original editable Texinfo source are also
committed under `Examples/Books/SICP`; generation uses that working directory
so it does not overwrite the checked-in example automatically.

- `book/main.typ`: one complete, editable Typst manuscript.
- `book/styles/book.typ`: reusable local typography, imported by the manuscript.
- `book/fig/`: local vector illustrations needed for compilation.
- `book/ATTRIBUTION.md` and `book/LICENSE`: keep with the project.
- `book/manifest.json`: source commit, hashes, content counts, versions and
  optional compiler results.
- `book/main.pdf`: compiled reading copy when `--compile` is used.
- `source/sicp-pocket.texi`: the upstream editable Texinfo source, with its README
  and license alongside it.
- `book.html`, `conversion.log`, `compile.log`: conversion and validation aids.

Open `book/main.typ` with its sibling `fig` and `styles` directories intact. Import or copy the
whole project if using a managed document library; copying only the `.typ` file
will lose its diagrams.

## Provenance and choice of source

The source is [Andres Raba's HTML5 edition of SICP](https://github.com/sarabander/sicp),
pinned to commit `bda03f79d6e2e8899ac2b5ca6a3732210e290a79`. Its lineage is the
Unofficial Texinfo edition and the original MIT Press HTML edition. The book is
by Harold Abelson and Gerald Jay Sussman, with Julie Sussman. Both the HTML and
SVG diagrams are expressly licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
The generated adaptation keeps that license; LeftBlank's code license does not
replace it.

The downloaded archive is verified against SHA-256
`0cf3220c848fa74b90e3235ef352694df772839f96f459e5fbe8eb6dc78417a9` before use.
The script extracts specific content and image files instead of executing the
upstream Texinfo/PhantomJS build pipeline.

[Source Academy's original Scheme Markdown export](https://github.com/source-academy/sicp#scheme-the-original)
was also evaluated. The inspected export omitted words from several headings,
left malformed footnote notation and supplied fewer figures. The pinned HTML5
edition preserves richer structure and its MathML converts to native Typst
mathematics through Pandoc.

## What is preserved and checked

The fixture contains the dedication, foreword, both prefaces, acknowledgments,
all five chapters, references, term index and original colophon. The converter:

- checks all **1,122 code blocks**, including **1,098 Scheme blocks**, against the
  original code text, language and indentation;
- preserves all **1,356 mathematical expressions** as native Typst math;
- retains **84 SVG figures**, **339 native footnotes** and **282 headings**;
- turns cross-page links into internal document links;
- rejects changed source hashes, missing blocks and Pandoc conversion warnings;
- records hashes for every diagram and the generated manuscript.

The code text comparison ignores only trailing newline characters. Counts are
checked against this pinned edition so a broken conversion fails instead of
silently yielding an incomplete benchmark. Scheme language tags remain on the
fences, including the 52 code fences nested inside footnotes, so the editor can
exercise embedded-language highlighting. The converter does not add synthetic
code or duplicate chapters. Pandoc writes prose with `--wrap=none`: each paragraph
uses natural editor wrapping instead of inherited web-source hard breaks. Code
fences retain their original newlines and indentation. This does not change
Typst paragraph boundaries or PDF pagination.

## Verified output

On 2026-10-01 with Pandoc 3.11 and LeftBlank's bundled Tinymist 0.15.8 / Typst 0.15.1:

| Item | Size or count |
| --- | ---: |
| Typst manuscript | 1,446,633 bytes |
| UTF-16 units | 1,442,138 |
| Source lines | 20,511 |
| SVG assets | 3,139,671 bytes |
| Manuscript, styles and diagrams | 4,587,094 bytes |
| Compiled PDF | 448 pages |

The complete PDF compiles with no warnings. Representative visual checks cover
the title page, chapter 1 code and mathematics, chapter 2 pointer diagrams, and
chapter 5 compiler examples with footnotes. Compilation is a separate workload
from typing, navigation and scrolling; use the editor benchmark for those
measurements.

## Conversion limits

This is a reading and performance fixture, not a new authoritative edition.
Pagination and typography differ from the original. Original emphasis inside
code becomes plain monospace while the actual code characters remain unchanged.
Diagrams are scaled to fit the page. A single negative MathML spacing kern is
removed because Pandoc's intermediate TeX reader cannot represent it; no
mathematical symbol or expression is removed. Web-only navigation and the
redundant web lists of exercises and figures are omitted. The complete book's
exercise text, figure captions and term index remain.

The PDF code is set in a restrained monochrome style. Editor highlighting is
provided independently by LeftBlank's Scheme grammar. No code execution is performed
by this conversion or required to read the book.
