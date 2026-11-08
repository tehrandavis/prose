//! The engine: fonts, files, the editor's texts, the context from the last
//! full compile, and the block cache, behind one lock.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use typst::diag::{FileError, Warned};
use typst::syntax::{FileId, Lines, RootedPath, Source, Span, VirtualPath, VirtualRoot};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt};
use typst_kit::files::{FileStore, FsRoot};
use typst_kit::fonts::{self, FontStore};
use typst_kit::packages::FsPackages;
use typst_layout::PagedDocument;

use crate::cache::{Cache, CacheStats, Dependencies};
use crate::context::{block_document, reference_texts, BlockInputs, Counters, Shift, PROBE};
use crate::geometry::{first_baseline, walk, GlyphBounds, GlyphBox, Rect};
use crate::outline::{split_tree, BlockKind, Outline};
use crate::world::{Loader, Shared, View};

/// How many evictions memoized Typst work (comemo) survives unused.
///
/// Typst memoizes evaluation and layout in process-wide caches that shrink
/// only when told to. A full compile of a 450-page book leaves about 700 MB
/// there, which the next refresh reuses to finish in a fifth of the time. A
/// block render adds about 150 KB that nothing reuses once our own cache holds
/// the result. Without eviction both grow for as long as the app runs.
const MEMO_MAX_AGE: usize = 3;

/// An eviction runs after every refresh and after this many renders that
/// compiled (cache hits add nothing to Typst's caches). Work that every block
/// shares, such as evaluating packages and context lines, is used by each
/// render and so stays. The full compile's work survives 383 compiled renders
/// without a refresh; after that, the next refresh starts cold. While typing,
/// refreshes come far more often than that.
const RENDERS_PER_EVICTION: usize = 128;

/// How to create an engine.
#[derive(Debug, Clone)]
pub struct Options {
    /// The project folder. Files outside it cannot be read.
    pub root: PathBuf,
    /// The main file, absolute or relative to the root.
    pub main: PathBuf,
    /// Package directories (`namespace/name/version`), read only. Missing
    /// directories are skipped.
    pub package_dirs: Vec<PathBuf>,
    /// Font directories, scanned once in addition to Typst's embedded fonts
    /// and the system fonts.
    pub font_dirs: Vec<PathBuf>,
    /// The cache's byte budget; 0 means the default, 64 MB.
    pub cache_budget: usize,
}

impl Options {
    pub fn new(root: impl Into<PathBuf>, main: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            main: main.into(),
            package_dirs: vec![],
            font_dirs: vec![],
            cache_budget: 0,
        }
    }
}

/// What the last `refresh` found.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RefreshInfo {
    /// Whether the full compile succeeded. When it failed, renders keep the
    /// context of the last compile that succeeded.
    pub ok: bool,
    pub errors: usize,
    pub warnings: usize,
    /// Pages of the full document; 0 when the compile failed.
    pub pages: usize,
    /// Headings, block equations and references in the context renders use.
    pub headings: usize,
    pub equations: usize,
    pub references: usize,
    /// The first error's message, when the compile failed.
    pub message: Option<String>,
}

/// A block as a UTF-16 range of its file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockRange {
    pub start: usize,
    pub end: usize,
    pub kind: BlockKind,
}

/// A typeset block. Geometry is in points, relative to the block's top-left
/// corner.
#[derive(Debug, Clone)]
pub struct Rendered {
    pub svg: String,
    pub width: f64,
    pub height: f64,
    /// The first line's baseline, from the top.
    pub baseline: f64,
    /// The bounds of everything drawn, from the frames.
    pub ink: Rect,
    /// Glyph boxes with `source` relative to the block's start, or -1, so the
    /// same block document at another place in the file can share the entry.
    /// `Render::glyphs` has the offsets in the file.
    pub relative_glyphs: Vec<GlyphBox>,
    /// The plain text of the block's text runs, separated by spaces. For tests
    /// and measurement.
    pub text: String,
}

impl Rendered {
    /// Approximate memory held, for the cache budget.
    pub fn bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.svg.len()
            + self.text.len()
            + self.relative_glyphs.len() * std::mem::size_of::<GlyphBox>()
    }
}

/// A render's result, and whether it came from the cache.
#[derive(Debug, Clone)]
pub struct Render {
    pub rendered: Arc<Rendered>,
    /// Glyph boxes with `source` as the UTF-16 offset in the file, or -1 for
    /// generated text.
    pub glyphs: Vec<GlyphBox>,
    pub cached: bool,
}

impl Render {
    fn new(rendered: Arc<Rendered>, start16: usize, cached: bool) -> Self {
        let glyphs = rendered
            .relative_glyphs
            .iter()
            .map(|glyph| GlyphBox {
                source: if glyph.source < 0 {
                    -1
                } else {
                    glyph.source.saturating_add(start16 as i32)
                },
                ..*glyph
            })
            .collect();
        Self {
            rendered,
            glyphs,
            cached,
        }
    }
}

/// Counter values and reference texts from the last full compile that
/// succeeded, with the source of each file that holds a counted element, as
/// that compile saw it.
#[derive(Default)]
struct Context {
    counters: Counters,
    references: HashMap<String, String>,
    snapshots: HashMap<FileId, Source>,
}

struct State {
    shared: Shared,
    root: PathBuf,
    main: FileId,
    /// Edit versions of the files in `shared.texts`. Files on disk are 0.
    versions: HashMap<FileId, u64>,
    /// Paths already resolved, so a render does not touch the file system.
    ids: HashMap<PathBuf, FileId>,
    next_version: u64,
    outlines: HashMap<FileId, (u64, Arc<Outline>)>,
    shifts: HashMap<FileId, (u64, Shift)>,
    /// The main file with the probe appended, edited in place so Typst
    /// reparses only what changed.
    probed: Option<Source>,
    context: Context,
    last: RefreshInfo,
    cache: Cache,
    glyph_bounds: GlyphBounds,
    error: Option<String>,
    /// Renders that compiled since the last eviction.
    compiled_renders: usize,
}

/// The render engine. Calls from several threads are safe and serialized.
pub struct Engine {
    state: Mutex<State>,
}

fn file_error(error: FileError) -> String {
    format!("{error:?}")
}

/// A path made absolute and canonical where it exists. A file that does not
/// exist yet keeps its name under its canonical folder.
fn canonical(path: &Path) -> PathBuf {
    if let Ok(path) = path.canonicalize() {
        return path;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => parent
            .canonicalize()
            .map(|p| p.join(name))
            .unwrap_or_else(|_| path.to_path_buf()),
        _ => path.to_path_buf(),
    }
}

/// The byte offset of a UTF-16 offset, rejecting one past the end or inside
/// a surrogate pair.
fn exact_byte(lines: &Lines<String>, utf16: usize) -> Option<usize> {
    let byte = lines.utf16_to_byte(utf16)?;
    (lines.byte_to_utf16(byte)? == utf16).then_some(byte)
}

/// UTF-16 offsets of ascending byte offsets, in one pass over the text.
fn utf16_offsets(text: &str, bytes: &[usize]) -> Vec<usize> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut chars = text.char_indices().peekable();
    let mut utf16 = 0;
    for &byte in bytes {
        while let Some(&(at, c)) = chars.peek() {
            if at >= byte {
                break;
            }
            utf16 += c.len_utf16();
            chars.next();
        }
        out.push(utf16);
    }
    out
}

/// For each byte of `text` (and one past the end), the UTF-16 offset of the
/// character it belongs to.
fn utf16_map(text: &str) -> Vec<u32> {
    let mut map = Vec::with_capacity(text.len() + 1);
    let mut utf16 = 0u32;
    for c in text.chars() {
        map.extend(std::iter::repeat_n(utf16, c.len_utf8()));
        utf16 += c.len_utf16() as u32;
    }
    map.push(utf16);
    map
}

fn first_message(errors: &[typst::diag::SourceDiagnostic]) -> String {
    errors
        .first()
        .map(|e| e.message.to_string())
        .unwrap_or_else(|| "compile failed".into())
}

impl Engine {
    /// Scans fonts and opens the project. Fails if the root is not a folder
    /// or the main file is outside it.
    pub fn new(options: Options) -> Result<Self, String> {
        let root = options
            .root
            .canonicalize()
            .map_err(|e| format!("root {:?}: {e}", options.root))?;
        if !root.is_dir() {
            return Err(format!("root {root:?} is not a folder"));
        }
        let main = Self::id_in(&root, &options.main)?;
        let mut fonts = FontStore::new();
        fonts.extend(fonts::embedded());
        fonts.extend(fonts::system());
        for dir in options.font_dirs.iter().filter(|dir| dir.is_dir()) {
            fonts.extend(fonts::scan(dir));
        }
        let packages = options
            .package_dirs
            .iter()
            .filter(|p| p.is_dir())
            .map(FsPackages::new)
            .collect();
        let shared = Shared {
            library: LazyHash::new(Library::builder().build()),
            fonts,
            files: FileStore::new(Loader {
                project: FsRoot::new(root.clone()),
                packages,
            }),
            texts: HashMap::new(),
        };
        Ok(Self {
            state: Mutex::new(State {
                shared,
                root,
                main,
                versions: HashMap::new(),
                ids: HashMap::new(),
                next_version: 1,
                outlines: HashMap::new(),
                shifts: HashMap::new(),
                probed: None,
                context: Context::default(),
                last: RefreshInfo::default(),
                cache: Cache::new(options.cache_budget),
                glyph_bounds: GlyphBounds::default(),
                error: None,
                compiled_renders: 0,
            }),
        })
    }

    fn id_in(root: &Path, path: &Path) -> Result<FileId, String> {
        let full = canonical(&if path.is_absolute() {
            path.to_path_buf()
        } else {
            root.join(path)
        });
        let vpath = VirtualPath::virtualize(root, &full)
            .map_err(|e| format!("{path:?} is not in the project: {e:?}"))?;
        Ok(RootedPath::new(VirtualRoot::Project, vpath).intern())
    }

    /// The state, even after a caught panic: Typst panics only while
    /// compiling, which reads the state but does not change it.
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Records an error for `last_error` and passes the result on.
    fn noted<T>(state: &mut State, result: Result<T, String>) -> Result<T, String> {
        if let Err(error) = &result {
            state.error = Some(error.clone());
        }
        result
    }

    /// The project folder, canonical.
    pub fn root(&self) -> PathBuf {
        self.lock().root.clone()
    }

    /// The current text of a file: the editor's text if it was set, otherwise
    /// the file on disk.
    pub fn text(&self, path: &Path) -> Result<String, String> {
        let mut state = self.lock();
        let result = state
            .id(path)
            .and_then(|id| state.shared.source(id).map_err(file_error))
            .map(|source| source.text().to_string());
        Self::noted(&mut state, result)
    }

    /// Replaces a file's text in memory (the editor buffer). Typst reparses
    /// only the changed part on the next compile.
    pub fn set_text(&self, path: &Path, text: &str) -> Result<(), String> {
        let mut state = self.lock();
        let result = state.id(path).map(|id| state.set_text(id, text));
        Self::noted(&mut state, result)
    }

    /// Compiles the whole document with the counter probe and keeps its
    /// counters and reference texts for later renders. A failed compile keeps
    /// the previous context.
    pub fn refresh(&self) -> RefreshInfo {
        let mut state = self.lock();
        let info = state.refresh();
        if let Some(message) = &info.message {
            state.error = Some(message.clone());
        }
        info
    }

    /// What the last refresh found.
    pub fn last_refresh(&self) -> RefreshInfo {
        self.lock().last.clone()
    }

    /// The text a reference to `label` shows in the last good full compile.
    pub fn reference_text(&self, label: &str) -> Option<String> {
        self.lock().context.references.get(label).cloned()
    }

    /// The file's blocks as UTF-16 ranges, in order. Context lines are not
    /// blocks.
    pub fn blocks(&self, path: &Path) -> Result<Vec<BlockRange>, String> {
        let mut state = self.lock();
        let result = state.blocks(path);
        Self::noted(&mut state, result)
    }

    /// Renders the block at UTF-16 `[start, end)` of a file, `width_pt` wide,
    /// with the file's current text and the last refreshed context.
    pub fn render(
        &self,
        path: &Path,
        start: usize,
        end: usize,
        width_pt: f64,
    ) -> Result<Render, String> {
        let mut state = self.lock();
        let result = state.render(path, start, end, width_pt);
        Self::noted(&mut state, result)
    }

    pub fn cache_stats(&self) -> CacheStats {
        self.lock().cache.stats()
    }

    /// The most recent error from any call, if there was one.
    pub fn last_error(&self) -> Option<String> {
        self.lock().error.clone()
    }
}

impl State {
    fn id(&mut self, path: &Path) -> Result<FileId, String> {
        if let Some(id) = self.ids.get(path) {
            return Ok(*id);
        }
        let id = Engine::id_in(&self.root, path)?;
        self.ids.insert(path.to_path_buf(), id);
        Ok(id)
    }

    fn version(versions: &HashMap<FileId, u64>, id: FileId) -> u64 {
        versions.get(&id).copied().unwrap_or(0)
    }

    fn set_text(&mut self, id: FileId, text: &str) {
        match self.shared.texts.get_mut(&id) {
            Some(source) => {
                source.replace(text);
            }
            None => {
                self.shared
                    .texts
                    .insert(id, Source::new(id, text.to_string()));
            }
        }
        self.versions.insert(id, self.next_version);
        self.next_version += 1;
    }

    fn outline(&mut self, id: FileId, source: &Source) -> Arc<Outline> {
        let version = Self::version(&self.versions, id);
        if let Some((at, outline)) = self.outlines.get(&id) {
            if *at == version {
                return outline.clone();
            }
        }
        let outline = Arc::new(split_tree(source.root(), source.text()));
        self.outlines.insert(id, (version, outline.clone()));
        outline
    }

    /// Maps offsets in the file's current text to the last full compile's.
    fn shift(&mut self, id: FileId, source: &Source) -> Shift {
        let Some(snapshot) = self.context.snapshots.get(&id) else {
            return Shift::identity();
        };
        let version = Self::version(&self.versions, id);
        if let Some((at, shift)) = self.shifts.get(&id) {
            if *at == version {
                return *shift;
            }
        }
        let shift = Shift::between(snapshot, source.text());
        self.shifts.insert(id, (version, shift));
        shift
    }

    fn refresh(&mut self) -> RefreshInfo {
        let main_source = match self.shared.source(self.main) {
            Ok(source) => source,
            Err(error) => {
                let info = RefreshInfo {
                    message: Some(file_error(error)),
                    errors: 1,
                    ..self.context_counts()
                };
                self.last = info.clone();
                return info;
            }
        };
        let probed_text = format!("{}\n{PROBE}", main_source.text());
        match &mut self.probed {
            Some(source) => {
                source.replace(&probed_text);
            }
            None => self.probed = Some(Source::new(self.main, probed_text)),
        }
        let probed = self.probed.clone().expect("probed source");
        let (outcome, warnings) = {
            let view = View::new(&self.shared, self.main, Some(&probed));
            let Warned { output, warnings } = typst::compile::<PagedDocument>(&view);
            let outcome = match output {
                Ok(document) => {
                    let counters = Counters::read(&view, &document);
                    let references = reference_texts(&document);
                    let files: HashSet<FileId> = counters
                        .headings
                        .iter()
                        .chain(&counters.equations)
                        .map(|(id, _, _)| *id)
                        .collect();
                    let snapshots = files
                        .into_iter()
                        .filter_map(|id| {
                            let source = if id == self.main {
                                Ok(main_source.clone())
                            } else {
                                self.shared.source(id)
                            };
                            source.ok().map(|source| (id, source))
                        })
                        .collect();
                    Ok((
                        Context {
                            counters,
                            references,
                            snapshots,
                        },
                        document.pages().len(),
                    ))
                }
                Err(errors) => Err((errors.len(), first_message(&errors))),
            };
            (outcome, warnings.len())
        };
        let info = match outcome {
            Ok((context, pages)) => {
                self.context = context;
                self.shifts.clear();
                RefreshInfo {
                    ok: true,
                    warnings,
                    pages,
                    ..self.context_counts()
                }
            }
            Err((errors, message)) => RefreshInfo {
                ok: false,
                errors,
                warnings,
                message: Some(message),
                ..self.context_counts()
            },
        };
        self.evict();
        self.last = info.clone();
        info
    }

    /// Drops memoized Typst work that recent compiles have not used. The
    /// caches are shared by every engine in the process, so one engine's
    /// evictions also age the others' entries.
    fn evict(&mut self) {
        typst::comemo::evict(MEMO_MAX_AGE);
        self.compiled_renders = 0;
    }

    fn context_counts(&self) -> RefreshInfo {
        RefreshInfo {
            headings: self.context.counters.headings.len(),
            equations: self.context.counters.equations.len(),
            references: self.context.references.len(),
            ..RefreshInfo::default()
        }
    }

    fn blocks(&mut self, path: &Path) -> Result<Vec<BlockRange>, String> {
        let id = self.id(path)?;
        let source = self.shared.source(id).map_err(file_error)?;
        let outline = self.outline(id, &source);
        let bytes: Vec<usize> = outline
            .blocks
            .iter()
            .flat_map(|b| [b.range.start, b.range.end])
            .collect();
        let utf16 = utf16_offsets(source.text(), &bytes);
        Ok(outline
            .blocks
            .iter()
            .zip(utf16.chunks(2))
            .map(|(block, pair)| BlockRange {
                start: pair[0],
                end: pair[1],
                kind: block.kind,
            })
            .collect())
    }

    fn render(
        &mut self,
        path: &Path,
        start16: usize,
        end16: usize,
        width_pt: f64,
    ) -> Result<Render, String> {
        if !(width_pt.is_finite() && width_pt > 0.0 && width_pt <= 100_000.0) {
            return Err(format!("width {width_pt} pt is not a usable measure"));
        }
        let id = self.id(path)?;
        let source = self.shared.source(id).map_err(file_error)?;
        let range = Self::byte_range(source.lines(), start16, end16)?;
        let outline = self.outline(id, &source);
        let main = if id != self.main {
            let main_source = self.shared.source(self.main).map_err(file_error)?;
            let main_outline = self.outline(self.main, &main_source);
            Some((main_source, main_outline))
        } else {
            None
        };
        let at = self.shift(id, &source).map(range.start);
        let (doc, prefix) = block_document(&BlockInputs {
            file_text: source.text(),
            outline: &outline,
            main: main
                .as_ref()
                .map(|(source, outline)| (source.text(), outline.as_ref())),
            range: range.clone(),
            heading: Counters::before(&self.context.counters.headings, id, at),
            equation: Counters::before(&self.context.counters.equations, id, at),
            references: &self.context.references,
            width_pt,
        });
        let key = typst::utils::hash128(&(&doc, width_pt.to_bits()));
        let versions = &self.versions;
        let current = |deps: &Dependencies| {
            deps.iter()
                .all(|(file, v)| Self::version(versions, *file) == *v)
        };
        if let Some(rendered) = self.cache.get(key, current) {
            return Ok(Render::new(rendered, start16, true));
        }

        self.compiled_renders += 1;
        if self.compiled_renders >= RENDERS_PER_EVICTION {
            self.evict();
        }
        let block_id = sibling(id, "__prose_block__.typ");
        let block_source = Source::new(block_id, doc);
        let view = View::new(&self.shared, block_id, Some(&block_source));
        let Warned { output, .. } = typst::compile::<PagedDocument>(&view);
        let document = output.map_err(|errors| first_message(&errors))?;
        let page = document
            .pages()
            .first()
            .ok_or("the block produced no page")?;
        let svg = typst_svg::svg(
            page,
            &typst_svg::SvgOptions {
                render_bleed: false,
                pretty: false,
            },
        );
        let walked = walk(&page.frame, &mut self.glyph_bounds);
        let baseline = first_baseline(&page.frame, &walked);

        // Map each glyph's span back to the file. Spans in the block document's
        // prefix (reference text), detached spans and other files are generated.
        let block_len = range.len();
        let map = utf16_map(&source.text()[range.clone()]);
        let mut spans: HashMap<Span, Option<(FileId, usize)>> = HashMap::new();
        let glyphs = walked
            .glyphs
            .iter()
            .map(|raw| {
                let located = *spans.entry(raw.span).or_insert_with(|| {
                    view.locate(raw.span)
                        .map(|(file, range)| (file, range.start))
                });
                let source = match located {
                    Some((file, start)) if file == block_id => {
                        let at = start + raw.offset as usize;
                        if at >= prefix && at - prefix <= block_len {
                            map[at - prefix] as i32
                        } else {
                            -1
                        }
                    }
                    _ => -1,
                };
                let (x, y, width, height) = raw.rect;
                GlyphBox {
                    x: x as f32,
                    y: y as f32,
                    width: width as f32,
                    height: height as f32,
                    source,
                }
            })
            .collect();
        let rendered = Arc::new(Rendered {
            svg,
            width: page.frame.width().to_pt(),
            height: page.frame.height().to_pt(),
            baseline,
            ink: walked.ink,
            relative_glyphs: glyphs,
            text: walked.text,
        });
        let dependencies: Dependencies = view
            .files_read()
            .into_iter()
            .map(|file| (file, Self::version(&self.versions, file)))
            .collect();
        drop(view);
        self.cache.insert(key, rendered.clone(), dependencies);
        Ok(Render::new(rendered, start16, false))
    }

    fn byte_range(
        lines: &Lines<String>,
        start16: usize,
        end16: usize,
    ) -> Result<Range<usize>, String> {
        let start = exact_byte(lines, start16)
            .ok_or_else(|| format!("start {start16} is past the end or inside a character"))?;
        let end = exact_byte(lines, end16)
            .ok_or_else(|| format!("end {end16} is past the end or inside a character"))?;
        if start >= end {
            return Err(format!("the range {start16}..{end16} is empty"));
        }
        Ok(start..end)
    }
}

/// A file id beside `near`, for a document that exists only in memory, so
/// relative paths in its context lines resolve as they do in `near`.
fn sibling(near: FileId, name: &str) -> FileId {
    let parent = near
        .vpath()
        .parent()
        .unwrap_or_else(|| VirtualPath::new("/").unwrap());
    RootedPath::new(VirtualRoot::Project, parent.join(name).unwrap()).intern()
}
