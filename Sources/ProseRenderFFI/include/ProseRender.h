// Per-block Typst rendering behind a small C ABI (Engine/RenderBridge).
//
// The macOS app links Engine/RenderBridge as a static library, which also
// carries the syntax bridge, so the same library exports lb_syntax_api
// (ProseSyntax.h) and prose_render_api. The app reaches the renderer only
// through the function table below.
//
// All text offsets are UTF-16 code units, compatible with NSString and
// NSRange. Offsets that would split a surrogate pair are rejected. Geometry
// is in points, relative to the block's top-left corner, y pointing down.
//
// An engine is internally locked: calls from several threads are safe but
// run one at a time. refresh is slow (a full compile, 0.3 to 2 s on a book);
// call it off the main thread. Every entry point catches internal panics and
// reports them as errors; nothing aborts the app.
#ifndef PROSE_RENDER_H
#define PROSE_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

// Increment whenever PRRenderAPI or any struct below changes.
#define PR_RENDER_ABI_VERSION 6u
// PRGlyphBox.source for generated text: numbers, reference text, text from
// other files.
#define PR_NO_SOURCE (-1)
// PRRenderResult.font for a block with no text of its own, and what
// font_face returns for an unknown font.
#define PR_NO_FONT UINT32_MAX
// PRBlock.kind values. Codes are never reused; new kinds are appended.
#define PR_BLOCK_HEADING 1u
// A display equation ($ x $ with a space or newline after the opening $).
#define PR_BLOCK_EQUATION 2u
#define PR_BLOCK_PARAGRAPH 3u
// A #set, #show, #let or #import line, with a comment on the same line. Its
// text is also the context of every later block's document. Not meant to be
// rendered alone (it renders with no ink).
#define PR_BLOCK_CONTEXT 4u
// An #include line, with a comment on the same line. Not meant to be
// rendered alone (it would render the whole included file).
#define PR_BLOCK_INCLUDE 5u
// A single fenced raw block (```), with an optional label.
#define PR_BLOCK_RAW 6u
// Only bullet (-), numbered (+, 1.) and term (/) list items.
#define PR_BLOCK_LIST 7u
// Only comments: nothing to render. The editor shows it as a pill.
#define PR_BLOCK_COMMENT 8u
// The largest PRRenderOptions.bitmap_scale render accepts.
#define PR_MAX_BITMAP_SCALE 16.0
// A bitmap with more pixels than this (128 MB) is not made; the result has
// no bitmap but is otherwise complete. 1 << 25.
#define PR_MAX_BITMAP_PIXELS 33554432u

typedef struct PREngine PREngine;

// One top-level block of a file. The blocks of a file are in order, do not
// overlap, and cover every character that is not whitespace between them. A
// block ends at its last character that is not whitespace.
typedef struct {
    uint32_t start;
    uint32_t end;
    uint32_t kind;
} PRBlock;

// One glyph's box: the glyph's advance by the font's ascender to descender.
typedef struct {
    float x;
    float y;
    float width;
    float height;
    // UTF-16 offset in the original file of the character the glyph starts
    // at, or PR_NO_SOURCE.
    int32_t source;
} PRGlyphBox;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} PRRect;

// How to render one block. Pass NULL to render for options all zero.
typedef struct {
    // Dark appearance (version 5). The block renders with the document's
    // own colours; then every paint of the laid-out page (text, shape fills
    // and strokes, gradient stops; never images) is mapped in OKLab onto the
    // dark page: black ink becomes #E8E4DE and white fades into #262626, hue
    // kept. Applies to the SVG and the bitmap. Part of the cache key.
    bool dark;
    // Pixels per point for a bitmap of the drawn area, at most
    // PR_MAX_BITMAP_SCALE; 0 means no bitmap. Bitmaps are made on every call
    // that asks for one, from the cached vector result, and are not cached
    // themselves, so the scale is not part of the cache key.
    double bitmap_scale;
} PRRenderOptions;

// One render. When error is non-NULL it is a NUL-terminated message (the
// first Typst diagnostic, or why the call failed) and every other field is
// zero or NULL. All pointers stay valid until result_free.
typedef struct {
    const char *_Nullable error;
    // SVG of the drawn area, UTF-8, not NUL-terminated. The page has no fill:
    // everything outside ink is transparent.
    const uint8_t *_Nullable svg;
    size_t svg_length;
    // The block's page: the measure wide, as tall as its content plus a
    // margin of 0.25 em above and 0.4 em below.
    double width;
    double height;
    // The first line's baseline, from the top.
    double baseline;
    // The bounds of everything drawn, from the frames, not the page box.
    PRRect ink;
    // What the SVG and the bitmap cover: the union of the page and the ink,
    // in the same coordinates as everything else. Its x and y are 0 or
    // negative, and it is wider or taller than the page when punctuation
    // hangs past the page's edges. Draw the SVG or bitmap into this rectangle
    // and glyph boxes, baseline and ink line up with it.
    PRRect drawn;
    const PRGlyphBox *_Nullable glyphs;
    size_t glyph_count;
    // The drawn area rasterized at the options' bitmap_scale: premultiplied
    // RGBA, 8 bits per channel, sRGB, rows from the top, pixel (0, 0) at the
    // drawn area's top-left corner. bitmap_width and bitmap_height are the
    // drawn area's size times the scale, rounded up; the fraction of a pixel
    // past the drawn area is transparent. NULL when no bitmap was asked for or
    // it would exceed PR_MAX_BITMAP_PIXELS.
    const uint8_t *_Nullable bitmap;
    size_t bitmap_length;
    size_t bitmap_row_bytes;
    uint32_t bitmap_width;
    uint32_t bitmap_height;
    // Whether the vector result came from the cache.
    bool cached;
    // The plain text of the block's text runs, separated by spaces, UTF-8, not
    // NUL-terminated: what the block shows, generated text included. For tests
    // and measurement.
    const uint8_t *_Nullable text;
    size_t text_length;
    // The block's text font (version 6): the font and size of the text runs
    // that hold the most of the block's own glyphs (glyphs with a source;
    // generated text does not count), grouped by font and size, the first
    // group on a tie. font is the font's index in the engine's font book: the
    // same face has the same index for the engine's life (the book is built
    // once, at engine_create, and refresh never changes it), and each face of
    // a collection has its own. Pass it to font_data, font_face and font_info
    // of the same engine only. PR_NO_FONT, with font_size and line_pitch 0,
    // when the block has no own glyph. Cached results carry it too.
    double font_size;
    // The smallest distance in points between consecutive baselines of that
    // font's runs, baselines closer than half the size counting as one line;
    // 0 when its text is on one line. The smallest, because a line with tall
    // inline math is pushed down and list items have spacing between them.
    double line_pitch;
    uint32_t font;
} PRRenderResult;

// What the last refresh found. headings, equations and references describe
// the context renders use: after a failed compile, the previous good one.
typedef struct {
    bool ok;
    uint32_t errors;
    uint32_t warnings;
    // Pages of the full document; 0 when the compile failed.
    uint32_t pages;
    uint32_t headings;
    uint32_t equations;
    uint32_t references;
} PRRefreshInfo;

typedef struct {
    uint64_t entries;
    uint64_t bytes;
    uint64_t budget;
    uint64_t hits;
    uint64_t misses;
} PRCacheStats;

typedef struct {
    uint32_t abi_version;
    // sizeof each struct as compiled into the library.
    uint32_t block_size;
    uint32_t glyph_size;
    uint32_t result_size;
    uint32_t refresh_size;
    uint32_t stats_size;
    uint32_t options_size;
    // Scans fonts (Typst's embedded fonts, system fonts, then font_dirs) and
    // opens the project. main is absolute or relative to root. Package
    // directories are read only; nothing is downloaded. Missing directories
    // are skipped. cache_budget is in bytes; 0 means 64 MB. Returns NULL on
    // failure and, if error is non-NULL, stores a message there; release it
    // with string_free. Release the engine with engine_free.
    PREngine *_Nullable (*_Nonnull engine_create)(const char *_Nullable root, const char *_Nullable main,
                                                  const char *_Nullable const *_Nullable package_dirs,
                                                  size_t package_dir_count,
                                                  const char *_Nullable const *_Nullable font_dirs,
                                                  size_t font_dir_count, uint64_t cache_budget,
                                                  char *_Nullable *_Nullable error);
    void (*_Nonnull engine_free)(PREngine *_Nullable engine);
    // Replaces a file's text in memory with UTF-8 text (the editor buffer).
    // path is absolute or relative to the root, and need not exist on disk.
    // Cheap. Returns false for an invalid path or invalid UTF-8.
    bool (*_Nonnull set_text)(PREngine *_Nullable engine, const char *_Nullable path, const uint8_t *_Nullable utf8,
                              size_t length);
    // Compiles the main file with the counter probe and keeps its counters
    // and reference texts for later renders. Returns whether the compile
    // succeeded; a failed compile keeps the previous context. info may be
    // NULL. On failure last_error holds the first error's message.
    bool (*_Nonnull refresh)(PREngine *_Nullable engine, PRRefreshInfo *_Nullable info);
    // The file's blocks in order, from its current text: every top-level
    // piece, context lines, #include lines and comments included. Release
    // with blocks_free. NULL on failure, with count set to 0.
    PRBlock *_Nullable (*_Nonnull blocks)(PREngine *_Nullable engine, const char *_Nullable path,
                                          size_t *_Nullable count);
    void (*_Nonnull blocks_free)(PRBlock *_Nullable blocks, size_t count);
    // Renders UTF-16 [start, end) of a file, width_pt points wide, with the
    // file's current text and the last refreshed context. Usually a range
    // from blocks. options may be NULL. The vector result is cached. Never
    // NULL; check error. Release with result_free.
    PRRenderResult *_Nonnull (*_Nonnull render)(PREngine *_Nullable engine, const char *_Nullable path,
                                                uint32_t start, uint32_t end, double width_pt,
                                                const PRRenderOptions *_Nullable options);
    void (*_Nonnull result_free)(PRRenderResult *_Nullable result);
    // Cache counters, for tests and tuning. All zero for a NULL engine.
    PRCacheStats (*_Nonnull cache_stats)(PREngine *_Nullable engine);
    // A copy of the most recent error message from any call on this engine,
    // or NULL if there was none. Release with string_free.
    char *_Nullable (*_Nonnull last_error)(PREngine *_Nullable engine);
    void (*_Nonnull string_free)(char *_Nullable string);
    // Files changed on disk: bibliographies, data, images, Typst files that
    // are not editor buffers. paths are absolute or relative to the root;
    // paths outside the project are ignored. Every file loaded from disk is
    // read again on its next use, and each changed file gets a new version,
    // so cached renders that read it compile again; editor buffers (set_text)
    // keep their text. Cheap: nothing is read or compiled here. Returns how
    // many of the files the main file, the last refresh or any render read;
    // when 0, nothing shown can have changed and no refresh is needed.
    size_t (*_Nonnull files_changed)(PREngine *_Nullable engine, const char *_Nullable const *_Nullable paths,
                                     size_t count);
    // The bibliography files the project's bibliography(...) calls name, as a
    // JSON array of paths relative to the root ("refs.bib", "back/refs.yml"),
    // in the order found: the main file, then each file it includes, depth
    // first, from their current texts. Only string literals count:
    // bibliography("a.bib") and bibliography(("a.bib", "b.yml")), each path
    // relative to the file holding the call ("/x.bib" from the root). Nothing
    // is compiled. "[]" when there is no call. NULL for a NULL engine.
    // Release with string_free.
    char *_Nullable (*_Nonnull bibliography_files)(PREngine *_Nullable engine);
    // The entries of bibliography files (paths absolute or relative to the
    // root; .bib is BibLaTeX, .yml and .yaml Hayagriva), parsed with Hayagriva
    // as Typst parses them, read as a compile reads them: an editor buffer
    // wins over the disk, and a file changed on disk is read again after
    // files_changed. Each file's parse is cached by its version. Returns JSON,
    // released with string_free, or NULL for a NULL engine or a non-UTF-8 path:
    //   {"entries": [{"key", "type", "title"?, "authors": [{"family",
    //     "given"?}], "year"?, "container"?, "doi"?, "url"?, "file", "line"}],
    //    "errors": [{"file", "line", "message"}],
    //    "files": [{"path", "entries", "accepted"}]}
    // type is Hayagriva's entry type in kebab case. authors are the editors
    // when there are no authors. container is the parent's title (journal,
    // book). file is relative to the root; line counts from 1, 0 when
    // unknown. A BibLaTeX or YAML syntax error yields one error and no entries
    // for that file. A field Hayagriva cannot convert yields an error for that
    // entry; the file's other entries are listed and the file is not
    // accepted, because Typst rejects the whole file. A key already listed
    // from an earlier file is left out and reported as a duplicate.
    char *_Nullable (*_Nonnull bibliography_entries)(PREngine *_Nullable engine,
                                                     const char *_Nullable const *_Nullable paths, size_t count);
    // The bytes of the font file that holds font, and the face's index in it
    // (non-zero only in a collection). The bytes are borrowed: they stay
    // valid, unchanged and at the same address until engine_free, and must
    // not be freed or written. Returns false, with *bytes NULL and *length
    // and *index 0, for an unknown font or a NULL engine. Any out-parameter
    // may be NULL.
    bool (*_Nonnull font_data)(PREngine *_Nullable engine, uint32_t font, const uint8_t *_Nullable *_Nullable bytes,
                               size_t *_Nullable length, uint32_t *_Nullable index);
    // The face Typst's font book selects in font's family for weight 700 when
    // strong (else font's own weight) and italic style when emphasis (else
    // font's own style), font's stretch kept. font itself when that selection
    // has font's own weight and style, as for a family with one face.
    // PR_NO_FONT for an unknown font or a NULL engine.
    uint32_t (*_Nonnull font_face)(PREngine *_Nullable engine, uint32_t font, bool strong, bool emphasis);
    // What font is, as JSON released with string_free, or NULL for an unknown
    // font or a NULL engine:
    //   {"family": "Libertinus Serif", "weight": 400, "style": "normal",
    //    "embedded": true}
    // weight is 100 to 900; style is "normal", "italic" or "oblique";
    // embedded is true for Typst's embedded fonts (Libertinus Serif, New
    // Computer Modern, New Computer Modern Math, DejaVu Sans Mono), which
    // macOS does not have.
    char *_Nullable (*_Nonnull font_info)(PREngine *_Nullable engine, uint32_t font);
} PRRenderAPI;

// The renderer's only exported symbol. The same library also exports
// lb_syntax_api (ProseSyntax.h).
const PRRenderAPI *prose_render_api(void);

#pragma clang assume_nonnull end

#endif
