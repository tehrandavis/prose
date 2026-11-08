//! Per-block Typst rendering for Prose's Writing mode (spec Section 5.2).
//!
//! Phase 2 spike: a World over a project folder, block splitting from the
//! syntax tree, block documents with their context, counter state from the full
//! compile, and glyph-to-source mapping. No C ABI or cache yet.

use std::collections::HashMap;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use typst::diag::{FileError, FileResult, PackageError, SourceDiagnostic, Warned};
use typst::foundations::{Bytes, Datetime, Duration, Label, NativeElement, Selector, Value};
use typst::introspection::{Introspector, MetadataElem};
use typst::layout::{Abs, Frame, FrameItem, Point, Transform};
use typst::math::EquationElem;
use typst::model::HeadingElem;
use typst::syntax::{
    FileId, RootedPath, Source, Span, SyntaxKind, SyntaxNode, VirtualPath, VirtualRoot,
};
use typst::text::{Font, FontBook};
use typst::utils::{LazyHash, PicoStr};
use typst::{Library, LibraryExt, World, WorldExt};
use typst_kit::files::{FileLoader, FileStore, FsRoot};
use typst_kit::fonts::{self, FontStore};
use typst_kit::packages::FsPackages;
use typst_layout::PagedDocument;

/// Loads project files from the folder and packages from local directories.
/// The spike never downloads packages.
struct Loader {
    project: FsRoot,
    packages: Vec<FsPackages>,
}

impl Loader {
    fn root(&self, id: FileId) -> FileResult<FsRoot> {
        match id.root() {
            VirtualRoot::Project => Ok(self.project.clone()),
            VirtualRoot::Package(spec) => self
                .packages
                .iter()
                .find_map(|packages| packages.obtain(spec))
                .ok_or_else(|| FileError::Package(PackageError::NotFound(spec.clone()))),
        }
    }
}

impl FileLoader for Loader {
    fn load(&self, id: FileId) -> FileResult<Bytes> {
        self.root(id)?.load(id.vpath())
    }
}

/// A project folder with fonts and packages, plus in-memory files that
/// replace or add to the files on disk.
pub struct Engine {
    library: LazyHash<Library>,
    fonts: FontStore,
    files: FileStore<Loader>,
    root: PathBuf,
    main: FileId,
    overlay: Mutex<HashMap<FileId, Source>>,
}

/// A view of the engine with a chosen main file, as Typst's `World`.
struct View<'a> {
    engine: &'a Engine,
    main: FileId,
}

impl World for View<'_> {
    fn library(&self) -> &LazyHash<Library> {
        &self.engine.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.engine.fonts.book()
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if let Some(source) = self.engine.overlay.lock().unwrap().get(&id) {
            return Ok(source.clone());
        }
        self.engine.files.source(id)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(source) = self.engine.overlay.lock().unwrap().get(&id) {
            return Ok(Bytes::from_string(source.clone()));
        }
        self.engine.files.file(id)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.engine.fonts.font(index)
    }

    fn today(&self, _: Option<Duration>) -> Option<Datetime> {
        None
    }
}

impl Engine {
    pub fn new(root: &Path, main: &Path, package_dirs: &[PathBuf]) -> Result<Self, String> {
        let root = root.canonicalize().map_err(|e| format!("root: {e}"))?;
        let main = main.canonicalize().map_err(|e| format!("main: {e}"))?;
        let mut store = FontStore::new();
        store.extend(fonts::embedded());
        store.extend(fonts::system());
        let packages = package_dirs.iter().filter(|p| p.exists()).map(FsPackages::new).collect();
        let main_id = Self::id_in(&root, &main)?;
        Ok(Self {
            library: LazyHash::new(Library::builder().build()),
            fonts: store,
            files: FileStore::new(Loader { project: FsRoot::new(root.clone()), packages }),
            root,
            main: main_id,
            overlay: Mutex::new(HashMap::new()),
        })
    }

    fn id_in(root: &Path, path: &Path) -> Result<FileId, String> {
        let vpath = VirtualPath::virtualize(root, path).map_err(|e| format!("{path:?}: {e:?}"))?;
        Ok(RootedPath::new(VirtualRoot::Project, vpath).intern())
    }

    pub fn main(&self) -> FileId {
        self.main
    }

    pub fn id(&self, path: &Path) -> Result<FileId, String> {
        let path = path.canonicalize().map_err(|e| format!("{path:?}: {e}"))?;
        Self::id_in(&self.root, &path)
    }

    /// A file id beside `near`, for a document that exists only in memory.
    pub fn sibling(&self, near: FileId, name: &str) -> FileId {
        let parent = near.vpath().parent().unwrap_or_else(|| VirtualPath::new("/").unwrap());
        RootedPath::new(VirtualRoot::Project, parent.join(name).unwrap()).intern()
    }

    /// The current text of a file, from memory if it was replaced.
    pub fn text(&self, id: FileId) -> Result<String, String> {
        View { engine: self, main: self.main }
            .source(id)
            .map(|s| s.text().to_string())
            .map_err(|e| format!("{e:?}"))
    }

    pub fn set_text(&self, id: FileId, text: String) {
        self.overlay.lock().unwrap().insert(id, Source::new(id, text));
    }

    pub fn compile(&self, main: FileId) -> Result<PagedDocument, Vec<SourceDiagnostic>> {
        let Warned { output, .. } = typst::compile::<PagedDocument>(&View { engine: self, main });
        output.map_err(|errors| errors.to_vec())
    }

    /// The byte range of a diagnostic's span.
    pub fn diagnostic_range(&self, diagnostic: &SourceDiagnostic) -> Option<Range<usize>> {
        View { engine: self, main: self.main }.range(diagnostic.span)
    }

    /// The byte range of a span, with its file.
    pub fn locate(&self, span: Span) -> Option<(FileId, Range<usize>)> {
        let id = span.id()?;
        let range = View { engine: self, main: self.main }.range(span)?;
        Some((id, range))
    }
}

/// What a top-level block is, for reporting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockKind {
    Heading,
    Equation,
    Paragraph,
}

#[derive(Debug, Clone)]
pub struct Block {
    pub range: Range<usize>,
    pub kind: BlockKind,
}

/// A file's top level, split into rendered blocks and context lines
/// (`#set`, `#show`, `#let`, `#import`).
#[derive(Debug, Default)]
pub struct Outline {
    pub blocks: Vec<Block>,
    pub context: Vec<Range<usize>>,
}

pub fn split(text: &str) -> Outline {
    let root = typst::syntax::parse(text);
    let mut outline = Outline::default();
    let mut current: Option<(usize, usize, BlockKind)> = None;
    let mut offset = 0;
    let children: Vec<&SyntaxNode> = root.children().collect();
    let flush = |current: &mut Option<(usize, usize, BlockKind)>, outline: &mut Outline| {
        if let Some((start, end, kind)) = current.take() {
            if !text[start..end].trim().is_empty() {
                outline.blocks.push(Block { range: start..end, kind });
            }
        }
    };
    let mut index = 0;
    while index < children.len() {
        let node = children[index];
        let start = offset;
        let end = start + node.len();
        let next = children.get(index + 1).copied();
        match node.kind() {
            SyntaxKind::Parbreak => flush(&mut current, &mut outline),
            SyntaxKind::Hash
                if next.is_some_and(|n| {
                    matches!(
                        n.kind(),
                        SyntaxKind::SetRule
                            | SyntaxKind::ShowRule
                            | SyntaxKind::LetBinding
                            | SyntaxKind::ModuleImport
                            | SyntaxKind::ModuleInclude
                    )
                }) =>
            {
                flush(&mut current, &mut outline);
                let expr = next.unwrap();
                if expr.kind() != SyntaxKind::ModuleInclude {
                    outline.context.push(start..end + expr.len());
                }
                offset = end + expr.len();
                index += 2;
                continue;
            }
            SyntaxKind::Heading => {
                flush(&mut current, &mut outline);
                // A heading ends its block, together with a trailing label.
                let mut end = end;
                let mut skip = 1;
                while let Some(n) = children.get(index + skip) {
                    let at = end;
                    if n.kind() == SyntaxKind::Space && !text[at..at + n.len()].contains('\n') {
                        end += n.len();
                    } else if n.kind() == SyntaxKind::Label {
                        end += n.len();
                    } else {
                        break;
                    }
                    skip += 1;
                }
                current = Some((start, end, BlockKind::Heading));
                flush(&mut current, &mut outline);
                offset = end;
                index += skip;
                continue;
            }
            SyntaxKind::Space if current.is_none() => {}
            kind => {
                // A display equation has a space or newline after its opening `$`.
                let source = &text[start..end];
                let block = if kind == SyntaxKind::Equation
                    && source.len() > 2
                    && source[1..].starts_with(char::is_whitespace)
                {
                    BlockKind::Equation
                } else {
                    BlockKind::Paragraph
                };
                current = Some(match current {
                    Some((s, _, k)) => (s, end, k),
                    None => (start, end, block),
                });
            }
        }
        offset = end;
        index += 1;
    }
    flush(&mut current, &mut outline);
    outline
}

/// Appended to the main file so the full compile records every heading's and
/// equation's counter value, in document order.
pub const PROBE: &str = r#"
#context [#metadata((
  headings: query(heading).map(h => counter(heading).at(h.location())),
  equations: query(math.equation).map(e => (e.block, counter(math.equation).at(e.location()))),
)) <prose-counters>]
"#;

/// Counter values at each heading and equation of the full document, with the
/// element's place in the source.
#[derive(Debug, Default, Clone)]
pub struct Counters {
    pub headings: Vec<(FileId, usize, Vec<i64>)>,
    pub equations: Vec<(FileId, usize, Vec<i64>)>,
}

fn ints(value: &Value) -> Vec<i64> {
    match value {
        Value::Array(items) => items.iter().filter_map(|v| v.clone().cast::<i64>().ok()).collect(),
        Value::Int(n) => vec![*n],
        _ => vec![],
    }
}

impl Counters {
    pub fn read(engine: &Engine, document: &PagedDocument) -> Self {
        let introspector = document.introspector();
        let Some(probe) = introspector.query(&Selector::Label(Label::new(PicoStr::intern("prose-counters")).unwrap())).first().cloned()
        else {
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
                    Value::Array(pair) if pair.len() == 2 => {
                        (pair.at(0, None).ok().and_then(|v| v.cast::<bool>().ok()).unwrap_or(false),
                         pair.at(1, None).map(|v| ints(&v)).unwrap_or_default())
                    }
                    _ => (false, vec![]),
                })
                .collect(),
            _ => vec![],
        };
        let place = |span: Span| engine.locate(span).map(|(id, range)| (id, range.start));
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
        Self { headings, equations }
    }

    /// The counter value just before `at` in `file`: the last element in
    /// document order before the first element of `file` at or after `at`.
    fn before(list: &[(FileId, usize, Vec<i64>)], file: FileId, at: usize) -> Option<Vec<i64>> {
        let after = list.iter().position(|(id, start, _)| *id == file && *start >= at);
        let end = after.unwrap_or_else(|| {
            list.iter().rposition(|(id, start, _)| *id == file && *start < at).map(|i| i + 1).unwrap_or(0)
        });
        list[..end].last().map(|(_, _, value)| value.clone())
    }
}

/// What a reference to each label displays in the full document. A block
/// rendered alone cannot resolve a reference to a label outside it, so the
/// block document shows this text. A reference is drawn as a link to its
/// target's location: the text inside the link's rectangle is what it shows.
pub fn reference_texts(document: &PagedDocument) -> HashMap<String, String> {
    struct Found {
        links: Vec<((f64, f64, f64, f64), typst::introspection::Location)>,
        texts: Vec<(f64, f64, String)>,
    }
    fn walk(frame: &Frame, ts: Transform, found: &mut Found) {
        for (pos, item) in frame.items() {
            match item {
                FrameItem::Group(group) => {
                    let ts = ts.pre_concat(Transform::translate(pos.x, pos.y)).pre_concat(group.transform);
                    walk(&group.frame, ts, found);
                }
                FrameItem::Link(typst::model::Destination::Location(location), size) => {
                    let a = pos.transform(ts);
                    let b = Point::new(pos.x + size.x, pos.y + size.y).transform(ts);
                    found.links.push(((a.x.to_pt(), a.y.to_pt(), b.x.to_pt(), b.y.to_pt()), *location));
                }
                FrameItem::Text(text) => {
                    let at = pos.transform(ts);
                    found.texts.push((at.x.to_pt(), at.y.to_pt(), text.text.to_string()));
                }
                _ => {}
            }
        }
    }
    let introspector = document.introspector();
    let mut texts = HashMap::new();
    for page in document.pages() {
        let mut found = Found { links: vec![], texts: vec![] };
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

/// Labels a block refers to (`@x`, `<x>` in code) and labels it defines.
fn labels(text: &str) -> (Vec<(usize, String, bool)>, Vec<String>) {
    let root = typst::syntax::parse(text);
    let mut uses = Vec::new();
    let mut defined = Vec::new();
    fn walk(node: &SyntaxNode, offset: usize, in_markup: bool, uses: &mut Vec<(usize, String, bool)>, defined: &mut Vec<String>) {
        match node.kind() {
            SyntaxKind::Ref => {
                let name = node.children().find(|c| c.kind() == SyntaxKind::RefMarker)
                    .map(|m| m.leaf_text().trim_start_matches('@').to_string()).unwrap_or_default();
                uses.push((offset, name, true));
            }
            SyntaxKind::Label => {
                let name = node.leaf_text().trim_start_matches('<').trim_end_matches('>').to_string();
                if in_markup { defined.push(name) } else { uses.push((offset, name, false)) }
            }
            _ => {}
        }
        let markup = matches!(node.kind(), SyntaxKind::Markup);
        let code = matches!(node.kind(), SyntaxKind::Code | SyntaxKind::Args | SyntaxKind::FuncCall | SyntaxKind::Array);
        let mut at = offset;
        for child in node.children() {
            walk(child, at, if markup { true } else if code { false } else { in_markup }, uses, defined);
            at += child.len();
        }
    }
    walk(&root, 0, true, &mut uses, &mut defined);
    (uses, defined)
}

/// One glyph of a rendered block, in block coordinates (points), with the byte
/// offset in the original file it came from, if any.
#[derive(Debug, Clone)]
pub struct GlyphBox {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub source: Option<usize>,
    pub generated: bool,
}

pub struct Rendered {
    pub svg: String,
    pub width: f64,
    pub height: f64,
    pub glyphs: Vec<GlyphBox>,
    pub text: String,
    pub document: String,
}

/// Builds the block document: context, a page as wide as the measure, counter
/// state, then the block itself.
pub fn block_document(
    engine: &Engine,
    file: FileId,
    file_text: &str,
    outline: &Outline,
    main_outline: Option<(&str, &Outline)>,
    block: &Block,
    counters: &Counters,
    references: &HashMap<String, String>,
    width_pt: f64,
) -> (String, usize) {
    let mut doc = String::new();
    if let Some((main_text, main_outline)) = main_outline {
        for range in &main_outline.context {
            doc.push_str(&main_text[range.clone()]);
            doc.push('\n');
        }
    }
    for range in outline.context.iter().filter(|r| r.end <= block.range.start) {
        doc.push_str(&file_text[range.clone()]);
        doc.push('\n');
    }
    doc.push_str(&format!(
        "#set page(width: {width_pt}pt, height: auto, margin: (x: 0pt, top: 0.25em, bottom: 0.4em), header: none, footer: none, numbering: none)\n"
    ));
    let _ = engine;
    if let Some(value) = Counters::before(&counters.headings, file, block.range.start) {
        let list: Vec<String> = value.iter().map(|n| n.to_string()).collect();
        doc.push_str(&format!("#counter(heading).update(({},))\n", list.join(", ")));
    }
    if let Some(value) = Counters::before(&counters.equations, file, block.range.start) {
        if let Some(n) = value.first() {
            doc.push_str(&format!("#counter(math.equation).update({n})\n"));
        }
    }
    // Labels outside the block get a stub, and references to them show the
    // text they have in the full document.
    let (uses, defined) = labels(&file_text[block.range.clone()]);
    let mut stubbed = std::collections::HashSet::new();
    for (offset, name, is_ref) in uses {
        if defined.contains(&name) || name.is_empty() {
            continue;
        }
        if stubbed.insert(name.clone()) {
            doc.push_str(&format!("#metadata(none) <{name}>\n"));
        }
        if is_ref {
            let _ = offset;
            let shown = references.get(&name).cloned().unwrap_or_else(|| "??".into());
            let quoted = shown.replace('\\', "\\\\").replace('"', "\\\"");
            doc.push_str(&format!("#show ref.where(target: <{name}>): \"{quoted}\"\n"));
        }
    }
    // A label at the start of a block attaches to the element before it. Give
    // it an invisible element, so it never renames a stub.
    doc.push_str("#metadata(none)\n");
    let prefix = doc.len();
    doc.push_str(&file_text[block.range.clone()]);
    doc.push('\n');
    (doc, prefix)
}

pub fn render(
    engine: &Engine,
    id: FileId,
    document: String,
    prefix: usize,
    block_start: usize,
) -> Result<Rendered, Vec<SourceDiagnostic>> {
    engine.set_text(id, document.clone());
    let doc = engine.compile(id)?;
    let page = doc.pages().first().ok_or_else(Vec::new)?;
    let svg = typst_svg::svg(page, &typst_svg::SvgOptions { render_bleed: false, pretty: false });
    let mut glyphs = Vec::new();
    let mut text = String::new();
    collect(&page.frame, Transform::identity(), &mut glyphs, &mut text);
    let mut spans: HashMap<Span, Option<(FileId, Range<usize>)>> = HashMap::new();
    let mapped = glyphs
        .into_iter()
        .map(|(rect, span, offset)| {
            let located = *spans.entry(span).or_insert_with(|| engine.locate(span)).as_ref().map(|(f, r)| (*f, r.start)).as_ref().unwrap_or(&(id, usize::MAX));
            let (file, start) = located;
            // Detached spans and spans in the block document's prefix (stub
            // reference text) are generated, not typed by the writer.
            let generated = span.is_detached() || (file == id && start != usize::MAX && start + (offset as usize) < prefix);
            let source = (!generated && file == id && start != usize::MAX && start + offset as usize >= prefix)
                .then(|| start + offset as usize - prefix + block_start);
            GlyphBox { x: rect.0, y: rect.1, width: rect.2, height: rect.3, source, generated }
        })
        .collect();
    Ok(Rendered {
        svg,
        width: page.frame.width().to_pt(),
        height: page.frame.height().to_pt(),
        glyphs: mapped,
        text,
        document,
    })
}

fn collect(frame: &Frame, ts: Transform, out: &mut Vec<((f64, f64, f64, f64), Span, u16)>, text: &mut String) {
    for (pos, item) in frame.items() {
        match item {
            FrameItem::Group(group) => {
                let ts = ts.pre_concat(Transform::translate(pos.x, pos.y)).pre_concat(group.transform);
                collect(&group.frame, ts, out, text);
            }
            FrameItem::Text(item) => {
                text.push_str(&item.text);
                text.push(' ');
                let mut x = Abs::zero();
                for glyph in &item.glyphs {
                    let advance = glyph.x_advance.at(item.size);
                    let origin = Point::new(pos.x + x, pos.y - item.size).transform(ts);
                    out.push((
                        (origin.x.to_pt(), origin.y.to_pt(), advance.to_pt(), item.size.to_pt()),
                        glyph.span.0,
                        glyph.span.1,
                    ));
                    x += advance;
                }
            }
            _ => {}
        }
    }
}
