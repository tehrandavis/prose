#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/environment.sh
# Cargo keeps dependency sources and build outputs inside the checkout.
export CARGO_HOME="$PWD/.tools/cargo-ipad"
scripts/prepare-ipad-engine.sh
rustup toolchain install 1.92.0 --profile minimal
manifest=Engine/TinymistBridge/Cargo.toml
cargo +1.92.0 build --locked --manifest-path "$manifest" --example engine-probe --release
python3 scripts/test-ipad-engine.py Engine/TinymistBridge/target/release/examples/engine-probe --scratch "$TMPDIR"
