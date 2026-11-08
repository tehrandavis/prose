#!/usr/bin/env python3
"""Download a real multi-MB book and prepare a reproducible highlighted fixture.

Run after sourcing scripts/environment.sh. The source and generated document
are regenerated under the checkout's .tools/tmp; reviewed copies live in Examples/Books. Prose is preserved, Typst punctuation escaped, chapter labels
become headings, and small benchmark code/math blocks are distributed across it.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.request

if "TMPDIR" not in os.environ:
    raise SystemExit("Source scripts/environment.sh first; it sets TMPDIR for fixtures.")
temporary = Path(os.environ["TMPDIR"]).resolve(strict=True)
root = temporary / "prose-large-document"
root.mkdir(parents=True, exist_ok=True)
url = "https://www.gutenberg.org/ebooks/2600.txt.utf-8"
original = root / "war-and-peace.txt"
if not original.exists():
    with urllib.request.urlopen(url, timeout=90) as response:
        original.write_bytes(response.read(8 * 1024 * 1024))
data = original.read_bytes()
expected = "2d5bb2ad5f422765e714617e21fa31bbaf8958aa79682c86fca6660fcc5d1b2b"
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit("The upstream text changed; review the source before updating its pinned hash.")
assert 2_000_000 < len(data) < 8_000_000, "Expected a real multi-megabyte source"
source = data.decode("utf-8-sig").replace("\r\n", "\n")
lines = ["#set text(size: 11pt)", "#set page(margin: 24mm)", ""]
chapters = blocks = 0
for line in source.splitlines():
    stripped = line.strip()
    if re.fullmatch(r"(?:BOOK|CHAPTER|FIRST EPILOGUE|SECOND EPILOGUE)[ A-Z0-9,.:—–-]*", stripped):
        chapters += 1
        lines.extend(["", "= " + stripped, ""])
        if chapters % 20 == 1:
            blocks += 1
            lines.extend([f"// Prose benchmark block {blocks}", "```python", "total = sum(range(1, 11))", "print(total)", "```", "", "$alpha + beta = gamma$", "", "*A highlighted passage* with _emphasis_ and `inline code`. 中文与 emoji 😀.", ""])
    else:
        lines.append(re.sub(r"([\\#\[\]*_$<>@`])", r"\\\1", line))
document = root / "war-and-peace-highlighted.typ"
document.write_text("\n".join(lines) + "\n", encoding="utf-8")
metadata = {"source_url": url, "source_sha256": hashlib.sha256(data).hexdigest(), "source_bytes": len(data),
            "fixture": str(document), "fixture_sha256": hashlib.sha256(document.read_bytes()).hexdigest(),
            "fixture_bytes": document.stat().st_size, "lines": len(lines), "headings": chapters, "code_blocks": blocks}
(root / "fixture.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
