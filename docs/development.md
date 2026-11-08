# Developing Prose

Prose uses SwiftUI and AppKit for the app and editing experience, with Tinymist as a managed child process for Typst language services and preview. Documents use ordinary `.typ` source and relative assets. The visual approach was inspired by Nano Emacs.

Use Xcode 26 or later with a Swift 6.2 or later toolchain and the macOS SDK. The Tinymist and macOS MCP helpers, and the engine library linked into ProseCore, are built with Rust 1.92.0 (`rustup toolchain install 1.92.0 --profile minimal`). The engine library is the render bridge (`Engine/RenderBridge`), which typesets single blocks for Writing mode and carries the typst-syntax parser bridge inside it, so the app links one Rust static library that exports both `prose_render_api` and `lb_syntax_api`. `scripts/build.sh` and `scripts/test.sh` build it through `scripts/bootstrap.sh`; run `scripts/build-render.sh` once before a plain `swift build` or `swift test`. Run from any checkout; `scripts/environment.sh` keeps temporary files, Cargo caches and fixtures under the checkout's `.tools/` directory, which git ignores:

```sh
scripts/build.sh release
scripts/test.sh
```

Run the tests as CI does, with `PROSE_DISTRIBUTION=preview scripts/test.sh`. The coverage gate counts `Sources/Prose/PreviewUpdateChannel.swift`, which compiles only in the Preview distribution, so a plain `scripts/test.sh` passes every test but stops at the coverage report.

The build compiles Tinymist **0.15.8** (Typst 0.15.1) from its pinned commit with `scripts/tinymist-native-tls.patch` and `scripts/tinymist-vfs.patch` (`scripts/build-tinymist.sh`), and produces `build/Prose.app` with an ad hoc development signature. The first build takes about 15 minutes; `.tools/tinymist.stamp` records the revision, toolchain and patch hashes, so later builds reuse the binary until a patch changes. CI caches the binary under the same inputs, and `scripts/test-tinymist-build.py` checks that the binary in use matches them. Functional tests exercise the real native editor, workspace, windows, WebKit preview and Tinymist process: discovery, insertion, undo/redo, Unicode, recovery, multiple files, compilation errors and PDF output. Small boundary tests cover text ranges and index validation.

`scripts/test.sh` writes HTML, raw coverage data and `build/coverage/summary.md`. It requires **80% coverage of unique executable lines across production Swift sources**, including the interface. LCOV records are deduplicated by source file and line to avoid counting SwiftUI generic instantiations repeatedly. Plain `swift test` omits explicitly enabled integration scenarios and does not enforce coverage.

GitHub Actions uses `macos-15` with Xcode 26.3 for both pull requests and signed releases. The `build and test` check must pass on an up-to-date pull request before merging. It checks functional coverage (at least 80%), runs book benchmarks, and uploads reports. Each night, after Mac validation passes on main, CI builds, signs, notarizes and uploads Prose Preview for testing, then publishes its signed automatic-update feed; a manual run can publish between nightlies. Preview uses a separate local library and can coexist with Prose. Swift package sources are cached; application binaries are rebuilt. [Codecov](https://app.codecov.io/github/tehrandavis/prose) reports project and patch coverage, including PR comments. A version tag matching `Info.plist` triggers testing and a release ZIP with SHA-256. Public releases require Developer ID signing, successful Apple notarization, ticket stapling and Gatekeeper validation. See [release signing](signing.md) and [Preview updates](preview-updates.md). Local builds remain development-signed.

The source is split into the launcher, testable native app and core document logic. Bundled third-party licenses are listed in `Resources/ThirdParty.txt`.

Prose is Mac only. The iPad target inherited from LeftBlank (its Xcode project, embedded Tinymist engine and iPad CI jobs) was removed on 2026-11-08.

### CI capacity policy

macOS runners are scarce, so `build and test` (`.github/workflows/ci.yml`) runs only what each change needs:

- **Path selection.** A small ubuntu `Select jobs` job runs `scripts/ci_changes.py`, which classifies every changed path as Mac or documentation. Documentation-only changes (`docs/`, `releases/`, `README.md`, `BRAND_POLICY.md`, `LICENSE`, `codecov.yml`, `Brand/README.md`) run no macOS job; any other path, listed or not, selects the Mac jobs. Pull requests diff against their base; main pushes diff against the last successful main run, so changes from a cancelled or failed run stay selected. List new scripts in the `MAC` tuple of `scripts/ci_changes.py`; `scripts/test-ci-policy.py` fails until you do.
- **Pull requests and main pushes** run exactly the same path-selected check: Mac regression. Main pushes do not run Mac App Store validation or Mac memory safety. A main push that selected the Mac jobs then signs and publishes the opt-in **alpha** Preview channel once Mac regression passes (about 5 macOS minutes). Publication does not wait for the combined gate. A newer push cancels publication with the run.
- **Nightly** at 18:00 UTC, the schedule runs every job on main: Mac regression, Mac App Store validation and Mac memory safety. It then signs and publishes Prose Preview once Mac regression and App Store validation pass. The nightly skips only when the same commit already had a fully successful nightly, so a failed nightly (tests or publication) runs again the next night even if main has not changed.
- **Manual runs.** Run **build and test** (`workflow_dispatch`) to check a commit sooner. It runs every job, adding App Store and memory checks on main. To upgrade Preview between nightlies, run it on main with `publish_preview` checked (`gh workflow run ci.yml --ref main -f publish_preview=true`). That runs the Mac checks, then signs and publishes.
- **Cancellation.** A newer run cancels the in-progress run with the same ref and event: a pull request's newer push, a newer main push, or a newer manual run. Main pushes never cancel the nightly or a manual run. A cancelled publication is harmless; at worst it leaves a build release without a feed update, which the next publication supersedes.
- **Gate.** `build and test` is the only required check. It fails unless every selected job passed and every other job was skipped, so a filtered skip passes but a failed, cancelled or wrongly skipped job does not. `scripts/test-ci-policy.py` checks this policy, the path table and the workflow structure in the `Select jobs` job.

## Scope and verification

Prose remains a development preview. It has one active editing buffer, with the main compilation entry preserved when navigating into included files. It does not provide collaborative accounts, Vim emulation, arbitrary visual editing of typeset pages. The editor styles source with attributes only (headings, strong, emphasis, raw and syntax colours); source-level visual editing (concealed markup, chips, inline images and equations) was removed on 2026-10-09, see [visual editing](visual-editing.md).

Unicode editing, marked-text protection, undo and saving have automated coverage. Complete third-party input-method and VoiceOver flows, and a physical Mac running macOS 14, still need manual verification. Real 1.4 MB SICP and 3.3 MB War and Peace fixtures exercise highlighting, typing, pointer placement and scrolling in [book benchmarks](large-document-performance.md). [Template and package discovery](discovery.md) includes a downloadable, editable SICP example; [the complete books and conversion scripts](../Examples/Books/README.md) are checked in with their own attribution and licenses. Verification evidence and remaining limitations live in [the progress record](progress.md).

## Design and engineering notes

- [MCP integration design and implementation status](mcp-design.md)
- [Product requirements](requirements.md)
- [Architecture](architecture.md)
- [Implementation and verification](progress.md)
- [Writing features](editor-evolution.md)
- [Editor styles, parser bridge and the removed visual layer (LB-019)](visual-editing.md)
- [Interaction and performance](interaction.md)
- [Brand assets and favicons](../Brand/README.md)
- [Localization](localization.md)
- [Library and synchronization](library-and-sync.md)
- [Code notes](code-notes.md)
- [Merge evaluation](merge-evaluation.md)
