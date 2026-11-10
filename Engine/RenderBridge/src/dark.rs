//! Dark appearance: every paint of a laid-out block mapped onto the dark page.
//!
//! A block renders with the document's own colours, then each paint in its
//! frame (text fills and strokes, shape fills and strokes, gradient stops)
//! is mapped in OKLab so that lightness turns over between the app's dark
//! text colour and the dark page: black ink becomes `#E8E4DE` and a white
//! fill fades into `#262626`. The turn follows the square of the lightness,
//! so mid greys stay light enough to read: any colour with 4.5:1 or better
//! on a white page keeps 4.5:1 or better on the dark page. Hue is kept,
//! chroma is scaled by the same factor as the lightness range (reduced
//! further only to stay in sRGB), and alpha is kept. Images are never
//! touched. Tilings keep their colours: their frame cannot be rebuilt from
//! outside Typst.

use std::sync::Arc;

use typst::layout::{Frame, FrameItem};
use typst::visualize::{Color, Gradient, Paint, Rgb};

/// The dark page, `#262626` (spec Section 4.1).
pub const DARK_PAGE: [u8; 3] = [0x26, 0x26, 0x26];
/// The dark text colour, `#E8E4DE` (spec Section 4.1).
pub const DARK_TEXT: [u8; 3] = [0xE8, 0xE4, 0xDE];

/// The dark-appearance colour of a straight (not premultiplied) sRGB colour,
/// components from 0 to 1. With `L` the colour's OKLab lightness and
/// `t = L * L`, the new lightness is `L_text + (L_page - L_text) * t`
/// (`L_text` 0.920 for `#E8E4DE`, `L_page` 0.269 for `#262626`). The square
/// keeps black at the text colour and white at the page, keeps the order of
/// lightness (reversed), and lifts mid tones toward the text colour: the
/// welcome guide's muted `#66736D` (5.0:1 on white) becomes about `#A3A9A1`
/// (6.3:1 on the page) where a straight line gave `#727972` (3.4:1). Its
/// slope is continuous everywhere. Light fills still fade toward the page
/// (`#DBE6DF` becomes about `#3D433E`, 1.5:1). The neutral axis maps onto
/// the line from the text colour to the page colour at the same `t`, and the
/// colour's own chroma, scaled by `|L_text - L_page|`, is added to it, as far
/// as sRGB allows. Alpha is kept.
pub fn dark_color(rgba: [f32; 4]) -> [f32; 4] {
    let [r, g, b, alpha] = rgba;
    let [l, a, bb] = oklab([r as f64, g as f64, b as f64]);
    let text = oklab(DARK_TEXT.map(|c| c as f64 / 255.0));
    let page = oklab(DARK_PAGE.map(|c| c as f64 / 255.0));
    let l = l.clamp(0.0, 1.0);
    let t = l * l;
    let lightness = text[0] + (page[0] - text[0]) * t;
    let tint = [
        text[1] + (page[1] - text[1]) * t,
        text[2] + (page[2] - text[2]) * t,
    ];
    let factor = (text[0] - page[0]).abs();
    let at = |share: f64| {
        linear_srgb([
            lightness,
            tint[0] + a * factor * share,
            tint[1] + bb * factor * share,
        ])
    };
    let inside = |c: [f64; 3]| c.iter().all(|v| (-1e-6..=1.0 + 1e-6).contains(v));
    let mut linear = at(1.0);
    if !inside(linear) {
        // Bisect the share of chroma that still fits sRGB.
        let (mut low, mut high) = (0.0, 1.0);
        for _ in 0..24 {
            let mid = (low + high) / 2.0;
            if inside(at(mid)) {
                low = mid;
            } else {
                high = mid;
            }
        }
        linear = at(low);
    }
    let [r, g, b] = linear.map(|c| encode(c.clamp(0.0, 1.0)) as f32);
    [r, g, b, alpha]
}

/// Maps every paint in `frame`, and in its groups, with `dark_color`.
pub(crate) fn darken_frame(frame: &mut Frame) {
    frame.retain(|item| {
        darken_item(item);
        true
    });
}

fn darken_item(item: &mut FrameItem) {
    match item {
        FrameItem::Group(group) => darken_frame(&mut group.frame),
        FrameItem::Text(text) => {
            text.fill = darken_paint(&text.fill);
            if let Some(stroke) = &mut text.stroke {
                stroke.paint = darken_paint(&stroke.paint);
            }
        }
        FrameItem::Shape(shape, _) => {
            if let Some(fill) = &mut shape.fill {
                *fill = darken_paint(fill);
            }
            if let Some(stroke) = &mut shape.stroke {
                stroke.paint = darken_paint(&stroke.paint);
            }
        }
        FrameItem::Image(..) | FrameItem::Link(..) | FrameItem::Tag(_) => {}
    }
}

fn darken_paint(paint: &Paint) -> Paint {
    match paint {
        Paint::Solid(color) => Paint::Solid(darken(color)),
        Paint::Gradient(gradient) => Paint::Gradient(match gradient {
            Gradient::Linear(inner) => {
                let mut inner = (**inner).clone();
                inner.stops.iter_mut().for_each(|(c, _)| *c = darken(c));
                Gradient::Linear(Arc::new(inner))
            }
            Gradient::Radial(inner) => {
                let mut inner = (**inner).clone();
                inner.stops.iter_mut().for_each(|(c, _)| *c = darken(c));
                Gradient::Radial(Arc::new(inner))
            }
            Gradient::Conic(inner) => {
                let mut inner = (**inner).clone();
                inner.stops.iter_mut().for_each(|(c, _)| *c = darken(c));
                Gradient::Conic(Arc::new(inner))
            }
        }),
        Paint::Tiling(_) => paint.clone(),
    }
}

fn darken(color: &Color) -> Color {
    let rgb = color.to_rgb();
    let [r, g, b, a] = dark_color([rgb.red, rgb.green, rgb.blue, rgb.alpha]);
    Color::Process(Rgb::new(r, g, b, a).into())
}

fn decode(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn encode(c: f64) -> f64 {
    if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

/// OKLab of an sRGB colour (Björn Ottosson's matrices).
fn oklab(srgb: [f64; 3]) -> [f64; 3] {
    let [r, g, b] = srgb.map(decode);
    let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
    let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
    let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
    [
        0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
        1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
        0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s,
    ]
}

/// Linear sRGB of an OKLab colour, not clamped.
fn linear_srgb(lab: [f64; 3]) -> [f64; 3] {
    let [l, a, b] = lab;
    let l_ = (l + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
    let m_ = (l - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
    let s_ = (l - 0.089_484_177_5 * a - 1.291_485_548_0 * b).powi(3);
    [
        4.076_741_662_1 * l_ - 3.307_711_591_3 * m_ + 0.230_969_929_2 * s_,
        -1.268_438_004_6 * l_ + 2.609_757_401_1 * m_ - 0.341_319_396_5 * s_,
        -0.004_196_086_3 * l_ - 0.703_418_614_7 * m_ + 1.707_614_701_0 * s_,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(bytes: [u8; 3]) -> [f32; 4] {
        [
            bytes[0] as f32 / 255.0,
            bytes[1] as f32 / 255.0,
            bytes[2] as f32 / 255.0,
            1.0,
        ]
    }

    fn assert_near(got: [f32; 4], want: [u8; 3]) {
        for channel in 0..3 {
            let delta = (got[channel] * 255.0 - want[channel] as f32).abs();
            assert!(
                delta <= 1.0,
                "{got:?} is not {want:02X?} (channel {channel})"
            );
        }
    }

    fn hue(rgba: [f32; 4]) -> f64 {
        let [_, a, b] = oklab([rgba[0] as f64, rgba[1] as f64, rgba[2] as f64]);
        b.atan2(a).to_degrees()
    }

    /// WCAG relative luminance, after rounding to 8 bits as a bitmap would.
    fn luminance(rgba: [f32; 4]) -> f64 {
        let channel = |c: f32| decode((c as f64 * 255.0).round() / 255.0);
        0.2126 * channel(rgba[0]) + 0.7152 * channel(rgba[1]) + 0.0722 * channel(rgba[2])
    }

    /// WCAG contrast ratio of two colours.
    fn contrast(x: [f32; 4], y: [f32; 4]) -> f64 {
        let (x, y) = (luminance(x), luminance(y));
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }

    fn lightness(rgba: [f32; 4]) -> f64 {
        oklab([rgba[0] as f64, rgba[1] as f64, rgba[2] as f64])[0]
    }

    /// Every colour of a grid with `steps` levels per channel, and every grey.
    fn sweep(steps: u32) -> Vec<[f32; 4]> {
        let level = |i: u32| i as f32 / (steps - 1) as f32;
        let mut colours = Vec::new();
        for r in 0..steps {
            for g in 0..steps {
                for b in 0..steps {
                    colours.push([level(r), level(g), level(b), 1.0]);
                }
            }
        }
        colours.extend((0..=255).map(|v| unit([v, v, v])));
        colours
    }

    #[test]
    fn black_becomes_the_text_colour_and_white_the_page() {
        assert_near(dark_color([0.0, 0.0, 0.0, 1.0]), DARK_TEXT);
        assert_near(dark_color([1.0, 1.0, 1.0, 1.0]), DARK_PAGE);
        // Dark ink, #1A1918 (OKLab L 0.21), lands at L 0.89, about #DFDAD3:
        // 10.9:1 against the page.
        let ink = dark_color(unit([0x1A, 0x19, 0x18]));
        assert!(ink.iter().take(3).all(|c| *c > 0.80), "{ink:?}");
        assert!(contrast(ink, unit(DARK_PAGE)) > 10.0, "{ink:?}");
    }

    #[test]
    fn a_saturated_red_keeps_its_hue_and_stays_distinct() {
        let red = unit([0xE0, 0x20, 0x20]);
        let dark = dark_color(red);
        let turn = (hue(dark) - hue(red)).abs();
        assert!(turn < 5.0, "hue turned {turn} degrees: {dark:?}");
        let text = oklab(DARK_TEXT.map(|c| c as f64 / 255.0));
        let got = oklab([dark[0] as f64, dark[1] as f64, dark[2] as f64]);
        let distance = (0..3)
            .map(|i| (got[i] - text[i]).powi(2))
            .sum::<f64>()
            .sqrt();
        assert!(
            distance > 0.15,
            "red is too close to the text colour: {dark:?}"
        );
        let chroma = got[1].hypot(got[2]);
        assert!(chroma > 0.08, "red lost its colour: {dark:?}");
        // Mapped, pure red gains green and blue (about #E9624E), so an image
        // left alone, near (234, 51, 35) on screen, is told apart from a
        // mapped one (DarkWritingFlowTests).
        let pure = dark_color([1.0, 0.0, 0.0, 1.0]);
        assert!(pure[1] > 0.35 && pure[2] > 0.29, "{pure:?}");
    }

    #[test]
    fn alpha_is_kept_and_results_stay_in_gamut() {
        assert_eq!(dark_color([0.2, 0.4, 0.9, 0.35])[3], 0.35);
        for r in 0..=4 {
            for g in 0..=4 {
                for b in 0..=4 {
                    let c = [r as f32 / 4.0, g as f32 / 4.0, b as f32 / 4.0, 1.0];
                    let dark = dark_color(c);
                    assert!(
                        dark.iter().all(|v| (0.0..=1.0).contains(v)),
                        "{c:?} -> {dark:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn lightness_turns_over() {
        let light_fill = dark_color(unit([0xE6, 0xEF, 0xE4]));
        let dark_ink = dark_color(unit([0x1A, 0x19, 0x18]));
        let l = |c: [f32; 4]| oklab([c[0] as f64, c[1] as f64, c[2] as f64])[0];
        assert!(l(light_fill) < l(dark_ink));
    }

    #[test]
    fn text_that_reads_on_white_reads_on_the_dark_page() {
        // Every grey and every colour of a 33-level grid with 4.5:1 or better
        // against white keeps 4.5:1 or better against #262626. The closest
        // is a light violet, #BF00FF: about 4.8:1.
        let white = [1.0, 1.0, 1.0, 1.0];
        let page = unit(DARK_PAGE);
        let mut checked = 0;
        for colour in sweep(33) {
            if contrast(colour, white) < 4.5 {
                continue;
            }
            checked += 1;
            let dark = dark_color(colour);
            assert!(
                contrast(dark, page) >= 4.5,
                "{colour:?} -> {dark:?}: {:.2}:1",
                contrast(dark, page)
            );
        }
        assert!(checked > 10_000, "{checked}");
        // The welcome guide's muted line, #66736D, 5.0:1 on white.
        let muted = dark_color(unit([0x66, 0x73, 0x6D]));
        assert!(contrast(muted, page) >= 6.0, "{muted:?}");
        // Its ink, #253238.
        let ink = dark_color(unit([0x25, 0x32, 0x38]));
        assert!(contrast(ink, page) >= 9.0, "{ink:?}");
    }

    #[test]
    fn a_lighter_grey_never_maps_lighter() {
        let mut previous = f64::INFINITY;
        for v in 0..=255u8 {
            let mapped = lightness(dark_color(unit([v, v, v])));
            assert!(mapped <= previous + 1e-9, "#{v:02X} maps to L {mapped}");
            previous = mapped;
        }
    }

    #[test]
    fn light_fills_stay_near_the_page() {
        // Light fills (the guide's sage, sage lightened 55 percent, near
        // white) stay within 0.11 of the page's OKLab lightness and below
        // 1.55:1 against it: a faint panel, not a bright block.
        let page = unit(DARK_PAGE);
        let page_lightness = lightness(page);
        for fill in [
            [0xDB, 0xE6, 0xDF],
            [0xEE, 0xF3, 0xF0],
            [0xE6, 0xEF, 0xE4],
            [0xF5, 0xF5, 0xF7],
        ] {
            let dark = dark_color(unit(fill));
            let lift = lightness(dark) - page_lightness;
            assert!((0.0..=0.11).contains(&lift), "{fill:02X?} -> {dark:?}: {lift}");
            assert!(contrast(dark, page) < 1.55, "{fill:02X?} -> {dark:?}");
        }
    }
}
