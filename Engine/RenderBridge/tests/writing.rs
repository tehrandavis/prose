//! What Writing mode needs from the engine (Phase 3): blocks that cover the
//! whole file, render options (text colour, bitmap), a transparent page and
//! a drawn area that holds hanging punctuation.

mod common;

use std::path::PathBuf;

use common::{rendering_blocks, utf16_slice, Project};
use prose_render::{BlockKind, BlockRange, Engine, Options, RenderOptions, MAX_BITMAP_PIXELS};

fn kinds(text: &str) -> Vec<(String, BlockKind)> {
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    engine
        .blocks(&project.path("main.typ"))
        .unwrap()
        .iter()
        .map(|b| (utf16_slice(text, b.start, b.end), b.kind))
        .collect()
}

/// Blocks are in order and do not overlap, each starts and ends at a
/// character that is not whitespace, and every character that is not
/// whitespace lies in a block.
fn assert_covers(text: &str, blocks: &[BlockRange]) {
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut covered = vec![false; units.len()];
    let mut last_end = 0;
    for block in blocks {
        assert!(block.start < block.end, "{block:?} is empty");
        assert!(
            block.start >= last_end,
            "{block:?} overlaps the block before"
        );
        last_end = block.end;
        let body = utf16_slice(text, block.start, block.end);
        assert_eq!(body.trim(), body, "{block:?} has whitespace at an end");
        covered[block.start..block.end].fill(true);
    }
    let uncovered: String = String::from_utf16_lossy(
        &units
            .iter()
            .zip(&covered)
            .filter(|(_, c)| !**c)
            .map(|(u, _)| *u)
            .collect::<Vec<_>>(),
    );
    assert!(
        uncovered.trim().is_empty(),
        "characters outside every block: {uncovered:?}"
    );
}

#[test]
fn include_raw_list_and_comment_blocks_have_their_own_kinds() {
    let text = "// A note at the top.\n/* And a block comment. */\n#import \"lib.typ\": f // why\n\n= Title <title>\n\n```rust\nfn main() {}\n```\n\n```py\nx = 1\n``` <listing>\n\n- one\n- two\n  continued\n+ three\n/ Term: its description\n\n#include \"chapter.typ\"\n\n// Only a comment.\n\nText with `inline raw`.\n\n- An item\nthen a paragraph line.\n\n// A comment, then\n$ x = 1 $\n";
    let shown = kinds(text);
    let expected: Vec<(&str, BlockKind)> = vec![
        (
            "// A note at the top.\n/* And a block comment. */",
            BlockKind::Comment,
        ),
        ("#import \"lib.typ\": f // why", BlockKind::Context),
        ("= Title <title>", BlockKind::Heading),
        ("```rust\nfn main() {}\n```", BlockKind::Raw),
        ("```py\nx = 1\n``` <listing>", BlockKind::Raw),
        (
            "- one\n- two\n  continued\n+ three\n/ Term: its description",
            BlockKind::List,
        ),
        ("#include \"chapter.typ\"", BlockKind::Include),
        ("// Only a comment.", BlockKind::Comment),
        ("Text with `inline raw`.", BlockKind::Paragraph),
        // The second line is not indented, so it is not the item's text.
        ("- An item\nthen a paragraph line.", BlockKind::Paragraph),
        ("// A comment, then\n$ x = 1 $", BlockKind::Equation),
    ];
    let shown: Vec<(&str, BlockKind)> = shown.iter().map(|(t, k)| (t.as_str(), *k)).collect();
    assert_eq!(shown, expected);
    assert_eq!(
        [
            BlockKind::Context,
            BlockKind::Include,
            BlockKind::Raw,
            BlockKind::List,
            BlockKind::Comment
        ]
        .map(BlockKind::code),
        [4, 5, 6, 7, 8]
    );
    assert!(BlockKind::Raw.renders() && BlockKind::List.renders());
    assert!(!BlockKind::Include.renders() && !BlockKind::Comment.renders());
}

#[test]
fn a_list_with_a_paragraph_after_its_item_is_still_a_list_but_text_first_is_not() {
    let shown = kinds("Intro text:\n- one\n- two\n\n1. first\n2. second\n");
    assert_eq!(shown[0].1, BlockKind::Paragraph);
    assert_eq!(shown[1], ("1. first\n2. second".into(), BlockKind::List));
}

#[test]
fn a_loose_list_is_one_block_and_keeps_its_numbering() {
    // Items of one kind with blank lines (and comments) between them are one
    // list in Typst, so one block, numbered 1, 2, 3.
    let text =
        "+ First item.\n\n+ Second item.\n\n// A note.\n\n+ Third item.\n\nAfter the list.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let blocks = engine.blocks(&path).unwrap();
    let shown: Vec<(String, BlockKind)> = blocks
        .iter()
        .map(|b| (utf16_slice(text, b.start, b.end), b.kind))
        .collect();
    assert_eq!(
        shown,
        [
            (
                "+ First item.\n\n+ Second item.\n\n// A note.\n\n+ Third item.".to_string(),
                BlockKind::List
            ),
            ("After the list.".to_string(), BlockKind::Paragraph),
        ]
    );
    let render = engine
        .render(&path, blocks[0].start, blocks[0].end, 300.0)
        .unwrap();
    let words: Vec<&str> = render.rendered.text.split_whitespace().collect();
    let numbers: Vec<&str> = words
        .iter()
        .copied()
        .filter(|w| w.ends_with('.') && w[..w.len() - 1].parse::<u32>().is_ok())
        .collect();
    assert_eq!(numbers, ["1.", "2.", "3."], "{words:?}");
    // The numbers are generated text, one run each.
    assert_eq!(render.glyphs.iter().filter(|g| g.source < 0).count(), 6);
}

#[test]
fn a_paragraph_or_another_kind_of_item_ends_a_loose_list() {
    let shown = kinds(
        "+ One.\n\n+ Two.\n\nA paragraph.\n\n+ Three.\n\n- A bullet.\n\n- Another.\n\n+ Four.\n",
    );
    let shown: Vec<(&str, BlockKind)> = shown.iter().map(|(t, k)| (t.as_str(), *k)).collect();
    assert_eq!(
        shown,
        [
            ("+ One.\n\n+ Two.", BlockKind::List),
            ("A paragraph.", BlockKind::Paragraph),
            ("+ Three.", BlockKind::List),
            ("- A bullet.\n\n- Another.", BlockKind::List),
            ("+ Four.", BlockKind::List),
        ]
    );
    // A paragraph that leads into a list keeps the list's later items with it,
    // as Typst groups the items; a heading or context line ends the list.
    let shown =
        kinds("Steps:\n+ One.\n\n+ Two.\n\n= Heading\n\n+ Three.\n#set text(red)\n\n+ Four.\n");
    let shown: Vec<(&str, BlockKind)> = shown.iter().map(|(t, k)| (t.as_str(), *k)).collect();
    assert_eq!(
        shown,
        [
            ("Steps:\n+ One.\n\n+ Two.", BlockKind::Paragraph),
            ("= Heading", BlockKind::Heading),
            ("+ Three.", BlockKind::List),
            ("#set text(red)", BlockKind::Context),
            ("+ Four.", BlockKind::List),
        ]
    );
}

#[test]
fn context_lines_still_feed_every_later_block() {
    // The context line's trailing comment is in its block, not in the
    // context, and a comment-only block before it changes nothing.
    let text = "// Setup.\n#show \"word\": \"WORD\" // shout\n\nA word here.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let blocks = engine.blocks(&path).unwrap();
    assert_eq!(
        blocks.iter().map(|b| b.kind).collect::<Vec<_>>(),
        [BlockKind::Comment, BlockKind::Context, BlockKind::Paragraph]
    );
    let render = engine
        .render(&path, blocks[2].start, blocks[2].end, 300.0)
        .unwrap();
    assert!(
        render.rendered.text.contains("WORD"),
        "{}",
        render.rendered.text
    );
}

#[test]
fn blocks_cover_the_whole_file() {
    let samples = [
        "#set text(size: 11pt)\n#let x = 1 // one\n\n= Title\n\nA paragraph.\n#set par(justify: true)\nAnother.\n\n$ x + y $ <eq>\n\n#include \"other.typ\"\n",
        "// c\n\n\n- a\n- b\n\n```\nraw\n```\n\n  Indented text.   \n\n#figure(table(columns: 2)[a][b])\n\nTrailing // comment\n",
        "= Heading // with a comment\n#import \"x.typ\": *\nText right after.\n/* block\ncomment */ text after it.\n\n#let f(x) = {\n  x\n\n  x\n}\n\nEnd.",
        "Unclosed #let x = (\n\nFine.\n\n#set text(\n",
        "",
        "   \n\n  ",
    ];
    for text in samples {
        let project = Project::new(&[("main.typ", text)]);
        let engine = project.engine();
        let blocks = engine.blocks(&project.path("main.typ")).unwrap();
        assert_covers(text, &blocks);
    }
}

#[test]
fn the_thesis_and_sicp_are_covered_by_their_blocks() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let thesis = manifest.join("fixtures/thesis");
    let sicp = manifest.join("../../Examples/Books/SICP");
    let mut files = vec![
        (thesis.clone(), thesis.join("main.typ")),
        (thesis.clone(), thesis.join("sections/method.typ")),
    ];
    if sicp.join("main.typ").exists() {
        files.push((sicp.clone(), sicp.join("main.typ")));
    }
    for (root, file) in files {
        let engine = Engine::new(Options::new(&root, "main.typ")).unwrap();
        let text = engine.text(&file).unwrap();
        let blocks = engine.blocks(&file).unwrap();
        assert_covers(&text, &blocks);
        // Every block starts at the start of a line, as Writing mode's
        // fragments need.
        let units: Vec<u16> = text.encode_utf16().collect();
        for block in &blocks {
            assert!(
                block.start == 0 || units[block.start - 1] == u16::from(b'\n'),
                "{file:?}: {block:?} starts inside a line"
            );
        }
    }
}

const HANGING: &str = "#set par(justify: true)\n#set text(size: 11pt)\n\nThe quick brown fox jumps over the lazy dog, again and again. Typst lets the punctuation at the end of a line hang into the margin, so the text looks straight. Commas, periods, hyphens and quotes all hang a little, every one of them, line by line, until the paragraph ends.\n";

/// Fill colours used on glyphs in an SVG (`fill="#rrggbb"` on `<use>` and
/// `<path>` of text groups), lowercased.
fn fills(svg: &str) -> Vec<String> {
    svg.split("fill=\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .map(str::to_lowercase)
        .collect()
}

/// Straight (not premultiplied) RGB of the bitmap's opaque pixels.
fn opaque_pixels(bitmap: &prose_render::Bitmap) -> Vec<[u8; 3]> {
    bitmap
        .data
        .chunks(4)
        .filter(|p| p[3] >= 250)
        .map(|p| [p[0], p[1], p[2]].map(|c| (c as u32 * 255 / p[3] as u32) as u8))
        .collect()
}

#[test]
fn dark_appearance_maps_the_documents_own_colours_but_not_images() {
    let text = "#set text(fill: rgb(\"#1A1918\"))\n\nDark ink words.\n\n#rect(width: 100pt, height: 20pt, fill: white)\n\n#table(columns: (1fr, 1fr), [A], [B])\n\n#image(\"dot.svg\", width: 20pt)\n";
    let dot = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\" fill=\"#ff0000\"/></svg>";
    let project = Project::new(&[("main.typ", text), ("dot.svg", dot)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let blocks = rendering_blocks(&engine, &path);
    assert_eq!(blocks.len(), 4, "{blocks:?}");
    let render = |block: BlockRange, dark| {
        engine
            .render_with(
                &path,
                block.start,
                block.end,
                300.0,
                &RenderOptions {
                    dark,
                    bitmap_scale: 2.0,
                },
            )
            .unwrap()
    };
    let light = |p: &[u8; 3]| p.iter().all(|c| *c >= 0xA0);
    let dim = |p: &[u8; 3]| p.iter().all(|c| *c <= 0x40);

    // Text in the document's own dark ink draws light; in light appearance
    // it keeps the ink.
    let words = render(blocks[0], true);
    assert!(!fills(&words.rendered.svg).contains(&"#1a1918".to_string()));
    let ink = opaque_pixels(words.bitmap.as_ref().unwrap());
    assert!(!ink.is_empty() && ink.iter().all(light), "{ink:?}");
    let plain = opaque_pixels(render(blocks[0], false).bitmap.as_ref().unwrap());
    assert!(!plain.is_empty() && plain.iter().all(dim));

    // A white fill fades into the page.
    let rect = render(blocks[1], true);
    let fill = opaque_pixels(rect.bitmap.as_ref().unwrap());
    assert!(!fill.is_empty());
    assert!(
        fill.iter().all(|p| p.iter().all(|c| c.abs_diff(0x26) <= 2)),
        "{:?}",
        &fill[..4]
    );

    // A table's default black rules and its text draw light.
    let table = render(blocks[2], true);
    let bitmap = table.bitmap.as_ref().unwrap();
    let rules = opaque_pixels(bitmap);
    assert!(
        rules.len() > 100 && rules.iter().all(light),
        "{}",
        rules.len()
    );
    // The top rule: a row across the table, light where it is drawn.
    let row = |y: u32| {
        (0..bitmap.width)
            .map(|x| y as usize * bitmap.row_bytes + x as usize * 4)
            .filter(|at| bitmap.data[at + 3] >= 128)
            .map(|at| bitmap.data[at] as u32 * 255 / bitmap.data[at + 3] as u32)
            .collect::<Vec<_>>()
    };
    let top = (0..bitmap.height / 2)
        .map(row)
        .find(|pixels| pixels.len() as u32 > bitmap.width / 2)
        .expect("a top rule");
    assert!(top.iter().all(|c| *c >= 0xA0), "{:?}", &top[..4]);

    // An image keeps its pixels.
    for dark in [false, true] {
        let image = render(blocks[3], dark);
        let red = opaque_pixels(image.bitmap.as_ref().unwrap());
        assert!(red.len() > 100);
        assert!(red.iter().all(|p| *p == [0xff, 0, 0]), "{:?}", &red[..4]);
    }
}

#[test]
fn the_page_is_transparent_in_svg_and_bitmap() {
    let project = Project::new(&[("main.typ", "Some words on a page.\n")]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = engine.blocks(&path).unwrap()[0];
    let options = RenderOptions {
        dark: false,
        bitmap_scale: 2.0,
    };
    let render = engine
        .render_with(&path, block.start, block.end, 300.0, &options)
        .unwrap();
    let svg = &render.rendered.svg;
    // No page-sized filled rectangle: Typst draws a page fill as a path of
    // the page's size with a fill.
    assert!(!fills(svg).contains(&"#ffffff".to_string()), "{svg}");
    assert!(!svg.contains("class=\"typst-page-fill\""));
    let bitmap = render.bitmap.expect("a bitmap");
    let pixel = |x: u32, y: u32| {
        let at = y as usize * bitmap.row_bytes + x as usize * 4;
        &bitmap.data[at..at + 4]
    };
    for (x, y) in [
        (0, 0),
        (bitmap.width - 1, 0),
        (0, bitmap.height - 1),
        (bitmap.width - 1, bitmap.height - 1),
    ] {
        assert_eq!(pixel(x, y), [0, 0, 0, 0], "corner {x}, {y}");
    }
    // Premultiplied: no channel exceeds alpha, and the ink is there.
    assert!(bitmap
        .data
        .chunks(4)
        .all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]));
    let max = bitmap.data.chunks(4).map(|p| p[3]).max().unwrap();
    assert!(max >= 250, "max alpha {max}");
}

#[test]
fn hanging_punctuation_lies_inside_the_drawn_area() {
    let project = Project::new(&[("main.typ", HANGING)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = rendering_blocks(&engine, &path)[0];
    let render = engine
        .render_with(
            &path,
            block.start,
            block.end,
            200.0,
            &RenderOptions {
                dark: false,
                bitmap_scale: 3.0,
            },
        )
        .unwrap();
    let r = &render.rendered;
    let right = r.ink.x + r.ink.width;
    assert!(
        right > r.width + 0.01,
        "nothing hangs: {:?} on {}",
        r.ink,
        r.width
    );
    let drawn = r.drawn;
    assert!(drawn.x <= 0.0 && drawn.y <= 0.0);
    assert!(drawn.x <= r.ink.x + 1e-9 && drawn.y <= r.ink.y + 1e-9);
    assert!(drawn.x + drawn.width >= right - 1e-9);
    assert!(drawn.y + drawn.height >= r.ink.y + r.ink.height - 1e-9);
    assert!(drawn.x + drawn.width >= r.width && drawn.y + drawn.height >= r.height);
    // Glyphs whose advance passes the measure start inside the drawn area.
    // (Their advance boxes include side bearings, so they can end past the
    // ink; the drawn area follows the ink.)
    let hanging: Vec<_> = render
        .glyphs
        .iter()
        .filter(|g| g.width > 0.0 && (g.x + g.width) as f64 > r.width + 0.01)
        .collect();
    assert!(!hanging.is_empty());
    for glyph in hanging {
        assert!(
            (glyph.x as f64) < drawn.x + drawn.width,
            "{glyph:?} in {drawn:?}"
        );
    }
    // The SVG's viewBox is the drawn area.
    let view_box = format!("viewBox=\"0 0 {} {}\"", drawn.width, drawn.height);
    let svg_head: String = r.svg.chars().take(300).collect();
    let widths: Vec<f64> = svg_head
        .split("viewBox=\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .map(|v| v.split(' ').filter_map(|n| n.parse().ok()).collect())
        .unwrap_or_default();
    assert_eq!(widths.len(), 4, "{svg_head} ({view_box})");
    assert!((widths[2] - drawn.width).abs() < 0.01 && (widths[3] - drawn.height).abs() < 0.01);
    // The bitmap is the drawn area times the scale, rounded up, and the
    // hanging glyph's ink reaches the right part of the bitmap.
    let bitmap = render.bitmap.unwrap();
    assert_eq!(bitmap.width, (drawn.width * 3.0).ceil() as u32);
    assert_eq!(bitmap.height, (drawn.height * 3.0).ceil() as u32);
    let page_right = ((r.width - drawn.x) * 3.0).ceil() as u32 + 1;
    let inked_past_page = (0..bitmap.height).any(|y| {
        (page_right..bitmap.width)
            .any(|x| bitmap.data[y as usize * bitmap.row_bytes + x as usize * 4 + 3] > 0)
    });
    assert!(inked_past_page, "the hanging ink was clipped");
}

#[test]
fn bitmap_sizes_follow_the_drawn_area_and_the_scale() {
    let project = Project::new(&[(
        "main.typ",
        "= A heading\n\nA paragraph that is long enough to wrap onto a second line here.\n\n$ sum_(i=1)^n i = (n(n+1))/2 $\n",
    )]);
    let engine = project.engine();
    let path = project.path("main.typ");
    for block in engine.blocks(&path).unwrap() {
        for scale in [1.0, 1.3, 2.0, 2.6] {
            let render = engine
                .render_with(
                    &path,
                    block.start,
                    block.end,
                    173.3,
                    &RenderOptions {
                        dark: false,
                        bitmap_scale: scale,
                    },
                )
                .unwrap();
            let drawn = render.rendered.drawn;
            let bitmap = render.bitmap.unwrap();
            assert_eq!(bitmap.width, (drawn.width * scale).ceil() as u32);
            assert_eq!(bitmap.height, (drawn.height * scale).ceil() as u32);
            assert_eq!(bitmap.row_bytes, bitmap.width as usize * 4);
            assert_eq!(bitmap.data.len(), bitmap.row_bytes * bitmap.height as usize);
            // A direct rasterize of the cached result gives the same pixels.
            assert_eq!(render.rendered.rasterize(scale).as_ref(), Some(&bitmap));
        }
    }
    let block = engine.blocks(&path).unwrap()[0];
    // No bitmap at scale 0; scales outside 0 to 16 are errors.
    let none = engine.render(&path, block.start, block.end, 173.3).unwrap();
    assert!(none.bitmap.is_none());
    for scale in [-1.0, f64::NAN, f64::INFINITY, 16.5] {
        let options = RenderOptions {
            dark: false,
            bitmap_scale: scale,
        };
        assert!(engine
            .render_with(&path, block.start, block.end, 173.3, &options)
            .is_err());
    }
    assert!(none.rendered.rasterize(0.0).is_none());
    assert!(none.rendered.rasterize(-2.0).is_none());
}

#[test]
fn a_bitmap_past_the_pixel_limit_is_left_out() {
    // About 400 lines at scale 16 on a 2000 pt measure: far past the limit.
    let mut text = String::new();
    for n in 0..400 {
        text.push_str(&format!("Line {n}\\\n"));
    }
    let project = Project::new(&[("main.typ", &text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = engine.blocks(&path).unwrap()[0];
    let options = RenderOptions {
        dark: false,
        bitmap_scale: 16.0,
    };
    let render = engine
        .render_with(&path, block.start, block.end, 2000.0, &options)
        .unwrap();
    let drawn = render.rendered.drawn;
    assert!(drawn.width * 16.0 * drawn.height * 16.0 > MAX_BITMAP_PIXELS as f64);
    assert!(render.bitmap.is_none());
    assert!(!render.rendered.svg.is_empty());
}

#[test]
fn options_separate_cache_entries_by_appearance_but_not_by_scale() {
    let project = Project::new(&[("main.typ", "Words to cache.\n")]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = engine.blocks(&path).unwrap()[0];
    let render = |dark, bitmap_scale| {
        engine
            .render_with(
                &path,
                block.start,
                block.end,
                300.0,
                &RenderOptions { dark, bitmap_scale },
            )
            .unwrap()
    };
    let dark = true;
    assert!(!render(false, 0.0).cached);
    assert!(!render(dark, 0.0).cached, "dark appearance is another key");
    assert!(render(false, 0.0).cached && render(dark, 0.0).cached);
    // The bitmap scale does not change the vector result, which is reused.
    let a = render(dark, 1.0);
    let b = render(dark, 2.0);
    assert!(a.cached && b.cached);
    assert!(std::sync::Arc::ptr_eq(&a.rendered, &b.rendered));
    assert_ne!(a.bitmap.unwrap().width, b.bitmap.unwrap().width);
    let stats = engine.cache_stats();
    assert_eq!((stats.entries, stats.misses), (2, 2));
}
