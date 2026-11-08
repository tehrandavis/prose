# Coverage and pull-request reports

`scripts/test.sh` enforces 80% coverage across unique executable lines in production Swift, including the native interface. Tests and generated test launchers are excluded. Functional tests use the real editor, WebKit and Tinymist; small boundary tests cover protocol framing and text ranges.

`scripts/coverage.py` writes HTML, raw LLVM output and `build/coverage/codecov.lcov`. LCOV uses repository-relative paths, deduplicates file/line records and covers the same production scope as the local gate. Codecov's additional report search, report generation and source-line adjustments are disabled to keep tests out of the report and preserve the denominator.

## iPad coverage

The simulator build instruments the native app and shared Core package. Hosted
unit tests and the writing UI suite run on both 11-inch and 13-inch iPads.
`scripts/ipad_coverage.py` merges LCOV exported from each native run's fresh
LLVM profile and instrumented application/framework images, counts each physical
executable line once, and enforces the same 80% floor. All `iPad/Sources` UI code
and the iOS implementation of `Sources/LeftBlankCore` count. Missing source records
fail the gate. LLVM also measures the shared package when a version of Xcode emits
an empty xccov package target; raw xccov reports remain available for diagnosis.
Profiles stay beside the build products.
`TinymistTransport.swift` contains only a protocol on iOS, so its absent
executable records are valid; executable code added there will count.

Dependencies, test targets, generated code and the uninstrumented Rust static
library do not contribute to the Swift percentage. The Rust engine has its own
real LSP, rendering, PDF and shutdown integration tests. CI retains raw xccov
reports, the normalized LCOV, source-line totals and the native result bundles;
`ipad-coverage` contains the coverage diagnostics.

## GitHub and Codecov

See [the testing strategy](testing-strategy.md) for current integration coverage, proposed XCUITest and screenshot layers, and release acceptance checks.

- PR and main CI upload coverage, including a generated report that fails the local threshold so failures can be investigated.
- Same-repository builds use GitHub OIDC, without a long-lived `CODECOV_TOKEN`. Public fork PRs use Codecov's supported tokenless upload.
- `codecov.yml` requires independent 80% project and patch checks for the `macos` and `ipad` flags and updates one PR comment with overall changes, changed-line coverage and file details. A platform's report cannot improve the other platform's gate, and stale reports are not carried forward.
- The README badge and [Codecov page](https://app.codecov.io/github/leftblank-app/leftblank) show main coverage. Raw data and HTML remain in the Actions `coverage-macos-15` artifact.

The Codecov GitHub App must be authorized for `leftblank-app/leftblank` after the repository transfer to read commits, update checks and comment on PRs. Installation and coverage upload are separate steps. Verification requires checking a real PR for both comments and statuses. A first PR without a main baseline may show onboarding information until a main upload establishes comparisons.

## Verification record

On 2026-10-01, before the LeftBlank rename, the app installation was limited to the original `fenjin-ai/sumi` repository. [The initial PR](https://github.com/leftblank-app/leftblank/pull/1) uploaded through GitHub OIDC without a Codecov token. Independent comparison of the platform report and downloaded LCOV matched: 21 production files, 2,107 of 2,442 unique executable lines, **86.28%**. This validates those two outputs from that run; later coverage is specific to its commit.

After main established a baseline, subsequent PRs displayed numeric comparisons and checks. See [PR #2's coverage comment](https://github.com/leftblank-app/leftblank/pull/2#issuecomment-5926250299).

References: [OIDC Action configuration](https://github.com/codecov/codecov-action#using-oidc), [public uploads](https://docs.codecov.com/docs/codecov-tokens), [status checks](https://docs.codecov.com/docs/commit-status), [PR comments](https://docs.codecov.com/docs/pull-request-comments).
