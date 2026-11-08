//! Measures per-block rendering on a real document through the engine's
//! Rust API. See docs/plans/2026-11-08-phase-2-engine-spike.md.
//!
//! render-spike <main.typ> [--width PT] [--sample N] [--budget MB] [--print] [--svg DIR]
//!
//! Each block is rendered twice in a row: the first render compiles it, the
//! second should come from the cache.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use prose_render::{BlockKind, Engine, Options};

fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn summary(label: &str, times: &mut [f64]) {
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "{label}: {} ok, median {:.3} ms, p95 {:.3} ms, max {:.1} ms",
        times.len(),
        percentile(times, 0.5),
        percentile(times, 0.95),
        times.last().copied().unwrap_or(0.0)
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let main_path = PathBuf::from(
        args.get(1)
            .expect("usage: render-spike <main.typ> [options]"),
    )
    .canonicalize()
    .expect("main file");
    let option = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let width: f64 = option("--width")
        .and_then(|v| v.parse().ok())
        .unwrap_or(450.0);
    let sample: usize = option("--sample")
        .and_then(|v| v.parse().ok())
        .unwrap_or(200);
    let print = args.iter().any(|a| a == "--print");
    let svg_dir = option("--svg").map(PathBuf::from);
    let root = main_path.parent().unwrap().to_path_buf();
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut options = Options::new(&root, &main_path);
    options.cache_budget = option("--budget")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0)
        * 1024
        * 1024;
    options.package_dirs.push(repo.join("Resources/Packages"));
    if let Some(home) = std::env::var_os("HOME") {
        options
            .package_dirs
            .push(PathBuf::from(home).join("Library/Caches/typst/packages"));
    }

    let start = Instant::now();
    let engine = Engine::new(options).expect("engine");
    println!("engine created: {:.0} ms", ms(start));

    let start = Instant::now();
    let info = engine.refresh();
    if !info.ok {
        println!("full compile error: {}", info.message.unwrap_or_default());
        std::process::exit(1);
    }
    println!(
        "refresh, cold: {:.0} ms, {} pages, {} headings, {} block equations, {} references",
        ms(start),
        info.pages,
        info.headings,
        info.equations,
        info.references
    );

    // An edit in the middle of the main file, then a full refresh.
    let main_text = engine.text(&main_path).expect("main text");
    let main_blocks = engine.blocks(&main_path).expect("main blocks");
    let paragraphs: Vec<_> = main_blocks
        .iter()
        .filter(|b| b.kind == BlockKind::Paragraph)
        .collect();
    if let Some(block) = paragraphs.get(paragraphs.len() / 2) {
        let mut utf16 = 0;
        let at = main_text
            .char_indices()
            .find(|(_, c)| {
                let here = utf16 >= block.start;
                utf16 += c.len_utf16();
                here
            })
            .map_or(main_text.len(), |(i, _)| i);
        let mut edited = main_text.clone();
        edited.insert_str(at, "Edited ");
        for round in 1..=2 {
            engine.set_text(&main_path, &edited).unwrap();
            let start = Instant::now();
            let ok = engine.refresh().ok;
            println!(
                "refresh after a one-paragraph edit ({round}): {:.0} ms, ok {ok}",
                ms(start)
            );
            edited.insert(at, 'x');
        }
        engine.set_text(&main_path, &main_text).unwrap();
        engine.refresh();
    }

    // Files: the main file and the files it includes directly.
    let mut files = vec![main_path.clone()];
    for line in main_text.lines() {
        if let Some(rest) = line.trim().strip_prefix("#include \"") {
            if let Some(path) = rest.split('"').next() {
                files.push(root.join(path));
            }
        }
    }
    let mut all = Vec::new();
    for (index, path) in files.iter().enumerate() {
        for block in engine.blocks(path).expect("blocks") {
            all.push((index, block));
        }
    }
    let step = (all.len() / sample.max(1)).max(1);
    let chosen: Vec<_> = all.iter().step_by(step).take(sample).collect();
    println!(
        "blocks: {} in {} files, rendering {}",
        all.len(),
        files.len(),
        chosen.len()
    );

    let mut times = Vec::new();
    let mut repeats = Vec::new();
    let mut repeat_hits = 0usize;
    let mut by_kind: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut failures: BTreeMap<String, usize> = BTreeMap::new();
    let (mut text_glyphs, mut mapped, mut generated) = (0usize, 0usize, 0usize);
    let mut svg_bytes = 0usize;
    for (n, (index, block)) in chosen.iter().enumerate() {
        let path = &files[*index];
        let start = Instant::now();
        match engine.render(path, block.start, block.end, width) {
            Ok(render) => {
                let elapsed = ms(start);
                let rendered = &render.rendered;
                if elapsed > 50.0 {
                    let head: String = rendered.text.chars().take(90).collect();
                    println!(
                        "  slow block {:.0} ms, {} UTF-16 units: {}",
                        elapsed,
                        block.end - block.start,
                        head.trim()
                    );
                }
                times.push(elapsed);
                by_kind
                    .entry(format!("{:?}", block.kind))
                    .or_default()
                    .push(elapsed);
                svg_bytes += rendered.svg.len();
                for glyph in &render.glyphs {
                    if glyph.source < 0 {
                        generated += 1;
                    } else {
                        text_glyphs += 1;
                        let at = glyph.source as usize;
                        if at >= block.start && at < block.end {
                            mapped += 1;
                        }
                    }
                }
                if print {
                    println!(
                        "  {:?} {:.1} ms: {}",
                        block.kind,
                        elapsed,
                        rendered.text.trim()
                    );
                }
                if let Some(dir) = &svg_dir {
                    std::fs::create_dir_all(dir).ok();
                    std::fs::write(dir.join(format!("block-{n:04}.svg")), &rendered.svg).ok();
                }
                let start = Instant::now();
                if let Ok(again) = engine.render(path, block.start, block.end, width) {
                    repeats.push(ms(start));
                    repeat_hits += again.cached as usize;
                }
            }
            Err(message) => {
                let key: String = message.chars().take(70).collect();
                *failures.entry(key).or_default() += 1;
                if print {
                    println!("  FAILED {:?}: {message}", block.kind);
                }
            }
        }
    }
    let ok = times.len();
    summary("block render, first", &mut times);
    for (kind, mut list) in by_kind {
        summary(&format!("  {kind}"), &mut list);
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
    println!(
        "svg: {:.1} KB per block on average",
        svg_bytes as f64 / 1024.0 / ok.max(1) as f64
    );

    summary("block render, repeated (cache)", &mut repeats);
    let stats = engine.cache_stats();
    println!(
        "cache: {repeat_hits} of {} repeats were hits; {} entries, {:.1} MB of {:.0} MB, {} hits, {} misses",
        repeats.len(),
        stats.entries,
        stats.bytes as f64 / 1024.0 / 1024.0,
        stats.budget as f64 / 1024.0 / 1024.0,
        stats.hits,
        stats.misses
    );
}
