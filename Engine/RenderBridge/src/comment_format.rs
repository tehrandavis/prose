//! Phase 8, step A: the comment format on Typst itself
//! (`docs/plans/2026-11-15-comments.md`, acceptance tests 1 and 2).
//!
//! A comment is stored as a start marker (`/*<k3f9x2*/`), an end marker
//! (`/*k3f9x2>*/`) and a store of `// prose:` line comments at the end of
//! the file. Each fixture is compiled twice: as written, and with every start
//! marker, end marker and record removed. For the places decision 2 allows
//! ("Yes" rows) the two laid-out documents must be equal, with no tolerance.
//! For the places it forbids ("No" rows) the two must differ, so each rule
//! has a test and not only a reason.

use std::collections::hash_map::DefaultHasher;
use std::fmt::Write as _;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use typst::layout::{Frame, FrameItem};
use typst::model::Destination;
use typst_layout::PagedDocument;

use crate::engine::{Engine, Options};

/// The characters of an id (decision 1).
const ALPHABET: &str = "abcdefghjkmnpqrstuvwxyz23456789";

/// A small page, so that longer fixtures run over more than one page.
const PAGE: &str = "#set page(width: 11cm, height: 9cm, margin: 1cm)\n";

/// Two entries of the crate's bibliography test file (`tests/bibliography.rs`).
const BIB: &str = r#"@article{smith2020,
  author = {Smith, John and van Gogh, Vincent and Doe, Jr., Jane},
  title = {{The} Shape of Things},
  journal = {Journal of Shapes},
  year = {2020},
}

@book{ostrom1990,
  editor = {Ostrom, Elinor},
  title = {Governing the Commons},
  publisher = {Cambridge University Press},
  date = {1990-11},
}
"#;

/// A project folder in the temporary folder, removed when dropped.
struct Folder(PathBuf);

impl Folder {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "prose-comment-format-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for (name, text) in [("main.typ", ""), ("chapter.typ", ""), ("refs.bib", BIB)] {
            std::fs::write(root.join(name), text).unwrap();
        }
        Self(root.canonicalize().unwrap())
    }

    fn engine(&self) -> Engine {
        Engine::new(Options::new(&self.0, "main.typ")).unwrap()
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn is_id(text: &str) -> bool {
    text.len() == 6
        && text.chars().all(|c| ALPHABET.contains(c))
        && text.starts_with(|c: char| c.is_ascii_lowercase())
}

/// Whether `text` starts with a start marker or an end marker.
fn marker_at(text: &str) -> bool {
    let Some(marker) = text.get(..11) else {
        return false;
    };
    let start = marker.starts_with("/*<") && marker.ends_with("*/") && is_id(&marker[3..9]);
    let end = marker.starts_with("/*") && marker.ends_with(">*/") && is_id(&marker[2..8]);
    start || end
}

/// The text with every start marker, end marker and record removed. Blank
/// lines and source comments stay.
fn strip(text: &str) -> String {
    let lines: String = text
        .split_inclusive('\n')
        .filter(|line| !line.starts_with("// prose:"))
        .collect();
    let mut out = String::with_capacity(lines.len());
    let mut rest = lines.as_str();
    while let Some(at) = rest.find("/*") {
        out.push_str(&rest[..at]);
        if marker_at(&rest[at..]) {
            rest = &rest[at + 11..];
        } else {
            out.push_str("/*");
            rest = &rest[at + 2..];
        }
    }
    out.push_str(rest);
    out
}

/// A store as decision 1 shows it, for the given ids, after one blank line.
/// The text holds `*/`, `/*`, `//` and a bar, which a line comment ignores.
fn store(ids: &[&str]) -> String {
    let mut out = String::from("\n// prose:comments 1\n");
    for id in ids {
        writeln!(
            out,
            "// prose:comment {id} | Tehran Davis | 2026-11-15T14:02:11Z | Is \"quick\" the right word here?"
        )
        .unwrap();
        writeln!(
            out,
            "// prose:reply {id} | Ada Park | 2026-11-15T15:10:40Z | Yes. Compare */ and /* and // | here.\\nA second paragraph."
        )
        .unwrap();
        writeln!(
            out,
            "// prose:resolve {id} | Tehran Davis | 2026-11-16T10:00:03Z"
        )
        .unwrap();
    }
    out
}

/// The ids of every start marker in a text, in order.
fn ids(text: &str) -> Vec<&str> {
    let mut found = vec![];
    let mut rest = text;
    while let Some(at) = rest.find("/*<") {
        if marker_at(&rest[at..]) {
            found.push(&rest[at + 3..at + 9]);
        }
        rest = &rest[at + 3..];
    }
    found
}

/// A fixture: the main file with its store, and optionally a chapter file
/// with its own. Without `#set page` the small page is set first.
struct Fixture {
    name: &'static str,
    main: String,
    chapter: Option<String>,
}

fn fixture(name: &'static str, body: &str) -> Fixture {
    Fixture {
        name,
        main: with_store(body),
        chapter: None,
    }
}

fn with_store(body: &str) -> String {
    let page = if body.contains("#set page") { "" } else { PAGE };
    let ids = ids(body);
    if ids.is_empty() {
        format!("{page}{body}")
    } else {
        format!("{page}{body}{}", store(&ids))
    }
}

fn hash<T: Hash + ?Sized>(value: &T) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

/// Every item of a frame, one line each, in order, with positions relative
/// to the frame. Numbers are printed exactly (`{:?}` of an `f64` round
/// trips), and parts whose printed form may round are hashed too. Spans and
/// introspection tags are left out: spans are source offsets, which the
/// markers move, and tags draw nothing. A link to a location is compared by
/// the position it leads to.
fn describe(document: &PagedDocument, frame: &Frame, depth: usize, out: &mut Vec<String>) {
    let indent = "  ".repeat(depth);
    for (point, item) in frame.items() {
        let at = format!("{indent}({:?}, {:?})", point.x.to_pt(), point.y.to_pt());
        match item {
            FrameItem::Group(group) => {
                out.push(format!(
                    "{at} group {:?} {:?} clip {} label {:?} parent {} size {:?}",
                    group.transform,
                    hash(&group.transform),
                    group.clip.as_ref().map(hash).unwrap_or(0),
                    group.label,
                    group.parent.is_some(),
                    group.frame.size(),
                ));
                describe(document, &group.frame, depth + 1, out);
            }
            FrameItem::Text(text) => {
                let glyphs: Vec<String> = text
                    .glyphs
                    .iter()
                    .map(|g| {
                        format!(
                            "{}:{:?}:{:?}:{:?}:{:?}:{:?}",
                            g.id,
                            g.x_advance.get(),
                            g.x_offset.get(),
                            g.y_advance.get(),
                            g.y_offset.get(),
                            g.range
                        )
                    })
                    .collect();
                out.push(format!(
                    "{at} text {:?} #{} {:?} fill {} stroke {} {:?} {:?} {:?} [{}]",
                    text.font,
                    text.font.font().index(),
                    text.size.to_pt(),
                    hash(&text.fill),
                    text.stroke.as_ref().map(hash).unwrap_or(0),
                    text.lang,
                    text.region,
                    text.text,
                    glyphs.join(" ")
                ));
            }
            FrameItem::Shape(shape, _) => {
                out.push(format!("{at} shape {} {shape:?}", hash(shape)));
            }
            FrameItem::Image(image, size, _) => {
                out.push(format!("{at} image {} {size:?}", hash(image)));
            }
            FrameItem::Link(destination, size) => {
                let to = match destination {
                    Destination::Url(url) => format!("url {}", url.as_str()),
                    Destination::Position(position) => format!("position {position:?}"),
                    // A location is a hash that the markers' offsets change;
                    // where it leads is what a reader sees.
                    Destination::Location(location) => format!(
                        "location at {:?}",
                        document.introspector().position(*location)
                    ),
                };
                out.push(format!("{at} link {to} {size:?}"));
            }
            FrameItem::Tag(_) => {}
        }
    }
}

/// The pages of a document, described.
fn pages(document: &PagedDocument) -> Vec<Vec<String>> {
    document
        .pages()
        .iter()
        .map(|page| {
            let mut lines = vec![format!(
                "page {} size {:?} fill {} numbering {:?} bleed {:?}",
                page.number,
                page.frame.size(),
                hash(&page.fill),
                page.numbering,
                page.bleed,
            )];
            describe(document, &page.frame, 0, &mut lines);
            lines
        })
        .collect()
}

type Laid = Result<Vec<Vec<String>>, String>;

/// Compiles the texts given and describes the pages, or gives the error.
fn lay_out(engine: &Engine, folder: &Folder, main: &str, chapter: &str) -> Laid {
    engine.set_text(&folder.0.join("main.typ"), main).unwrap();
    engine
        .set_text(&folder.0.join("chapter.typ"), chapter)
        .unwrap();
    engine.compile_document().map(|document| pages(&document))
}

/// The first place where two outcomes differ, or None when they are equal.
fn difference(commented: &Laid, plain: &Laid) -> Option<String> {
    match (commented, plain) {
        (Err(a), Err(b)) if a == b => None,
        (Err(a), _) => Some(format!("with comments the compile fails: {a}")),
        (_, Err(b)) => Some(format!("without comments the compile fails: {b}")),
        (Ok(a), Ok(b)) => {
            if a.len() != b.len() {
                return Some(format!("{} pages against {}", a.len(), b.len()));
            }
            for (number, (pa, pb)) in a.iter().zip(b).enumerate() {
                for index in 0..pa.len().max(pb.len()) {
                    let la = pa.get(index).map(String::as_str).unwrap_or("(nothing)");
                    let lb = pb.get(index).map(String::as_str).unwrap_or("(nothing)");
                    if la != lb {
                        return Some(format!(
                            "page {}, item {index}:\n  with comments:    {la}\n  without comments: {lb}",
                            number + 1
                        ));
                    }
                }
            }
            None
        }
    }
}

/// Both outcomes of a fixture: (with comments, without comments).
fn both(engine: &Engine, folder: &Folder, fixture: &Fixture) -> (Laid, Laid) {
    let chapter = fixture.chapter.as_deref().unwrap_or("");
    let plain_main = strip(&fixture.main);
    let plain_chapter = strip(chapter);
    assert_ne!(
        plain_main, fixture.main,
        "{}: nothing to remove",
        fixture.name
    );
    assert!(
        !plain_main.contains("prose:") && !plain_chapter.contains("prose:"),
        "{}: a record is left",
        fixture.name
    );
    let commented = lay_out(engine, folder, &fixture.main, chapter);
    let plain = lay_out(engine, folder, &plain_main, &plain_chapter);
    (commented, plain)
}

/// The described text items of the pages: font, size, text and glyphs.
fn text_items(laid: &Laid) -> Vec<String> {
    laid.as_ref()
        .unwrap()
        .iter()
        .flatten()
        .filter_map(|line| line.split_once(" text ").map(|(_, rest)| rest.to_string()))
        .collect()
}

/// Checks that each fixture lays out exactly as without its comments, and
/// that it has glyphs and no missing glyph (id 0) without them.
fn assert_same(fixtures: &[Fixture]) {
    let folder = Folder::new();
    let engine = folder.engine();
    let mut failures = vec![];
    for fixture in fixtures {
        let (commented, plain) = both(&engine, &folder, fixture);
        assert!(
            plain.is_ok(),
            "{}: the fixture does not compile: {:?}",
            fixture.name,
            plain.as_ref().err()
        );
        let items = text_items(&plain);
        assert!(!items.is_empty(), "{}: no text", fixture.name);
        assert!(
            !items
                .iter()
                .any(|item| item.contains("[0:") || item.contains(" 0:")),
            "{}: a glyph is missing from every font",
            fixture.name
        );
        if let Some(difference) = difference(&commented, &plain) {
            failures.push(format!("{}: {difference}", fixture.name));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// Checks that each fixture changes when its comments are removed.
fn assert_differs(fixtures: &[Fixture]) {
    let folder = Folder::new();
    let engine = folder.engine();
    let mut same = vec![];
    for fixture in fixtures {
        let (commented, plain) = both(&engine, &folder, fixture);
        if difference(&commented, &plain).is_none() {
            same.push(fixture.name);
        }
    }
    assert!(
        same.is_empty(),
        "the same with and without comments: {same:?}"
    );
}

#[test]
fn strip_removes_markers_and_records_and_nothing_else() {
    let text = "A /*<k3f9x2*/b/*k3f9x2>*/ c /*<note*/ /* other */ d.\n// a source comment\n\n// prose:comments 1\n// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x\n";
    assert_eq!(
        strip(text),
        "A b c /*<note*/ /* other */ d.\n// a source comment\n\n"
    );
    assert_eq!(ids(text), ["k3f9x2"]);
    assert!(!marker_at("/*<k3f9x1*/"), "1 is not in the alphabet");
    assert!(!marker_at("/*<3kf9x2*/"), "an id starts with a letter");
    let stored = store(&["k3f9x2"]);
    let root = typst::syntax::parse(&stored);
    assert!(root.errors_and_warnings().0.is_empty());
    assert_eq!(
        root.children()
            .filter(|n| n.kind() == typst::syntax::SyntaxKind::LineComment)
            .count(),
        4
    );
}

/// Decision 2's "Yes" rows: between words and inside a word in a paragraph,
/// a heading, a list item and a term item; across strong and emphasis; from
/// one block to a later one; around whole nodes; overlapping and nested
/// anchors; inside the content blocks of calls.
fn allowed() -> Vec<Fixture> {
    vec![
        fixture(
            "between words in a paragraph",
            "The /*<k3f9x2*/quick brown fox/*k3f9x2>*/ jumps over the lazy dog.\n",
        ),
        fixture(
            "inside words in a paragraph",
            "An un/*<a2b3c4*/believ/*a2b3c4>*/able result, and a /*<m4n5p6*/sen/*m4n5p6>*/tence that goes on long enough to wrap.\n",
        ),
        fixture(
            "inside a heading",
            "#set heading(numbering: \"1.\")\n= The /*<k3f9x2*/quick/*k3f9x2>*/ heading\n\n== In/*<a2b3c4*/word/*a2b3c4>*/s\n\nText.\n",
        ),
        fixture(
            "a heading with markers at its ends",
            "#set heading(numbering: \"1.\")\n= /*<k3f9x2*/Title/*k3f9x2>*/\n\n= /*<a2b3c4*/Labelled/*a2b3c4>*/ <intro>\n\n= Other <other>/*m4n5p6>*/\n\nSee @intro, /*<m4n5p6*/and @other.\n",
        ),
        fixture(
            "inside list, numbered and term items",
            "- An /*<k3f9x2*/item/*k3f9x2>*/ here\n- /*<h8j9k2*/First/*h8j9k2>*/ word\n- An/*<a2b3c4*/oth/*a2b3c4>*/er\n  continued /*<m4n5p6*/line/*m4n5p6>*/\n  - nested /*<e3f4g5*/item/*e3f4g5>*/\n+ /*<q7r8s9*/Numbered/*q7r8s9>*/ item\n+ An/*<p2q3r4*/other/*p2q3r4>*/\n/ Term: its /*<t2u3v4*/description/*t2u3v4>*/\n/ Te/*<w5x6y7*/rm/*w5x6y7>*/: more\n",
        ),
        fixture(
            "across strong and emphasis",
            "Some *bold /*<k3f9x2*/text* and more/*k3f9x2>*/ words, and _emph/*<a2b3c4*/asis_ plain/*a2b3c4>*/ text. Then *str/*<m4n5p6*/ong* and _em/*m4n5p6>*/ph_ end.\n",
        ),
        fixture(
            "from one block to a later block",
            "First /*<k3f9x2*/paragraph ends here.\n\nSecond paragraph/*k3f9x2>*/ goes on.\n\n= A heading\n\nThird/*<a2b3c4*/ text.\n\n- item one\n- item/*a2b3c4>*/ two\n\nLast /*<m4n5p6*/one.\n\n$ x = y $\n\nAfter the/*m4n5p6>*/ equation.\n",
        ),
        fixture(
            "around whole nodes",
            "#set heading(numbering: \"1.\")\n= Intro /*<k3f9x2*/<intro>/*k3f9x2>*/\n\nAn /*<a2b3c4*/$x^2 + 1$/*a2b3c4>*/ equation, /*<m4n5p6*/`raw code`/*m4n5p6>*/, a /*<q7r8s9*/#link(\"https://example.com\")[link]/*q7r8s9>*/, a /*<w5x6y7*/#box[boxed]/*w5x6y7>*/ call, see /*<h8j9k2*/@intro/*h8j9k2>*/ and /*<e3f4g5*/@smith2020[p. 4]/*e3f4g5>*/ and /*<p2q3r4*/@ostrom1990/*p2q3r4>*/.\n\n/*<s5t6u7*/$ x = y $/*s5t6u7>*/\n\n/*<v8w9x2*/```rust\nfn main() {}\n```/*v8w9x2>*/\n\nA /*<y3z4a5*/#figure(rect(width: 1cm, height: 5mm), caption: [Box])/*y3z4a5>*/ figure.\n\n#bibliography(\"refs.bib\")\n",
        ),
        fixture(
            "overlapping and nested anchors",
            "One /*<k3f9x2*/two /*<a2b3c4*/three/*k3f9x2>*/ four/*a2b3c4>*/ five /*<m4n5p6*/six /*<q7r8s9*/seven/*q7r8s9>*/ eight/*m4n5p6>*/ nine, /*<t2u3v4*//*<w5x6y7*/ten/*w5x6y7>*//*t2u3v4>*/ eleven.\n",
        ),
        fixture(
            "inside emph, a footnote, a figure caption and a table cell",
            "#emph[an /*<k3f9x2*/emphasised/*k3f9x2>*/ word] and text#footnote[A /*<a2b3c4*/foot/*a2b3c4>*/note.] more.\n\n#figure(rect(width: 2cm, height: 1cm), caption: [A /*<m4n5p6*/caption/*m4n5p6>*/ here.])\n\n#table(columns: 2, [/*<q7r8s9*/cell/*q7r8s9>*/ one], [two /*<t2u3v4*/cells/*t2u3v4>*/])\n",
        ),
    ]
}

/// Decision 1's store at the end of a file, after each kind of last block,
/// and an included file with its own comments and store.
fn stores() -> Vec<Fixture> {
    vec![
        fixture("a store after a paragraph", "A /*<k3f9x2*/paragraph/*k3f9x2>*/.\n"),
        fixture("a store after a list", "- one\n- /*<k3f9x2*/two/*k3f9x2>*/\n"),
        fixture(
            "a store after a numbered list",
            "+ one\n+ /*<k3f9x2*/two/*k3f9x2>*/\n",
        ),
        fixture("a store after a heading", "= /*<k3f9x2*/Heading/*k3f9x2>*/\n"),
        fixture(
            "a store after a bibliography",
            "See /*<k3f9x2*/@smith2020/*k3f9x2>*/.\n\n#bibliography(\"refs.bib\")\n",
        ),
        fixture(
            "a store after a display equation",
            "Text /*<k3f9x2*/here/*k3f9x2>*/.\n\n$ x = y $\n",
        ),
        Fixture {
            name: "a store with no newline at the end of the file",
            main: with_store("A /*<k3f9x2*/paragraph/*k3f9x2>*/.\n")
                .trim_end()
                .to_string(),
            chapter: None,
        },
        Fixture {
            name: "a store that fills the page exactly",
            main: with_store(
                "#set page(width: 11cm, height: 3cm, margin: 1cm)\n#v(1fr)\nLast /*<k3f9x2*/line/*k3f9x2>*/.\n",
            ),
            chapter: None,
        },
        Fixture {
        name: "an included file with its own comments and store",
        main: with_store(
            "= Main\n\nMain /*<k3f9x2*/text/*k3f9x2>*/.\n\n#include \"chapter.typ\"\n\nAfter /*<m4n5p6*/the chapter/*m4n5p6>*/.\n",
        ),
        chapter: Some(format!(
            "= Chapter\n\nChapter /*<a2b3c4*/text/*a2b3c4>*/ here.\n{}",
            store(&["a2b3c4"])
        )),
        },
    ]
}

/// Facts 7 and 8: shaping, line breaking and justification across a marker.
fn typography() -> Vec<Fixture> {
    let long = "Typst /*<k3f9x2*/lays out/*k3f9x2>*/ text in paragraphs. A paragraph is broken into lines by the /*<a2b3c4*/Knuth/*a2b3c4>*/ and Plass algorithm, which weighs every possible break, and with justification the spaces of each line stretch or shrink so that the line fills the measure. A start/*<m4n5p6*/ marker beside a space, /*<q7r8s9*/a marker after a space,/*q7r8s9>*/ and a marker before /*m4n5p6>*/a space must change none of it. ";
    let justified = format!("#set par(justify: true)\n{}\n", long.repeat(3));
    vec![
        fixture("justified text over several pages", &justified),
        fixture(
            "a first-line indent",
            "#set par(first-line-indent: 1.5em)\nThe first paragraph has no indent and runs on to a second line of text.\n\n/*<k3f9x2*/The second paragraph starts with a start marker and is indented./*k3f9x2>*/\n\nThe /*<a2b3c4*/third/*a2b3c4>*/ paragraph.\n\n#set par(first-line-indent: (amount: 2em, all: true))\n/*<m4n5p6*/Every/*m4n5p6>*/ paragraph is indented now.\n",
        ),
        fixture(
            "hyphenation with a start marker inside a long word",
            "#set page(width: 5cm, height: auto, margin: 5mm)\n#set text(hyphenate: true)\n#set par(justify: true)\nThe incompre/*<k3f9x2*/hensibilities of characteristically/*k3f9x2>*/ uncharacteristic/*<a2b3c4*/ally internationalisation/*a2b3c4>*/ and institutionalisation of counter/*<m4n5p6*/revolutionaries/*m4n5p6>*/.\n",
        ),
        fixture(
            "ligatures and kerning cut by markers",
            "A /*<k3f9x2*/fi/*k3f9x2>*/ne of/*<a2b3c4*/fice: f/*<m4n5p6*/ind the ef/*a2b3c4>*/f/*m4n5p6>*/ort, a/*<q7r8s9*/ff/*q7r8s9>*/ect, A/*<t2u3v4*/V/*t2u3v4>*/ To/*<w5x6y7*/ward Wa/*w5x6y7>*/ve.\n",
        ),
        fixture(
            "smart quotes next to markers",
            "He said /*<k3f9x2*/\"hello\"/*k3f9x2>*/ and \"/*<a2b3c4*/quoted/*a2b3c4>*/\" text, it/*<m4n5p6*/'s fine, '/*<q7r8s9*/single/*q7r8s9>*/' and /*m4n5p6>*/'tis, x/*<t2u3v4*/\"y\"/*t2u3v4>*/ z.\n",
        ),
        fixture(
            "CJK text",
            "#set text(lang: \"zh\")\n#set par(justify: true)\n排版是一门/*<k3f9x2*/古老的手艺/*k3f9x2>*/，它把文字安排在页面上，使读者能够舒适地阅读。好的排/*<a2b3c4*/版让人不会注意到/*a2b3c4>*/它的存在，而坏的排版会打断阅读的节奏。“/*<m4n5p6*/引号/*m4n5p6>*/”与标点挤压也要保持不变。\n\n#text(lang: \"ja\")[日本語の/*<q7r8s9*/文章/*q7r8s9>*/も、禁則処理を守って改行されます。]\n",
        ),
        fixture(
            "right-to-left text",
            "#set text(lang: \"he\")\nשלום /*<k3f9x2*/עולם/*k3f9x2>*/, זהו טקסט בעברית שנמשך עד שהשורה נשברת לשורה שנייה.\n\n#text(lang: \"ar\")[مر/*<a2b3c4*/حبا بالعا/*a2b3c4>*/لم، هذا نص عربي تتصل /*<m4n5p6*/حروفه/*m4n5p6>*/.]\n",
        ),
    ]
}

/// The fixtures for facts 7 and 8 hold what they are meant to test: more
/// than one page, a hyphen at a line's end, and ligatures.
#[test]
fn the_typography_fixtures_hold_pages_a_hyphen_and_ligatures() {
    let folder = Folder::new();
    let engine = folder.engine();
    let plain = |name: &str| {
        let fixture = typography().into_iter().find(|f| f.name == name).unwrap();
        engine
            .set_text(&folder.0.join("main.typ"), &strip(&fixture.main))
            .unwrap();
        engine.compile_document().unwrap()
    };
    assert!(plain("justified text over several pages").pages().len() > 1);
    let items = pages(&plain("hyphenation with a start marker inside a long word"));
    assert!(
        items
            .iter()
            .flatten()
            .any(|line| line.contains(r#""\u{ad}" ["#)),
        "no line ends in a hyphen"
    );
    let document = plain("ligatures and kerning cut by markers");
    let mut joined = vec![];
    collect_ligatures(&document.pages()[0].frame, &mut joined);
    for ligature in ["fi", "ffi", "ff"] {
        assert!(
            joined.iter().any(|text| text == ligature),
            "no {ligature}: {joined:?}"
        );
    }
}

/// The text of every glyph that stands for more than one character.
fn collect_ligatures(frame: &Frame, out: &mut Vec<String>) {
    for (_, item) in frame.items() {
        match item {
            FrameItem::Group(group) => collect_ligatures(&group.frame, out),
            FrameItem::Text(text) => {
                for glyph in &text.glyphs {
                    let part = &text.text[glyph.range()];
                    if part.chars().count() > 1 {
                        out.push(part.to_string());
                    }
                }
            }
            _ => {}
        }
    }
}

/// Decision 2's "No" rows: each one changes the document.
#[test]
fn forbidden_places_change_the_document() {
    assert_differs(&[
        fixture(
            "inside math: two letters instead of a symbol",
            "$p/*<k3f9x2*/i r^2$\n",
        ),
        fixture("inside raw text: the marker prints", "`a/*<k3f9x2*/b`\n"),
        fixture("inside a string: the marker prints", "#\"a/*<k3f9x2*/b\"\n"),
        fixture(
            "inside a label",
            "#set heading(numbering: \"1.\")\n= Intro <in/*<k3f9x2*/tro>\n\nText.\n",
        ),
        fixture(
            "inside a reference",
            "#set heading(numbering: \"1.\")\n= Intro <intro>\n\nSee @in/*<k3f9x2*/tro.\n",
        ),
        fixture(
            "inside a bare link",
            "Visit https://typst.app/do/*<k3f9x2*/cs now.\n",
        ),
        fixture("inside an escape", "A \\/*<k3f9x2*/# sign.\n"),
        fixture(
            "inside a shorthand: no en dash",
            "Pages 1 -/*<k3f9x2*/- 2.\n",
        ),
        fixture(
            "inside a shorthand: no ellipsis",
            "Wait../*<k3f9x2*/. then.\n",
        ),
        fixture("inside a call's name", "#em/*<k3f9x2*/ph[x]\n"),
        fixture(
            "between a call and its content block",
            "#emph/*<k3f9x2*/[x]\n",
        ),
        fixture(
            "between a call's arguments and its content block",
            "#text(fill: red)/*<k3f9x2*/[x]\n",
        ),
        fixture(
            "between a reference and its supplement",
            "#set heading(numbering: \"1.\")\n= Intro <intro>\n\nSee @intro/*<k3f9x2*/[Part].\n",
        ),
        fixture(
            "between a citation and its supplement",
            "See @smith2020/*<k3f9x2*/[p. 4].\n\n#bibliography(\"refs.bib\")\n",
        ),
        fixture(
            "between a variable and a field",
            "#let d = (y: [Field])\n#d/*<k3f9x2*/.y\n",
        ),
        fixture(
            "before a list marker: the item nests",
            "- one\n/*<k3f9x2*/- two\n",
        ),
        fixture(
            "before a numbered marker: the item nests",
            "+ one\n/*<k3f9x2*/+ two\n",
        ),
        fixture(
            "in the indent of a nested item: the next item stops nesting under it",
            "- a\n  /*<k3f9x2*/- b\n    - c\n",
        ),
        fixture(
            "before a term marker: the item nests",
            "/ A: one\n/*<k3f9x2*// B: two\n",
        ),
        fixture(
            "at the start of a line after a list item: the line joins the item",
            "- one\n/*<k3f9x2*/after\n",
        ),
        fixture(
            "at the end of a statement's line: the line break is kept",
            "A#let x = 1/*<k3f9x2*/\nb\n",
        ),
        fixture(
            "between a digit and a star: strong instead of text",
            "2/*<k3f9x2*/*3 is six.\n",
        ),
        fixture(
            "between a letter and an underscore: emphasis instead of text",
            "A snake/*<k3f9x2*/_case name.\n",
        ),
        fixture(
            "after a dash at the start of a line: a list item instead of text",
            "-/*<k3f9x2*/item\n",
        ),
        fixture(
            "an end marker directly after a bare link: an error",
            "Visit /*<k3f9x2*/https://typst.app/*k3f9x2>*/ now.\n",
        ),
        fixture(
            "directly after a closing star: an error",
            "Some *bold*/*k3f9x2>*/ text.\n",
        ),
        fixture(
            "directly after an opening star: an error",
            "Some */*<k3f9x2*/bold* text.\n",
        ),
    ]);
}

/// "No" rows that change nothing in these cases. They stay "No" in decision
/// 2 (version one keeps out of code, and the list rules need one form), but
/// the reason is the rule's simplicity, not the output.
fn harmless() -> Vec<Fixture> {
    vec![
        fixture(
            "before a heading marker",
            "#set heading(numbering: \"1.\")\n/*<k3f9x2*/= Title\n\nText.\n",
        ),
        fixture(
            "in a call's parenthesised arguments",
            "#text(fill: red, /*<k3f9x2*/size: 14pt)[x]\n",
        ),
        fixture("in a code block", "#{ let x = /*<k3f9x2*/1; [#x] }\n"),
        fixture(
            "in the indent of a list item's later line",
            "- one\n  /*<k3f9x2*/more\n- two\n",
        ),
        fixture("inside math, before an attachment", "$x/*<k3f9x2*/^2$\n"),
        fixture("inside math, before a factorial", "$n/*<k3f9x2*/!$\n"),
        fixture(
            "a space between a bare link and an end marker",
            "Visit /*<k3f9x2*/https://typst.app /*k3f9x2>*/now.\n",
        ),
    ]
}

#[test]
fn allowed_places_lay_out_exactly_as_without_comments() {
    assert_same(&allowed());
}

#[test]
fn a_store_changes_nothing_after_any_last_block() {
    assert_same(&stores());
}

#[test]
fn shaping_and_line_breaks_are_unchanged_by_markers() {
    assert_same(&typography());
}

#[test]
fn some_forbidden_places_change_nothing() {
    assert_same(&harmless());
}

/// Tinymist's command line, which the app's build makes (`.tools/tinymist`).
/// It exports PDF with the same Typst as this crate.
fn tinymist() -> Option<PathBuf> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.tools/tinymist");
    path.is_file().then_some(path)
}

/// The PDF of a main file and a chapter file, exported by Tinymist.
fn pdf(tinymist: &Path, folder: &Path, main: &str, chapter: &str) -> Result<Vec<u8>, String> {
    std::fs::create_dir_all(folder).unwrap();
    // Without a date the PDF holds no creation time, and its id, which is
    // made from that time, is the same on every run.
    let main = format!("#set document(date: none)\n{main}");
    for (file, text) in [
        ("main.typ", main.as_str()),
        ("chapter.typ", chapter),
        ("refs.bib", BIB),
    ] {
        std::fs::write(folder.join(file), text).unwrap();
    }
    // The output is a pattern: its folder must not hold a folder of its name.
    let output = folder.join("document.pdf");
    let run = Command::new(tinymist)
        .arg("compile")
        .arg("--root")
        .arg(folder)
        .arg(folder.join("main.typ"))
        .arg(&output)
        .output()
        .map_err(|e| e.to_string())?;
    if !run.status.success() {
        return Err(String::from_utf8_lossy(&run.stderr).into_owned());
    }
    std::fs::read(&output).map_err(|e| e.to_string())
}

/// Wherever the layout is the same, the exported PDF is the same, byte for
/// byte. Skipped when Tinymist has not been built.
#[test]
fn pdf_bytes_are_identical_where_the_layout_is() {
    let Some(tinymist) = tinymist() else {
        eprintln!("skipped: .tools/tinymist is not built");
        return;
    };
    let folder = Folder::new();
    let fixtures: Vec<Fixture> = [allowed(), stores(), typography(), harmless()]
        .into_iter()
        .flatten()
        .collect();
    let failures: Vec<String> = std::thread::scope(|scope| {
        let runs: Vec<_> = fixtures
            .iter()
            .enumerate()
            .map(|(index, fixture)| {
                let (tinymist, root) = (&tinymist, &folder.0);
                scope.spawn(move || {
                    let chapter = fixture.chapter.as_deref().unwrap_or("");
                    let base = root.join(index.to_string());
                    let commented = pdf(tinymist, &base.join("commented"), &fixture.main, chapter);
                    let plain = pdf(
                        tinymist,
                        &base.join("plain"),
                        &strip(&fixture.main),
                        &strip(chapter),
                    );
                    match (commented, plain) {
                        (Ok(a), Ok(b)) if a == b => None,
                        (Ok(a), Ok(b)) => {
                            let at = a.iter().zip(&b).position(|(x, y)| x != y);
                            Some(format!(
                                "{}: {} bytes against {}, first difference at {at:?}",
                                fixture.name,
                                a.len(),
                                b.len()
                            ))
                        }
                        (a, b) => Some(format!("{}: {:?} {:?}", fixture.name, a.err(), b.err())),
                    }
                })
            })
            .collect();
        runs.into_iter()
            .filter_map(|run| run.join().unwrap())
            .collect()
    });
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    // The comparison can see a difference: two hyphens are not an en dash.
    let dash = "Pages 1 -/*<k3f9x2*/- 2.\n";
    assert_ne!(
        pdf(&tinymist, &folder.0.join("dash/commented"), dash, "").unwrap(),
        pdf(&tinymist, &folder.0.join("dash/plain"), &strip(dash), "").unwrap()
    );
}
