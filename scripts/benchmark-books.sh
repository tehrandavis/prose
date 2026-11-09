#!/bin/bash
# Run after scripts/test.sh. Reuses its instrumented debug test binary.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
mkdir -p build/benchmarks
status=0
# Keep the other book and preview evidence even if one scenario fails. Never
# retry a failing measurement or let an old report stand in for the current run.
python3 - <<'PYCLEAN'
from pathlib import Path
for name in ('war-and-peace.json', 'sicp.json', 'war-and-peace-writing.json', 'sicp-writing.json', 'syntax.json', 'summary.md', 'book-preview-1.png', 'book-preview-224.png', 'book-preview-448.png'):
    (Path('build/benchmarks') / name).unlink(missing_ok=True)
PYCLEAN
PROSE_INTEGRATION=1 \
  PROSE_LARGE_FIXTURE="$PWD/Examples/Books/WarAndPeace/war-and-peace-highlighted.typ" \
  PROSE_PERFORMANCE_REPORT="$PWD/build/benchmarks/war-and-peace.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
PROSE_INTEGRATION=1 PROSE_CODE_WORD="define size" PROSE_SEARCH_WORD=procedure PROSE_BENCH_EXPORT=1 \
  PROSE_LARGE_FIXTURE="$PWD/Examples/Books/SICP/main.typ" \
  PROSE_PERFORMANCE_REPORT="$PWD/build/benchmarks/sicp.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
# The same scenario in Writing mode (acceptance test 14 of the Phase 3 note).
PROSE_INTEGRATION=1 PROSE_WRITING_MODE=1 \
  PROSE_LARGE_FIXTURE="$PWD/Examples/Books/WarAndPeace/war-and-peace-highlighted.typ" \
  PROSE_PERFORMANCE_REPORT="$PWD/build/benchmarks/war-and-peace-writing.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
PROSE_INTEGRATION=1 PROSE_WRITING_MODE=1 PROSE_CODE_WORD="define size" PROSE_SEARCH_WORD=procedure PROSE_BENCH_EXPORT=1 \
  PROSE_LARGE_FIXTURE="$PWD/Examples/Books/SICP/main.typ" \
  PROSE_PERFORMANCE_REPORT="$PWD/build/benchmarks/sicp-writing.json" \
  swift test --skip-build --enable-code-coverage --filter realMultiMegabyteDocumentNavigationScrollingAndTyping || status=1
PROSE_SYNTAX_REPORT="$PWD/build/benchmarks/syntax.json" \
  swift test --skip-build --enable-code-coverage --filter bookLengthSourcesParseWithinBudget || status=1
PROSE_INTEGRATION=1 PROSE_BOOK_PREVIEW=1 \
  swift test --skip-build --enable-code-coverage --filter completeBookPreviewRemainsUsableInLargeWindow || status=1
python3 - <<'PY'
import json
from pathlib import Path
books = ['war-and-peace', 'sicp', 'war-and-peace-writing', 'sicp-writing']
rows = ['# Book editing benchmarks', '', '| Book | Mode | Source bytes | Open (s) | First compile (s) | Typing median / p95 / max (ms) | Typing CPU max (ms) | Navigate + draw median / max (ms) | Jumps on target / hit error | Scroll + draw p95 (ms) | Scroll drift (pt) | Paragraphs built |', '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
reports = {}
for name in books:
    book, mode = (name[:-8], 'Writing') if name.endswith('-writing') else (name, 'Code')
    report = Path(f'build/benchmarks/{name}.json')
    if not report.exists():
        rows.append(f'| {book} | {mode} | Report unavailable: scenario failed before completion | | | | | | | | | |')
        continue
    r = reports[name] = json.loads(report.read_text())
    first = r.get('first_compile_seconds')
    first = f'{first:.2f}' if isinstance(first, (int, float)) else 'not reached'
    rows.append(f'| {book} | {mode} | {r["bytes"]:,} | {r["open_seconds"]:.2f} | {first} | {r["typing_ms"]["median"]:.2f} / {r["typing_ms"]["p95"]:.2f} / {r["typing_ms"]["max"]:.2f} | {r["typing_thread_cpu_ms"]["max"]:.2f} | {r["navigation_ms"]["median"]:.2f} / {r["navigation_ms"]["max"]:.2f} | {r["jumps_on_target"]}/6 / {r["max_hit_error"]} | {r["scroll_draw_ms"]["p95"]:.2f} | {r["scroll_drift_pt"]:.1f} | {r["paragraphs_built"]["typed"]:,} |')
rows += ['', '| Book | Mode | Peak memory (MiB) | Writing engine (MiB) | Tinymist peak (MiB) | Typing: main thread / process / Tinymist CPU (s) | After typing: main thread / process / Tinymist CPU (s) | Swaps | Rendered draws |', '|---|---|---:|---:|---:|---:|---:|---:|---:|']
def cpu(usage):
    return f'{usage["main_thread_cpu_seconds"]:.2f} / {usage["process_cpu_seconds"]:.2f} / {usage["children_cpu_seconds"]:.2f} in {usage["wall_seconds"]:.1f} s'
for name, r in reports.items():
    book, mode = (name[:-8], 'Writing') if name.endswith('-writing') else (name, 'Code')
    writing = r.get('writing', {})
    engine = f'{r["memory_writing_entered_mib"] - r["memory_before_writing_mib"]:.0f}' if 'memory_writing_entered_mib' in r else ''
    rows.append(f'| {book} | {mode} | {r["memory_peak_mib"]:.0f} | {engine} | {r["children_peak_mib"]:.0f} | {cpu(r["typing_phase"])} | {cpu(r["after_typing"])} | {writing.get("swaps_total", "")} | {writing.get("rendered_fragment_draws", "")} |')
syntax = Path('build/benchmarks/syntax.json')
if syntax.exists():
    parsed = json.loads(syntax.read_text())
    rows += ['', '| Parser (typst-syntax) | Nodes | Full parse (ms) | Keystroke median / max (ms) | Unclosed `$` (ms) |', '|---|---:|---:|---:|---:|']
    for book in ['war-and-peace', 'sicp']:
        r = parsed[book]
        rows.append(f'| {book} | {r["nodes"]:,} | {r["parse_ms"]:.2f} | {r["typing_median_ms"]:.2f} / {r["typing_max_ms"]:.2f} | {r["unclosed_dollar_ms"]:.2f} |')
else:
    rows += ['', 'Parser report unavailable: scenario failed before completion.']
rows += ['', 'Writing mode: every jump and the typing land in a block that is rendered when they start, so each one swaps it to source. Writing engine: footprint after entering Writing mode (engine ready, first renders, first full compile) minus before. Peak memory: largest physical footprint of the test process; Tinymist peak: largest footprint of its live processes. After typing: from the end of typing, at least 4 s and until both engines are idle.', '', 'First compile: engine start to the first successful Tinymist compile, measured while the benchmark keeps working. Typing gates: 80 samples, wall p95 < 100 ms, wall max < 250 ms, main-thread CPU max < 100 ms. First input is included; no retries or discarded outliers.', '', 'Instrumented debug AppKit tests. CPU layout and bitmap painting, not display FPS. Peak memory excludes Tinymist and WebKit. See docs/large-document-performance.md for scope.']
Path('build/benchmarks/summary.md').write_text('\n'.join(rows) + '\n')
PY
exit "$status"
