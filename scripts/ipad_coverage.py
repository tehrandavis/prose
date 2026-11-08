#!/usr/bin/env python3
"""Gate real iPad executable-line coverage from XCTest result bundles.

Use executed LLVM LCOV records from the native app and framework images, with
xccov archives as a fallback. Swift closure instantiations count once per line. Test targets,
dependencies, generated code and the uninstrumented Rust static library never
contribute to the percentage. All iPad UI and compiled shared Core code count.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


SOURCE_FOLDERS = ("iPad/Sources", "Sources/ProseCore")
# On iOS this file contains only the TinymistTransport protocol; the concrete
# Process implementation is macOS-only. Count it if executable code is added.
DECLARATION_ONLY = "Sources/ProseCore/TinymistTransport.swift"


def executable_lines(archive):
    lines = {}
    for text in archive.splitlines():
        match = re.match(r"^\s*(\d+):\s*(\d+|\*)(?:\s*\[)?\s*$", text)
        if match and match[2] != "*":
            number, hits = int(match[1]), int(match[2])
            if number < 1:
                raise ValueError("Invalid source line in coverage archive")
            lines[number] = max(lines.get(number, 0), hits)
        elif re.match(r"^\s*\d+:", text) and not match:
            raise ValueError(f"Unrecognized xccov execution count: {text}")
    return lines


def production_sources(root):
    return {path.resolve() for folder in SOURCE_FOLDERS for path in (root / folder).rglob("*.swift")}


def lcov_lines(text):
    sources = {}
    for record in text.split('end_of_record'):
        path = next((line[3:] for line in record.splitlines() if line.startswith('SF:')), None)
        if not path:
            continue
        lines = sources.setdefault(Path(path).resolve(), {})
        for line in record.splitlines():
            if line.startswith('DA:'):
                number, hits, *_ = line[3:].split(',')
                number, hits = int(number), int(hits)
                if number < 1 or hits < 0:
                    raise ValueError('Invalid LCOV execution count')
                lines[number] = max(lines.get(number, 0), hits)
    return sources


def collect(root, bundles, output):
    expected = production_sources(root)
    if not expected:
        raise ValueError("No iPad production sources found")
    source_lines = {}
    reports = []
    for bundle in bundles:
        report = json.loads(subprocess.check_output(
            ["xcrun", "xccov", "view", "--report", "--json", str(bundle)], text=True))
        reports.append({"bundle": str(bundle), "report": report})
        lcov = bundle.with_suffix('.lcov')
        if lcov.exists():
            # LLVM reads the executed application/framework images directly. Some Xcode
            # versions emit an empty xccov target for an instrumented Swift package.
            for path, lines in lcov_lines(lcov.read_text()).items():
                if path not in expected:
                    continue
                merged = source_lines.setdefault(path, {})
                for number, hits in lines.items():
                    merged[number] = max(merged.get(number, 0), hits)
            continue
        paths = {Path(entry["path"]).resolve()
                 for target in report["targets"] for entry in target["files"]}
        for path in sorted(paths & expected):
            archive = subprocess.check_output(
                ["xcrun", "xccov", "view", "--archive", "--file", str(path), str(bundle)], text=True)
            lines = executable_lines(archive)
            merged = source_lines.setdefault(path, {})
            for number, hits in lines.items():
                merged[number] = max(merged.get(number, 0), hits)
    output.mkdir(parents=True, exist_ok=True)
    (output / "xccov-reports.json").write_text(json.dumps(reports, indent=2) + "\n")
    missing = expected - source_lines.keys() - {(root / DECLARATION_ONLY).resolve()}
    if missing:
        raise ValueError("Coverage is missing production sources: " +
                         ", ".join(str(path.relative_to(root)) for path in sorted(missing)))
    for path, lines in source_lines.items():
        if not lines and path != (root / DECLARATION_ONLY).resolve():
            raise ValueError(f"Coverage has no executable line records: {path.relative_to(root)}")
        if lines and max(lines) > len(path.read_text().splitlines()):
            raise ValueError(f"Coverage source does not match this checkout: {path.relative_to(root)}")
    return {path: lines for path, lines in source_lines.items() if lines}


def write_report(root, output, source_lines, minimum):
    covered = sum(sum(hits > 0 for hits in lines.values()) for lines in source_lines.values())
    total = sum(len(lines) for lines in source_lines.values())
    if not total:
        raise ValueError("No executable production lines were measured")
    percent = covered / total * 100
    files, records, rows = [], [], ["| File | Covered lines | Coverage |", "|---|---:|---:|"]
    for path, lines in sorted(source_lines.items()):
        name = str(path.relative_to(root))
        hits = sum(count > 0 for count in lines.values())
        files.append({"path": name, "covered": hits, "total": len(lines)})
        records.append(f"SF:{name}")
        records.extend(f"DA:{number},{count}" for number, count in sorted(lines.items()))
        records.extend((f"LF:{len(lines)}", f"LH:{hits}", "end_of_record"))
        rows.append(f"| {name} | {hits}/{len(lines)} | {hits / len(lines) * 100:.1f}% |")
    (output / "codecov.lcov").write_text("\n".join(records) + "\n")
    (output / "coverage.json").write_text(json.dumps(
        {"covered": covered, "total": total, "percent": percent, "files": files}, indent=2) + "\n")
    summary = (f"iPad application source-line coverage: **{percent:.2f}%** ({covered}/{total}), "
               f"required **{minimum:g}%**.\n\n"
               "All executable lines in `iPad/Sources` and the iOS build of `Sources/ProseCore` "
               "count once, including UI. XCTest and UI runs supply actual LLVM execution counts. "
               "Dependencies, test code, generated code and the uninstrumented Rust engine are "
               "outside this Swift coverage report. `TinymistTransport.swift` has only protocol "
               "declarations on iOS; any executable lines added there will count.\n\n" +
               "\n".join(rows) + "\n")
    (output / "summary.md").write_text(summary)
    print(summary)
    return percent >= minimum


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, nargs="+", required=True)
    parser.add_argument("--minimum", type=float, default=80)
    args = parser.parse_args(argv)
    if not 0 <= args.minimum <= 100:
        parser.error("--minimum must be between 0 and 100")
    root = Path(__file__).resolve().parent.parent
    output = root / "build/iPad-coverage"
    lines = collect(root, args.result, output)
    if not write_report(root, output, lines, args.minimum):
        raise ValueError(f"iPad coverage is below {args.minimum:g}%")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
