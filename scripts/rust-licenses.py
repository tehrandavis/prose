#!/usr/bin/env python3
"""Collect pinned Rust dependency notices into a macOS package resource.

Usage: rust-licenses.py {mcp|syntax|render}. Run with the CARGO_HOME that built the crate.
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
BUNDLES = {
    # The macOS MCP helper executable (scripts/build-mcp.sh).
    'mcp': ('Tools/MCPServer/Cargo.toml', '.tools/MCP-LICENSES.txt',
            'Prose macOS MCP helper dependency notices.'),
    # typst-syntax linked into the macOS app (scripts/build-syntax.sh).
    'syntax': ('Engine/SyntaxBridge/Cargo.toml', '.tools/SYNTAX-LICENSES.txt',
               'Prose macOS Typst parser (typst-syntax) dependency notices.'),
    # The engine library linked into the macOS app (scripts/build-render.sh):
    # the per-block Typst renderer with the typst-syntax bridge inside it.
    'render': ('Engine/RenderBridge/Cargo.toml', '.tools/RENDER-LICENSES.txt',
               'Prose macOS Typst engine (renderer and parser) dependency notices.'),
}
# Crates whose published archive or git subdirectory omits the repository-root license.
SHARED_LICENSES = {
    'rmcp': root / 'Tools/MCPServer/LICENSE-rmcp',
    'typst-syntax': root / 'Resources/Typst-LICENSE',
    'typst-timing': root / 'Resources/Typst-LICENSE',
    'typst-utils': root / 'Resources/Typst-LICENSE',
}
# The render bridge's graph has more such crates. These texts are copied from
# each upstream repository at the pinned version's tag; comemo's come from the
# comemo 0.5.1 crate archive, the same repository and release as comemo-macros.
RENDER_TEXTS = root / 'Engine/RenderBridge/licenses'
WASMI = [RENDER_TEXTS / 'wasmi-LICENSE-APACHE', RENDER_TEXTS / 'wasmi-LICENSE-MIT']
SHARED_LICENSES_LISTS = {
    'comemo-macros': [RENDER_TEXTS / 'comemo-LICENSE-APACHE', RENDER_TEXTS / 'comemo-LICENSE-MIT'],
    'glidesort': [RENDER_TEXTS / 'glidesort-NOTICE.txt'],
    'roman-numerals-rs': [RENDER_TEXTS / 'roman-numerals-LICENCE.rst'],
    'wasmi': WASMI, 'wasmi_collections': WASMI, 'wasmi_core': WASMI, 'wasmi_ir': WASMI,
    'wasmparser': [RENDER_TEXTS / 'wasm-tools-LICENSE-Apache-2.0_WITH_LLVM-exception',
                   RENDER_TEXTS / 'wasm-tools-LICENSE-APACHE', RENDER_TEXTS / 'wasm-tools-LICENSE-MIT'],
}
# Every Typst crate comes from Tinymist's pinned fork, whose crate directories
# omit the repository-root license.
TYPST_FORK = 'git+https://github.com/Myriad-Dreamin/typst.git'


def notices(bundle):
    manifest, output, title = BUNDLES[bundle]
    metadata = json.loads(subprocess.check_output([
        'cargo', '+1.92.0', 'metadata', '--locked', '--format-version', '1',
        '--manifest-path', str(root / manifest), '--filter-platform', 'aarch64-apple-darwin',
    ], text=True))
    workspace = set(metadata['workspace_members'])
    sections = [title + '\n']
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        # Path dependencies (the syntax bridge inside the render bridge) are Prose's own code.
        if package['id'] in workspace or package['source'] is None:
            continue
        directory = Path(package['manifest_path']).parent
        licenses = sorted(p for p in directory.iterdir()
                          if p.is_file() and p.name.lower().startswith(('license', 'licence', 'copying', 'notice')))
        if not licenses and package['name'] in SHARED_LICENSES:
            licenses = [SHARED_LICENSES[package['name']]]
        elif not licenses and package['name'] in SHARED_LICENSES_LISTS:
            licenses = SHARED_LICENSES_LISTS[package['name']]
        elif not licenses and package['name'].startswith('typst') and package['source'].startswith(TYPST_FORK):
            licenses = [root / 'Resources/Typst-LICENSE']
        elif package['name'] == 'rmcp':
            licenses = [SHARED_LICENSES['rmcp']]
        if not licenses:
            raise SystemExit('Missing license notice for ' + package['name'])
        sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']} ({package['license']})\n"
                        f"{package.get('repository') or ''}\n")
        for license_file in licenses:
            sections.append('\n' + license_file.read_text() + '\n')
    (root / output).parent.mkdir(exist_ok=True)
    (root / output).write_text(''.join(sections))


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in BUNDLES:
        raise SystemExit('Usage: rust-licenses.py {' + '|'.join(BUNDLES) + '}')
    notices(sys.argv[1])
