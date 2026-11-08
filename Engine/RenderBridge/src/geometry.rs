//! Geometry of a rendered block: glyph boxes, ink bounds and first baseline.

use std::collections::HashMap;

use typst::layout::{Abs, Frame, FrameItem, Point, Transform};
use typst::syntax::Span;
use typst::text::FontInstance;

/// A glyph's outline box in font units: x min, y min, x max, y max.
type GlyphOutline = Option<(i16, i16, i16, i16)>;

/// Glyph outline boxes in font units, by font and glyph id. Reading one from
/// a CFF font interprets the glyph's outline, so the engine keeps them.
#[derive(Default)]
pub(crate) struct GlyphBounds {
    fonts: HashMap<FontInstance, HashMap<u16, GlyphOutline>>,
}

impl GlyphBounds {
    fn of(&mut self, font: &FontInstance) -> &mut HashMap<u16, GlyphOutline> {
        if !self.fonts.contains_key(font) {
            self.fonts.insert(font.clone(), HashMap::new());
        }
        self.fonts.get_mut(font).expect("font present")
    }
}

/// One glyph of a rendered block, in points relative to the block's top-left
/// corner, with its UTF-16 offset in the original file or -1 for generated
/// text (numbers, reference text, text from other files). The same layout as
/// `PRGlyphBox` in `ProseRender.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GlyphBox {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub source: i32,
}

/// A rectangle in points. The same layout as `PRRect`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A glyph before its span is mapped to the source.
pub(crate) struct RawGlyph {
    pub(crate) rect: (f64, f64, f64, f64),
    pub(crate) span: Span,
    pub(crate) offset: u16,
}

/// Accumulates the bounding box of everything drawn.
#[derive(Default)]
struct Ink {
    min: Option<(f64, f64)>,
    max: (f64, f64),
}

impl Ink {
    fn add(&mut self, x: f64, y: f64) {
        match &mut self.min {
            None => {
                self.min = Some((x, y));
                self.max = (x, y);
            }
            Some(min) => {
                min.0 = min.0.min(x);
                min.1 = min.1.min(y);
                self.max.0 = self.max.0.max(x);
                self.max.1 = self.max.1.max(y);
            }
        }
    }

    /// Adds a local rectangle's four corners, transformed.
    fn add_rect(&mut self, ts: Transform, x0: Abs, y0: Abs, x1: Abs, y1: Abs) {
        for (x, y) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] {
            let p = Point::new(x, y).transform(ts);
            self.add(p.x.to_pt(), p.y.to_pt());
        }
    }

    fn rect(&self) -> Rect {
        match self.min {
            None => Rect::default(),
            Some((x, y)) => Rect {
                x,
                y,
                width: self.max.0 - x,
                height: self.max.1 - y,
            },
        }
    }
}

/// Everything read from a block's page frame in one walk.
pub(crate) struct Walked {
    pub(crate) glyphs: Vec<RawGlyph>,
    pub(crate) text: String,
    pub(crate) ink: Rect,
    pub(crate) first_text_baseline: Option<f64>,
}

pub(crate) fn walk(frame: &Frame, bounds: &mut GlyphBounds) -> Walked {
    let mut walked = Walked {
        glyphs: Vec::new(),
        text: String::new(),
        ink: Rect::default(),
        first_text_baseline: None,
    };
    let mut ink = Ink::default();
    visit(frame, Transform::identity(), &mut walked, &mut ink, bounds);
    walked.ink = ink.rect();
    walked
}

fn visit(frame: &Frame, ts: Transform, out: &mut Walked, ink: &mut Ink, bounds: &mut GlyphBounds) {
    for (pos, item) in frame.items() {
        match item {
            FrameItem::Group(group) => {
                let ts = ts
                    .pre_concat(Transform::translate(pos.x, pos.y))
                    .pre_concat(group.transform);
                visit(&group.frame, ts, out, ink, bounds);
            }
            FrameItem::Text(item) => {
                out.text.push_str(&item.text);
                out.text.push(' ');
                if out.first_text_baseline.is_none() {
                    out.first_text_baseline = Some(pos.transform(ts).y.to_pt());
                }
                let size = item.size;
                let metrics = item.font.metrics();
                let ascender = metrics.ascender.at(size);
                let descender = metrics.descender.at(size);
                let scale = size.to_pt() / item.font.units_per_em();
                let ttf = item.font.ttf();
                let font_bounds = bounds.of(&item.font);
                let mut x = Abs::zero();
                for glyph in &item.glyphs {
                    let advance = glyph.x_advance.at(size);
                    let origin = Point::new(pos.x + x, pos.y - ascender).transform(ts);
                    out.glyphs.push(RawGlyph {
                        rect: (
                            origin.x.to_pt(),
                            origin.y.to_pt(),
                            advance.to_pt(),
                            (ascender - descender).to_pt(),
                        ),
                        span: glyph.span.0,
                        offset: glyph.span.1,
                    });
                    // Ink: the glyph's outline box, or its line box if it has none.
                    let gx = pos.x + x + glyph.x_offset.at(size);
                    let gy = pos.y - glyph.y_offset.at(size);
                    let outline = *font_bounds.entry(glyph.id).or_insert_with(|| {
                        ttf.glyph_bounding_box(ttf_parser::GlyphId(glyph.id))
                            .map(|bb| (bb.x_min, bb.y_min, bb.x_max, bb.y_max))
                    });
                    match outline {
                        Some((x_min, y_min, x_max, y_max)) => ink.add_rect(
                            ts,
                            gx + Abs::pt(x_min as f64 * scale),
                            gy - Abs::pt(y_max as f64 * scale),
                            gx + Abs::pt(x_max as f64 * scale),
                            gy - Abs::pt(y_min as f64 * scale),
                        ),
                        None if advance > Abs::zero() => {
                            ink.add_rect(ts, gx, gy - ascender, gx + advance, gy - descender)
                        }
                        None => {}
                    }
                    x += advance;
                }
            }
            FrameItem::Shape(shape, _) => {
                let bbox = shape.bbox(true);
                if bbox.max.x > bbox.min.x || bbox.max.y > bbox.min.y {
                    ink.add_rect(
                        ts,
                        pos.x + bbox.min.x,
                        pos.y + bbox.min.y,
                        pos.x + bbox.max.x,
                        pos.y + bbox.max.y,
                    );
                }
            }
            FrameItem::Image(_, size, _) => {
                ink.add_rect(ts, pos.x, pos.y, pos.x + size.x, pos.y + size.y);
            }
            FrameItem::Link(..) | FrameItem::Tag(..) => {}
        }
    }
}

/// The baseline of the block's first line, from the top: the first frame in
/// depth-first order that has its own baseline (Typst sets one on a flow from
/// its first line). Falls back to the first text run's baseline, then to the
/// height.
pub(crate) fn first_baseline(frame: &Frame, walked: &Walked) -> f64 {
    fn find(frame: &Frame, ts: Transform) -> Option<f64> {
        if frame.has_baseline() {
            return Some(Point::with_y(frame.baseline()).transform(ts).y.to_pt());
        }
        frame.items().find_map(|(pos, item)| match item {
            FrameItem::Group(group) => {
                let ts = ts
                    .pre_concat(Transform::translate(pos.x, pos.y))
                    .pre_concat(group.transform);
                find(&group.frame, ts)
            }
            _ => None,
        })
    }
    find(frame, Transform::identity())
        .or(walked.first_text_baseline)
        .unwrap_or_else(|| frame.height().to_pt())
}
