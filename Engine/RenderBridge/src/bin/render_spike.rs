//! Measures per-block rendering on a real document. See
//! docs/plans/2026-11-08-phase-2-engine-spike.md.
//!
//! render-spike <main.typ> [--width PT] [--sample N] [--print] [--svg DIR]

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use prose_render::{block_document, reference_texts, render, split, BlockKind, Counters, Engine, PROBE};

fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let main_path = PathBuf::from(args.get(1).expect("usage: render-spike <main.typ> [options]"));
    let option = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let width: f64 = option("--width").and_then(|v| v.parse().ok()).unwrap_or(450.0);
    let sample: usize = option("--sample").and_then(|v| v.parse().ok()).unwrap_or(200);
    let print = args.iter().any(|a| a == "--print");
    let svg_dir = option("--svg").map(PathBuf::from);
    let root = main_path.parent().unwrap().to_path_buf();
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut package_dirs = vec![repo.join("Resources/Packages")];
    if let Some(home) = std::env::var_os("HOME") {
        package_dirs.push(PathBuf::from(home).join("Library/Caches/typst/packages"));
    }

    let start = Instant::now();
    let engine = Engine::new(&root, &main_path, &package_dirs).expect("engine");
    println!("engine created: {:.0} ms", ms(start));

    let main = engine.main();
    let main_text = engine.text(main).expect("main text");
    engine.set_text(main, format!("{main_text}\n{PROBE}"));
    let start = Instant::now();
    let document = match engine.compile(main) {
        Ok(doc) => doc,
        Err(errors) => {
            for e in errors.iter().take(5) {
                let at = engine.diagnostic_range(e);
                println!("full compile error: {} at {:?}", e.message, at);
            }
            std::process::exit(1);
        }
    };
    println!("full compile, cold: {:.0} ms, {} pages", ms(start), document.pages().len());
    let start = Instant::now();
    let counters = Counters::read(&engine, &document);
    println!(
        "counters read: {:.1} ms, {} headings, {} block equations",
        ms(start),
        counters.headings.len(),
        counters.equations.len()
    );

    let start = Instant::now();
    let references = reference_texts(&document);
    println!("reference texts read: {:.0} ms, {} references", ms(start), references.len());

    // An edit in the middle of the main file, then a full recompile.
    let main_outline = split(&main_text);
    if let Some(block) = main_outline.blocks.iter().filter(|b| b.kind == BlockKind::Paragraph).nth(
        main_outline.blocks.iter().filter(|b| b.kind == BlockKind::Paragraph).count() / 2,
    ) {
        let mut edited = main_text.clone();
        edited.insert_str(block.range.start, "Edited ");
        for round in 1..=2 {
            engine.set_text(main, format!("{edited}\n{PROBE}"));
            let start = Instant::now();
            let ok = engine.compile(main).is_ok();
            println!("full compile after a one-paragraph edit ({round}): {:.0} ms, ok {ok}", ms(start));
            edited.insert_str(block.range.start, "x");
        }
        engine.set_text(main, format!("{main_text}\n{PROBE}"));
        let _ = engine.compile(main);
    }

    // Files: the main file and the files it includes directly.
    let mut files = vec![(main, main_text.clone())];
    for line in main_text.lines() {
        if let Some(rest) = line.trim().strip_prefix("#include \"") {
            if let Some(path) = rest.split('"').next() {
                if let Ok(id) = engine.id(&root.join(path)) {
                    files.push((id, engine.text(id).unwrap_or_default()));
                }
            }
        }
    }
    let mut all = Vec::new();
    for (index, (id, text)) in files.iter().enumerate() {
        let outline = split(text);
        for block in outline.blocks.clone() {
            all.push((index, *id, block));
        }
    }
    let step = (all.len() / sample.max(1)).max(1);
    let chosen: Vec<_> = all.iter().step_by(step).take(sample).collect();
    println!("blocks: {} in {} files, rendering {}", all.len(), files.len(), chosen.len());

    let outlines: Vec<_> = files.iter().map(|(_, text)| split(text)).collect();
    let mut times = Vec::new();
    let mut by_kind: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut failures: BTreeMap<String, usize> = BTreeMap::new();
    let (mut text_glyphs, mut mapped, mut generated) = (0usize, 0usize, 0usize);
    let mut svg_bytes = 0usize;
    for (n, (index, id, block)) in chosen.iter().enumerate() {
        let (_, file_text) = &files[*index];
        let block_id = engine.sibling(*id, "__prose_block__.typ");
        let main_context = (*index != 0).then(|| (main_text.as_str(), &outlines[0]));
        let (doc, prefix) =
            block_document(&engine, *id, file_text, &outlines[*index], main_context, block, &counters, &references, width);
        let start = Instant::now();
        match render(&engine, block_id, doc, prefix, block.range.start) {
            Ok(rendered) => {
                let elapsed = ms(start);
                if elapsed > 50.0 {
                    let head: String = file_text[block.range.clone()].chars().take(90).collect();
                    println!("  slow block {:.0} ms, {} bytes: {}", elapsed, block.range.len(), head.replace('\n', " "));
                }
                times.push(elapsed);
                by_kind.entry(format!("{:?}", block.kind)).or_default().push(elapsed);
                svg_bytes += rendered.svg.len();
                for glyph in &rendered.glyphs {
                    if glyph.generated {
                        generated += 1;
                    } else {
                        text_glyphs += 1;
                        if glyph.source.is_some_and(|s| s >= block.range.start && s < block.range.end) {
                            mapped += 1;
                        }
                    }
                }
                if print {
                    println!("  {:?} {:.1} ms: {}", block.kind, elapsed, rendered.text.trim());
                }
                if let Some(dir) = &svg_dir {
                    std::fs::create_dir_all(dir).ok();
                    std::fs::write(dir.join(format!("block-{n:04}.svg")), &rendered.svg).ok();
                }
            }
            Err(errors) => {
                let message = errors.first().map(|e| e.message.to_string()).unwrap_or_else(|| "no page".into());
                let key: String = message.chars().take(70).collect();
                *failures.entry(key).or_default() += 1;
                if print {
                    println!("  FAILED {:?}: {message}", block.kind);
                }
            }
        }
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "block render: {} ok, median {:.1} ms, p95 {:.1} ms, max {:.1} ms",
        times.len(),
        percentile(&times, 0.5),
        percentile(&times, 0.95),
        times.last().copied().unwrap_or(0.0)
    );
    for (kind, mut list) in by_kind {
        list.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("  {kind}: {} blocks, median {:.1} ms, p95 {:.1} ms", list.len(), percentile(&list, 0.5), percentile(&list, 0.95));
    }
    println!("block failures: {}", failures.values().sum::<usize>());
    for (message, count) in &failures {
        println!("  {count} × {message}");
    }
    println!(
        "glyphs: {} from source, {:.1} percent map into their block; {} generated (numbers, markers)",
        text_glyphs,
        100.0 * mapped as f64 / text_glyphs.max(1) as f64,
        generated
    );
    println!("svg: {:.1} KB per block on average", svg_bytes as f64 / 1024.0 / times.len().max(1) as f64);
}
