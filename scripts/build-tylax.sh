#!/bin/bash
# Build the Tylax converter (t2l) used by File > Export LaTeX… from the pinned
# crates.io release. Every Mac distribution bundles this one binary.
#
# Usage: scripts/build-tylax.sh [--stamp|--check]
#   (none)   build .tools/t2l unless its stamp matches the current inputs
#   --stamp  print the expected stamp without building
#   --check  fail unless .tools/t2l was built from the current inputs
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.3.8
toolchain=1.92.0
# macOS 27 rejects misaligned proc-macro dylibs produced when debug info is
# stripped, and Tylax's release profile strips; see build-tinymist.sh.
build_env=(MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=1
  CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none)
install_args=(install tylax --version "$version" --locked --bin t2l)
binary=.tools/t2l
stamp_file=.tools/t2l.stamp
root="$PWD/.tools/tylax"
cargo_home="$PWD/.tools/cargo-tylax"

stamp() {
  printf 'tylax %s\nrust %s\nbuild %s cargo %s\n' "$version" "$toolchain" \
    "${build_env[*]}" "${install_args[*]}"
}

current() {
  [ -x "$binary" ] && [ "$(cat "$stamp_file" 2>/dev/null)" = "$(stamp)" ] &&
    "$binary" --version | grep "$version" >/dev/null
}

case "${1:-}" in
  --stamp) stamp; exit 0 ;;
  --check)
    current || { echo "$binary was not built from the pinned Tylax $version; run scripts/build-tylax.sh" >&2; exit 1; }
    exit 0 ;;
  '') ;;
  *) echo 'Usage: scripts/build-tylax.sh [--stamp|--check]' >&2; exit 2 ;;
esac

source scripts/environment.sh
# Dependency notices for the bundle (Resources/TylaxConverter-LICENSES.txt).
licenses() {
  CARGO_HOME="$cargo_home" python3 scripts/rust-licenses.py tylax
}
if current; then
  [ -f .tools/TYLAX-LICENSES.txt ] || licenses
  "$binary" --version
  exit 0
fi
mkdir -p .tools
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  rustup toolchain install "$toolchain" --profile minimal
fi
env CARGO_HOME="$cargo_home" "${build_env[@]}" \
  cargo "+$toolchain" "${install_args[@]}" --root "$root" --force
rm -f "$stamp_file"
# Replace rather than overwrite, so a running helper keeps its signed pages.
cp "$root/bin/t2l" "$binary.new"
chmod +x "$binary.new"
mv -f "$binary.new" "$binary"
stamp > "$stamp_file"
licenses
"$binary" --version
