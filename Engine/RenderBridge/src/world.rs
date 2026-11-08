//! Typst's `World` over a project folder, with the editor's buffers on top.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::Mutex;

use typst::diag::{FileError, FileResult, PackageError};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, Source, Span, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, World, WorldExt};
use typst_kit::files::{FileLoader, FileStore, FsRoot};
use typst_kit::fonts::FontStore;
use typst_kit::packages::FsPackages;

/// Loads project files from the folder and packages from local directories.
/// The engine never downloads packages.
pub(crate) struct Loader {
    pub(crate) project: FsRoot,
    pub(crate) packages: Vec<FsPackages>,
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

/// What every compile shares: the standard library, fonts, files on disk and
/// the editor's in-memory texts.
pub(crate) struct Shared {
    pub(crate) library: LazyHash<Library>,
    pub(crate) fonts: FontStore,
    pub(crate) files: FileStore<Loader>,
    /// Editor buffers, which replace or add to the files on disk.
    pub(crate) texts: HashMap<FileId, Source>,
}

impl Shared {
    pub(crate) fn source(&self, id: FileId) -> FileResult<Source> {
        match self.texts.get(&id) {
            Some(source) => Ok(source.clone()),
            None => self.files.source(id),
        }
    }
}

/// One compile: a chosen main file, and optionally one more in-memory source
/// that wins over everything else (the probed main file, or a block
/// document). Records the files it reads, so a cached block can be checked
/// against later edits to its imports.
pub(crate) struct View<'a> {
    pub(crate) shared: &'a Shared,
    pub(crate) main: FileId,
    pub(crate) extra: Option<&'a Source>,
    pub(crate) read: Mutex<HashSet<FileId>>,
}

impl<'a> View<'a> {
    pub(crate) fn new(shared: &'a Shared, main: FileId, extra: Option<&'a Source>) -> Self {
        Self {
            shared,
            main,
            extra,
            read: Mutex::new(HashSet::new()),
        }
    }

    fn note(&self, id: FileId) {
        if let Ok(mut read) = self.read.lock() {
            read.insert(id);
        }
    }

    /// The files this compile read, other than the extra source.
    pub(crate) fn files_read(&self) -> Vec<FileId> {
        self.read
            .lock()
            .map(|read| read.iter().copied().collect())
            .unwrap_or_default()
    }

    /// The byte range of a span, with its file.
    pub(crate) fn locate(&self, span: Span) -> Option<(FileId, Range<usize>)> {
        let id = span.id()?;
        let range = self.range(span)?;
        Some((id, range))
    }
}

impl World for View<'_> {
    fn library(&self) -> &LazyHash<Library> {
        &self.shared.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.shared.fonts.book()
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if let Some(extra) = self.extra.filter(|extra| extra.id() == id) {
            return Ok(extra.clone());
        }
        self.note(id);
        self.shared.source(id)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(extra) = self.extra.filter(|extra| extra.id() == id) {
            return Ok(Bytes::from_string(extra.clone()));
        }
        self.note(id);
        match self.shared.texts.get(&id) {
            Some(source) => Ok(Bytes::from_string(source.clone())),
            None => self.shared.files.file(id),
        }
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.shared.fonts.font(index)
    }

    fn today(&self, _: Option<Duration>) -> Option<Datetime> {
        None
    }
}
