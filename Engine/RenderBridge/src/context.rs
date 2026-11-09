//! What a block needs from the whole document: counter values and reference
//! texts from the last full compile, and the block document built from them.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use typst::foundations::{Label, NativeElement, Selector, Value};
use typst::introspection::{Introspector, Location, MetadataElem};
use typst::layout::{Frame, FrameItem, Point, Transform};
use typst::math::EquationElem;
use typst::model::{BibliographyElem, CiteElem, Destination, HeadingElem};
use typst::syntax::{FileId, Span};
use typst::utils::PicoStr;
use typst_layout::PagedDocument;

use crate::outline::{calls, labels, Outline};
use crate::world::View;

/// Appended to the main file for the full compile, so it records every
/// heading's and equation's counter value, in document order.
pub const PROBE: &str = r#"
#context [#metadata((
  headings: query(heading).map(h => counter(heading).at(h.location())),
  equations: query(math.equation).map(e => (e.block, counter(math.equation).at(e.location()))),
)) <prose-counters>]
"#;

/// Counter values at each heading and block equation of the full document,
/// in document order, with the element's file and byte offset at the time of
/// the compile.
#[derive(Debug, Default, Clone)]
pub struct Counters {
    pub headings: Vec<(FileId, usize, Vec<i64>)>,
    pub equations: Vec<(FileId, usize, Vec<i64>)>,
}

fn ints(value: &Value) -> Vec<i64> {
    match value {
        Value::Array(items) => items
            .iter()
            .filter_map(|v| v.clone().cast::<i64>().ok())
            .collect(),
        Value::Int(n) => vec![*n],
        _ => vec![],
    }
}

impl Counters {
    /// Reads the probe's metadata and zips it with the same elements from the
    /// introspector, which carry source spans.
    pub(crate) fn read(view: &View, document: &PagedDocument) -> Self {
        let introspector = document.introspector();
        let Some(label) = Label::new(PicoStr::intern("prose-counters")) else {
            return Self::default();
        };
        let Some(probe) = introspector.query(&Selector::Label(label)).first().cloned() else {
            return Self::default();
        };
        let Some(meta) = probe.to_packed::<MetadataElem>() else {
            return Self::default();
        };
        let Value::Dict(dict) = &meta.value else {
            return Self::default();
        };
        let heading_values: Vec<Vec<i64>> = match dict.get("headings") {
            Ok(Value::Array(items)) => items.iter().map(ints).collect(),
            _ => vec![],
        };
        let equation_values: Vec<(bool, Vec<i64>)> = match dict.get("equations") {
            Ok(Value::Array(items)) => items
                .iter()
                .map(|item| match item {
                    Value::Array(pair) if pair.len() == 2 => (
                        pair.at(0, None)
                            .ok()
                            .and_then(|v| v.cast::<bool>().ok())
                            .unwrap_or(false),
                        pair.at(1, None).map(|v| ints(&v)).unwrap_or_default(),
                    ),
                    _ => (false, vec![]),
                })
                .collect(),
            _ => vec![],
        };
        let place = |span: Span| view.locate(span).map(|(id, range)| (id, range.start));
        let headings = introspector
            .query(&Selector::Elem(HeadingElem::ELEM, None))
            .iter()
            .zip(heading_values)
            .filter_map(|(elem, value)| place(elem.span()).map(|(id, at)| (id, at, value)))
            .collect();
        let equations = introspector
            .query(&Selector::Elem(EquationElem::ELEM, None))
            .iter()
            .zip(equation_values)
            .filter(|(_, (block, _))| *block)
            .filter_map(|(elem, (_, value))| place(elem.span()).map(|(id, at)| (id, at, value)))
            .collect();
        Self {
            headings,
            equations,
        }
    }

    /// The counter value just before `at` in `file`: the last element in
    /// document order before the first element of `file` at or after `at`.
    pub fn before(list: &[(FileId, usize, Vec<i64>)], file: FileId, at: usize) -> Option<Vec<i64>> {
        let after = list
            .iter()
            .position(|(id, start, _)| *id == file && *start >= at);
        let end = after.unwrap_or_else(|| {
            list.iter()
                .rposition(|(id, start, _)| *id == file && *start < at)
                .map(|i| i + 1)
                .unwrap_or(0)
        });
        list[..end].last().map(|(_, _, value)| value.clone())
    }
}

/// The citations of the full document: every cited key in the order of its
/// first citation, and the document's bibliography call. A block that cites
/// renders with a hidden copy of both, so its citations show what they show
/// in the whole document and the bibliography block lists every cited entry.
#[derive(Debug, Default, Clone)]
pub struct Citations {
    pub keys: Vec<String>,
    pub key_set: HashSet<String>,
    /// The first `bibliography(...)` call's text and the file it is in.
    pub bibliography: Option<(FileId, String)>,
}

impl Citations {
    pub(crate) fn read(view: &View, document: &PagedDocument) -> Self {
        let introspector = document.introspector();
        let mut citations = Self::default();
        for elem in introspector.query(&Selector::Elem(CiteElem::ELEM, None)) {
            let Some(cite) = elem.to_packed::<CiteElem>() else {
                continue;
            };
            let key = cite.key.resolve().to_string();
            if citations.key_set.insert(key.clone()) {
                citations.keys.push(key);
            }
        }
        citations.bibliography = introspector
            .query(&Selector::Elem(BibliographyElem::ELEM, None))
            .first()
            .and_then(|elem| {
                let (id, range) = view.locate(elem.span())?;
                let source = typst::World::source(view, id).ok()?;
                let text = source.text().get(range)?;
                text.starts_with("bibliography(")
                    .then(|| (id, text.to_string()))
            });
        citations
    }
}

/// What a reference to each label displays in the full document. A block
/// rendered alone cannot resolve a reference to a label outside it, so the
/// block document shows this text. A reference is drawn as a link to its
/// target's location: the text inside the link's rectangle is what it shows.
pub fn reference_texts(document: &PagedDocument) -> HashMap<String, String> {
    struct Found {
        links: Vec<((f64, f64, f64, f64), Location)>,
        texts: Vec<(f64, f64, String)>,
    }
    fn walk(frame: &Frame, ts: Transform, found: &mut Found) {
        for (pos, item) in frame.items() {
            match item {
                FrameItem::Group(group) => {
                    let ts = ts
                        .pre_concat(Transform::translate(pos.x, pos.y))
                        .pre_concat(group.transform);
                    walk(&group.frame, ts, found);
                }
                FrameItem::Link(Destination::Location(location), size) => {
                    let a = pos.transform(ts);
                    let b = Point::new(pos.x + size.x, pos.y + size.y).transform(ts);
                    found.links.push((
                        (a.x.to_pt(), a.y.to_pt(), b.x.to_pt(), b.y.to_pt()),
                        *location,
                    ));
                }
                FrameItem::Text(text) => {
                    let at = pos.transform(ts);
                    found
                        .texts
                        .push((at.x.to_pt(), at.y.to_pt(), text.text.to_string()));
                }
                _ => {}
            }
        }
    }
    let introspector = document.introspector();
    let mut texts = HashMap::new();
    for page in document.pages() {
        let mut found = Found {
            links: vec![],
            texts: vec![],
        };
        walk(&page.frame, Transform::identity(), &mut found);
        for ((x0, y0, x1, y1), location) in found.links {
            let Some(label) = introspector
                .query(&Selector::Location(location))
                .first()
                .and_then(|elem| elem.label())
            else {
                continue;
            };
            let name = label.resolve().to_string();
            if texts.contains_key(&name) {
                continue;
            }
            let shown: String = found
                .texts
                .iter()
                .filter(|(x, y, _)| *x >= x0 - 0.5 && *x < x1 && *y >= y0 - 0.5 && *y <= y1 + 0.5)
                .map(|(_, _, text)| text.as_str())
                .collect();
            if !shown.is_empty() {
                texts.insert(name, shown);
            }
        }
    }
    texts
}

/// Maps a byte offset in a file's current text to the same place in the text
/// the last full compile saw, so stored counter offsets stay valid while the
/// writer types. Built from the common prefix and suffix of the two texts.
/// An offset inside the changed region maps to the region's start.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Shift {
    prefix: usize,
    old_end: usize,
    new_end: usize,
}

impl Shift {
    pub(crate) fn identity() -> Self {
        Self {
            prefix: usize::MAX,
            old_end: usize::MAX,
            new_end: usize::MAX,
        }
    }

    pub(crate) fn between(old: &typst::syntax::Source, new: &str) -> Self {
        match old.lines().replacement_range(new) {
            None => Self::identity(),
            Some((prefix, suffix)) => Self {
                prefix,
                old_end: old.text().len() - suffix,
                new_end: new.len() - suffix,
            },
        }
    }

    pub(crate) fn map(&self, at: usize) -> usize {
        if at <= self.prefix {
            at
        } else if at >= self.new_end {
            at - self.new_end + self.old_end
        } else {
            self.prefix
        }
    }
}

/// The inputs of one block document.
pub(crate) struct BlockInputs<'a> {
    /// The text of the block's file and its outline.
    pub(crate) file_text: &'a str,
    pub(crate) outline: &'a Outline,
    /// The main file's text and outline, when the block is in another file.
    pub(crate) main: Option<(&'a str, &'a Outline)>,
    pub(crate) range: Range<usize>,
    pub(crate) heading: Option<Vec<i64>>,
    pub(crate) equation: Option<Vec<i64>>,
    pub(crate) references: &'a HashMap<String, String>,
    /// The document's citations, and whether its bibliography call resolves
    /// its paths as it does in the block's file (the same folder).
    pub(crate) citations: &'a Citations,
    pub(crate) bibliography_here: bool,
    pub(crate) width_pt: f64,
    /// A default text colour (straight RGBA), set before the document's own
    /// context lines so a document that sets its own colour keeps it.
    pub(crate) text_color: Option<[u8; 4]>,
}

/// Builds the block document: the default text colour, context lines, a
/// transparent page as wide as the measure, counter state, stubs for outside
/// labels, then the block itself. Returns the document and the byte offset
/// where the block's text starts in it.
pub(crate) fn block_document(inputs: &BlockInputs) -> (String, usize) {
    let mut doc = String::new();
    if let Some([r, g, b, a]) = inputs.text_color {
        doc.push_str(&format!("#set text(fill: rgb({r}, {g}, {b}, {a}))\n"));
    }
    if let Some((main_text, main_outline)) = inputs.main {
        for range in &main_outline.context {
            doc.push_str(&main_text[range.clone()]);
            doc.push('\n');
        }
    }
    for range in inputs
        .outline
        .context
        .iter()
        .filter(|r| r.end <= inputs.range.start)
    {
        doc.push_str(&inputs.file_text[range.clone()]);
        doc.push('\n');
    }
    // Margins above and below keep descenders from being clipped. No fill:
    // the page is transparent outside ink, in SVG and bitmaps.
    doc.push_str(&format!(
        "#set page(width: {}pt, height: auto, margin: (x: 0pt, top: 0.25em, bottom: 0.4em), fill: none, header: none, footer: none, background: none, foreground: none, numbering: none)\n",
        inputs.width_pt
    ));
    if let Some(value) = &inputs.heading {
        let list: Vec<String> = value.iter().map(|n| n.to_string()).collect();
        doc.push_str(&format!(
            "#counter(heading).update(({},))\n",
            list.join(", ")
        ));
    }
    if let Some(n) = inputs.equation.as_ref().and_then(|value| value.first()) {
        doc.push_str(&format!("#counter(math.equation).update({n})\n"));
    }
    // Labels outside the block get a stub, and references to them show the
    // text they have in the full document.
    let block_text = &inputs.file_text[inputs.range.clone()];
    let (uses, defined) = labels(block_text);
    // Citations: the block cites, or holds the bibliography. Typst resolves
    // them itself, given every cited key in document order (so numbers and
    // disambiguation match the whole document) and the bibliography, hidden.
    let citations = inputs.citations;
    let holds_bibliography = calls(block_text, "bibliography");
    let cites = uses
        .iter()
        .any(|label| citations.key_set.contains(&label.name));
    let cited_here = !citations.keys.is_empty()
        && (holds_bibliography
            || (cites && inputs.bibliography_here && citations.bibliography.is_some()));
    if cited_here {
        doc.push_str("#place(hide[\n#set bibliography(title: none)\n");
        for key in &citations.keys {
            let quoted = key.replace('\\', "\\\\").replace('"', "\\\"");
            doc.push_str(&format!("#cite(label(\"{quoted}\"))\n"));
        }
        if !holds_bibliography {
            if let Some((_, call)) = &citations.bibliography {
                doc.push_str(&format!("#{call}\n"));
            }
        }
        doc.push_str("])\n");
    }
    let mut stubbed = HashSet::new();
    let mut shown_refs = HashSet::new();
    for label in uses {
        if label.name.is_empty() || defined.contains(&label.name) {
            continue;
        }
        if cited_here && citations.key_set.contains(&label.name) {
            continue;
        }
        let name = &label.name;
        if stubbed.insert(name.clone()) {
            doc.push_str(&format!("#metadata(none) <{name}>\n"));
        }
        if label.is_ref && shown_refs.insert(name.clone()) {
            let shown = inputs
                .references
                .get(name)
                .map(String::as_str)
                .unwrap_or("??");
            let quoted = shown.replace('\\', "\\\\").replace('"', "\\\"");
            doc.push_str(&format!(
                "#show ref.where(target: <{name}>): \"{quoted}\"\n"
            ));
        }
    }
    // A label at the start of a block attaches to the element before it. Give
    // it an invisible element, so it never renames a stub.
    doc.push_str("#metadata(none)\n");
    let prefix = doc.len();
    doc.push_str(block_text);
    doc.push('\n');
    (doc, prefix)
}
