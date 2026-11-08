#!/usr/bin/env python3
"""Offline contracts for the iPad executable coverage denominator and gate."""

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ipad_coverage as coverage


class CoverageContracts(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="ipad-coverage-", dir=os.environ["TMPDIR"])
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.app = self.source("iPad/Sources/App.swift")
        self.core = self.source("Sources/ProseCore/Core.swift")
        self.source(coverage.DECLARATION_ONLY)
        self.output = self.root / "output"

    def source(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("first\nsecond\nthird\n")
        return path

    def report(self, *paths):
        return json.dumps({"targets": [{"files": [{"path": str(path)} for path in paths]}]})

    def test_unique_lines_ignore_nonexecutable_and_subranges(self):
        self.assertEqual(coverage.executable_lines(
            "1: *\n2: 0\n3: 2 [\n(1, 24, 1)\n]\n3: 8\n"), {2: 0, 3: 8})
        with self.assertRaisesRegex(ValueError, "Unrecognized"):
            coverage.executable_lines("2: unknown")

    def test_real_runs_merge_hits_and_never_count_tests_or_dependencies(self):
        dependency = self.source(".build/checkouts/Dependency/Sources/Fake.swift")
        test = self.source("iPad/Tests/Test.swift")
        counts = iter(["1: 2\n2: 0\n", "1: 0\n2: 1\n", "1: 0\n2: 3\n", "1: 4\n2: 0\n"])

        def command(args, **_options):
            if "--report" in args:
                return self.report(self.app, self.core, dependency, test)
            self.assertIn(Path(args[-2]), {self.app, self.core})
            return next(counts)

        with patch.object(coverage.subprocess, "check_output", side_effect=command):
            lines = coverage.collect(self.root, [Path("small.xcresult"), Path("large.xcresult")], self.output)
        self.assertEqual(set(lines), {self.app, self.core})
        self.assertTrue(all(all(hits > 0 for hits in entries.values()) for entries in lines.values()))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(coverage.write_report(self.root, self.output, lines, 80))
        lcov = (self.output / "codecov.lcov").read_text()
        self.assertIn("SF:iPad/Sources/App.swift", lcov)
        self.assertNotIn("Dependency", lcov)
        self.assertNotIn("Tests", lcov)

    def test_missing_app_or_shared_core_cannot_improve_gate(self):
        for present in (self.app, self.core):
            with self.subTest(present=present), patch.object(
                    coverage.subprocess, "check_output", side_effect=[self.report(present), "1: 1\n"]):
                with self.assertRaisesRegex(ValueError, "missing production sources"):
                    coverage.collect(self.root, [Path("test.xcresult")], self.output)

    def test_declaration_file_counts_if_it_gains_executable_lines(self):
        declared = self.root / coverage.DECLARATION_ONLY
        with patch.object(coverage.subprocess, "check_output", side_effect=[
                self.report(self.app, self.core, declared), "1: 1\n", "1: 1\n", "1: 0\n"]):
            lines = coverage.collect(self.root, [Path("test.xcresult")], self.output)
        self.assertIn(declared, lines)

    def test_empty_or_stale_archive_cannot_report_success(self):
        for records in ("1: *\n", "4: 1\n"):
            with self.subTest(records=records), patch.object(
                    coverage.subprocess, "check_output", side_effect=[
                        self.report(self.app, self.core), records, "1: 1\n"]):
                with self.assertRaises(ValueError):
                    coverage.collect(self.root, [Path("test.xcresult")], self.output)

    def test_threshold_fails_and_preserves_diagnostic_report(self):
        self.output.mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(coverage.write_report(
                self.root, self.output, {self.app: {1: 1, 2: 0, 3: 0}}, 80))
        self.assertEqual(json.loads((self.output / "coverage.json").read_text())["total"], 3)
        self.assertIn("required **80%**", (self.output / "summary.md").read_text())

    def test_llvm_images_supply_package_lines_missing_from_xccov(self):
        bundle = self.root / 'native.xcresult'
        bundle.with_suffix('.lcov').write_text(
            f'SF:{self.app}\nDA:1,1\nend_of_record\nSF:{self.core}\nDA:1,0\nDA:1,2\nend_of_record\n')
        with patch.object(coverage.subprocess, 'check_output', return_value=self.report(self.app)):
            lines = coverage.collect(self.root, [bundle], self.output)
        self.assertEqual(lines, {self.app: {1: 1}, self.core: {1: 2}})


if __name__ == "__main__":
    unittest.main()
