//! The bibliography index (Phase 5 step B): the entries of a project's
//! bibliography files, parsed with Hayagriva as Typst's `bibliography`
//! parses them, and the files the project's `bibliography(...)` calls name.
//!
//! A key the index lists is a key Typst accepts, with two limits Typst also
//! has, reported as errors rather than hidden:
//!
//! - A BibLaTeX syntax error (an unclosed brace, a key defined twice in one
//!   file) stops the parser: the file yields no entries and one error.
//!   Hayagriva's YAML parser is the same: one error, no entries.
//! - A BibLaTeX field Hayagriva cannot convert (a malformed date, say) makes
//!   Typst reject the whole file. The index still lists the file's other
//!   entries, each converted by Hayagriva alone, reports each bad entry, and
//!   marks the file as not accepted, so the picker can say that the document
//!   will not compile until the entry is fixed.

use std::sync::Arc;

use hayagriva::types::{EntryType, Person};
use typst::syntax::ast;
use typst::syntax::{FileId, SyntaxNode, VirtualPath};

/// One author or editor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BibAuthor {
    /// The family name with its prefix: "van Gogh".
    pub family: String,
    /// The given names, with a suffix after a comma: "Vincent", "John, Jr.".
    pub given: Option<String>,
}

/// One entry of a bibliography file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BibEntry {
    pub key: String,
    /// Hayagriva's entry type in kebab case: `article`, `book`, `thesis`. A
    /// BibLaTeX type maps to Hayagriva's (`inproceedings` is `article`).
    pub kind: String,
    pub title: Option<String>,
    /// The authors; the editors when the entry has no authors.
    pub authors: Vec<BibAuthor>,
    pub year: Option<i32>,
    /// The title of the first parent: the journal, book or proceedings.
    pub container: Option<String>,
    pub doi: Option<String>,
    pub url: Option<String>,
    /// The file, relative to the project root, with `/` separators.
    pub file: String,
    /// The line the entry starts on, from 1; 0 when unknown.
    pub line: usize,
}

/// A problem in a bibliography file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BibError {
    pub file: String,
    /// From 1; 0 when the error has no place (a missing file).
    pub line: usize,
    pub message: String,
}

/// What became of one requested file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BibFile {
    pub path: String,
    /// Entries listed from this file, duplicates of earlier files excluded.
    pub entries: usize,
    /// Whether Typst would load the file as it is: it exists, parses and
    /// converts with no error.
    pub accepted: bool,
}

/// The entries of a set of bibliography files, in file order and then in the
/// order of each file. A key defined in two files is listed once, from the
/// first, and reported as an error in the second, as Typst rejects it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BibIndex {
    pub entries: Vec<BibEntry>,
    pub errors: Vec<BibError>,
    pub files: Vec<BibFile>,
}

/// One file's parse, cached by file and version.
#[derive(Debug, Clone, Default)]
pub(crate) struct Parsed {
    pub(crate) entries: Vec<BibEntry>,
    pub(crate) errors: Vec<BibError>,
    pub(crate) accepted: bool,
}

/// Line starts of a text, for byte offset to line.
struct Lines(Vec<usize>);

impl Lines {
    fn new(text: &str) -> Self {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(at, _)| at + 1));
        Self(starts)
    }

    /// The line, from 1, of a byte offset.
    fn line(&self, byte: usize) -> usize {
        self.0.partition_point(|&start| start <= byte)
    }
}

/// The project-relative path of a file, without a leading slash.
pub(crate) fn display_path(id: FileId) -> String {
    id.vpath().get_without_slash().to_string()
}

fn person(person: &Person) -> BibAuthor {
    let family = match &person.prefix {
        Some(prefix) if !prefix.is_empty() => format!("{prefix} {}", person.name),
        _ => person.name.clone(),
    };
    let given = match (&person.given_name, &person.suffix) {
        (Some(given), Some(suffix)) => Some(format!("{given}, {suffix}")),
        (Some(given), None) => Some(given.clone()),
        (None, Some(suffix)) => Some(suffix.clone()),
        (None, None) => None,
    };
    BibAuthor { family, given }
}

fn kind_name(kind: &EntryType) -> String {
    // Hayagriva serializes entry types in kebab case; Debug is the variant name.
    let debug = format!("{kind:?}");
    let mut out = String::with_capacity(debug.len() + 2);
    for (i, c) in debug.chars().enumerate() {
        if c.is_uppercase() {
            if i > 0 {
                out.push('-');
            }
            out.extend(c.to_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

fn entry(entry: &hayagriva::Entry, file: &str, line: usize) -> BibEntry {
    let authors = entry
        .authors()
        .filter(|a| !a.is_empty())
        .or_else(|| entry.editors())
        .map(|people| people.iter().map(person).collect())
        .unwrap_or_default();
    let nonempty = |s: String| (!s.trim().is_empty()).then_some(s);
    BibEntry {
        key: entry.key().to_string(),
        kind: kind_name(entry.entry_type()),
        title: entry
            .title()
            .and_then(|t| nonempty(t.value.to_str().into_owned())),
        authors,
        year: entry
            .date()
            .or_else(|| entry.parents().iter().find_map(|p| p.date()))
            .map(|d| d.year),
        container: entry
            .parents()
            .iter()
            .find_map(|p| p.title())
            .and_then(|t| nonempty(t.value.to_str().into_owned())),
        doi: entry.doi().map(str::to_string),
        url: entry.url().map(|u| u.value.to_string()),
        file: file.to_string(),
        line,
    }
}

/// Parses one bibliography file's text by its extension, as Typst does.
pub(crate) fn parse(file: &str, text: &str) -> Parsed {
    let extension = file
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_lowercase())
        .unwrap_or_default();
    let lines = Lines::new(text);
    let error = |line: usize, message: String| BibError {
        file: file.to_string(),
        line,
        message,
    };
    match extension.as_str() {
        "bib" => parse_biblatex(file, text, &lines),
        "yml" | "yaml" => match hayagriva::io::from_yaml_str(text) {
            Ok(library) => Parsed {
                entries: library
                    .iter()
                    .map(|e| entry(e, file, yaml_line(text, e.key())))
                    .collect(),
                errors: vec![],
                accepted: true,
            },
            Err(e) => Parsed {
                entries: vec![],
                errors: vec![error(
                    e.location().map_or(0, |l| l.line()),
                    format!("failed to parse YAML: {e}"),
                )],
                accepted: false,
            },
        },
        _ => Parsed {
            entries: vec![],
            errors: vec![error(
                0,
                "unknown bibliography format (must be .yaml/.yml or .bib)".into(),
            )],
            accepted: false,
        },
    }
}

/// BibLaTeX through Hayagriva's own steps (`hayagriva::io::from_biblatex_str`
/// is `Bibliography::parse` then a conversion of each entry), with the raw
/// parse in between for each entry's line.
fn parse_biblatex(file: &str, text: &str, lines: &Lines) -> Parsed {
    let error = |line: usize, message: String| BibError {
        file: file.to_string(),
        line,
        message,
    };
    let failed = |span: std::ops::Range<usize>, message: String| Parsed {
        entries: vec![],
        errors: vec![error(
            lines.line(span.start),
            format!("failed to parse BibLaTeX: {message}"),
        )],
        accepted: false,
    };
    let raw = match biblatex::RawBibliography::parse(text) {
        Ok(raw) => raw,
        Err(e) => return failed(e.span, e.kind.to_string()),
    };
    let starts: std::collections::HashMap<String, usize> = raw
        .entries
        .iter()
        .map(|e| (e.v.key.v.to_string(), e.span.start))
        .collect();
    let bibliography = match biblatex::Bibliography::from_raw(raw) {
        Ok(bibliography) => bibliography,
        Err(e) => return failed(e.span, e.kind.to_string()),
    };
    let mut parsed = Parsed {
        accepted: true,
        ..Parsed::default()
    };
    for tex in bibliography.iter() {
        let start = starts.get(&tex.key).copied();
        match hayagriva::Entry::try_from(tex) {
            Ok(converted) => {
                parsed
                    .entries
                    .push(entry(&converted, file, start.map_or(0, |s| lines.line(s))))
            }
            Err(e) => {
                parsed.accepted = false;
                parsed.errors.push(error(
                    lines.line(e.span.start),
                    format!(
                        "failed to parse BibLaTeX: {} (entry {}; Typst rejects the whole file until it is fixed)",
                        e.kind, tex.key
                    ),
                ));
            }
        }
    }
    parsed
}

/// The line of a top-level YAML key, from 1; 0 if not found.
fn yaml_line(text: &str, key: &str) -> usize {
    text.lines()
        .position(|line| {
            let line = line.trim_end();
            [
                format!("{key}:"),
                format!("\"{key}\":"),
                format!("'{key}':"),
            ]
            .iter()
            .any(|form| line.starts_with(form.as_str()))
        })
        .map_or(0, |i| i + 1)
}

/// Joins the parses of several files into one index: duplicates of a key in
/// a later file are reported there and left out.
pub(crate) fn merge(files: &[(String, Arc<Parsed>)]) -> BibIndex {
    let mut index = BibIndex::default();
    let mut seen: std::collections::HashMap<&str, &str> = std::collections::HashMap::new();
    for (path, parsed) in files {
        let mut listed = 0;
        let mut accepted = parsed.accepted;
        for entry in &parsed.entries {
            match seen.get(entry.key.as_str()) {
                Some(first) => {
                    accepted = false;
                    index.errors.push(BibError {
                        file: path.clone(),
                        line: entry.line,
                        message: format!(
                            "duplicate bibliography key {} (also in {first})",
                            entry.key
                        ),
                    });
                }
                None => {
                    seen.insert(&entry.key, &entry.file);
                    index.entries.push(entry.clone());
                    listed += 1;
                }
            }
        }
        index.errors.extend(parsed.errors.iter().cloned());
        index.files.push(BibFile {
            path: path.clone(),
            entries: listed,
            accepted,
        });
    }
    index
}

/// What a file's syntax tree names: bibliography paths and included files,
/// each resolved against the file's folder (a path starting with `/` against
/// the project root).
pub(crate) struct Named {
    pub(crate) bibliographies: Vec<VirtualPath>,
    pub(crate) includes: Vec<VirtualPath>,
}

/// The paths a file's `bibliography(...)` calls and `include` expressions
/// name, when they are string literals: `bibliography("a.bib")`,
/// `bibliography(("a.bib", "b.yml"))`, `include "chapter.typ"`.
pub(crate) fn named(file: FileId, root: &SyntaxNode) -> Named {
    let folder = file
        .vpath()
        .parent()
        .unwrap_or_else(|| VirtualPath::new("/").expect("root path"));
    let resolve = |path: &str| -> Option<VirtualPath> {
        if path.starts_with('/') {
            VirtualPath::new(path).ok()
        } else {
            folder.join(path).ok()
        }
    };
    fn walk(node: &SyntaxNode, found: &mut (Vec<String>, Vec<String>)) {
        if let Some(call) = node.cast::<ast::FuncCall>() {
            if matches!(call.callee(), ast::Expr::Ident(name) if name.as_str() == "bibliography") {
                if let Some(first) = call.args().items().find_map(|arg| match arg {
                    ast::Arg::Pos(expr) => Some(expr),
                    _ => None,
                }) {
                    match first {
                        ast::Expr::Str(path) => found.0.push(path.get().to_string()),
                        ast::Expr::Array(array) => {
                            for item in array.items() {
                                if let ast::ArrayItem::Pos(ast::Expr::Str(path)) = item {
                                    found.0.push(path.get().to_string());
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        if let Some(include) = node.cast::<ast::ModuleInclude>() {
            if let ast::Expr::Str(path) = include.source() {
                found.1.push(path.get().to_string());
            }
        }
        for child in node.children() {
            walk(child, found);
        }
    }
    let mut found = (vec![], vec![]);
    walk(root, &mut found);
    Named {
        bibliographies: found.0.iter().filter_map(|p| resolve(p)).collect(),
        includes: found.1.iter().filter_map(|p| resolve(p)).collect(),
    }
}
