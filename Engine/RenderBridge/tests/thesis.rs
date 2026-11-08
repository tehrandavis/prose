//! The thesis fixture: numbering and references in blocks rendered alone must
//! match the full document.

use std::path::PathBuf;

use prose_render::{BlockKind, Engine, Options};

#[test]
fn blocks_render_alone_with_the_full_documents_numbers_and_references() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/thesis");
    let engine = Engine::new(Options::new(&root, "main.typ")).unwrap();
    let info = engine.refresh();
    assert!(info.ok, "{:?}", info.message);
    assert_eq!(info.headings, 7);
    assert_eq!(info.equations, 3);
    assert_eq!(
        engine.reference_text("method").as_deref(),
        Some("Section\u{a0}2")
    );

    let mut shown = Vec::new();
    for path in [root.join("main.typ"), root.join("sections/method.typ")] {
        for block in engine.blocks(&path).unwrap() {
            let render = engine
                .render(&path, block.start, block.end, 450.0)
                .unwrap_or_else(|message| panic!("{:?}: {message}", block.kind));
            let rendered = &render.rendered;
            for glyph in render.glyphs.iter().filter(|g| g.source >= 0) {
                let at = glyph.source as usize;
                assert!(
                    (block.start..block.end).contains(&at),
                    "{at} outside {block:?}"
                );
            }
            if block.kind != BlockKind::Paragraph
                || rendered.text.contains("Section")
                || rendered.text.contains("Equation")
            {
                shown.push(
                    rendered
                        .text
                        .split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" "),
                );
            }
        }
    }
    let expected = [
        "1 Introduction",
        "Perception and action are coupled. We return to this in Section 2 .",
        "(1)",
        "3 Results",
        "Section 2.2.2",
        "(3)",
        "2 Method",
        "2.1 Participants",
        "2.2 Procedure",
        "2.2.1 Apparatus",
        "2.2.2 Adaptive staircase",
        "(2)",
        "Equation 1 and Equation 2",
    ];
    for (shown, expected) in shown.iter().zip(expected) {
        assert!(
            shown.contains(expected),
            "{shown:?} should contain {expected:?}"
        );
    }
    assert_eq!(shown.len(), expected.len());
}
