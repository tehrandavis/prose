//! The engine's Rust API: blocks, UTF-16 offsets, the cache, context from the
//! last good refresh, and errors.

mod common;

use common::{rendering_blocks, utf16_index, utf16_slice, Project};
use prose_render::{BlockKind, Engine, Options};

const NUMBERED: &str = "#set heading(numbering: \"1.\")\n#set text(size: 11pt)\n\n";

#[test]
fn context_and_include_lines_are_blocks_of_their_own() {
    let text = "#set text(size: 11pt)\n#let x = 1\n#import \"lib.typ\": f\n#show heading: set text(red)\n\n= Title\n\nA paragraph.\n#set par(justify: true)\nAnother.\n\n$ x + y $\n\n#include \"other.typ\"\n";
    let project = Project::new(&[
        ("main.typ", text),
        ("lib.typ", "#let f(x) = x\n"),
        ("other.typ", "Other.\n"),
    ]);
    let engine = project.engine();
    let blocks = engine.blocks(&project.path("main.typ")).unwrap();
    let shown: Vec<(String, BlockKind)> = blocks
        .iter()
        .map(|b| (utf16_slice(text, b.start, b.end), b.kind))
        .collect();
    let expected = [
        ("#set text(size: 11pt)", BlockKind::Context),
        ("#let x = 1", BlockKind::Context),
        ("#import \"lib.typ\": f", BlockKind::Context),
        ("#show heading: set text(red)", BlockKind::Context),
        ("= Title", BlockKind::Heading),
        ("A paragraph.", BlockKind::Paragraph),
        ("#set par(justify: true)", BlockKind::Context),
        ("Another.", BlockKind::Paragraph),
        ("$ x + y $", BlockKind::Equation),
        ("#include \"other.typ\"", BlockKind::Include),
    ];
    assert_eq!(
        shown,
        expected
            .iter()
            .map(|(t, k)| (t.to_string(), *k))
            .collect::<Vec<_>>()
    );
    // Context blocks are the context, and render with no ink; no rendering
    // block holds a context line.
    for block in blocks.iter().filter(|b| b.kind.renders()) {
        let body = utf16_slice(text, block.start, block.end);
        for line in ["#set", "#let", "#import", "#show", "#include"] {
            assert!(!body.contains(line), "{body:?} holds a context line");
        }
    }
    let path = project.path("main.typ");
    let first = engine
        .render(&path, blocks[0].start, blocks[0].end, 300.0)
        .unwrap();
    assert!(first.glyphs.is_empty());
}

#[test]
fn offsets_are_utf16_with_non_ascii_text() {
    let text =
        "这是中文段落 😀 with an emoji.\n\n= Überschrift 😀 Tötle\n\nDer Text: 漢字 und 🎉 Ende.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    assert!(engine.refresh().ok);
    let path = project.path("main.typ");
    let blocks = engine.blocks(&path).unwrap();
    assert_eq!(blocks.len(), 3);
    assert_eq!(
        utf16_slice(text, blocks[1].start, blocks[1].end).trim(),
        "= Überschrift 😀 Tötle"
    );
    assert_eq!(
        utf16_slice(text, blocks[2].start, blocks[2].end).trim(),
        "Der Text: 漢字 und 🎉 Ende."
    );

    for block in &blocks {
        let render = engine.render(&path, block.start, block.end, 300.0).unwrap();
        let typed: Vec<_> = render.glyphs.iter().filter(|g| g.source >= 0).collect();
        assert!(!typed.is_empty());
        for glyph in typed {
            let at = glyph.source as usize;
            assert!(
                (block.start..block.end).contains(&at),
                "{at} outside {block:?}"
            );
        }
    }

    // Specific characters after the emoji map to their own UTF-16 offsets.
    let last = engine
        .render(&path, blocks[2].start, blocks[2].end, 300.0)
        .unwrap();
    let sources: Vec<usize> = last
        .glyphs
        .iter()
        .filter(|g| g.source >= 0)
        .map(|g| g.source as usize)
        .collect();
    let ende = utf16_index(text, "Ende");
    let kanji = utf16_index(text, "漢字");
    assert!(sources.contains(&ende), "{ende} in {sources:?}");
    assert!(sources.contains(&kanji), "{kanji} in {sources:?}");
    assert!(
        sources.contains(&(kanji + 1)),
        "{} in {sources:?}",
        kanji + 1
    );
    let heading = engine
        .render(&path, blocks[1].start, blocks[1].end, 300.0)
        .unwrap();
    let tötle = utf16_index(text, "Tötle");
    assert!(heading.glyphs.iter().any(|g| g.source == tötle as i32));
    // A range inside a surrogate pair is rejected, not rounded.
    let emoji = utf16_index(text, "😀");
    assert!(engine
        .render(&path, emoji + 1, blocks[0].end, 300.0)
        .is_err());
}

#[test]
fn geometry_reports_ink_and_first_baseline() {
    let project = Project::new(&[("main.typ", "#set text(size: 11pt)\n\nA line of text\nthat wraps onto a second line because the measure is narrow.\n")]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = rendering_blocks(&engine, &path)[0];
    let render = engine.render(&path, block.start, block.end, 120.0).unwrap();
    let r = &render.rendered;
    assert_eq!(r.width, 120.0);
    assert!(r.height > 30.0, "wraps to several lines: {}", r.height);
    // Ink sits inside the page box, below the top margin.
    assert!(r.ink.x >= -0.01 && r.ink.y > 0.0, "{:?}", r.ink);
    assert!(r.ink.x + r.ink.width <= r.width + 0.01);
    assert!(
        r.ink.y + r.ink.height <= r.height + 0.01,
        "{:?} in {}",
        r.ink,
        r.height
    );
    // The first baseline is in the first line: below the ink's top, well
    // above the block's bottom.
    assert!(
        r.baseline > r.ink.y && r.baseline < r.ink.y + 11.0,
        "{} vs {:?}",
        r.baseline,
        r.ink
    );
    // Glyph boxes straddle the first baseline on the first line.
    let first = render.glyphs.iter().find(|g| g.source >= 0).unwrap();
    assert!((first.y as f64) < r.baseline && ((first.y + first.height) as f64) > r.baseline);
    assert!(r.svg.starts_with("<svg"));
}

#[test]
fn cache_hits_on_identical_render_and_misses_after_a_change() {
    let text = format!("{NUMBERED}= One\n\nA first paragraph.\n");
    let project = Project::new(&[("main.typ", &text)]);
    let engine = project.engine();
    assert!(engine.refresh().ok);
    let path = project.path("main.typ");
    let block = rendering_blocks(&engine, &path)[1];

    let first = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(!first.cached);
    let second = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(second.cached);
    assert!(std::sync::Arc::ptr_eq(&first.rendered, &second.rendered));
    let stats = engine.cache_stats();
    assert_eq!((stats.hits, stats.misses, stats.entries), (1, 1, 1));
    assert!(stats.bytes as usize >= first.rendered.svg.len());

    // Another width is another key.
    assert!(
        !engine
            .render(&path, block.start, block.end, 200.0)
            .unwrap()
            .cached
    );
    // Changing the block is another key.
    let edited = text.replace("A first paragraph.", "A changed paragraph.");
    engine.set_text(&path, &edited).unwrap();
    let block = rendering_blocks(&engine, &path)[1];
    let changed = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(!changed.cached);
    assert!(changed.rendered.text.contains("changed"));
    // Typing elsewhere in the file leaves the block's document, and its
    // cache entry, alone.
    let typed = edited.replace("= One", "= One more");
    engine.set_text(&path, &typed).unwrap();
    let block = rendering_blocks(&engine, &path)[1];
    assert!(
        engine
            .render(&path, block.start, block.end, 300.0)
            .unwrap()
            .cached
    );
    let stats = engine.cache_stats();
    assert_eq!((stats.hits, stats.misses), (2, 3));
}

#[test]
fn identical_blocks_share_an_entry_but_keep_their_own_offsets() {
    let text = "Same words.\n\nOther.\n\nSame words.";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let blocks = engine.blocks(&path).unwrap();
    let first = engine
        .render(&path, blocks[0].start, blocks[0].end, 300.0)
        .unwrap();
    let last = engine
        .render(&path, blocks[2].start, blocks[2].end, 300.0)
        .unwrap();
    assert!(last.cached);
    for (render, block) in [(&first, blocks[0]), (&last, blocks[2])] {
        let sources: Vec<i32> = render
            .glyphs
            .iter()
            .map(|g| g.source)
            .filter(|s| *s >= 0)
            .collect();
        assert_eq!(sources.first().copied(), Some(block.start as i32));
        assert!(sources
            .iter()
            .all(|s| (block.start as i32..block.end as i32).contains(s)));
    }
}

#[test]
fn cache_checks_imported_files() {
    let project = Project::new(&[
        (
            "main.typ",
            "#import \"lib.typ\": word\n\nThe word is #word.\n",
        ),
        ("lib.typ", "#let word = \"apple\"\n"),
    ]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let block = rendering_blocks(&engine, &path)[0];
    assert!(engine
        .render(&path, block.start, block.end, 300.0)
        .unwrap()
        .rendered
        .text
        .contains("apple"));
    engine
        .set_text(&project.path("lib.typ"), "#let word = \"pear\"\n")
        .unwrap();
    let render = engine.render(&path, block.start, block.end, 300.0).unwrap();
    assert!(!render.cached);
    assert!(render.rendered.text.contains("pear"));
}

#[test]
fn cache_stays_within_its_budget() {
    let mut text = String::new();
    for n in 0..40 {
        text.push_str(&format!(
            "Paragraph number {n} with some words to typeset.\n\n"
        ));
    }
    let project = Project::new(&[("main.typ", &text)]);
    let mut options = Options::new(&project.root, "main.typ");
    options.cache_budget = 64 * 1024;
    let engine = Engine::new(options).unwrap();
    let path = project.path("main.typ");
    for block in engine.blocks(&path).unwrap() {
        engine.render(&path, block.start, block.end, 300.0).unwrap();
    }
    let stats = engine.cache_stats();
    assert_eq!(stats.budget, 64 * 1024);
    assert!(stats.bytes <= stats.budget);
    assert!(stats.entries > 0 && stats.entries < 40, "{stats:?}");
}

#[test]
fn render_keeps_the_old_context_when_a_refresh_fails() {
    let text = format!("{NUMBERED}= One\n\nA paragraph.\n\n= Two <two>\n\nSee @two.\n");
    let project = Project::new(&[("main.typ", &text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let info = engine.refresh();
    assert!(info.ok);
    assert_eq!((info.headings, info.references), (2, 1));

    // A broken edit before the second heading, so its offset moves too.
    let broken = text.replace("A paragraph.", "A longer paragraph #unknown-function().");
    engine.set_text(&path, &broken).unwrap();
    let info = engine.refresh();
    assert!(!info.ok);
    assert!(info.errors > 0);
    assert!(info.message.is_some());
    assert_eq!(engine.last_error(), info.message);
    assert_eq!(
        (info.headings, info.references),
        (2, 1),
        "the old context is kept"
    );

    let blocks = rendering_blocks(&engine, &path);
    let shown: Vec<String> = blocks
        .iter()
        .filter(|b| !utf16_slice(&broken, b.start, b.end).contains("unknown"))
        .map(|b| {
            engine
                .render(&path, b.start, b.end, 300.0)
                .unwrap()
                .rendered
                .text
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect();
    assert_eq!(shown, ["1. One", "2. Two", "See Section 2 ."]);
}

#[test]
fn a_broken_block_returns_an_error() {
    let text = "Fine.\n\nBroken #unknown-function() here.\n\nAlso #(1 + ) broken.\n";
    let project = Project::new(&[("main.typ", text)]);
    let engine = project.engine();
    let path = project.path("main.typ");
    let blocks = engine.blocks(&path).unwrap();
    assert!(engine
        .render(&path, blocks[0].start, blocks[0].end, 300.0)
        .is_ok());
    let error = engine
        .render(&path, blocks[1].start, blocks[1].end, 300.0)
        .unwrap_err();
    assert!(error.contains("unknown"), "{error}");
    assert!(engine
        .render(&path, blocks[2].start, blocks[2].end, 300.0)
        .is_err());
    assert!(engine.last_error().is_some());
    // Bad input is an error too.
    assert!(engine.render(&path, 3, 3, 300.0).is_err());
    assert!(engine.render(&path, 0, 99_999, 300.0).is_err());
    assert!(engine
        .render(&path, blocks[0].start, blocks[0].end, f64::NAN)
        .is_err());
    assert!(engine
        .render(&path, blocks[0].start, blocks[0].end, 0.0)
        .is_err());
    assert!(engine
        .render(&project.path("missing.typ"), 0, 1, 300.0)
        .is_err());
    assert!(engine
        .blocks(std::path::Path::new("/elsewhere/outside.typ"))
        .is_err());
}

#[test]
fn included_files_use_the_main_files_context_and_numbering() {
    let project = Project::new(&[
        ("main.typ", "#set heading(numbering: \"1.\")\n#show \"say\": \"SAY\"\n\n= First\n\n#include \"part.typ\"\n"),
        ("part.typ", "= Second\n\nWe say it.\n"),
    ]);
    let engine = project.engine();
    assert!(engine.refresh().ok);
    let path = project.path("part.typ");
    let blocks = engine.blocks(&path).unwrap();
    let texts: Vec<String> = blocks
        .iter()
        .map(|b| {
            engine
                .render(&path, b.start, b.end, 300.0)
                .unwrap()
                .rendered
                .text
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect();
    assert_eq!(texts, ["2. Second", "We SAY it."]);
}

#[test]
fn set_text_accepts_a_file_not_yet_on_disk() {
    let project = Project::new(&[("main.typ", "Main.\n")]);
    let engine = project.engine();
    let path = project.path("draft.typ");
    assert!(!path.exists());
    engine.set_text(&path, "A draft.\n").unwrap();
    let block = engine.blocks(&path).unwrap()[0];
    assert!(engine
        .render(&path, block.start, block.end, 300.0)
        .unwrap()
        .rendered
        .text
        .contains("draft"));
    assert!(Engine::new(Options::new(project.root.join("nowhere"), "main.typ")).is_err());
    assert!(Engine::new(Options::new(&project.root, "/elsewhere/main.typ")).is_err());
}

#[test]
fn renders_and_refreshes_stay_correct_across_memo_evictions() {
    // Enough compiled renders for several of Typst's cache evictions, with a
    // refresh in between, so later renders and refreshes run on evicted caches.
    let mut text = String::from(NUMBERED);
    text.push_str("= Start <start>\n\n");
    for n in 0..300 {
        text.push_str(&format!("Paragraph {n}, after @start.\n\n"));
    }
    let project = Project::new(&[("main.typ", &text)]);
    let mut options = Options::new(&project.root, "main.typ");
    options.cache_budget = 64 * 1024;
    let engine = Engine::new(options).unwrap();
    let path = project.path("main.typ");
    assert!(engine.refresh().ok);
    let blocks = rendering_blocks(&engine, &path);
    assert_eq!(blocks.len(), 301);
    for (round, width) in [300.0, 280.0].into_iter().enumerate() {
        for (n, block) in blocks.iter().skip(1).enumerate() {
            let render = engine.render(&path, block.start, block.end, width).unwrap();
            assert!(!render.cached);
            let shown = render
                .rendered
                .text
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            assert_eq!(shown, format!("Paragraph {n}, after Section 1 ."));
        }
        let info = engine.refresh();
        assert!(info.ok, "round {round}: {:?}", info.message);
        assert_eq!((info.headings, info.references), (1, 1));
    }
    assert_eq!(engine.cache_stats().misses, 600);
}
