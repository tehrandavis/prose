//! The C ABI, called through the function table as Swift will.

mod common;

use std::ffi::{CStr, CString};

use common::{utf16_index, Project};
use prose_render::ffi::{
    prose_render_api, PRBlock, PRRefreshInfo, PRRenderAPI, PRRenderOptions, PRRenderResult,
    ABI_VERSION,
};
use prose_render::{CacheStats, GlyphBox, Rect};

fn api() -> &'static PRRenderAPI {
    // SAFETY: the table is a static.
    unsafe { &*prose_render_api() }
}

fn take_string(api: &PRRenderAPI, text: *mut std::ffi::c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string from the library, released once.
    let value = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    unsafe { (api.string_free)(text) };
    Some(value)
}

#[test]
fn the_table_reports_its_version_and_sizes() {
    let api = api();
    assert_eq!(api.abi_version, ABI_VERSION);
    assert_eq!(api.block_size as usize, std::mem::size_of::<PRBlock>());
    assert_eq!(api.glyph_size as usize, std::mem::size_of::<GlyphBox>());
    assert_eq!(
        api.result_size as usize,
        std::mem::size_of::<PRRenderResult>()
    );
    assert_eq!(
        api.refresh_size as usize,
        std::mem::size_of::<PRRefreshInfo>()
    );
    assert_eq!(api.stats_size as usize, std::mem::size_of::<CacheStats>());
    assert_eq!(
        api.options_size as usize,
        std::mem::size_of::<PRRenderOptions>()
    );
    // The C layouts in ProseRender.h, on a 64-bit target.
    assert_eq!(std::mem::size_of::<PRBlock>(), 12);
    assert_eq!(std::mem::size_of::<GlyphBox>(), 20);
    assert_eq!(std::mem::size_of::<Rect>(), 32);
    assert_eq!(std::mem::size_of::<PRRefreshInfo>(), 28);
    assert_eq!(std::mem::size_of::<CacheStats>(), 40);
    assert_eq!(std::mem::size_of::<PRRenderResult>(), 168);
    assert_eq!(std::mem::offset_of!(PRRenderResult, ink), 48);
    assert_eq!(std::mem::offset_of!(PRRenderResult, drawn), 80);
    assert_eq!(std::mem::offset_of!(PRRenderResult, glyphs), 112);
    assert_eq!(std::mem::offset_of!(PRRenderResult, bitmap), 128);
    assert_eq!(std::mem::offset_of!(PRRenderResult, bitmap_width), 152);
    assert_eq!(std::mem::offset_of!(PRRenderResult, cached), 160);
    assert_eq!(std::mem::size_of::<PRRenderOptions>(), 16);
    assert_eq!(std::mem::offset_of!(PRRenderOptions, text_color), 1);
    assert_eq!(std::mem::offset_of!(PRRenderOptions, bitmap_scale), 8);
    assert_eq!(std::mem::offset_of!(PRRenderAPI, options_size), 24);
    assert_eq!(std::mem::offset_of!(PRRenderAPI, engine_create), 32);
    assert_eq!(std::mem::size_of::<PRRenderAPI>(), 120);
}

#[test]
fn a_round_trip_through_the_c_abi() {
    let text = "#set heading(numbering: \"1.\")\n\n= Über 😀\n\nSee @end, then $x^2$ and 漢字.\n\n= End <end>\n";
    let project = Project::new(&[("main.typ", text)]);
    let api = api();
    let root = CString::new(project.root.to_str().unwrap()).unwrap();
    let main = CString::new("main.typ").unwrap();
    let packages = [CString::new("/nonexistent/packages").unwrap()];
    let package_ptrs: Vec<_> = packages.iter().map(|p| p.as_ptr()).collect();
    let mut error = std::ptr::null_mut();
    // SAFETY: valid strings and arrays; the engine is freed below.
    let engine = unsafe {
        (api.engine_create)(
            root.as_ptr(),
            main.as_ptr(),
            package_ptrs.as_ptr(),
            1,
            std::ptr::null(),
            0,
            0,
            &mut error,
        )
    };
    assert!(!engine.is_null(), "{:?}", take_string(api, error));
    assert!(error.is_null());

    unsafe {
        let path = CString::new(project.path("main.typ").to_str().unwrap()).unwrap();
        assert!((api.set_text)(
            engine,
            path.as_ptr(),
            text.as_ptr(),
            text.len()
        ));
        // Invalid UTF-8 is refused.
        assert!(!(api.set_text)(
            engine,
            path.as_ptr(),
            [0xff, 0xfe].as_ptr(),
            2
        ));

        let mut info = PRRefreshInfo::default();
        assert!((api.refresh)(engine, &mut info));
        assert!(info.ok);
        assert_eq!((info.pages, info.headings, info.references), (1, 2, 1));

        let mut count = 0usize;
        let blocks = (api.blocks)(engine, path.as_ptr(), &mut count);
        assert!(!blocks.is_null());
        assert_eq!(count, 4);
        let list = std::slice::from_raw_parts(blocks, count).to_vec();
        (api.blocks_free)(blocks, count);
        assert_eq!(
            list.iter().map(|b| b.kind).collect::<Vec<_>>(),
            [4, 1, 3, 1]
        );
        assert_eq!(list[2].start as usize, utf16_index(text, "See"));

        let paragraph = list[2];
        let result = (api.render)(
            engine,
            path.as_ptr(),
            paragraph.start,
            paragraph.end,
            300.0,
            std::ptr::null(),
        );
        let r: &PRRenderResult = &*result;
        assert!(r.error.is_null());
        assert!(!r.cached);
        let svg = std::str::from_utf8(std::slice::from_raw_parts(r.svg, r.svg_length)).unwrap();
        assert!(svg.starts_with("<svg"));
        assert_eq!(r.width, 300.0);
        assert!(r.height > 0.0 && r.baseline > 0.0 && r.baseline < r.height);
        assert!(r.ink.width > 0.0 && r.ink.height > 0.0);
        assert!(r.drawn.x <= 0.0 && r.drawn.width >= r.width);
        assert!(r.bitmap.is_null() && r.bitmap_width == 0 && r.bitmap_length == 0);
        let glyphs = std::slice::from_raw_parts(r.glyphs, r.glyph_count);
        let kanji = utf16_index(text, "漢字") as i32;
        assert!(glyphs.iter().any(|g| g.source == kanji));
        assert!(
            glyphs.iter().any(|g| g.source == -1),
            "reference text is generated"
        );
        assert!(glyphs.iter().all(|g| g.source == -1
            || (paragraph.start as i32..paragraph.end as i32).contains(&g.source)));
        (api.result_free)(result);

        // Options: a bitmap from the cached vector result.
        let options = PRRenderOptions {
            use_text_color: false,
            text_color: [0; 4],
            bitmap_scale: 2.0,
        };
        let again = (api.render)(
            engine,
            path.as_ptr(),
            paragraph.start,
            paragraph.end,
            300.0,
            &options,
        );
        let a: &PRRenderResult = &*again;
        assert!(a.error.is_null() && a.cached);
        assert_eq!(a.bitmap_width, (a.drawn.width * 2.0).ceil() as u32);
        assert_eq!(a.bitmap_height, (a.drawn.height * 2.0).ceil() as u32);
        assert_eq!(a.bitmap_row_bytes, a.bitmap_width as usize * 4);
        assert_eq!(
            a.bitmap_length,
            a.bitmap_row_bytes * a.bitmap_height as usize
        );
        let pixels = std::slice::from_raw_parts(a.bitmap, a.bitmap_length);
        assert!(pixels.chunks(4).any(|p| p[3] >= 250), "ink is opaque");
        (api.result_free)(again);
        // A scale out of range is an error result.
        let options = PRRenderOptions {
            bitmap_scale: -1.0,
            ..options
        };
        let bad = (api.render)(
            engine,
            path.as_ptr(),
            paragraph.start,
            paragraph.end,
            300.0,
            &options,
        );
        assert!(!(*bad).error.is_null() && (*bad).bitmap.is_null());
        (api.result_free)(bad);
        let stats = (api.cache_stats)(engine);
        assert_eq!((stats.entries, stats.hits, stats.misses), (1, 1, 1));
        assert_eq!(stats.budget, 64 * 1024 * 1024);

        // Errors come back as results and as last_error.
        let bad = (api.render)(engine, path.as_ptr(), 5, 2, 300.0, std::ptr::null());
        assert!(!(*bad).error.is_null());
        assert!((*bad).svg.is_null() && (*bad).glyph_count == 0);
        let message = CStr::from_ptr((*bad).error).to_string_lossy().into_owned();
        (api.result_free)(bad);
        assert_eq!(take_string(api, (api.last_error)(engine)), Some(message));

        let missing = CString::new("missing.typ").unwrap();
        let mut count = 7usize;
        assert!((api.blocks)(engine, missing.as_ptr(), &mut count).is_null());
        assert_eq!(count, 0);

        (api.engine_free)(engine);
    }
}

#[test]
fn null_and_invalid_arguments_fail_safely() {
    let api = api();
    unsafe {
        let mut error = std::ptr::null_mut();
        let root = CString::new("/nonexistent/prose/root").unwrap();
        let main = CString::new("main.typ").unwrap();
        let engine = (api.engine_create)(
            root.as_ptr(),
            main.as_ptr(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            0,
            &mut error,
        );
        assert!(engine.is_null());
        assert!(take_string(api, error).unwrap().contains("root"));
        // A count with no array is refused.
        let engine = (api.engine_create)(
            root.as_ptr(),
            main.as_ptr(),
            std::ptr::null(),
            2,
            std::ptr::null(),
            0,
            0,
            std::ptr::null_mut(),
        );
        assert!(engine.is_null());

        let null = std::ptr::null_mut();
        assert!(!(api.set_text)(null, main.as_ptr(), std::ptr::null(), 0));
        assert!(!(api.refresh)(null, std::ptr::null_mut()));
        let mut count = 3;
        assert!((api.blocks)(null, main.as_ptr(), &mut count).is_null());
        assert_eq!(count, 0);
        let result = (api.render)(null, main.as_ptr(), 0, 1, 300.0, std::ptr::null());
        assert!(!(*result).error.is_null());
        (api.result_free)(result);
        assert_eq!((api.cache_stats)(null), CacheStats::default());
        assert!((api.last_error)(null).is_null());
        (api.engine_free)(null);
        (api.blocks_free)(std::ptr::null_mut(), 0);
        (api.result_free)(std::ptr::null_mut());
        (api.string_free)(std::ptr::null_mut());
    }
}

#[test]
fn the_syntax_table_is_linked_in() {
    let api = prose_render::lb_syntax_api();
    assert!(!api.is_null());
    // SAFETY: the syntax bridge's static table.
    assert_eq!(unsafe { (*api).abi_version }, prose_syntax::ABI_VERSION);
}
