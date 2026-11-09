//! Files changed on disk (Phase 5 step A): `files_changed` makes the engine
//! read them again, and citations render with the whole document's texts.

mod common;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use common::{rendering_blocks, Project};
use prose_render::{Engine, Options};

const DOCUMENT: &str = "#set heading(numbering: \"1.\")\n= Intro\n\nSee @a here.\n\nAnd @b there.\n\nNo citation.\n\n= Sources\n\n#bibliography(\"refs.bib\", style: \"ieee\")\n";
const OLD_BIB: &str = "@book{a, title={Old Title}, author={Writer, Ann}, year={2020}}\n";
const NEW_BIB: &str = "@book{a, title={New Title}, author={Writer, Ann}, year={2020}}\n@book{b, title={Bee Book}, author={Bee, Bob}, year={2021}}\n";

/// The text of each rendering block of the main file, whitespace collapsed,
/// and whether it came from the cache.
fn texts(engine: &Engine, project: &Project) -> Vec<(String, bool)> {
    let path = project.path("main.typ");
    rendering_blocks(engine, &path)
        .iter()
        .map(|block| {
            let render = engine.render(&path, block.start, block.end, 400.0).unwrap();
            let text = render
                .rendered
                .text
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            (text, render.cached)
        })
        .collect()
}

fn bibliography_text(texts: &[(String, bool)]) -> &str {
    &texts.last().unwrap().0
}

#[test]
fn without_files_changed_a_bibliography_read_once_stays_as_it_was() {
    let project = Project::new(&[("main.typ", DOCUMENT), ("refs.bib", OLD_BIB)]);
    let engine = project.engine();
    // `b` is not in the file yet: the compile fails.
    assert!(!engine.refresh().ok);
    std::fs::write(project.path("refs.bib"), NEW_BIB).unwrap();
    let info = engine.refresh();
    assert!(
        !info.ok,
        "the engine read the file again without being told"
    );
    assert!(info.message.unwrap().contains("<b>"));
}

#[test]
fn a_changed_bibliography_reaches_citations_and_the_bibliography_block() {
    let project = Project::new(&[("main.typ", DOCUMENT), ("refs.bib", OLD_BIB)]);
    let engine = project.engine();
    assert!(!engine.refresh().ok);
    let before = texts(&engine, &project);
    assert_eq!(before[1].0, "See ?? here.");

    std::fs::write(project.path("refs.bib"), NEW_BIB).unwrap();
    assert_eq!(engine.files_changed(&[project.path("refs.bib")]), 1);
    let info = engine.refresh();
    assert!(info.ok, "{:?}", info.message);
    let after = texts(&engine, &project);
    assert_eq!(after[1].0, "See [1] here.");
    assert_eq!(after[2].0, "And [2] there.");
    assert_eq!(after[3].0, "No citation.");
    assert_eq!(
        bibliography_text(&after),
        "Bibliography [1] A. Writer, New Title . 2020. [2] B. Bee, Bee Book . 2021."
    );

    // A new title for a cited entry: the bibliography block and the blocks
    // that cite read the file, so they compile again; the others hit.
    std::fs::write(
        project.path("refs.bib"),
        NEW_BIB.replace("New Title", "Newer Title"),
    )
    .unwrap();
    assert_eq!(engine.files_changed(&[project.path("refs.bib")]), 1);
    assert!(engine.refresh().ok);
    let again = texts(&engine, &project);
    assert!(bibliography_text(&again).contains("Newer Title"));
    assert!(
        !again.last().unwrap().1,
        "the bibliography block came from the cache"
    );
    assert!(
        !again[1].1 && !again[2].1,
        "a citing block came from the cache"
    );
    assert!(
        again[3].1,
        "a block that reads no bibliography compiled again"
    );
}

#[test]
fn a_bibliography_replaced_by_a_rename_is_read_again() {
    let project = Project::new(&[("main.typ", DOCUMENT), ("refs.bib", OLD_BIB)]);
    let engine = project.engine();
    assert!(!engine.refresh().ok);
    let temporary = project.path(".refs.bib.tmp");
    std::fs::write(&temporary, NEW_BIB).unwrap();
    std::fs::rename(&temporary, project.path("refs.bib")).unwrap();
    assert_eq!(
        engine.files_changed(&[temporary, project.path("refs.bib")]),
        1
    );
    assert!(engine.refresh().ok);
    assert!(bibliography_text(&texts(&engine, &project)).contains("Bee Book"));
}

#[test]
fn files_the_document_does_not_read_and_paths_outside_the_project_count_for_nothing() {
    let project = Project::new(&[
        ("main.typ", "A paragraph with #read(\"data.txt\").\n"),
        ("data.txt", "old data"),
        ("notes.txt", "unrelated"),
    ]);
    let engine = project.engine();
    assert!(engine.refresh().ok);
    let first = texts(&engine, &project);
    assert_eq!(first[0].0, "A paragraph with old data.");

    std::fs::write(project.path("notes.txt"), "changed").unwrap();
    let outside = std::env::temp_dir().join("prose-outside.bib");
    assert_eq!(
        engine.files_changed(&[project.path("notes.txt"), outside]),
        0
    );
    assert_eq!(engine.files_changed(&[]), 0);
    let unchanged = texts(&engine, &project);
    assert!(
        unchanged[0].1,
        "an unrelated change made a block compile again"
    );

    std::fs::write(project.path("data.txt"), "new data").unwrap();
    assert_eq!(engine.files_changed(&[project.path("data.txt")]), 1);
    let changed = texts(&engine, &project);
    assert_eq!(
        changed[0],
        ("A paragraph with new data.".to_string(), false)
    );
}

#[test]
fn editor_buffers_keep_winning_over_the_disk() {
    let project = Project::new(&[
        ("main.typ", "#include \"chapter.typ\"\n"),
        ("chapter.typ", "From disk.\n"),
    ]);
    let engine = project.engine();
    engine
        .set_text(&project.path("chapter.typ"), "From the editor.\n")
        .unwrap();
    assert!(engine.refresh().ok);
    std::fs::write(project.path("chapter.typ"), "Changed on disk.\n").unwrap();
    assert_eq!(engine.files_changed(&[project.path("chapter.typ")]), 1);
    assert!(engine.refresh().ok);
    assert_eq!(
        engine.text(&project.path("chapter.typ")).unwrap(),
        "From the editor.\n"
    );
}

/// Acceptance test 10 of the citations note: `files_changed` on SICP, and
/// what reading every file again adds to the next refresh. Skipped when the
/// book is not in the checkout.
#[test]
fn files_changed_on_a_book_is_cheap() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Examples/Books/SICP");
    if !root.join("main.typ").exists() {
        return;
    }
    let engine = Engine::new(Options::new(&root, "main.typ")).unwrap();
    assert!(engine.refresh().ok);
    let warm = |engine: &Engine| {
        let start = Instant::now();
        assert!(engine.refresh().ok);
        start.elapsed()
    };
    warm(&engine);
    let unchanged = warm(&engine);
    let figure = root.join("fig/chap1/Fig1.1g.std.svg");
    let start = Instant::now();
    assert_eq!(engine.files_changed(&[figure]), 1);
    let call = start.elapsed();
    let reloaded = warm(&engine);
    let extra = reloaded.saturating_sub(unchanged);
    eprintln!(
        "SICP files_changed: call {:.2} ms; refresh {:.1} ms after it, {:.1} ms unchanged",
        call.as_secs_f64() * 1000.0,
        reloaded.as_secs_f64() * 1000.0,
        unchanged.as_secs_f64() * 1000.0,
    );
    assert!(
        call < Duration::from_millis(50),
        "files_changed took {call:?}"
    );
    assert!(
        call + extra < Duration::from_millis(250),
        "reading the files again added {extra:?} to the refresh"
    );
}
