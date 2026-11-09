//! Per-block Typst rendering for Prose's Writing mode (spec Section 5.2).
//!
//! Swift asks for any top-level block of the open document and gets back a
//! typeset fragment: SVG, its size, its first baseline, its ink bounds, the
//! drawn area (the page and any hanging punctuation), a box for each glyph
//! with the UTF-16 offset in the file it came from, and on request a bitmap
//! of the drawn area. The page is transparent.
//!
//! How a block renders alone, as the Phase 2 spike established
//! (`docs/plans/2026-11-08-phase-2-engine-spike.md`):
//!
//! - `refresh` compiles the whole document with a probe appended to the main
//!   file. The probe records every heading's and equation's counter value,
//!   and each reference's displayed text is read from the link rectangles of
//!   the full layout. A failed compile keeps the previous context.
//! - `render` builds a block document: the
//!   context lines (`#set`, `#show`, `#let`, `#import`), a transparent page
//!   as wide as the measure, counter updates, a `metadata` stub and a `show ref.where(target:)` rule for each outside
//!   label, an invisible `#metadata(none)` anchor, then the block's text.
//!   Results are cached by a hash of that document, the width and the
//!   appearance. In dark appearance every paint of the laid-out page (not
//!   images) is mapped onto the dark page before the SVG and the bitmap are
//!   made (`dark_color`).
//!
//! The Rust API is `Engine`. The C API is `ffi::prose_render_api`, declared in
//! `Sources/ProseRenderFFI/include/ProseRender.h`. This library also carries
//! the syntax bridge, so the static library exports `lb_syntax_api` too and
//! the app links one Rust library.

#![deny(unsafe_op_in_unsafe_fn)]

mod bibliography;
mod cache;
mod context;
mod dark;
mod engine;
pub mod ffi;
mod geometry;
mod outline;
mod raster;
mod world;

pub use bibliography::{BibAuthor, BibEntry, BibError, BibFile, BibIndex};
pub use cache::{CacheStats, DEFAULT_BUDGET};
pub use context::PROBE;
pub use dark::{dark_color, DARK_PAGE, DARK_TEXT};
pub use engine::{
    BlockRange, Engine, Options, RefreshInfo, Render, RenderOptions, Rendered, MAX_BITMAP_SCALE,
};
pub use geometry::{GlyphBox, Rect};
pub use outline::{split, Block, BlockKind, Outline};
pub use raster::{Bitmap, MAX_BITMAP_PIXELS};

/// The syntax bridge's C function table, linked into this library. Two Rust
/// static libraries in one binary duplicate the standard library's symbols,
/// so the Mac app links this one, which exports both tables.
pub use prose_syntax::lb_syntax_api;
