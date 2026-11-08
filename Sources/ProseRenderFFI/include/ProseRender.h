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
#define PR_RENDER_ABI_VERSION 1u
// PRGlyphBox.source for generated text: numbers, reference text, text from
// other files.
#define PR_NO_SOURCE (-1)
// PRBlock.kind values.
#define PR_BLOCK_HEADING 1u
#define PR_BLOCK_EQUATION 2u
#define PR_BLOCK_PARAGRAPH 3u

typedef struct PREngine PREngine;

// One top-level block of a file. Context lines (#set, #show, #let, #import)
// and #include lines are not blocks.
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

// One render. When error is non-NULL it is a NUL-terminated message (the
// first Typst diagnostic, or why the call failed) and every other field is
// zero or NULL. All pointers stay valid until result_free.
typedef struct {
    const char *_Nullable error;
    // SVG bytes, UTF-8, not NUL-terminated.
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
    const PRGlyphBox *_Nullable glyphs;
    size_t glyph_count;
    // Whether the result came from the cache.
    bool cached;
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
    // The file's blocks in order, from its current text. Release with
    // blocks_free. NULL on failure, with count set to 0.
    PRBlock *_Nullable (*_Nonnull blocks)(PREngine *_Nullable engine, const char *_Nullable path,
                                          size_t *_Nullable count);
    void (*_Nonnull blocks_free)(PRBlock *_Nullable blocks, size_t count);
    // Renders UTF-16 [start, end) of a file, width_pt points wide, with the
    // file's current text and the last refreshed context. Usually a range
    // from blocks. Cached. Never NULL; check error. Release with result_free.
    PRRenderResult *_Nonnull (*_Nonnull render)(PREngine *_Nullable engine, const char *_Nullable path,
                                                uint32_t start, uint32_t end, double width_pt);
    void (*_Nonnull result_free)(PRRenderResult *_Nullable result);
    // Cache counters, for tests and tuning. All zero for a NULL engine.
    PRCacheStats (*_Nonnull cache_stats)(PREngine *_Nullable engine);
    // A copy of the most recent error message from any call on this engine,
    // or NULL if there was none. Release with string_free.
    char *_Nullable (*_Nonnull last_error)(PREngine *_Nullable engine);
    void (*_Nonnull string_free)(char *_Nullable string);
} PRRenderAPI;

// The renderer's only exported symbol. The same library also exports
// lb_syntax_api (ProseSyntax.h).
const PRRenderAPI *prose_render_api(void);

#pragma clang assume_nonnull end

#endif
