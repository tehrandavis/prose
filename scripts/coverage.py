#!/usr/bin/env python3
"""Report and gate instrumented application line coverage, including native UI.

Select all production implementation targets; no UI exclusions.
Count LCOV's executable source-line records once per physical line. SwiftUI's
nested closure instantiations can inflate LLVM summary line totals beyond the
actual source length. Raw LLVM JSON and LCOV are retained alongside the report.
Missing source files fail instead of silently improving the percentage.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--minimum", type=float, default=80)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip())
profile_directory = binary_dir / "codecov"
profile = profile_directory / "prose.profdata"
raw_profiles = sorted(profile_directory.glob("*.profraw"))
if not raw_profiles:
    sys.exit("No test coverage profiles were produced.")
subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, raw_profiles), "-o", str(profile)], check=True)
# Swift 6.4's swiftbuild backend creates one bundle per test target; older
# SwiftPM produces ProsePackageTests. Merge all bundles into one app report.
binaries = sorted(p for p in binary_dir.glob("*.xctest/Contents/MacOS/*") if p.is_file())
if not binaries:
    sys.exit("No Swift test bundles found.")
objects = [str(binaries[0])]
for binary in binaries[1:]:
    objects += ["-object", str(binary)]
raw = subprocess.check_output(["xcrun", "llvm-cov", "export", *objects, f"-instr-profile={profile}"], cwd=root)
report = json.loads(raw)
lcov = subprocess.check_output(["xcrun", "llvm-cov", "export", *objects, f"-instr-profile={profile}", "-format=lcov"], cwd=root, text=True)
source_lines = {}
for record in lcov.split("end_of_record"):
    filename = next((line[3:] for line in record.splitlines() if line.startswith("SF:")), None)
    if not filename:
        continue
    entries = source_lines.setdefault(Path(filename).resolve(), {})
    for line in record.splitlines():
        if line.startswith("DA:"):
            number, hits, *_ = line[3:].split(",")
            entries[int(number)] = max(entries.get(int(number), 0), int(hits))
expected = {p.resolve() for folder in ("Sources/ProseCore", "Sources/Prose") for p in (root / folder).glob("**/*.swift")}
by_path = {Path(entry["filename"]).resolve(): entry for data in report["data"] for entry in data["files"] if Path(entry["filename"]).resolve() in expected}
files = list(by_path.values())
missing = expected - {Path(entry["filename"]).resolve() for entry in files}
if missing:
    sys.exit("Coverage export is missing production sources: " + ", ".join(str(p.relative_to(root)) for p in sorted(missing)))
for entry in files:
    lines = source_lines.get(Path(entry["filename"]).resolve(), {})
    if not lines:
        sys.exit("Coverage has no executable line records for production source: " + entry["filename"])
    covered_lines = sum(hits > 0 for hits in lines.values())
    entry["sourceLineCoverage"] = {"covered": covered_lines, "count": len(lines), "percent": covered_lines / len(lines) * 100 if lines else 0}
covered = sum(entry["sourceLineCoverage"]["covered"] for entry in files)
total = sum(entry["sourceLineCoverage"]["count"] for entry in files)
percent = covered / total * 100 if total else 0
output = root / "build/coverage"
output.mkdir(parents=True, exist_ok=True)
(output / "llvm-coverage.json").write_bytes(raw)
(output / "coverage.lcov").write_text(lcov)
# Publish the same unique production source lines used by the 80% gate.
# Keep raw LLVM reports above for diagnosis; test and generated sources must
# not inflate the hosted report, and repository-relative paths work on any CI.
codecov_records = []
for path in sorted(expected):
    lines = source_lines[path]
    codecov_records.append(f"SF:{path.relative_to(root)}")
    codecov_records.extend(f"DA:{number},{hits}" for number, hits in sorted(lines.items()))
    codecov_records.extend((f"LF:{len(lines)}", f"LH:{sum(hits > 0 for hits in lines.values())}", "end_of_record"))
(output / "codecov.lcov").write_text("\n".join(codecov_records) + "\n")
(output / "coverage.json").write_text(json.dumps({"covered": covered, "total": total, "percent": percent, "files": files}, indent=2))
rows = ["| File | Covered lines | Coverage |", "|---|---:|---:|"]
for entry in sorted(files, key=lambda f: f["filename"]):
    lines = entry["sourceLineCoverage"]
    rows.append(f"| {Path(entry['filename']).relative_to(root)} | {lines['covered']}/{lines['count']} | {lines['percent']:.1f}% |")
summary = f"Application source-line coverage: **{percent:.2f}%** ({covered}/{total}), required **{args.minimum:g}%**.\n\nEvery executable implementation line under `Sources/ProseCore`, `Sources/Prose` is counted once using LCOV DA records. Only the minimal Swift process launcher is outside the gate. No UI exclusions.\n\n" + "\n".join(rows) + "\n"
(output / "summary.md").write_text(summary)
print(summary)
subprocess.run(["xcrun", "llvm-cov", "show", *objects, f"-instr-profile={profile}", "-format=html", f"-output-dir={output / 'html'}", *map(str, sorted(expected))], check=True, stdout=subprocess.DEVNULL)
if percent < args.minimum:
    sys.exit(f"Coverage {percent:.2f}% is below {args.minimum:g}%.")
