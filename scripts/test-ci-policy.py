#!/usr/bin/env python3
"""CI capacity policy: path selection, nightly release checks, gate and publication.

Runs in the ubuntu `changes` job before any macOS job starts. Workflow files are
inspected as text so the test needs only the Python standard library.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_changes as ci  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / '.github/workflows'
MAC_JOBS = {'integration', 'appstore', 'memory'}


def jobs(workflow):
    """Map each job id to its text block."""
    text = (WORKFLOWS / workflow).read_text()
    body = text[text.index('\njobs:\n') + len('\njobs:\n'):]
    parts = re.split(r'^  ([a-z][a-z0-9-]*):\n', body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


def field(block, name):
    match = re.search(rf'^    {name}: (.*)$', block, flags=re.M)
    return match.group(1).strip() if match else None


def needs(block):
    value = field(block, 'needs') or ''
    return set(value.strip('[]').replace(' ', '').split(',')) - {''}


def condition_passes(block, context, *, cancelled=False):
    """Evaluate the workflow's publication conditions with supplied job results."""
    expression = field(block, 'if')
    if expression == '>-':
        expression = re.search(r'    if: >-\n((?:      .*\n)+)', block).group(1)
    expression = ' '.join(expression.removeprefix('${{').removesuffix('}}').split())
    expression = expression.replace('!cancelled()', repr(not cancelled))
    expression = re.sub(r'needs\.[\w.-]+', lambda match: repr(context[match.group()]), expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    return eval(expression, {'__builtins__': {}})


class PathClassificationTests(unittest.TestCase):
    MAC, DOCS = {'mac'}, set()
    TABLE = {
        # Mac app, MCP helper, engine and packaging.
        'Sources/Prose/Workspace.swift': MAC,
        'Sources/ProseLauncher/main.swift': MAC,
        'Tests/ProseAppTests/WritingFlowTests.swift': MAC,
        'Tests/MCP/editing.hurl': MAC,
        'Tools/MCPServer/src/main.rs': MAC,
        'Tools/MCPServer/Cargo.lock': MAC,
        'Engine/RenderBridge/src/lib.rs': MAC,
        'Engine/RenderBridge/Cargo.lock': MAC,
        'Sources/ProseRenderFFI/include/ProseRender.h': MAC,
        'scripts/build-render.sh': MAC,
        'Resources/Info.plist': MAC,
        'Resources/Preview-Info.plist': MAC,
        'Resources/AppIcon.icns': MAC,
        'Resources/en.lproj/InfoPlist.strings': MAC,
        'scripts/test.sh': MAC,
        'scripts/test-swiftlint-policy.py': MAC,
        'scripts/build-tinymist.sh': MAC,
        'scripts/tinymist-native-tls.patch': MAC,
        'scripts/release.sh': MAC,
        'scripts/staple_app.py': MAC,
        'scripts/test-staple-app.py': MAC,
        'scripts/publish-preview.py': MAC,
        'scripts/preview_channels.py': MAC,
        'scripts/check-memory.sh': MAC,
        'scripts/build-syntax.sh': MAC,
        'Benchmarks/Diffing/TextDiffingRoundTripTests.swift': MAC,
        '.swiftlint.yml': MAC,
        '.github/workflows/release.yml': MAC,
        # Core code, resources and CI infrastructure.
        'Sources/ProseCore/TinymistClient.swift': MAC,
        'Sources/ProseCore/Resources/en.lproj/Localizable.strings': MAC,
        'Sources/ProseSyntaxFFI/include/ProseSyntax.h': MAC,
        'Engine/SyntaxBridge/src/lib.rs': MAC,
        'Engine/SyntaxBridge/Cargo.lock': MAC,
        'Engine/NewBridge/Cargo.toml': MAC,
        'scripts/rust-licenses.py': MAC,
        'Package.swift': MAC,
        'Package.resolved': MAC,
        'Tests/ProseCoreTests/CoreTests.swift': MAC,
        'Tests/Support/TestPaths.swift': MAC,
        'Resources/Icons/pen.svg': MAC,
        'Resources/Packages/preview/cetz/0.5.2/src/lib.typ': MAC,
        'Resources/ThirdParty.txt': MAC,
        'Examples/Welcome.typ': MAC,
        'Brand/Prose/icon-1024.png': MAC,
        'scripts/environment.sh': MAC,
        'scripts/lint.sh': MAC,
        'scripts/tinymist-vfs.patch': MAC,
        'scripts/coverage.py': MAC,
        'scripts/appstore_connect.py': MAC,
        'scripts/test-appstore-release.py': MAC,
        'scripts/release_metadata.py': MAC,
        'scripts/ci_changes.py': MAC,
        'scripts/test-ci-policy.py': MAC,
        'scripts/test-package-graphs.py': MAC,
        '.github/workflows/ci.yml': MAC,
        '.github/dependabot.yml': MAC,
        # Unknown paths run the Mac jobs.
        'something/new.txt': MAC,
        # Documentation runs no macOS job.
        'docs/development.md': DOCS,
        'docs/screenshots/editor.png': DOCS,
        'README.md': DOCS,
        'releases/0.5.0.md': DOCS,
        'LICENSE': DOCS,
        'Brand/README.md': DOCS,
    }

    def test_each_path_selects_its_platforms(self):
        for path, expected in self.TABLE.items():
            with self.subTest(path=path):
                self.assertEqual(ci.classify(path), expected)

    def test_prefixes_match_whole_names_or_directories(self):
        # A sibling sharing a name prefix with a docs path is not documentation.
        self.assertEqual(ci.classify('docsite/index.md'), {'mac'})
        self.assertEqual(ci.classify('README.md.orig'), {'mac'})
        self.assertEqual(ci.classify('Brand/README.mdx'), {'mac'})
        self.assertEqual(ci.classify('Examples/Books/SICP/README.md'), {'mac'})
        self.assertFalse(ci.matches('scripts/test.sh.orig', ci.MAC))

    def test_every_tracked_script_is_classified_deliberately(self):
        scripts = subprocess.check_output(['git', 'ls-files', 'scripts'], cwd=ROOT, text=True).split()
        for script in scripts:
            with self.subTest(script=script):
                self.assertTrue(ci.matches(script, ci.MAC + ci.DOCS),
                                'List new scripts in scripts/ci_changes.py MAC')
        # Each listed script still exists, so the list cannot silently go stale.
        for prefix in ci.MAC:
            if prefix.startswith('scripts/'):
                with self.subTest(listed=prefix):
                    self.assertIn(prefix, scripts)

    def test_selection_unions_the_changed_paths(self):
        self.assertEqual(ci.select(['docs/development.md', 'README.md']), {'mac': False})
        self.assertEqual(ci.select([]), {'mac': False})
        self.assertEqual(ci.select(['Tools/MCPServer/src/main.rs', 'docs/mcp-design.md']), {'mac': True})
        self.assertEqual(ci.select(['Sources/ProseCore/Library.swift']), {'mac': True})


class PlanTests(unittest.TestCase):
    """Event handling against a real scratch repository."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='prose-ci-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        patcher = mock.patch.object(ci, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.git('init', '-q', '-b', 'main')
        self.base = self.commit('docs/start.md')

    def git(self, *args):
        env = {**os.environ, 'GIT_AUTHOR_NAME': 'CI', 'GIT_AUTHOR_EMAIL': 'ci@example.invalid',
               'GIT_COMMITTER_NAME': 'CI', 'GIT_COMMITTER_EMAIL': 'ci@example.invalid'}
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, env=env).strip()

    def commit(self, path):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(file.read_text() + '.' if file.exists() else path)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', path)
        return self.git('rev-parse', 'HEAD')

    def plan(self, event, head, runs=lambda repository, event: [], **kwargs):
        return ci.plan(event, head, 'tehrandavis/prose', runs=runs, **kwargs)[0]

    def test_push_diffs_against_the_last_successful_main_run(self):
        self.commit('Sources/Prose/Workspace.swift')   # its run was cancelled
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.base]), {'mac': True})
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.git('rev-parse', 'HEAD~1')]),
                         {'mac': False})

    def test_push_ignores_its_own_and_unrelated_successes(self):
        head = self.commit('Tools/MCPServer/src/main.rs')
        self.git('checkout', '-q', '-b', 'other', self.base)
        unrelated = self.commit('Sources/Prose/Other.swift')
        self.git('checkout', '-q', 'main')
        # A rerun of an already successful commit still diffs against an earlier run.
        runs = lambda repository, event: [head, unrelated, self.base]  # noqa: E731
        self.assertEqual(self.plan('push', head, runs=runs), {'mac': True})
        # Only an ancestor may be the base: the unrelated run would select Mac
        # jobs for this docs-only commit.
        docs = self.commit('docs/more.md')
        runs = lambda repository, event: [unrelated, head]  # noqa: E731
        self.assertEqual(self.plan('push', docs, runs=runs), {'mac': False})

    def test_push_without_a_usable_base_runs_everything(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('push', head), {'mac': True})

        def broken(repository, event):
            raise subprocess.CalledProcessError(1, 'gh')
        self.assertEqual(self.plan('push', head, runs=broken), {'mac': True})

    def test_docs_only_push_runs_no_macos_job(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.base]), {'mac': False})

    def test_pull_request_diffs_its_test_merge_commit_against_the_base(self):
        self.git('checkout', '-q', '-b', 'feature')
        self.commit('docs/feature.md')
        self.git('checkout', '-q', 'main')
        self.commit('Sources/Prose/Landed.swift')          # already on the base branch
        self.git('merge', '-q', '--no-ff', '-m', 'merge', 'feature')
        merge = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.plan('pull_request', merge), {'mac': False})

    def test_pull_request_head_checkout_uses_the_merge_base(self):
        self.git('checkout', '-q', '-b', 'feature')
        head = self.commit('Sources/Prose/Workspace.swift')
        self.assertEqual(self.plan('pull_request', head, pr_base=self.base), {'mac': True})

    def test_nightly_runs_everything_unless_main_is_unchanged(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('schedule', head, runs=lambda repository, event: [self.base]), {'mac': True})
        self.assertEqual(self.plan('schedule', head, runs=lambda repository, event: [head, self.base]),
                         {'mac': False})
        self.assertEqual(self.plan('schedule', head), {'mac': True})

    def test_a_failed_nightly_is_retried_so_preview_still_publishes(self):
        # The successful-runs query never returns a failed nightly, whether its
        # tests or its Preview publication failed, so the same commit runs again.
        head = self.commit('Sources/Prose/Workspace.swift')
        last_success = lambda repository, event: [self.base]  # noqa: E731  (the run for head failed)
        selection = self.plan('schedule', head, runs=last_success)
        self.assertEqual(selection, {'mac': True})
        self.assertTrue(ci.outputs(selection, 'schedule', 'refs/heads/main')['publish'])

    def test_nightly_only_compares_with_earlier_nightlies(self):
        seen = []
        self.plan('schedule', self.base, runs=lambda repository, event: seen.append(event) or [])
        self.assertEqual(seen, ['schedule'])

    def test_manual_and_unknown_events_run_everything(self):
        for event in ('workflow_dispatch', 'merge_group', 'release'):
            with self.subTest(event=event):
                self.assertEqual(self.plan(event, self.base), {'mac': True})

    def test_preview_dispatch_runs_the_mac_checks(self):
        self.assertEqual(self.plan('workflow_dispatch', self.base, publish_preview=True), {'mac': True})


class OutputTests(unittest.TestCase):
    """Release checks and Preview publication run only from main's nightly or a manual main run."""
    MAIN, BRANCH = 'refs/heads/main', 'refs/heads/feature'

    def result(self, event, ref=MAIN, mac=True, publish_preview=False):
        values = ci.outputs({'mac': mac}, event, ref, publish_preview)
        return values['release'], values['publish']

    def channel(self, event, **kwargs):
        return ci.outputs({'mac': True}, event, self.MAIN, **kwargs)['channel']

    def test_pull_requests_never_release_or_publish(self):
        self.assertEqual(self.result('pull_request', 'refs/pull/79/merge'), (False, False))
        self.assertEqual(self.result('pull_request', 'refs/pull/79/merge', publish_preview=True), (False, False))

    def test_mac_affecting_main_pushes_publish_the_alpha_channel(self):
        self.assertEqual(self.result('push'), (False, True))
        self.assertEqual(self.channel('push'), 'alpha')
        # Docs-only pushes select no Mac job, so they publish nothing.
        self.assertEqual(self.result('push', mac=False), (False, False))
        self.assertEqual(self.result('push', self.BRANCH), (False, False))
        for event in ('schedule', 'workflow_dispatch'):
            self.assertEqual(self.channel(event, publish_preview=True), 'nightly')

    def test_nightly_releases_and_publishes_from_main(self):
        self.assertEqual(self.result('schedule'), (True, True))
        # An unchanged nightly selects no Mac job, so it neither tests nor publishes.
        self.assertEqual(self.result('schedule', mac=False), (False, False))

    def test_manual_main_runs_release_and_publish_only_on_request(self):
        self.assertEqual(self.result('workflow_dispatch'), (True, False))
        self.assertEqual(self.result('workflow_dispatch', publish_preview=True), (True, True))
        self.assertEqual(self.result('workflow_dispatch', self.BRANCH, publish_preview=True), (False, False))
        self.assertEqual(self.result('schedule', self.BRANCH), (False, False))


class GateTests(unittest.TestCase):
    def needs(self, mac, release, **overrides):
        outputs = {'mac': str(mac).lower(), 'release': str(release).lower(), 'publish': str(release).lower()}
        result = {'changes': {'result': 'success', 'outputs': outputs}}
        for job, expected in ci.expected_results(mac, release).items():
            result[job] = {'result': expected, 'outputs': {}}
        for job, value in overrides.items():
            result[job.replace('_', '-')] = {'result': value, 'outputs': {}}
        return result

    def test_selected_jobs_must_pass_and_filtered_jobs_must_skip(self):
        for mac in (True, False):
            for release in ((True, False) if mac else (False,)):
                with self.subTest(mac=mac, release=release):
                    self.assertEqual(ci.gate(self.needs(mac, release)), [])

    def test_docs_only_run_passes_with_every_macos_job_skipped(self):
        needs = self.needs(False, False)
        self.assertTrue(all(needs[job]['result'] == 'skipped' for job in MAC_JOBS))
        self.assertEqual(ci.gate(needs), [])

    def test_failed_cancelled_or_unexpected_results_fail(self):
        cases = [
            self.needs(True, False, integration='failure'),
            self.needs(True, False, integration='cancelled'),
            self.needs(True, False, integration='skipped'),
            self.needs(True, True, memory='failure'),
            self.needs(True, True, appstore='skipped'),
            # A job that should have been filtered out but ran is a selection bug.
            self.needs(False, False, integration='success'),
            self.needs(True, False, appstore='success'),
            self.needs(True, False, memory='success'),
        ]
        for needs in cases:
            with self.subTest(needs=needs):
                self.assertNotEqual(ci.gate(needs), [])

    def test_preview_publication_is_reported_separately(self):
        needs = self.needs(True, True)
        needs['preview'] = {'result': 'failure'}
        self.assertEqual(ci.gate(needs), [])
        self.assertNotIn('preview', ci.expected_results(True, True))

    def test_a_failed_or_malformed_selection_fails(self):
        needs = self.needs(True, False)
        needs['changes']['result'] = 'failure'
        self.assertNotEqual(ci.gate(needs), [])
        for outputs in ({'mac': '', 'release': 'false'},
                        {'mac': 'true'},
                        {'mac': 'false', 'release': 'true'}, {}):
            needs = self.needs(True, False)
            needs['changes']['outputs'] = outputs
            with self.subTest(outputs=outputs):
                self.assertNotEqual(ci.gate(needs), [])


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (WORKFLOWS / 'ci.yml').read_text()
        cls.jobs = jobs('ci.yml')

    def test_nightly_schedule_and_preview_dispatch(self):
        self.assertRegex(self.text, r"\n  schedule:\n    - cron: '0 18 \* \* \*'\n")
        self.assertRegex(self.text, r'publish_preview:\n(?:        .*\n)*        type: boolean\n'
                                    r'        default: false\n')

    def test_changes_job_runs_contracts_then_selects(self):
        changes = self.jobs['changes']
        self.assertIn('runs-on: ubuntu-latest', changes)
        self.assertIn('fetch-depth: 0', changes)
        self.assertIn('actions: read', changes)
        self.assertIn('PUBLISH_PREVIEW: ${{ inputs.publish_preview }}', changes)
        self.assertLess(changes.index('python3 scripts/test-ci-policy.py'),
                        changes.index('python3 scripts/ci_changes.py select'))
        for output in ('mac', 'release', 'publish', 'channel'):
            self.assertIn(f'{output}: ${{{{ steps.select.outputs.{output} }}}}', changes)

    def test_path_outputs_gate_every_macos_job(self):
        macos = {name for name, block in self.jobs.items() if 'runs-on: macos' in block}
        self.assertEqual(macos, MAC_JOBS | {'preview'})
        for name in MAC_JOBS:
            block = self.jobs[name]
            output = 'release' if name in ('appstore', 'memory') else 'mac'
            with self.subTest(job=name):
                self.assertIn('changes', needs(block))
                self.assertTrue(field(block, 'if').startswith(f"needs.changes.outputs.{output} == 'true'"))
        # Release checks no longer run on pull requests or main pushes.
        for name in ('appstore', 'memory'):
            self.assertEqual(field(self.jobs[name], 'if'), "needs.changes.outputs.release == 'true'")

    def test_mac_regression_lints(self):
        self.assertIn('run: scripts/lint.sh', self.jobs['integration'])

    def test_mandatory_lint_checks_its_own_regression_rules(self):
        lint = (ROOT / 'scripts/lint.sh').read_text()
        self.assertIn('"$lint" lint --strict --config .swiftlint.yml --no-cache || status=1', lint)
        self.assertIn('python3 scripts/test-swiftlint-policy.py "$lint" || status=1', lint)
        self.assertIn('exit "$status"', lint)

    def test_ticket_retry_contracts_gate_preview_and_tagged_releases(self):
        contract = 'python3 scripts/test-staple-app.py'
        self.assertIn(contract, self.jobs['integration'])
        self.assertIn(contract, jobs('release.yml')['validate'])
        release = (ROOT / 'scripts/release.sh').read_text()
        ticket = 'python3 scripts/staple_app.py "$app"'
        self.assertLess(release.index('if result.get("status") != "Accepted"'), release.index(ticket))
        self.assertLess(release.index(ticket), release.index('codesign --verify --deep --strict'))
        self.assertLess(release.index(ticket), release.index('spctl --assess'))
        self.assertLess(release.index(ticket), release.index('archive="Prose-${version}'))

    def test_packaged_mcp_contract_gates_prs_and_preview_publication(self):
        integration, preview = self.jobs['integration'], self.jobs['preview']
        smoke = 'python3 scripts/smoke-app.py'
        for block in (integration, preview):
            self.assertIn(smoke, block)
            self.assertIn('--hurl .tools/hurl/bin/hurl', block)
            self.assertLess(block.index('scripts/prepare-mcp-hurl.sh'), block.index(smoke))
        self.assertLess(integration.index('scripts/build.sh release'), integration.index(smoke))
        self.assertLess(preview.index(smoke), preview.index('- name: Upload runnable app'))

    def test_gate_checks_every_job_and_treats_filtered_skips_as_success(self):
        gate = self.jobs['gate']
        self.assertEqual(field(gate, 'name'), 'build and test')
        self.assertEqual(field(gate, 'if'), 'always()')
        self.assertIn('runs-on: ubuntu-latest', gate)
        gated = set(self.jobs) - {'changes', 'gate', 'preview', 'publish-preview'}
        self.assertEqual(needs(gate), gated | {'changes'})
        self.assertEqual(set(ci.expected_results(True, True)), gated)
        self.assertIn('NEEDS: ${{ toJSON(needs) }}', gate)
        self.assertIn('run: python3 scripts/ci_changes.py gate', gate)
        self.assertEqual(ci.gate({'changes': {'result': 'success', 'outputs': {
            'mac': 'false', 'release': 'false', 'publish': 'false'}},
            **{job: {'result': 'skipped'} for job in gated}}), [])

    def test_newer_runs_cancel_older_ones_of_the_same_event_only(self):
        self.assertIn('\nconcurrency:\n  group: ci-${{ github.workflow }}-${{ github.ref }}-${{ github.event_name }}\n'
                      '  cancel-in-progress: true\n', self.text)

    def test_preview_publishes_each_channel_after_its_checks(self):
        preview, publish = self.jobs['preview'], self.jobs['publish-preview']
        # Neither job may inherit a dependency on the combined gate.
        self.assertEqual(needs(preview), {'changes', 'integration', 'appstore'})
        self.assertEqual(needs(publish), {'changes', 'preview'})
        # Override implicit success(): alpha intentionally skips App Store checks.
        self.assertEqual(field(publish, 'if'), "${{ !cancelled() && needs.preview.result == 'success' }}")
        self.assertIn('PROSE_PREVIEW_CHANNEL: ${{ needs.changes.outputs.channel }}', preview)
        self.assertIn('PREVIEW_CHANNEL: ${{ needs.changes.outputs.channel }}', publish)
        self.assertIn('channel: ${{ steps.select.outputs.channel }}', self.jobs['changes'])

    def test_preview_conditions_require_only_the_selected_mac_checks(self):
        for channel in ('alpha', 'nightly', 'unknown'):
            for integration in ('success', 'failure', 'cancelled', 'skipped'):
                for appstore in ('success', 'failure', 'cancelled', 'skipped'):
                    for publish in ('true', 'false'):
                        for cancelled in (False, True):
                            context = {'needs.changes.outputs.channel': channel,
                                       'needs.changes.outputs.publish': publish,
                                       'needs.integration.result': integration,
                                       'needs.appstore.result': appstore}
                            expected = (not cancelled and publish == 'true' and integration == 'success' and
                                        (channel == 'alpha' or (channel == 'nightly' and appstore == 'success')))
                            with self.subTest(context=context, cancelled=cancelled):
                                self.assertEqual(condition_passes(self.jobs['preview'], context, cancelled=cancelled),
                                                 expected)

    def test_publish_requires_a_successful_package_and_an_active_run(self):
        for preview in ('success', 'failure', 'cancelled', 'skipped'):
            for cancelled in (False, True):
                with self.subTest(preview=preview, cancelled=cancelled):
                    self.assertEqual(condition_passes(self.jobs['publish-preview'],
                                                     {'needs.preview.result': preview}, cancelled=cancelled),
                                     preview == 'success' and not cancelled)

if __name__ == '__main__':
    unittest.main()
