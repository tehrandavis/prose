#!/usr/bin/env python3
"""Prepare a pinned, attributed SICP book as a real-world Typst editor fixture.

Requires Python 3, Pandoc 3.11+ and (with --compile) Typst. Never executes the
book's Scheme examples or downloaded build scripts. All downloads stay under the checkout's .tools/tmp.
"""

import argparse
from collections import Counter
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

COMMIT = "bda03f79d6e2e8899ac2b5ca6a3732210e290a79"
ARCHIVE_URL = f"https://codeload.github.com/sarabander/sicp/zip/{COMMIT}"
ARCHIVE_SHA256 = "0cf3220c848fa74b90e3235ef352694df772839f96f459e5fbe8eb6dc78417a9"
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / ".tools/tmp/prose-sicp"
EXPECTED_COUNTS = {"code_blocks": 1122, "scheme_blocks": 1098, "math_expressions": 1356, "source_figures": 84, "footnotes": 339, "headings": 282}
PRELUDE = r'''// SICP, second edition: a reading and editor-performance fixture.
// Abelson and Sussman with Julie Sussman. HTML/figures by Andres Raba and
// the Unofficial Texinfo contributors. Adapted to Typst by the LeftBlank project.
// CC BY-SA 4.0: see ATTRIBUTION.md, LICENSE and manifest.json beside this file.
#import "styles/book.typ": book, horizontalRule, divider
#show: book
#align(center)[
  #v(30mm)
  #text(size: 28pt, weight: "bold")[Structure and Interpretation\
  of Computer Programs]
  #v(8mm)
  #text(size: 15pt)[Second edition · Scheme]
  #v(12mm)
  Harold Abelson and Gerald Jay Sussman\
  with Julie Sussman
  #v(25mm)
  #text(size: 9pt)[A Typst adaptation for reading and editor testing.\
  Based on the complete HTML5 edition by Andres Raba.\
  Creative Commons Attribution–ShareAlike 4.0.]
]
#pagebreak()
#outline(title: [Contents], depth: 3)
#pagebreak()

'''

STYLE = r'''// Local book typography. The main document imports and applies this function.
#let book(body) = {
  set document(title: "Structure and Interpretation of Computer Programs", author: ("Harold Abelson", "Gerald Jay Sussman", "Julie Sussman"))
  set page(paper: "a4", margin: (x: 24mm, y: 22mm), numbering: "1")
  set text(font: "Libertinus Serif", size: 10pt, lang: "en")
  set par(justify: true, leading: 0.65em)
  set heading(numbering: none)
  set figure(numbering: none)
  show raw: set text(font: "DejaVu Sans Mono", size: 8pt)
  show raw.where(block: true): block.with(fill: luma(97%), inset: 8pt, radius: 3pt)
  show heading.where(level: 1): it => { pagebreak(weak: true); it }
  body
}
#let horizontalRule = line(length: 100%, stroke: 0.5pt + luma(75%))
#let divider = horizontalRule
'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def download_archive(cache):
    if not cache.exists():
        request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "Prose-fixture/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(32 * 1024 * 1024 + 1)
        if len(data) > 32 * 1024 * 1024:
            raise RuntimeError("Source archive exceeds the 32 MiB download limit")
        if sha256(data) != ARCHIVE_SHA256:
            raise RuntimeError("Source archive hash changed; review the pinned upstream before updating")
        cache.write_bytes(data)
    data = cache.read_bytes()
    if sha256(data) != ARCHIVE_SHA256:
        raise RuntimeError(f"Cached archive hash does not match: {cache}")
    return zipfile.ZipFile(io.BytesIO(data))


def ordered_pages(names):
    pages = ["Dedication.xhtml", "Foreword.xhtml", "Preface.xhtml", "Preface-1e.xhtml", "Acknowledgments.xhtml"]
    for chapter in range(1, 6):
        pages.append(f"Chapter-{chapter}.xhtml")
        sections = [n for n in names if re.fullmatch(fr"{chapter}_002e[0-9]+\.xhtml", n)]
        pages.extend(sorted(sections, key=lambda n: int(n.split("_002e")[1].split(".")[0])))
    return pages + ["References.xhtml", "Term-Index.xhtml", "Colophon.xhtml"]


def remove_element(parent, element):
    """Preserve the tail: an inline web control must not eat adjacent prose."""
    index = list(parent).index(element)
    if element.tail:
        if index:
            previous = parent[index - 1]
            previous.tail = (previous.tail or "") + element.tail
        else:
            parent.text = (parent.text or "") + element.tail
    parent.remove(element)


def prepare_html(source, page, assets, counts, included, source_code):
    root = ET.fromstring(source)
    for el in root.iter():
        el.tag = el.tag.rsplit("}", 1)[-1]
    body = root.find("body")
    if body is None:
        raise RuntimeError(f"No book content in {page}")
    for parent in list(body.iter()):
        for el in list(parent):
            classes = el.get("class", "").split()
            # Pandoc texmath cannot read a negative MathML kern (spacing only).
            if el.tag == "mspace" and el.get("width", "").startswith("-"):
                remove_element(parent, el)
                counts["normalized_negative_math_kerns"] += 1
                continue
            if el.tag in ("script", "nav") or "jump" in classes or el.get("id") in ("pagetop", "pagebottom") or "footnote_backlink" in classes:
                remove_element(parent, el)
    for el in body.iter():
        if el.tag == "section":
            el.tag = "div"
        if re.fullmatch(r"h[2-6]", el.tag):
            el.tag = f"h{int(el.tag[1]) - 1}"
        if "secnum" in el.get("class", "").split():
            el.tail = " " + (el.tail or "")
        if el.tag == "pre":
            text = "".join(el.itertext())
            language = "scheme" if "lisp" in el.get("class", "").split() else "text"
            tail = el.tail
            el.clear()
            el.tail = tail
            ET.SubElement(el, "code", {"class": "language-" + language}).text = text
            source_code.append((language, text.rstrip("\n")))
            counts["source_code_blocks"] += 1
            counts["scheme_blocks"] += language == "scheme"
        if el.tag == "math":
            el.set("xmlns", "http://www.w3.org/1998/Math/MathML")
            counts["source_math_expressions"] += 1
        if el.tag == "object" and el.get("type") == "image/svg+xml":
            relative = el.get("data", "")
            if not relative.startswith("fig/") or ".." in PurePosixPath(relative).parts:
                raise RuntimeError(f"Unexpected diagram path: {relative}")
            width = re.search(r"width:\s*([0-9.]+)ex", el.get("style", ""))
            height = re.search(r"height:\s*([0-9.]+)ex", el.get("style", ""))
            points = float(width[1]) * 4.5 if width else 320
            if height and float(height[1]) * 4.5 > 480:
                points *= 480 / (float(height[1]) * 4.5)
            tail = el.tail
            el.clear()
            el.tag, el.tail = "img", tail
            el.attrib.update(src=relative, alt="SICP diagram", width=f"{min(points, 450):.2f}pt")
            assets.add(relative)
            counts["source_figures"] += 1
        if el.tag == "a":
            target = el.get("href", "")
            match = re.fullmatch(r"([^/#]+\.xhtml)(?:#(.*))?", target)
            if match:
                destination, fragment = match.groups()
                if destination in included:
                    el.set("href", "#" + (fragment or ("page-" + destination[:-6])))
                else:
                    el.set("href", "https://sarabander.github.io/sicp/html/" + target)
    anchor = ET.Element("a", {"id": "page-" + page[:-6]})
    body.insert(0, anchor)
    return "".join(ET.tostring(el, encoding="unicode") for el in body)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def convert_notes_and_blocks(document):
    notes = {}
    for node in walk(document):
        if node.get("t") == "Div" and re.fullmatch("FOOT[0-9]+", node["c"][0][0]):
            notes[node["c"][0][0]] = node["c"][1]
    count = 0

    def convert(value):
        nonlocal count
        if isinstance(value, list):
            result = []
            for item in value:
                transformed = convert(item)
                if isinstance(transformed, list):
                    # Only block wrappers return lists; scalar lists retain shape below.
                    result.extend(transformed) if isinstance(item, dict) else result.append(transformed)
                elif transformed is not None or item is None:
                    result.append(transformed)
            return result
        if not isinstance(value, dict):
            return value
        if value.get("t") == "Link" and "footnote_link" in value["c"][0][1]:
            target = value["c"][2][0].lstrip("#")
            if target not in notes:
                raise RuntimeError(f"Missing footnote {target}")
            count += 1
            content = convert(deepcopy(notes[target]))
            return {"t": "Note", "c": [{"t": "RawBlock", "c": ["typst", f"#box[]<{target}>"]}] + content}
        if value.get("t") == "Span" and value["c"][0][0]:
            # Consecutive empty HTML anchors need distinct Typst elements;
            # consecutive labels otherwise replace one another on a paragraph.
            attributes, inlines = value["c"]
            return [{"t": "RawInline", "c": ["typst", f"#box[]<{attributes[0]}>"]}] + convert(inlines)
        if value.get("t") == "Div":
            attributes, blocks = value["c"]
            if "footnote" in attributes[1]:
                return None
            converted = convert(blocks)
            if attributes[0]:
                converted.insert(0, {"t": "RawBlock", "c": ["typst", f"#box[]<{attributes[0]}>"]})
            return converted
        return {key: convert(child) for key, child in value.items()}

    return convert(document), count


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args[0]}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--compile", action="store_true", help="Also compile book/main.pdf with Typst")
    parser.add_argument("--typst", default=shutil.which("typst"), help="Typst executable (for --compile)")
    args = parser.parse_args()
    if not shutil.which("pandoc"):
        parser.error("Pandoc is required; install it before preparing this fixture")
    if args.compile and not args.typst:
        parser.error("--compile requires a Typst executable; pass --typst /path/to/typst")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    book = output / "book"
    book.mkdir(exist_ok=True)
    archive = download_archive(output / "sarabander-sicp.zip")
    prefix = f"sicp-{COMMIT}/"
    names = [n.removeprefix(prefix + "html/") for n in archive.namelist() if n.startswith(prefix + "html/")]
    pages = ordered_pages(names)
    assets, counts, source_code = set(), Counter(), []
    html_parts = [prepare_html(archive.read(prefix + "html/" + page), page, assets, counts, pages, source_code) for page in pages]
    combined = "<!DOCTYPE html><html><head><meta charset='utf-8'></head><body>" + "\n".join(html_parts) + "</body></html>"
    combined_path = output / "book.html"
    combined_path.write_text(combined)
    ast_result = run(["pandoc", "-f", "html", "-t", "json", str(combined_path)])
    ast, footnote_count = convert_notes_and_blocks(json.loads(ast_result.stdout))
    counts["footnotes"] = footnote_count
    counts.update({"headings": sum(n.get("t") == "Header" for n in walk(ast)), "math_expressions": sum(n.get("t") == "Math" for n in walk(ast)), "code_blocks": sum(n.get("t") == "CodeBlock" for n in walk(ast))})
    converted_code = [(n["c"][0][1][0], n["c"][1].rstrip("\n")) for n in walk(ast) if n.get("t") == "CodeBlock"]
    if Counter(source_code) != Counter(converted_code):
        raise RuntimeError("Conversion changed or lost a code block's language, text or indentation")
    for key, expected in EXPECTED_COUNTS.items():
        if counts[key] != expected:
            raise RuntimeError(f"Incomplete fixture: {key} is {counts[key]}, expected {expected}")
    result = run(["pandoc", "-f", "json", "-t", "typst", "--wrap=none"], input=json.dumps(ast))
    warnings = ast_result.stderr + result.stderr
    (output / "conversion.log").write_text(warnings)
    if warnings.strip():
        raise RuntimeError(f"Pandoc emitted conversion warnings; inspect {output / 'conversion.log'}")
    main_path = book / "main.typ"
    main_path.write_text(PRELUDE + result.stdout)
    (book / "styles").mkdir(exist_ok=True)
    (book / "styles/book.typ").write_text(STYLE)
    for asset in sorted(assets):
        path = book / asset
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(archive.read(prefix + "html/" + asset))
    (book / "LICENSE").write_bytes(archive.read(prefix + "LICENSE"))
    upstream_source = output / "source"
    upstream_source.mkdir(exist_ok=True)
    for filename in ("sicp-pocket.texi", "README.md", "LICENSE"):
        (upstream_source / filename).write_bytes(archive.read(prefix + filename))
    archive.close()
    attribution = f"""# Structure and Interpretation of Computer Programs, second edition

Harold Abelson and Gerald Jay Sussman, with Julie Sussman (1996).

This fixture adapts the complete book text, Scheme code, MathML mathematics,
and SVG diagrams from Andres Raba's HTML5 edition, which descends from the
Unofficial Texinfo edition and the original MIT Press HTML edition.

- Source: https://github.com/sarabander/sicp/tree/{COMMIT}
- Readable HTML: https://sarabander.github.io/sicp/
- License: Creative Commons Attribution-ShareAlike 4.0 International,
  https://creativecommons.org/licenses/by-sa/4.0/
- Contributors to the source edition include Lytha Ayth, Neil Van Dyke,
  Gavrie Philipson, Li Xuanji, J. E. Johnson, Matt Iversen and Eugene Sharygin.

Changes by the LeftBlank project: converted HTML/MathML to Typst using Pandoc;
converted web endnotes into page footnotes; joined cross-page references;
removed web navigation and source syntax-highlight spans; labeled Scheme
blocks; removed source-only prose line wrapping; adapted figure dimensions and added book typography and an outline.
The adapted book remains under CC BY-SA 4.0. No author endorsement is implied.
All Scheme examples remain source text and are never executed.

This is a reading/performance fixture, not an authoritative new edition.
Pagination differs from the original; see the repository's docs/sicp-fixture.md
for conversion limitations. Keep this file and LICENSE with any redistribution.
"""
    (book / "ATTRIBUTION.md").write_text(attribution)
    data = main_path.read_bytes()
    manifest = {
        "source_repository": "https://github.com/sarabander/sicp", "source_commit": COMMIT,
        "archive_url": ARCHIVE_URL, "archive_sha256": ARCHIVE_SHA256,
        "license": "CC-BY-SA-4.0", "source_pages": pages,
        "pandoc_version": run(["pandoc", "--version"]).stdout.splitlines()[0],
        "typst_bytes": len(data), "typst_utf16_units": len(data.decode().encode("utf-16-le")) // 2,
        "typst_sha256": sha256(data), "typst_lines": data.count(b"\n"),
        "source_code_content_verified": True,
        "upstream_texinfo_sha256": sha256((upstream_source / "sicp-pocket.texi").read_bytes()),
        "style_sha256": sha256(STYLE.encode()),
        "source_project_bytes": len(data) + len(STYLE.encode()) + sum((book / a).stat().st_size for a in assets),
        "counts": dict(counts),
        "assets": [{"path": a, "bytes": (book / a).stat().st_size, "sha256": sha256((book / a).read_bytes())} for a in sorted(assets)],
        "pandoc_warnings": warnings,
    }
    if args.compile:
        start = time.perf_counter()
        compiled = run([args.typst, "compile", "--root", str(book), str(main_path), str(book / "main.pdf")])
        manifest["compile_seconds"] = round(time.perf_counter() - start, 3)
        manifest["typst_version"] = run([args.typst, "--version"]).stdout.strip()
        manifest["typst_warnings"] = compiled.stderr
        (output / "compile.log").write_text(compiled.stderr)
        manifest["pdf_bytes"] = (book / "main.pdf").stat().st_size
    (book / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"entry": str(main_path), "bytes": len(data), "counts": dict(counts), "assets": len(assets), "manifest": str(book / "manifest.json")}, indent=2))


if __name__ == "__main__":
    main()
