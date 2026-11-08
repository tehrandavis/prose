# Bundled Typst packages

These unmodified package archives are redistributed from the official Typst package registry to make the Prose welcome guide and existing Code notes documents work without a first-use download. Imports stay explicit and version-pinned in exported Typst source. Runtime files and upstream license notices are preserved.

| Package | Registry archive | SHA-256 |
| --- | --- | --- |
| codly 1.3.0 | https://packages.typst.org/preview/codly-1.3.0.tar.gz | `355a8afca97ec28b23110fe1fa1d33dcc98d99ef8b93fc1a29e2ec2c78a6f6cb` |
| codly-languages 0.1.1 | https://packages.typst.org/preview/codly-languages-0.1.1.tar.gz | `8e7f59a10b0d55ee7bcdf85e73ebb2da242e7cf93915fcf88f35b0c2f93d16bf` |
| cetz 0.5.2 | https://packages.typst.org/preview/cetz-0.5.2.tar.gz | `77cf8490114ae04c6e665a11efa691d284a0cadb9719771b5708c1197292f23f` |
| oxifmt 1.0.0 (CeTZ dependency) | https://packages.typst.org/preview/oxifmt-1.0.0.tar.gz | `7d17a1fc8ad01740ec3cb2b03c7360a4225ff9318e5710765fa98ea6fd59594f` |

Codly and codly-languages use MIT; CeTZ uses LGPL-3.0-or-later; oxifmt offers MIT OR Apache-2.0. See each package's LICENSE file. Package data is copied atomically into Prose's private package cache on service startup. Existing documents do not acquire hidden imports, and upgrading Prose does not silently change an existing document's package version.

CeTZ is distributed as unmodified `.typ` files and its upstream `cetz_core.wasm` helper, not linked into the application executable. The registry files and license are included. The matching helper's Rust source, Cargo manifest/lockfile, license and upstream build recipe are also included in `Sources/cetz-0.5.2`, from [the v0.5.2 source tree](https://github.com/cetz-package/cetz/tree/v0.5.2/cetz-core). The complete upstream release source is available at https://github.com/cetz-package/cetz/archive/refs/tags/v0.5.2.tar.gz. These sources ship in the app's `Contents/Resources/Packages` directory as well as this repository.

To rebuild the WASM helper with Rust, install the `wasm32-unknown-unknown` target, then run `cargo build --release --locked --target wasm32-unknown-unknown` from `Sources/cetz-0.5.2/cetz-core`. The output is `target/wasm32-unknown-unknown/release/cetz_core.wasm`. Replace `preview/cetz/0.5.2/cetz-core/cetz_core.wasm` in the package cache to use it. No Prose signing key is needed to replace a cached package. Source projects retain explicit imports; users can change or remove them. Original registry archives can be retrieved from the URLs above. Prose's original example prose, drawing and Python listing are not copied from upstream examples.
