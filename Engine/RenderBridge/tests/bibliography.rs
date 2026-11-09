//! The bibliography index (Phase 5 step B, acceptance test 4): entries of
//! BibLaTeX and Hayagriva files, parsed as Typst parses them, and the files
//! the project's `bibliography(...)` calls name.

mod common;

use std::fmt::Write as _;
use std::time::Instant;

use common::Project;
use prose_render::{BibAuthor, BibEntry, BibIndex, Engine};

const BIB: &str = r#"% A comment line before the entries.
@article{smith2020,
  author = {Smith, John and van Gogh, Vincent and Doe, Jr., Jane},
  title = {{The} Shape of Things},
  journal = {Journal of Shapes},
  year = {2020},
  doi = {10.1000/shape.2020},
  url = {https://example.org/shape},
}

@book{ostrom1990,
  editor = {Ostrom, Elinor},
  title = {Governing the Commons},
  publisher = {Cambridge University Press},
  date = {1990-11},
}

@inproceedings{lee2019,
  author = {Lee, Kim},
  title = {Proceedings Paper},
  booktitle = {Proceedings of Things},
  year = {2019},
}
"#;

const YAML: &str = r#"muller2018:
  type: article
  title: Über Bäume
  author: ["Müller, Jürgen", "Åberg, Lena"]
  date: 2018-03
  serial-number:
    doi: 10.1000/trees
  url: https://example.org/trees
  parent:
    type: periodical
    title: Forest Letters

"web2021":
  type: web
  title: A Web Page
  date: 2021
"#;

fn engine(project: &Project) -> Engine {
    project.engine()
}

fn index(engine: &Engine, files: &[&str]) -> BibIndex {
    let paths: Vec<_> = files.iter().map(std::path::PathBuf::from).collect();
    engine.bibliography(&paths)
}

fn find<'a>(index: &'a BibIndex, key: &str) -> &'a BibEntry {
    index
        .entries
        .iter()
        .find(|e| e.key == key)
        .unwrap_or_else(|| panic!("{key} missing from {:?}", index.entries))
}

fn author(family: &str, given: Option<&str>) -> BibAuthor {
    BibAuthor {
        family: family.into(),
        given: given.map(Into::into),
    }
}

#[test]
fn biblatex_entries_carry_every_field() {
    let project = Project::new(&[("main.typ", "Hello\n"), ("refs.bib", BIB)]);
    let index = index(&engine(&project), &["refs.bib"]);
    assert!(index.errors.is_empty(), "{:?}", index.errors);
    assert_eq!(
        index
            .entries
            .iter()
            .map(|e| e.key.as_str())
            .collect::<Vec<_>>(),
        ["smith2020", "ostrom1990", "lee2019"]
    );
    let smith = find(&index, "smith2020");
    assert_eq!(
        smith,
        &BibEntry {
            key: "smith2020".into(),
            kind: "article".into(),
            title: Some("The Shape of Things".into()),
            authors: vec![
                author("Smith", Some("John")),
                author("van Gogh", Some("Vincent")),
                author("Doe", Some("Jane, Jr.")),
            ],
            year: Some(2020),
            container: Some("Journal of Shapes".into()),
            doi: Some("10.1000/shape.2020".into()),
            url: Some("https://example.org/shape".into()),
            file: "refs.bib".into(),
            line: 2,
        }
    );
    // An edited book lists its editors; a date gives the year.
    let ostrom = find(&index, "ostrom1990");
    assert_eq!(ostrom.kind, "book");
    assert_eq!(ostrom.authors, vec![author("Ostrom", Some("Elinor"))]);
    assert_eq!(ostrom.year, Some(1990));
    assert_eq!(ostrom.container, None);
    assert_eq!(ostrom.line, 11);
    // Hayagriva's mapping: a paper in proceedings is an article in a
    // proceedings parent.
    let lee = find(&index, "lee2019");
    assert_eq!(lee.kind, "article");
    assert_eq!(lee.container.as_deref(), Some("Proceedings of Things"));
    assert_eq!(index.files.len(), 1);
    assert!(index.files[0].accepted);
    assert_eq!(index.files[0].entries, 3);
}

#[test]
fn hayagriva_yaml_entries_carry_every_field() {
    let project = Project::new(&[("main.typ", "Hello\n"), ("refs.yml", YAML)]);
    let index = index(&engine(&project), &["refs.yml"]);
    assert!(index.errors.is_empty(), "{:?}", index.errors);
    let muller = find(&index, "muller2018");
    assert_eq!(
        muller,
        &BibEntry {
            key: "muller2018".into(),
            kind: "article".into(),
            title: Some("Über Bäume".into()),
            authors: vec![
                author("Müller", Some("Jürgen")),
                author("Åberg", Some("Lena"))
            ],
            year: Some(2018),
            container: Some("Forest Letters".into()),
            doi: Some("10.1000/trees".into()),
            url: Some("https://example.org/trees".into()),
            file: "refs.yml".into(),
            line: 1,
        }
    );
    let web = find(&index, "web2021");
    assert_eq!(web.kind, "web");
    assert!(web.authors.is_empty());
    assert_eq!(web.line, 13);
}

#[test]
fn both_formats_together_and_keys_typst_accepts() {
    let main = "See @smith2020 and @muller2018.\n\n#bibliography((\"refs.bib\", \"refs.yml\"))\n";
    let project = Project::new(&[("main.typ", main), ("refs.bib", BIB), ("refs.yml", YAML)]);
    let engine = engine(&project);
    let files = engine.bibliography_files();
    assert_eq!(files, ["refs.bib", "refs.yml"]);
    let paths: Vec<_> = files.iter().map(std::path::PathBuf::from).collect();
    let index = engine.bibliography(&paths);
    assert_eq!(index.entries.len(), 5);
    assert!(index.files.iter().all(|f| f.accepted));
    // Typst accepts both files and every key the index lists.
    let all: String = index
        .entries
        .iter()
        .map(|e| format!("@{} ", e.key))
        .collect();
    engine
        .set_text(
            &project.path("main.typ"),
            &format!("{all}\n\n#bibliography((\"refs.bib\", \"refs.yml\"))\n"),
        )
        .unwrap();
    let info = engine.refresh();
    assert!(info.ok, "{:?}", info.message);
}

/// What Hayagriva does with a malformed entry, reported as it is.
#[test]
fn a_malformed_entry_is_reported_with_file_and_line() {
    // A field Hayagriva cannot convert: Typst rejects the whole file, the
    // index keeps the other entries and marks the file not accepted.
    let bad_field = "@book{good1, title={Good One}, author={A, B}, year={2001}}\n\n@book{bad,\n  title={Bad},\n  year={not a year},\n}\n\n@book{good2, title={Good Two}, year={2002}}\n";
    // A syntax error stops the BibLaTeX parser: no entries from that file.
    let bad_syntax =
        "@book{fine, title={Fine}, year={2000}}\n\n@book{broken,\n  title = {Unclosed,\n";
    let project = Project::new(&[
        ("main.typ", "#bibliography(\"field.bib\")\n@good1\n"),
        ("field.bib", bad_field),
        ("syntax.bib", bad_syntax),
        ("good.yml", YAML),
    ]);
    let engine = engine(&project);
    let index = index(&engine, &["field.bib", "syntax.bib", "good.yml"]);

    let keys: Vec<_> = index.entries.iter().map(|e| e.key.as_str()).collect();
    assert_eq!(keys, ["good1", "good2", "muller2018", "web2021"]);
    assert_eq!(index.errors.len(), 2, "{:?}", index.errors);
    let field = &index.errors[0];
    assert_eq!(field.file, "field.bib");
    assert_eq!(field.line, 5, "{field:?}");
    assert!(field.message.contains("entry bad"), "{}", field.message);
    let syntax = &index.errors[1];
    assert_eq!(syntax.file, "syntax.bib");
    assert!(
        syntax.message.starts_with("failed to parse BibLaTeX"),
        "{}",
        syntax.message
    );
    assert!(syntax.line >= 3, "{syntax:?}");
    let accepted: Vec<_> = index
        .files
        .iter()
        .map(|f| (f.path.as_str(), f.accepted, f.entries))
        .collect();
    assert_eq!(
        accepted,
        [
            ("field.bib", false, 2),
            ("syntax.bib", false, 0),
            ("good.yml", true, 2)
        ]
    );
    // Typst indeed rejects field.bib as a whole.
    assert!(!engine.refresh().ok);

    // Malformed YAML: one error with its line, no entries.
    let project = Project::new(&[
        ("main.typ", "Hello\n"),
        ("bad.yaml", "ok:\n  type: book\n  title: Fine\nbroken: [\n"),
        ("notes.txt", "x"),
    ]);
    let index = self::index(&project.engine(), &["bad.yaml", "missing.bib", "notes.txt"]);
    assert!(index.entries.is_empty());
    assert_eq!(index.errors.len(), 3, "{:?}", index.errors);
    assert_eq!(index.errors[0].file, "bad.yaml");
    assert!(index.errors[0].line >= 4, "{:?}", index.errors[0]);
    assert_eq!(
        (index.errors[1].file.as_str(), index.errors[1].line),
        ("missing.bib", 0)
    );
    assert_eq!(index.errors[1].message, "file not found");
    assert!(index.errors[2]
        .message
        .contains("unknown bibliography format"));
}

#[test]
fn a_key_in_two_files_is_listed_once_and_reported() {
    let project = Project::new(&[
        ("main.typ", "Hello\n"),
        ("a.bib", "@book{same, title={First}}\n"),
        (
            "b.bib",
            "@book{other, title={Other}}\n\n@book{same, title={Second}}\n",
        ),
    ]);
    let index = index(&project.engine(), &["a.bib", "b.bib"]);
    assert_eq!(index.entries.len(), 2);
    assert_eq!(find(&index, "same").title.as_deref(), Some("First"));
    assert_eq!(index.errors.len(), 1);
    assert_eq!(index.errors[0].file, "b.bib");
    assert_eq!(index.errors[0].line, 3);
    assert!(index.errors[0].message.contains("duplicate"));
    assert!(index.files[0].accepted && !index.files[1].accepted);
}

#[test]
fn files_changed_reparses_and_an_unchanged_file_is_cached() {
    let project = Project::new(&[
        ("main.typ", "Hello\n"),
        ("refs.bib", "@book{a, title={A}}\n"),
        ("other.yml", YAML),
    ]);
    let engine = engine(&project);
    let first = index(&engine, &["refs.bib", "other.yml"]);
    assert_eq!(first.entries.len(), 3);

    // On disk but not reported: the engine still serves what it read.
    std::fs::write(
        project.path("refs.bib"),
        "@book{a, title={A}}\n@book{b, title={B}}\n",
    )
    .unwrap();
    assert_eq!(index(&engine, &["refs.bib", "other.yml"]), first);

    engine.files_changed(&[project.path("refs.bib")]);
    let second = index(&engine, &["refs.bib", "other.yml"]);
    assert_eq!(second.entries.len(), 4);
    assert_eq!(find(&second, "b").title.as_deref(), Some("B"));

    // other.yml was not reported: its parse is reused even though the file
    // store read every file again. Changing it on disk without a report
    // proves the cached parse answered.
    std::fs::write(project.path("other.yml"), "z:\n  type: book\n").unwrap();
    engine.files_changed(&[project.path("refs.bib")]);
    let third = index(&engine, &["refs.bib", "other.yml"]);
    assert_eq!(third, second);
}

#[test]
fn an_editor_buffer_wins_over_the_disk() {
    let project = Project::new(&[
        ("main.typ", "Hello\n"),
        ("refs.bib", "@book{disk, title={On Disk}}\n"),
    ]);
    let engine = engine(&project);
    assert_eq!(index(&engine, &["refs.bib"]).entries[0].key, "disk");
    engine
        .set_text(
            &project.path("refs.bib"),
            "@book{buffer, title={In the Editor}}\n",
        )
        .unwrap();
    let index_now = index(&engine, &["refs.bib"]);
    assert_eq!(index_now.entries.len(), 1);
    assert_eq!(index_now.entries[0].key, "buffer");
    // A change on disk does not replace the buffer.
    std::fs::write(project.path("refs.bib"), "@book{newer, title={N}}\n").unwrap();
    engine.files_changed(&[project.path("refs.bib")]);
    assert_eq!(index(&engine, &["refs.bib"]).entries[0].key, "buffer");
}

#[test]
fn bibliography_files_come_from_calls_in_the_main_file_and_its_includes() {
    // A single path.
    let project = Project::new(&[(
        "main.typ",
        "Text.\n\n#bibliography(\"refs.bib\", style: \"apa\")\n",
    )]);
    assert_eq!(project.engine().bibliography_files(), ["refs.bib"]);

    // An array, in code, with a path from the root.
    let project = Project::new(&[(
        "main.typ",
        "#let x = 1\n#{\n  bibliography((\"a.bib\", \"/data/b.yml\"))\n}\n",
    )]);
    assert_eq!(
        project.engine().bibliography_files(),
        ["a.bib", "data/b.yml"]
    );

    // A call in an included file, with a path relative to that file; a
    // nested include; an include cycle; no duplicates.
    let project = Project::new(&[
        (
            "main.typ",
            "= Book\n#include \"chapters/one.typ\"\n#include \"chapters/two.typ\"\n",
        ),
        ("chapters/one.typ", "One.\n#include \"../back/refs.typ\"\n"),
        (
            "chapters/two.typ",
            "Two.\n#include \"one.typ\"\n#bibliography(\"../refs.bib\")\n",
        ),
        (
            "back/refs.typ",
            "#bibliography((\"sources.bib\", \"../refs.bib\"))\n",
        ),
    ]);
    assert_eq!(
        project.engine().bibliography_files(),
        ["back/sources.bib", "refs.bib"]
    );

    // None, and calls with no literal path.
    let project = Project::new(&[(
        "main.typ",
        "#let files = (\"a.bib\",)\n#bibliography(files)\n// #bibliography(\"c.bib\")\n",
    )]);
    assert!(project.engine().bibliography_files().is_empty());

    // The editor buffer of the main file counts.
    let project = Project::new(&[("main.typ", "Hello\n")]);
    let engine = project.engine();
    engine
        .set_text(&project.path("main.typ"), "#bibliography(\"new.bib\")\n")
        .unwrap();
    assert_eq!(engine.bibliography_files(), ["new.bib"]);
}

/// A BibLaTeX file of `count` realistic entries, built here (no network).
pub fn generated_bib(count: usize) -> String {
    let families = [
        "Smith",
        "Müller",
        "García",
        "Nguyen",
        "O'Brien",
        "van der Berg",
        "Kowalski",
        "Dubois",
        "Johansson",
        "Tanaka",
        "Rossi",
        "Ivanova",
        "Okafor",
        "Fernández",
        "Lindqvist",
        "Chen",
    ];
    let given = [
        "Anna", "Björn", "Carlos", "Dana", "Émile", "Fatima", "Gustav", "Hiro",
    ];
    let words = [
        "dynamics",
        "perception",
        "coordination",
        "action",
        "ecological",
        "affordances",
        "recurrence",
        "fractal",
        "variability",
        "movement",
        "synergy",
        "attention",
        "learning",
        "interpersonal",
        "posture",
        "rhythm",
    ];
    let journals = [
        "Ecological Psychology",
        "Journal of Experimental Psychology: Human Perception and Performance",
        "Cognitive Science",
        "Human Movement Science",
    ];
    let mut out = String::with_capacity(count * 420);
    for i in 0..count {
        let family = families[i % families.len()];
        let co = families[(i * 7 + 3) % families.len()];
        let title: Vec<&str> = (0..6)
            .map(|w| words[(i * 3 + w * 5) % words.len()])
            .collect();
        let year = 1970 + (i % 55);
        let key = format!(
            "{}{}{}",
            family.to_lowercase().replace([' ', '\''], ""),
            year,
            i
        );
        match i % 4 {
            0 | 1 => writeln!(
                out,
                "@article{{{key},\n  author = {{{family}, {} and {co}, {}}},\n  title = {{{{The}} {} of {}}},\n  journal = {{{}}},\n  volume = {{{}}},\n  number = {{{}}},\n  pages = {{{}--{}}},\n  year = {{{year}}},\n  doi = {{10.1000/{key}}},\n  abstract = {{An abstract about {} and {} that runs for a while, as abstracts do.}},\n  keywords = {{{}, {}}},\n}}\n",
                given[i % given.len()],
                given[(i + 3) % given.len()],
                title[..3].join(" "),
                title[3..].join(" "),
                journals[i % journals.len()],
                i % 40 + 1,
                i % 6 + 1,
                i % 300 + 1,
                i % 300 + 20,
                title[0],
                title[1],
                title[2],
                title[4],
            ),
            2 => writeln!(
                out,
                "@book{{{key},\n  author = {{{family}, {}}},\n  title = {{{}}},\n  publisher = {{Academic Press}},\n  address = {{New York}},\n  year = {{{year}}},\n  isbn = {{978-0-00-{:06}-0}},\n}}\n",
                given[i % given.len()],
                title.join(" "),
                i,
            ),
            _ => writeln!(
                out,
                "@incollection{{{key},\n  author = {{{family}, {}}},\n  editor = {{{co}, {}}},\n  title = {{{}}},\n  booktitle = {{Handbook of {}}},\n  pages = {{{}--{}}},\n  publisher = {{Springer}},\n  date = {{{year}-0{}}},\n  url = {{https://example.org/{key}}},\n}}\n",
                given[i % given.len()],
                given[(i + 1) % given.len()],
                title[..4].join(" "),
                title[5],
                i % 100 + 1,
                i % 100 + 15,
                i % 9 + 1,
            ),
        }
        .unwrap();
    }
    out
}

#[test]
fn two_thousand_entries_parse_quickly_and_are_cached() {
    let bib = generated_bib(2000);
    let project = Project::new(&[("main.typ", "Hello\n"), ("big.bib", &bib)]);
    let engine = engine(&project);
    let started = Instant::now();
    let index = index(&engine, &["big.bib"]);
    let parse = started.elapsed();
    assert!(index.errors.is_empty(), "{:?}", &index.errors[..1]);
    assert_eq!(index.entries.len(), 2000);
    assert!(index
        .entries
        .iter()
        .all(|e| e.title.is_some() && !e.authors.is_empty() && e.year.is_some()));

    let started = Instant::now();
    let again = self::index(&engine, &["big.bib"]);
    let cached = started.elapsed();
    assert_eq!(again.entries.len(), 2000);

    let started = Instant::now();
    let json = prose_render::ffi::index_json(&again).to_string();
    let encode = started.elapsed();
    eprintln!(
        "bibliography: 2000 entries ({} KB): parse {:.1} ms, cached {:.2} ms, JSON {:.1} ms ({} KB)",
        bib.len() / 1024,
        parse.as_secs_f64() * 1000.0,
        cached.as_secs_f64() * 1000.0,
        encode.as_secs_f64() * 1000.0,
        json.len() / 1024,
    );
    assert!(parse.as_millis() < 200, "parse took {parse:?}");
    assert!(cached < parse);
}
