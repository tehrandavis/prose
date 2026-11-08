#!/bin/bash
# Build the Rust engine library that ProseCore links on macOS: the per-block
# renderer (Engine/RenderBridge) with the typst-syntax bridge inside it, so the
# app links one Rust library and one Rust runtime. SwiftPM consumes it as a
# binary target, so run this (or scripts/bootstrap.sh) before the first
# `swift build`. scripts/build-syntax.sh still builds the syntax crate alone.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
export CARGO_HOME="$PWD/.tools/cargo-render"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  rustup toolchain install 1.92.0 --profile minimal --component rustfmt --component clippy
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
target=aarch64-apple-darwin
cargo +1.92.0 build --locked --release --lib --manifest-path Engine/RenderBridge/Cargo.toml --target "$target"
library="Engine/RenderBridge/target/$target/release/libprose_render.a"
framework=Engine/RenderBridge/target/ProseEngine.xcframework
# Recreate only after the library changes, so SwiftPM does not relink needlessly.
if [ ! -f "$framework/Info.plist" ] || [ "$library" -nt "$framework/Info.plist" ]; then
  rm -rf "$framework"
  xcodebuild -create-xcframework -library "$library" -output "$framework" >/dev/null
fi
python3 scripts/rust-licenses.py render
