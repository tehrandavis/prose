#!/usr/bin/env python3
"""Evaluate the real Swift manifest offline and check the Mac package graph."""

import json
import os
from pathlib import Path
import subprocess
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
MAC_TARGETS = {
    'ProseCore', 'ProseSyntaxFFI', 'ProseRenderFFI', 'ProseEngineLibrary',
    'ProseApp', 'ProseLauncher', 'ProseTestSupport', 'ProseCoreTests',
    'ProseAppTests',
}


def manifest(path, distribution):
    env = {**os.environ, 'PROSE_DISTRIBUTION': distribution}
    # dump-package evaluates the manifest without resolving, fetching or building
    # any dependency. Separate scratch paths avoid a shared manifest cache.
    scratch = ROOT / 'build/package-contracts' / f'{path.name}-{distribution}'
    result = subprocess.run(
        ['swift', 'package', '--package-path', str(path), '--scratch-path', str(scratch),
         '--cache-path', str(ROOT / 'build/package-contracts/cache'), '--manifest-cache', 'local',
         'dump-package'],
        env=env, check=True, capture_output=True, text=True, timeout=60,
    )
    return json.loads(result.stdout)


def dependencies(graph):
    return {row['sourceControl'][0]['identity'] for row in graph['dependencies']}


def targets(graph):
    return {target['name']: target for target in graph['targets']}


class PackageGraphs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mac = {mode: manifest(ROOT, mode) for mode in ('appstore', 'preview')}

    def test_package_targets_macos_only(self):
        for mode, graph in self.mac.items():
            with self.subTest(distribution=mode):
                self.assertEqual([(p['platformName'], p['version']) for p in graph['platforms']],
                                 [('macos', '14.0')])

    def test_mcp_stays_outside_shared_core(self):
        for source in (ROOT / 'Sources/ProseCore').glob('*.swift'):
            text = source.read_text()
            self.assertNotRegex(text, r'(?m)^import (?:MCP|RMCP|AppKit)$', str(source))

    def test_mac_links_one_engine_library_that_reexports_the_parser(self):
        for mode, graph in self.mac.items():
            with self.subTest(distribution=mode):
                library = targets(graph)['ProseEngineLibrary']
                self.assertEqual(library['type'], 'binary')
                self.assertEqual(library['path'], 'Engine/RenderBridge/target/ProseEngine.xcframework')
                # Both header modules resolve to the one Rust library.
                for name in ('ProseSyntaxFFI', 'ProseRenderFFI'):
                    self.assertEqual(targets(graph)[name]['dependencies'],
                                     [{'byName': ['ProseEngineLibrary', None]}])
                self.assertEqual([t for t in graph['targets'] if t['type'] == 'binary'], [library])
        render = (ROOT / 'Engine/RenderBridge/Cargo.toml').read_text()
        self.assertIn('prose-syntax = { path = "../SyntaxBridge" }', render)
        self.assertIn('pub use prose_syntax::lb_syntax_api;', (ROOT / 'Engine/RenderBridge/src/lib.rs').read_text())

        def pins(lock):
            packages = tomllib.loads((ROOT / lock).read_text())['package']
            return {p['name']: (p['version'], p.get('source')) for p in packages
                    if p['name'] in {'typst-syntax', 'typst-utils', 'typst-timing'}
                    and p['version'].startswith('0.15.')}
        # The standalone parser and the Mac engine use one typst-syntax revision.
        parser = pins('Engine/SyntaxBridge/Cargo.lock')
        self.assertEqual(len(parser), 3)
        self.assertEqual(parser, pins('Engine/RenderBridge/Cargo.lock'))

    def test_mac_keeps_apps_and_preview_updater(self):
        for mode, graph in self.mac.items():
            with self.subTest(distribution=mode):
                self.assertEqual(set(targets(graph)), MAC_TARGETS)
                self.assertEqual({p['name'] for p in graph['products']},
                                 {'ProseCore', 'Prose'})
                expected = {'zipfoundation'} | ({'sparkle'} if mode == 'preview' else set())
                self.assertEqual(dependencies(graph), expected)
                for name in ('ProseApp', 'ProseAppTests'):
                    has_updater = any(row.get('product', [])[:2] == ['Sparkle', 'Sparkle']
                                      for row in targets(graph)[name]['dependencies'])
                    self.assertEqual(has_updater, mode == 'preview')


if __name__ == '__main__':
    unittest.main()
