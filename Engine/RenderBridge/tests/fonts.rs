//! The block's text font and the font calls (C ABI version 6).

mod common;

use common::{rendering_blocks, utf16_index, Project};
use prose_render::{Engine, TextFont};
use typst::text::FontStyle;

/// The text font of the first block that renders whose text holds `needle`.
fn font_of(engine: &Engine, project: &Project, text: &str, needle: &str) -> Option<TextFont> {
    let path = project.path("main.typ");
    let at = utf16_index(text, needle);
    let block = rendering_blocks(engine, &path)
        .into_iter()
        .find(|b| b.start <= at && at < b.end)
        .unwrap_or_else(|| panic!("no block holds {needle:?}"));
    engine
        .render(&path, block.start, block.end, 300.0)
        .unwrap()
        .rendered
        .text_font
}

fn family(engine: &Engine, font: u32) -> String {
    engine.font_info(font).unwrap().family
}

#[test]
fn a_paragraph_in_the_default_font_reports_libertinus_serif_at_11pt() {
    let text = "A short line.\n\nA paragraph long enough to wrap onto a second line at this narrow measure of three hundred points, and then a third.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();

    let one = font_of(&engine, &project, text, "A short").unwrap();
    assert_eq!(family(&engine, one.font), "Libertinus Serif");
    assert_eq!(one.size, 11.0);
    assert_eq!(one.line_pitch, 0.0, "one line has no pitch");
    let info = engine.font_info(one.font).unwrap();
    assert_eq!(info.weight, 400);
    assert_eq!(info.style, FontStyle::Normal);
    assert!(info.embedded);

    let two = font_of(&engine, &project, text, "A paragraph").unwrap();
    assert_eq!(two.font, one.font, "the same face has the same identifier");
    assert_eq!(two.size, 11.0);
    // Typst's default: the cap height plus a leading of 0.65 em.
    assert!(
        two.line_pitch > 11.0 && two.line_pitch < 22.0,
        "{}",
        two.line_pitch
    );
}

#[test]
fn inline_math_and_strong_text_do_not_change_the_font_or_the_pitch() {
    // Four lines; tall inline math on the first pushes it down, so the
    // pitch is the distance between the plain lines below.
    let plain = "Words that wrap onto a second line at this measure, set in the plain body font of the document, and then they run on to a third line and a fourth line of plain words.\n";
    let mixed = "Words with $sum_(i=1)^n x_i^2$ that wrap onto a *second* line at this measure, set in the _body_ font of the document, and then they run on to a third line and a fourth line of plain words.\n";
    let project = Project::new(&[("main.typ", plain)]);
    let engine = project.engine();
    let base = font_of(&engine, &project, plain, "Words").unwrap();
    engine.set_text(&project.path("main.typ"), mixed).unwrap();
    let with_math = font_of(&engine, &project, mixed, "Words").unwrap();
    assert_eq!(with_math.font, base.font);
    assert_eq!(with_math.size, 11.0);
    assert!(
        (with_math.line_pitch - base.line_pitch).abs() < 0.01,
        "{} vs {}",
        with_math.line_pitch,
        base.line_pitch
    );
}

#[test]
fn a_set_rule_changes_the_family_and_the_size() {
    let text =
        "#set text(font: \"New Computer Modern\", size: 14pt)\n\nA paragraph in another font.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let font = font_of(&engine, &project, text, "A paragraph").unwrap();
    assert_eq!(family(&engine, font.font), "New Computer Modern");
    assert_eq!(font.size, 14.0);
}

#[test]
fn a_heading_reports_its_own_size() {
    let text = "#show heading: set text(size: 32pt)\n\n= A Heading\n\nBody text.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let heading = font_of(&engine, &project, text, "A Heading").unwrap();
    assert_eq!(heading.size, 32.0);
    assert_eq!(heading.line_pitch, 0.0);
    // Headings are bold by default: another face of the same family.
    let body = font_of(&engine, &project, text, "Body").unwrap();
    assert_eq!(family(&engine, heading.font), family(&engine, body.font));
    assert_eq!(engine.font_info(heading.font).unwrap().weight, 700);
    assert_eq!(body.size, 11.0);
}

#[test]
fn a_block_with_only_generated_text_reports_none() {
    let text = "#set heading(numbering: \"1.\")\n\n= End <end>\n\n@end\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    assert!(engine.refresh().ok);
    let path = project.path("main.typ");
    let at = utf16_index(text, "@end");
    let block = rendering_blocks(&engine, &path)
        .into_iter()
        .find(|b| b.start == at)
        .unwrap();
    let render = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(!render.glyphs.is_empty());
    assert!(render.glyphs.iter().all(|g| g.source < 0));
    assert_eq!(render.rendered.text_font, None);
}

#[test]
fn bold_and_italic_faces_come_from_the_font_book() {
    let text = "Plain words.\n\n#text(font: \"DejaVu Sans Mono\")[Code words.]\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let base = font_of(&engine, &project, text, "Plain").unwrap().font;

    let bold = engine.font_face(base, true, false).unwrap();
    let italic = engine.font_face(base, false, true).unwrap();
    let both = engine.font_face(base, true, true).unwrap();
    assert_ne!(bold, base);
    assert_ne!(italic, base);
    let bold_info = engine.font_info(bold).unwrap();
    assert_eq!(bold_info.family, "Libertinus Serif");
    assert_eq!(bold_info.weight, 700);
    assert_eq!(bold_info.style, FontStyle::Normal);
    let italic_info = engine.font_info(italic).unwrap();
    assert_eq!(italic_info.family, "Libertinus Serif");
    assert_eq!(italic_info.weight, 400);
    assert_eq!(italic_info.style, FontStyle::Italic);
    let both_info = engine.font_info(both).unwrap();
    assert_eq!(
        (both_info.weight, both_info.style),
        (700, FontStyle::Italic)
    );
    assert_eq!(engine.font_face(base, false, false), Some(base));
    assert_eq!(engine.font_face(u32::MAX, true, false), None);
    assert_eq!(engine.font_info(u32::MAX), None);

    // Typst embeds DejaVu Sans Mono in one face: no bold, no italic.
    let mono = font_of(&engine, &project, text, "#text").unwrap().font;
    let mono_info = engine.font_info(mono).unwrap();
    assert_eq!(mono_info.family, "DejaVu Sans Mono");
    if engine.font_face(mono, true, true) != Some(mono) {
        // A system copy of the family has more faces: then the answer must
        // be another face of the same family.
        let other = engine.font_face(mono, true, true).unwrap();
        assert_eq!(family(&engine, other), "DejaVu Sans Mono");
    }
}

#[test]
fn a_family_with_no_italic_face_answers_its_base_face_for_emphasis() {
    // Typst embeds New Computer Modern Math upright only, at 400, 450 and 700.
    let text = "#text(font: \"New Computer Modern Math\")[Math font words.]\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let font = font_of(&engine, &project, text, "#text").unwrap().font;
    let info = engine.font_info(font).unwrap();
    assert_eq!(info.family, "New Computer Modern Math");
    assert_eq!((info.weight, info.style), (400, FontStyle::Normal));
    assert_eq!(engine.font_face(font, false, true), Some(font));
    let bold = engine.font_face(font, true, true).unwrap();
    let bold_info = engine.font_info(bold).unwrap();
    assert_eq!(bold_info.family, "New Computer Modern Math");
    assert_eq!(
        (bold_info.weight, bold_info.style),
        (700, FontStyle::Normal)
    );
}

#[test]
fn font_data_parses_with_ttf_parser_as_the_same_family() {
    let text = "Plain words.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let base = font_of(&engine, &project, text, "Plain").unwrap().font;
    for id in [
        base,
        engine.font_face(base, true, false).unwrap(),
        engine.font_face(base, false, true).unwrap(),
    ] {
        let font = engine.font(id).unwrap();
        let data = font.data().as_slice();
        let face = ttf_parser::Face::parse(data, font.index()).unwrap();
        let name = face
            .names()
            .into_iter()
            .filter(|n| {
                n.name_id == ttf_parser::name_id::TYPOGRAPHIC_FAMILY
                    || n.name_id == ttf_parser::name_id::FAMILY
            })
            .find_map(|n| n.to_string())
            .unwrap();
        assert!(name.starts_with("Libertinus Serif"), "{name}");
        // The same address on every call: the engine keeps the data.
        assert_eq!(
            engine.font(id).unwrap().data().as_slice().as_ptr(),
            data.as_ptr()
        );
    }
    assert!(engine.font(u32::MAX).is_none());
}

#[test]
fn a_cached_render_and_a_refresh_keep_the_same_font() {
    let text = "#set text(size: 12pt)\n\nA paragraph long enough to wrap onto a second line at this narrow measure of three hundred points.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = rendering_blocks(&engine, &path)[0];
    let first = engine.render(&path, block.start, block.end, 300.0).unwrap();
    let again = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(!first.cached && again.cached);
    assert!(first.rendered.text_font.is_some());
    assert_eq!(again.rendered.text_font, first.rendered.text_font);
    assert!(engine.refresh().ok);
    let other = Engine::new(prose_render::Options::new(&project.root, "main.typ")).unwrap();
    let fresh = other.render(&path, block.start, block.end, 300.0).unwrap();
    // A second engine scans the same fonts in the same order.
    assert_eq!(fresh.rendered.text_font, first.rendered.text_font);
    let after = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert_eq!(after.rendered.text_font, first.rendered.text_font);
}
