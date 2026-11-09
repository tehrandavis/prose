//! The C ABI: one function table returned by `prose_render_api`. The
//! declarations live in `Sources/ProseRenderFFI/include/ProseRender.h`.
//!
//! Every entry point catches panics and turns them into an error result, so
//! nothing crosses into Swift as an unwind or aborts the app.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{json, Map, Value};

use crate::bibliography::{BibEntry, BibIndex};
use crate::cache::CacheStats;
use crate::engine::{Engine, Options, RenderOptions, Rendered};
use crate::geometry::{GlyphBox, Rect};
use crate::raster::Bitmap;

/// `PR_RENDER_ABI_VERSION`. Increment whenever the table or a struct changes.
/// Version 2 (Phase 3): blocks cover the whole file with four more kinds,
/// `render` takes options, and results carry the drawn area and a bitmap.
/// Version 3 (Phase 5 step A): `files_changed`, and results carry the
/// block's plain text.
/// Version 4 (Phase 5 step B): `bibliography_files` and
/// `bibliography_entries`, which return JSON.
pub const ABI_VERSION: u32 = 4;

/// An engine, opaque to C.
pub struct PREngine {
    engine: Engine,
}

/// One block; see `ProseRender.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PRBlock {
    pub start: u32,
    pub end: u32,
    pub kind: u32,
}

/// What the last refresh found; see `ProseRender.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PRRefreshInfo {
    pub ok: bool,
    pub errors: u32,
    pub warnings: u32,
    pub pages: u32,
    pub headings: u32,
    pub equations: u32,
    pub references: u32,
}

/// How to render one block; see `ProseRender.h`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct PRRenderOptions {
    pub use_text_color: bool,
    pub text_color: [u8; 4],
    pub bitmap_scale: f64,
}

/// One render result; see `ProseRender.h`.
#[repr(C)]
#[derive(Debug)]
pub struct PRRenderResult {
    pub error: *const c_char,
    pub svg: *const u8,
    pub svg_length: usize,
    pub width: f64,
    pub height: f64,
    pub baseline: f64,
    pub ink: Rect,
    pub drawn: Rect,
    pub glyphs: *const GlyphBox,
    pub glyph_count: usize,
    pub bitmap: *const u8,
    pub bitmap_length: usize,
    pub bitmap_row_bytes: usize,
    pub bitmap_width: u32,
    pub bitmap_height: u32,
    pub cached: bool,
    pub text: *const u8,
    pub text_length: usize,
}

/// The result handed to C, with what keeps its pointers alive. The C struct
/// comes first, so a pointer to this is a pointer to it.
#[repr(C)]
struct ResultBox {
    result: PRRenderResult,
    rendered: Option<Arc<Rendered>>,
    glyphs: Vec<GlyphBox>,
    bitmap: Option<Bitmap>,
    error: Option<CString>,
}

/// The function table returned by `prose_render_api`.
#[repr(C)]
pub struct PRRenderAPI {
    pub abi_version: u32,
    pub block_size: u32,
    pub glyph_size: u32,
    pub result_size: u32,
    pub refresh_size: u32,
    pub stats_size: u32,
    pub options_size: u32,
    pub engine_create: unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const *const c_char,
        usize,
        *const *const c_char,
        usize,
        u64,
        *mut *mut c_char,
    ) -> *mut PREngine,
    pub engine_free: unsafe extern "C" fn(*mut PREngine),
    pub set_text: unsafe extern "C" fn(*mut PREngine, *const c_char, *const u8, usize) -> bool,
    pub refresh: unsafe extern "C" fn(*mut PREngine, *mut PRRefreshInfo) -> bool,
    pub blocks: unsafe extern "C" fn(*mut PREngine, *const c_char, *mut usize) -> *mut PRBlock,
    pub blocks_free: unsafe extern "C" fn(*mut PRBlock, usize),
    pub render: unsafe extern "C" fn(
        *mut PREngine,
        *const c_char,
        u32,
        u32,
        f64,
        *const PRRenderOptions,
    ) -> *mut PRRenderResult,
    pub result_free: unsafe extern "C" fn(*mut PRRenderResult),
    pub cache_stats: unsafe extern "C" fn(*mut PREngine) -> CacheStats,
    pub last_error: unsafe extern "C" fn(*mut PREngine) -> *mut c_char,
    pub string_free: unsafe extern "C" fn(*mut c_char),
    pub files_changed: unsafe extern "C" fn(*mut PREngine, *const *const c_char, usize) -> usize,
    pub bibliography_files: unsafe extern "C" fn(*mut PREngine) -> *mut c_char,
    pub bibliography_entries:
        unsafe extern "C" fn(*mut PREngine, *const *const c_char, usize) -> *mut c_char,
}

fn guarded<T>(fallback: impl FnOnce() -> T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or_else(|_| fallback())
}

/// A C string the caller owns, with any interior NUL replaced.
fn owned_string(text: &str) -> *mut c_char {
    CString::new(text.replace('\0', " ")).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// `text` must be null or a NUL-terminated string.
unsafe fn c_str<'a>(text: *const c_char) -> Option<&'a str> {
    if text.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees a NUL-terminated string.
    unsafe { CStr::from_ptr(text) }.to_str().ok()
}

/// # Safety
/// `items` must be null or point to `count` NUL-terminated strings.
unsafe fn c_paths(items: *const *const c_char, count: usize) -> Option<Vec<PathBuf>> {
    if count == 0 {
        return Some(vec![]);
    }
    if items.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees `count` readable pointers.
    let items = unsafe { std::slice::from_raw_parts(items, count) };
    // SAFETY: each pointer is null or a NUL-terminated string.
    items
        .iter()
        .map(|item| unsafe { c_str(*item) }.map(PathBuf::from))
        .collect()
}

/// # Safety
/// `engine` must be null or a live engine from `engine_create`.
unsafe fn engine<'a>(engine: *mut PREngine) -> Option<&'a Engine> {
    // SAFETY: forwarded caller contract.
    unsafe { engine.as_ref() }.map(|e| &e.engine)
}

/// # Safety
/// See `ProseRender.h`.
unsafe extern "C" fn engine_create(
    root: *const c_char,
    main: *const c_char,
    package_dirs: *const *const c_char,
    package_dir_count: usize,
    font_dirs: *const *const c_char,
    font_dir_count: usize,
    cache_budget: u64,
    error: *mut *mut c_char,
) -> *mut PREngine {
    let result = guarded(
        || Err("engine creation panicked".to_string()),
        || {
            // SAFETY: forwarded caller contract.
            let (root, main) = unsafe { (c_str(root), c_str(main)) };
            let (Some(root), Some(main)) = (root, main) else {
                return Err("root and main must be UTF-8 paths".to_string());
            };
            // SAFETY: forwarded caller contract.
            let package_dirs = unsafe { c_paths(package_dirs, package_dir_count) }
                .ok_or("package directories must be UTF-8 paths")?;
            // SAFETY: forwarded caller contract.
            let font_dirs = unsafe { c_paths(font_dirs, font_dir_count) }
                .ok_or("font directories must be UTF-8 paths")?;
            Engine::new(Options {
                root: root.into(),
                main: main.into(),
                package_dirs,
                font_dirs,
                cache_budget: usize::try_from(cache_budget).unwrap_or(usize::MAX),
            })
        },
    );
    match result {
        Ok(engine) => Box::into_raw(Box::new(PREngine { engine })),
        Err(message) => {
            // SAFETY: `error` is null or writable.
            if let Some(out) = unsafe { error.as_mut() } {
                *out = owned_string(&message);
            }
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `engine` must be null or come from `engine_create` and not be used afterwards.
unsafe extern "C" fn engine_free(engine: *mut PREngine) {
    if !engine.is_null() {
        guarded(
            || (),
            || {
                // SAFETY: the caller transfers an engine created by `engine_create`.
                drop(unsafe { Box::from_raw(engine) })
            },
        );
    }
}

/// # Safety
/// `engine` must be null or live; `path` null or NUL-terminated; `utf8` null
/// or valid for `length` bytes.
unsafe extern "C" fn set_text(
    engine: *mut PREngine,
    path: *const c_char,
    utf8: *const u8,
    length: usize,
) -> bool {
    guarded(
        || false,
        || {
            // SAFETY: forwarded caller contract.
            let (Some(engine), Some(path)) =
                (unsafe { self::engine(engine) }, unsafe { c_str(path) })
            else {
                return false;
            };
            let text = if length == 0 {
                Some("")
            } else if utf8.is_null() {
                None
            } else {
                // SAFETY: the caller guarantees `length` readable bytes.
                std::str::from_utf8(unsafe { std::slice::from_raw_parts(utf8, length) }).ok()
            };
            match text {
                Some(text) => engine.set_text(Path::new(path), text).is_ok(),
                None => false,
            }
        },
    )
}

/// # Safety
/// `engine` must be null or live; `info` null or writable.
unsafe extern "C" fn refresh(engine: *mut PREngine, info: *mut PRRefreshInfo) -> bool {
    guarded(
        || false,
        || {
            // SAFETY: forwarded caller contract.
            let Some(engine) = (unsafe { self::engine(engine) }) else {
                return false;
            };
            let found = engine.refresh();
            let count = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
            // SAFETY: `info` is null or writable.
            if let Some(out) = unsafe { info.as_mut() } {
                *out = PRRefreshInfo {
                    ok: found.ok,
                    errors: count(found.errors),
                    warnings: count(found.warnings),
                    pages: count(found.pages),
                    headings: count(found.headings),
                    equations: count(found.equations),
                    references: count(found.references),
                };
            }
            found.ok
        },
    )
}

/// # Safety
/// `engine` must be null or live; `path` null or NUL-terminated; `count` null
/// or writable.
unsafe extern "C" fn blocks(
    engine: *mut PREngine,
    path: *const c_char,
    count: *mut usize,
) -> *mut PRBlock {
    let list = guarded(
        || None,
        || {
            // SAFETY: forwarded caller contract.
            let (Some(engine), Some(path)) =
                (unsafe { self::engine(engine) }, unsafe { c_str(path) })
            else {
                return None;
            };
            let blocks = engine.blocks(Path::new(path)).ok()?;
            Some(
                blocks
                    .iter()
                    .map(|b| PRBlock {
                        start: b.start as u32,
                        end: b.end as u32,
                        kind: b.kind.code(),
                    })
                    .collect::<Vec<_>>()
                    .into_boxed_slice(),
            )
        },
    );
    // SAFETY: `count` is null or writable.
    if let Some(out) = unsafe { count.as_mut() } {
        *out = list.as_ref().map_or(0, |list| list.len());
    }
    match list {
        Some(list) => Box::into_raw(list) as *mut PRBlock,
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `blocks` must be null or come from `blocks` with the `count` it reported.
unsafe extern "C" fn blocks_free(blocks: *mut PRBlock, count: usize) {
    if !blocks.is_null() {
        // SAFETY: the caller returns the boxed slice `blocks` allocated.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(blocks, count)) });
    }
}

fn error_result(message: &str) -> ResultBox {
    let error = CString::new(message.replace('\0', " ")).unwrap_or_default();
    ResultBox {
        result: PRRenderResult {
            error: error.as_ptr(),
            svg: std::ptr::null(),
            svg_length: 0,
            width: 0.0,
            height: 0.0,
            baseline: 0.0,
            ink: Rect::default(),
            drawn: Rect::default(),
            glyphs: std::ptr::null(),
            glyph_count: 0,
            bitmap: std::ptr::null(),
            bitmap_length: 0,
            bitmap_row_bytes: 0,
            bitmap_width: 0,
            bitmap_height: 0,
            cached: false,
            text: std::ptr::null(),
            text_length: 0,
        },
        rendered: None,
        glyphs: Vec::new(),
        bitmap: None,
        error: Some(error),
    }
}

/// # Safety
/// `engine` must be null or live; `path` null or NUL-terminated; `options`
/// null or readable.
unsafe extern "C" fn render(
    engine: *mut PREngine,
    path: *const c_char,
    start: u32,
    end: u32,
    width_pt: f64,
    options: *const PRRenderOptions,
) -> *mut PRRenderResult {
    let boxed = guarded(
        || error_result("the render panicked"),
        || {
            // SAFETY: forwarded caller contract.
            let Some(engine) = (unsafe { self::engine(engine) }) else {
                return error_result("no engine");
            };
            // SAFETY: forwarded caller contract.
            let Some(path) = (unsafe { c_str(path) }) else {
                return error_result("the path must be a UTF-8 string");
            };
            // SAFETY: `options` is null or readable.
            let options = unsafe { options.as_ref() }.copied().unwrap_or_default();
            let options = RenderOptions {
                text_color: options.use_text_color.then_some(options.text_color),
                bitmap_scale: options.bitmap_scale,
            };
            let rendered = engine.render_with(
                Path::new(path),
                start as usize,
                end as usize,
                width_pt,
                &options,
            );
            match rendered {
                Ok(mut render) => {
                    let r = &render.rendered;
                    let bitmap = render.bitmap.take();
                    let (pixels, length, row_bytes, width, height) = match &bitmap {
                        Some(b) => (
                            b.data.as_ptr(),
                            b.data.len(),
                            b.row_bytes,
                            b.width,
                            b.height,
                        ),
                        None => (std::ptr::null(), 0, 0, 0, 0),
                    };
                    ResultBox {
                        result: PRRenderResult {
                            error: std::ptr::null(),
                            svg: r.svg.as_ptr(),
                            svg_length: r.svg.len(),
                            width: r.width,
                            height: r.height,
                            baseline: r.baseline,
                            ink: r.ink,
                            drawn: r.drawn,
                            glyphs: if render.glyphs.is_empty() {
                                std::ptr::null()
                            } else {
                                render.glyphs.as_ptr()
                            },
                            glyph_count: render.glyphs.len(),
                            bitmap: pixels,
                            bitmap_length: length,
                            bitmap_row_bytes: row_bytes,
                            bitmap_width: width,
                            bitmap_height: height,
                            cached: render.cached,
                            text: r.text.as_ptr(),
                            text_length: r.text.len(),
                        },
                        rendered: Some(render.rendered.clone()),
                        glyphs: render.glyphs,
                        bitmap,
                        error: None,
                    }
                }
                Err(message) => error_result(&message),
            }
        },
    );
    Box::into_raw(Box::new(boxed)) as *mut PRRenderResult
}

/// # Safety
/// `result` must be null or come from `render` and not be used afterwards.
unsafe extern "C" fn result_free(result: *mut PRRenderResult) {
    if !result.is_null() {
        // SAFETY: `render` returned a `ResultBox`, whose first field is the result.
        drop(unsafe { Box::from_raw(result as *mut ResultBox) });
    }
}

/// # Safety
/// `engine` must be null or live.
unsafe extern "C" fn cache_stats(engine: *mut PREngine) -> CacheStats {
    guarded(CacheStats::default, || {
        // SAFETY: forwarded caller contract.
        unsafe { self::engine(engine) }.map_or_else(CacheStats::default, Engine::cache_stats)
    })
}

/// # Safety
/// `engine` must be null or live.
unsafe extern "C" fn last_error(engine: *mut PREngine) -> *mut c_char {
    guarded(std::ptr::null_mut, || {
        // SAFETY: forwarded caller contract.
        match unsafe { self::engine(engine) }.and_then(Engine::last_error) {
            Some(message) => owned_string(&message),
            None => std::ptr::null_mut(),
        }
    })
}

/// # Safety
/// `text` must be null or a string this library returned, not used afterwards.
unsafe extern "C" fn string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller returns a string from `CString::into_raw`.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// # Safety
/// `engine` must be null or live; `paths` null or `count` NUL-terminated strings.
unsafe extern "C" fn files_changed(
    engine: *mut PREngine,
    paths: *const *const c_char,
    count: usize,
) -> usize {
    guarded(
        || 0,
        || {
            // SAFETY: forwarded caller contract.
            let (Some(engine), Some(paths)) = (unsafe { self::engine(engine) }, unsafe {
                c_paths(paths, count)
            }) else {
                return 0;
            };
            engine.files_changed(&paths)
        },
    )
}

/// # Safety
/// `engine` must be null or live.
unsafe extern "C" fn bibliography_files(engine: *mut PREngine) -> *mut c_char {
    guarded(std::ptr::null_mut, || {
        // SAFETY: forwarded caller contract.
        match unsafe { self::engine(engine) } {
            Some(engine) => owned_string(&Value::from(engine.bibliography_files()).to_string()),
            None => std::ptr::null_mut(),
        }
    })
}

/// # Safety
/// `engine` must be null or live; `paths` null or `count` NUL-terminated strings.
unsafe extern "C" fn bibliography_entries(
    engine: *mut PREngine,
    paths: *const *const c_char,
    count: usize,
) -> *mut c_char {
    guarded(std::ptr::null_mut, || {
        // SAFETY: forwarded caller contract.
        let (Some(engine), Some(paths)) = (unsafe { self::engine(engine) }, unsafe {
            c_paths(paths, count)
        }) else {
            return std::ptr::null_mut();
        };
        owned_string(&index_json(&engine.bibliography(&paths)).to_string())
    })
}

fn entry_json(entry: &BibEntry) -> Value {
    let mut object = Map::new();
    object.insert("key".into(), entry.key.clone().into());
    object.insert("type".into(), entry.kind.clone().into());
    let authors: Vec<Value> = entry
        .authors
        .iter()
        .map(|author| match &author.given {
            Some(given) => json!({ "family": author.family, "given": given }),
            None => json!({ "family": author.family }),
        })
        .collect();
    object.insert("authors".into(), authors.into());
    let optional = [
        ("title", &entry.title),
        ("container", &entry.container),
        ("doi", &entry.doi),
        ("url", &entry.url),
    ];
    for (name, value) in optional {
        if let Some(value) = value {
            object.insert(name.into(), value.clone().into());
        }
    }
    if let Some(year) = entry.year {
        object.insert("year".into(), year.into());
    }
    object.insert("file".into(), entry.file.clone().into());
    object.insert("line".into(), entry.line.into());
    Value::Object(object)
}

/// The index as `ProseRender.h` describes it.
pub fn index_json(index: &BibIndex) -> Value {
    json!({
        "entries": index.entries.iter().map(entry_json).collect::<Vec<_>>(),
        "errors": index.errors.iter().map(|e| json!({
            "file": e.file, "line": e.line, "message": e.message,
        })).collect::<Vec<_>>(),
        "files": index.files.iter().map(|f| json!({
            "path": f.path, "entries": f.entries, "accepted": f.accepted,
        })).collect::<Vec<_>>(),
    })
}

static API: PRRenderAPI = PRRenderAPI {
    abi_version: ABI_VERSION,
    block_size: std::mem::size_of::<PRBlock>() as u32,
    glyph_size: std::mem::size_of::<GlyphBox>() as u32,
    result_size: std::mem::size_of::<PRRenderResult>() as u32,
    refresh_size: std::mem::size_of::<PRRefreshInfo>() as u32,
    stats_size: std::mem::size_of::<CacheStats>() as u32,
    options_size: std::mem::size_of::<PRRenderOptions>() as u32,
    engine_create,
    engine_free,
    set_text,
    refresh,
    blocks,
    blocks_free,
    render,
    result_free,
    cache_stats,
    last_error,
    string_free,
    files_changed,
    bibliography_files,
    bibliography_entries,
};

/// The render engine's C function table.
#[no_mangle]
pub extern "C" fn prose_render_api() -> *const PRRenderAPI {
    &API
}
