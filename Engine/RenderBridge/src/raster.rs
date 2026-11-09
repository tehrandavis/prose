//! The drawn area of a block and its bitmap.
//!
//! Typst lets punctuation at a line's end hang past the measure (and opening
//! punctuation past its start), so a block's ink can lie outside its page.
//! The drawn area is the union of the page and the ink. The SVG and the
//! bitmap cover the drawn area, and its origin is reported relative to the
//! block's top-left corner, so glyph boxes, the baseline and the ink keep the
//! page's coordinates.

use typst::layout::{Abs, Frame, FrameItem, Point, Size};
use typst::utils::Scalar;
use typst_layout::Page;

use crate::geometry::Rect;

/// The most pixels a bitmap may have: 32 Mi pixels, 128 MB. A larger block
/// (SICP's 10,500-line index table at scale 2.6 would be over 500 MB) gets
/// no bitmap; the vector result is still returned.
pub const MAX_BITMAP_PIXELS: u64 = 1 << 25;

/// Ink closer than this to the page's edge does not widen the drawn area, so
/// rounding in the ink bounds does not make a page that is not needed.
const TOLERANCE: f64 = 0.01;

/// A block rasterized at a scale: premultiplied RGBA, 8 bits per channel,
/// rows from the top. Pixel (0, 0) is the drawn area's top-left corner. The
/// width and height are the drawn area's times the scale, rounded up; the
/// part of the last column and row past the drawn area is transparent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bitmap {
    pub width: u32,
    pub height: u32,
    pub row_bytes: usize,
    pub data: Vec<u8>,
}

/// The drawn area, relative to the block's top-left corner, and a page that
/// covers it with the block's page frame placed at the right offset. Returns
/// the page itself when the ink stays inside it.
pub(crate) fn drawn_page(page: &Page, ink: Rect) -> (Page, Rect) {
    let width = page.frame.width().to_pt();
    let height = page.frame.height().to_pt();
    let has_ink = ink.width > 0.0 || ink.height > 0.0;
    let extend = |inside: f64, ink: f64, grow: bool| {
        let beyond = if grow { ink - inside } else { inside - ink };
        if has_ink && beyond > TOLERANCE {
            ink
        } else {
            inside
        }
    };
    let x0 = extend(0.0, ink.x, false);
    let y0 = extend(0.0, ink.y, false);
    let x1 = extend(width, ink.x + ink.width, true);
    let y1 = extend(height, ink.y + ink.height, true);
    let drawn = Rect {
        x: x0,
        y: y0,
        width: x1 - x0,
        height: y1 - y0,
    };
    if x0 == 0.0 && y0 == 0.0 && x1 == width && y1 == height {
        return (page.clone(), drawn);
    }
    let mut frame = Frame::hard(Size::new(Abs::pt(drawn.width), Abs::pt(drawn.height)));
    frame.push_frame(Point::new(Abs::pt(-x0), Abs::pt(-y0)), page.frame.clone());
    (
        Page {
            frame,
            ..page.clone()
        },
        drawn,
    )
}

/// The size in pixels of a drawn area at `scale`, or None if it is empty or
/// larger than `MAX_BITMAP_PIXELS`.
pub(crate) fn pixel_size(drawn: Rect, scale: f64) -> Option<(u32, u32)> {
    let width = (drawn.width * scale).ceil().max(1.0);
    let height = (drawn.height * scale).ceil().max(1.0);
    if !(width.is_finite() && height.is_finite()) || width * height > MAX_BITMAP_PIXELS as f64 {
        return None;
    }
    Some((width as u32, height as u32))
}

/// Rasterizes a drawn page (from `drawn_page`) at `scale` pixels per point.
pub(crate) fn rasterize(page: &Page, drawn: Rect, scale: f64) -> Option<Bitmap> {
    let (width, height) = pixel_size(drawn, scale)?;
    // Pad the page to whole pixels, so typst-render's rounding gives exactly
    // the size above.
    let mut page = page.clone();
    page.frame.set_size(Size::new(
        Abs::pt(width as f64 / scale),
        Abs::pt(height as f64 / scale),
    ));
    let pixmap = typst_render::render(
        &page,
        &typst_render::RenderOptions {
            pixel_per_pt: Scalar::new(scale),
            render_bleed: false,
        },
    );
    let (width, height) = (pixmap.width(), pixmap.height());
    Some(Bitmap {
        width,
        height,
        row_bytes: width as usize * 4,
        data: pixmap.take(),
    })
}

/// Approximate memory a frame holds, for the cache budget. Counts items and
/// glyphs; fonts and images are shared with Typst and not counted.
pub(crate) fn frame_bytes(frame: &Frame) -> usize {
    frame
        .items()
        .map(|(_, item)| {
            std::mem::size_of::<(Point, FrameItem)>()
                + match item {
                    FrameItem::Group(group) => frame_bytes(&group.frame),
                    FrameItem::Text(text) => {
                        text.glyphs.len() * std::mem::size_of::<typst::text::Glyph>()
                            + text.text.len()
                    }
                    FrameItem::Shape(shape, _) => match &shape.geometry {
                        typst::visualize::Geometry::Curve(curve) => {
                            curve.0.len() * std::mem::size_of::<typst::visualize::CurveItem>()
                        }
                        _ => 0,
                    },
                    _ => 0,
                }
        })
        .sum()
}
