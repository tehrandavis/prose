#!/bin/bash
# Build the typst-syntax bridge on its own, as a macOS static library. The Mac
# app no longer links this one: it links the render bridge, which carries the
# same crate (scripts/build-render.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
export CARGO_HOME="$PWD/.tools/cargo-syntax"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  rustup toolchain install 1.92.0 --profile minimal --component rustfmt --component clippy
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
target=aarch64-apple-darwin
cargo +1.92.0 build --locked --release --lib --manifest-path Engine/SyntaxBridge/Cargo.toml --target "$target"
library="Engine/SyntaxBridge/target/$target/release/libprose_syntax.a"
framework=Engine/SyntaxBridge/target/ProseSyntax.xcframework
# Recreate only after the library changes, so SwiftPM does not relink needlessly.
if [ ! -f "$framework/Info.plist" ] || [ "$library" -nt "$framework/Info.plist" ]; then
  rm -rf "$framework"
  xcodebuild -create-xcframework -library "$library" -output "$framework" >/dev/null
fi
python3 scripts/rust-licenses.py syntax
