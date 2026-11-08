#!/bin/bash
# Source from development scripts. Local build artifacts stay inside the
# checkout under .tools/ (ignored by git); hosted CI uses the runner's
# disposable temporary directory.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  : "${RUNNER_TEMP:?GitHub Actions must provide RUNNER_TEMP}"
  export TMPDIR="$RUNNER_TEMP/prose" TMP="$RUNNER_TEMP/prose" TEMP="$RUNNER_TEMP/prose"
else
  environment_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  export TMPDIR="$environment_root/.tools/tmp" TMP="$environment_root/.tools/tmp" TEMP="$environment_root/.tools/tmp"
  unset environment_root
fi
mkdir -p "$TMPDIR"
