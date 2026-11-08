#!/usr/bin/env python3
"""Refresh the metadata-only offline catalog. Package code and images are not bundled."""
import argparse
import datetime
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--index", type=Path, help="Use an already downloaded official index")
parser.add_argument("--date", default=datetime.datetime.now(datetime.timezone.utc).date().isoformat())
args = parser.parse_args()
if args.index:
    data = args.index.read_bytes()
else:
    request = urllib.request.Request("https://packages.typst.org/preview/index.json", headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(12 * 1024 * 1024 + 1)
if len(data) > 12 * 1024 * 1024:
    raise ValueError("Official index exceeds 12 MiB")
fields = ["name", "version", "description", "authors", "license", "keywords", "categories", "disciplines", "compiler", "template"]
latest = {}
for item in json.loads(data):
    version = tuple(map(int, item["version"].split(".")))
    if item["name"] not in latest or version > tuple(map(int, latest[item["name"]]["version"].split("."))):
        latest[item["name"]] = {key: item[key] for key in fields if key in item}
if not latest:
    raise ValueError("Official index is empty")
when = datetime.datetime.fromisoformat(args.date)
fetched_at = (when - datetime.datetime(2001, 1, 1)).total_seconds()
output = Path(__file__).resolve().parents[1] / "Sources/ProseCore/Resources/Universe/universe-index.json"
entries = [json.dumps(latest[name], ensure_ascii=False, sort_keys=True, separators=(",", ":")) for name in sorted(latest)]
output.write_text('{"schema":2,"fetchedAt":' + str(fetched_at) + ',"packages":[\n' + ',\n'.join(entries) + '\n]}\n')
print(f"Saved {len(latest)} package records ({output.stat().st_size:,} bytes), dated {args.date}")
