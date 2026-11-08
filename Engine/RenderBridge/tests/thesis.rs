//! The thesis fixture: numbering and references in blocks rendered alone must
//! match the full document.

use std::path::PathBuf;

use prose_render::{block_document, reference_texts, render, split, BlockKind, Counters, Engine, PROBE};

#[test]
fn blocks_render_alone_with_the_full_documents_numbers_and_references() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/thesis");
    let engine = Engine::new(&root, &root.join("main.typ"), &[]).unwrap();
    let main = engine.main();
    let main_text = engine.text(main).unwrap();
    engine.set_text(main, format!("{main_text}\n{PROBE}"));
    let document = engine.compile(main).unwrap();
    let counters = Counters::read(&engine, &document);
    assert_eq!(counters.headings.len(), 7);
    assert_eq!(counters.equations.len(), 3);
    let references = reference_texts(&document);
    assert_eq!(references.get("method").map(String::as_str), Some("Section\u{a0}2"));

    let method_id = engine.id(&root.join("sections/method.typ")).unwrap();
    let method_text = engine.text(method_id).unwrap();
    let main_outline = split(&main_text);
    let mut shown = Vec::new();
    for (id, text, context) in [(main, &main_text, None), (method_id, &method_text, Some((main_text.as_str(), &main_outline)))] {
        let outline = split(text);
        for block in &outline.blocks {
            let (doc, prefix) = block_document(&engine, id, text, &outline, context, block, &counters, &references, 450.0);
            let rendered = render(&engine, engine.sibling(id, "__prose_block__.typ"), doc, prefix, block.range.start)
                .unwrap_or_else(|errors| panic!("{:?}: {}", block.kind, errors[0].message));
            for glyph in rendered.glyphs.iter().filter(|g| !g.generated) {
                let at = glyph.source.expect("every typed glyph maps to the source");
                assert!(block.range.contains(&at));
            }
            if block.kind != BlockKind::Paragraph || rendered.text.contains("Section") || rendered.text.contains("Equation") {
                shown.push(rendered.text.split_whitespace().collect::<Vec<_>>().join(" "));
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
        assert!(shown.contains(expected), "{shown:?} should contain {expected:?}");
    }
    assert_eq!(shown.len(), expected.len());
}
