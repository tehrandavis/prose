#!/usr/bin/env python3
"""Select CI jobs from changed paths, and check the selected jobs' results.

`select` runs in the small ubuntu `changes` job of .github/workflows/ci.yml and
writes the `mac`, `release`, `publish` and `channel` outputs that every macOS
job's `if:` consumes. `release` adds the Mac App Store and memory checks; it
runs only from main's nightly schedule or a manual main dispatch. `publish`
signs Prose Preview: the nightly channel from those runs, the opt-in alpha
channel from each Mac-affecting main push.
`gate` runs in the required `build and test` job and fails unless each job
either passed (selected) or was skipped (not selected).

Any doubt runs more, never less: unknown paths select the Mac jobs, and a
missing base commit, API error or unexpected event selects every job.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = 'ci.yml'

# A prefix ending in '/' matches a directory; anything else must match the
# whole path. Documentation selects no macOS job; every other path selects the
# Mac jobs. MAC lists those paths for readers and for the check that every
# tracked script is classified deliberately; unlisted paths behave the same way.
DOCS = (
    'docs/', 'releases/', 'README.md', 'BRAND_POLICY.md', 'LICENSE', 'codecov.yml', 'Brand/README.md',
)
MAC = (
    'Sources/', 'Tests/', 'Tools/MCPServer/', 'Engine/RenderBridge/', 'Engine/SyntaxBridge/',
    'Package.swift', 'Package.resolved', 'Resources/', 'Examples/', 'Brand/',
    # Only scripts/lint.sh reads these; Mac regression runs it.
    'Benchmarks/', '.swiftlint.yml', '.swiftformat',
    'scripts/appstore_connect.py', 'scripts/benchmark-books.sh', 'scripts/bootstrap.sh', 'scripts/build.sh',
    'scripts/build-mcp.sh', 'scripts/build-render.sh', 'scripts/build-syntax.sh', 'scripts/build-tinymist.sh',
    'scripts/check-memory.sh', 'scripts/ci_changes.py', 'scripts/coverage.py', 'scripts/environment.sh',
    'scripts/export-appstore.py', 'scripts/lint.sh', 'scripts/make-app-icon.py', 'scripts/package-app.py',
    'scripts/package-sicp.py', 'scripts/prepare-icloud-profile.py', 'scripts/prepare-large-document.py',
    'scripts/prepare-mcp-hurl.sh', 'scripts/prepare-sicp.py', 'scripts/preview-feed.py', 'scripts/preview_channels.py',
    'scripts/publish-preview.py', 'scripts/release.sh', 'scripts/release-appstore.sh', 'scripts/release_metadata.py',
    'scripts/running_app.py', 'scripts/rust-licenses.py', 'scripts/sign-app.sh', 'scripts/smoke-app.py',
    'scripts/sparkle-tools.sh', 'scripts/staple_app.py', 'scripts/test-appstore-release.py',
    'scripts/test-ci-policy.py', 'scripts/test-icloud-profile.py', 'scripts/test-package-graphs.py',
    'scripts/test-preview-release.py', 'scripts/test-running-app.py', 'scripts/test-staple-app.py',
    'scripts/test-swiftlint-policy.py', 'scripts/test-tinymist-build.py', 'scripts/test.sh',
    'scripts/tinymist-native-tls.patch', 'scripts/tinymist-vfs.patch', 'scripts/update-universe-snapshot.py',
    'scripts/verify-update.swift',
    '.github/',
)


def matches(path, prefixes):
    return any(path.startswith(prefix) if prefix.endswith('/') else path == prefix for prefix in prefixes)


def classify(path):
    """Return the platforms a changed path needs validated: {'mac'}, or none for docs."""
    return set() if matches(path, DOCS) else {'mac'}


def select(paths):
    return {'mac': any(classify(path) for path in paths)}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def is_ancestor(base, head):
    return subprocess.run(['git', 'merge-base', '--is-ancestor', base, head], cwd=ROOT).returncode == 0


def changed_paths(base, head):
    return [line for line in git('diff', '--name-only', '--no-renames', base, head).splitlines() if line]


def successful_runs(repository, event):
    """Head SHAs of this workflow's successful main runs for an event, newest first."""
    output = subprocess.check_output(
        ['gh', 'api', '-X', 'GET', f'repos/{repository}/actions/workflows/{WORKFLOW}/runs',
         '-f', 'branch=main', '-f', f'event={event}', '-f', 'status=success', '-f', 'per_page=30',
         '--jq', '.workflow_runs[].head_sha'], text=True)
    return [line for line in output.splitlines() if line]


def plan(event, head, repository, runs=successful_runs, pr_base=None, publish_preview=False):
    """Decide whether the Mac jobs run; returns (selection dict, human-readable reason)."""
    everything = {'mac': True}
    if event == 'workflow_dispatch':
        if publish_preview:
            return everything, 'preview dispatch runs the Mac checks and publishes'
        return everything, 'manual dispatch runs every job'
    if event == 'schedule':
        try:
            last = next(iter(runs(repository, 'schedule')), None)
        except (OSError, subprocess.CalledProcessError) as error:
            return everything, f'could not read previous nightly runs ({error}); running everything'
        # Only a fully successful nightly (tests and Preview publication) of
        # this exact commit is skipped; a failed one is retried.
        if last == head:
            return {'mac': False}, f'main is unchanged since the last successful nightly ({head})'
        return everything, 'nightly runs every job'
    if event == 'pull_request':
        try:
            parents = git('rev-list', '--parents', '-n', '1', head).split()[1:]
            # The default checkout is GitHub's test merge commit; its first
            # parent is the base branch, so the diff is exactly this PR.
            base = parents[0] if len(parents) == 2 else git('merge-base', pr_base, head)
        except (subprocess.CalledProcessError, TypeError) as error:
            return everything, f'could not find the pull request base ({error}); running everything'
    elif event == 'push':
        try:
            candidates = [sha for sha in runs(repository, 'push') if sha != head]
        except (OSError, subprocess.CalledProcessError) as error:
            return everything, f'could not read previous main runs ({error}); running everything'
        # Diffing against the last successful main run, not the previous
        # commit, keeps changes from cancelled or failed runs selected.
        base = next((sha for sha in candidates if is_ancestor(sha, head)), None)
        if base is None:
            return everything, 'no successful earlier main run is an ancestor; running everything'
    else:
        return everything, f'unexpected event {event}; running everything'
    try:
        paths = changed_paths(base, head)
    except subprocess.CalledProcessError as error:
        return everything, f'could not diff {base}..{head} ({error}); running everything'
    selection = select(paths)
    listed = '\n'.join(f'- `{path}`: {"+".join(sorted(classify(path))) or "docs"}' for path in paths[:200])
    return selection, f'{len(paths)} changed path(s) since {base}:\n{listed}'


def outputs(selection, event, ref, publish_preview=False):
    """The job outputs: Mac selection plus the main-only release and publish steps."""
    main = selection['mac'] and ref == 'refs/heads/main'
    release = main and event in ('schedule', 'workflow_dispatch')
    alpha = main and event == 'push'
    publish = alpha or (release and (event == 'schedule' or publish_preview))
    return {'mac': selection['mac'], 'release': release, 'publish': publish,
            'channel': 'alpha' if alpha else 'nightly'}


def expected_results(mac, release):
    """The result each gated job must report for this selection. Preview
    publication is deliberately not gated: it reports its own failure."""
    def need(selected):
        return 'success' if selected else 'skipped'
    return {
        'integration': need(mac),
        'appstore': need(release),
        'memory': need(release),
    }


def gate(needs):
    """Return a list of problems with the `needs` context of the gate job."""
    changes = needs.get('changes', {})
    if changes.get('result') != 'success':
        return [f"changes is {changes.get('result')}, expected success"]
    values = changes.get('outputs', {})
    flags = [values.get(name) for name in ('mac', 'release')]
    if any(flag not in ('true', 'false') for flag in flags):
        return [f'changes produced invalid outputs {values}']
    mac, release = (flag == 'true' for flag in flags)
    if release and not mac:
        return [f'changes selected release checks without Mac jobs: {values}']
    expected = expected_results(mac, release)
    problems = []
    for job, result in expected.items():
        actual = needs.get(job, {}).get('result')
        if actual != result:
            problems.append(f'{job} is {actual}, expected {result}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('select', help='write the job selection to $GITHUB_OUTPUT')
    commands.add_parser('gate', help='check the gate job needs context (JSON in $NEEDS)')
    commands.add_parser('classify', help='print mac or docs for each path on stdin')
    args = parser.parse_args()

    if args.command == 'classify':
        for path in sys.stdin.read().split():
            print(path, '+'.join(sorted(classify(path))) or 'docs')
        return 0
    if args.command == 'gate':
        problems = gate(json.loads(os.environ['NEEDS']))
        for problem in problems:
            print('::error::' + problem)
        if not problems:
            print('Every selected job passed; every other job was skipped.')
        return 1 if problems else 0

    event = os.environ['GITHUB_EVENT_NAME']
    publish_preview = event == 'workflow_dispatch' and os.environ.get('PUBLISH_PREVIEW') == 'true'
    selection, reason = plan(event, os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'],
                             pr_base=os.environ.get('PR_BASE_SHA'), publish_preview=publish_preview)
    result = outputs(selection, event, os.environ['GITHUB_REF'], publish_preview)
    lines = [f'{name}={str(value).lower() if isinstance(value, bool) else value}' for name, value in result.items()]
    print('\n'.join(lines))
    print(reason)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('\n'.join(lines) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write('### Selected jobs\n\n' + ', '.join(f'{name}: **{value}**' for name, value in result.items())
                         + f'\n\n{reason}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
