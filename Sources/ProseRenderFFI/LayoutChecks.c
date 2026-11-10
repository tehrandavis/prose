// Header-only module for the renderer C ABI. The implementation is Rust
// (Engine/RenderBridge); this file pins the layout Swift and Rust agree on.
#include "ProseRender.h"

_Static_assert(sizeof(PRBlock) == 12, "PRBlock layout is part of the ABI");
_Static_assert(offsetof(PRBlock, kind) == 8, "PRBlock layout is part of the ABI");
_Static_assert(sizeof(PRGlyphBox) == 20, "PRGlyphBox layout is part of the ABI");
_Static_assert(offsetof(PRGlyphBox, source) == 16, "PRGlyphBox layout is part of the ABI");
_Static_assert(sizeof(PRRect) == 32, "PRRect layout is part of the ABI");
_Static_assert(sizeof(PRRenderOptions) == 16, "PRRenderOptions layout is part of the ABI");
_Static_assert(offsetof(PRRenderOptions, dark) == 0, "PRRenderOptions layout is part of the ABI");
_Static_assert(offsetof(PRRenderOptions, bitmap_scale) == 8, "PRRenderOptions layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, text) == 168, "PRRenderResult layout is part of the ABI");
_Static_assert(sizeof(PRRenderResult) == 208, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, font_size) == 184, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, line_pitch) == 192, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, font) == 200, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, ink) == 48, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, drawn) == 80, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, glyphs) == 112, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, bitmap) == 128, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, bitmap_width) == 152, "PRRenderResult layout is part of the ABI");
_Static_assert(offsetof(PRRenderResult, cached) == 160, "PRRenderResult layout is part of the ABI");
_Static_assert(sizeof(PRRefreshInfo) == 28, "PRRefreshInfo layout is part of the ABI");
_Static_assert(sizeof(PRCacheStats) == 40, "PRCacheStats layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, options_size) == 24, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, engine_create) == 32, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, string_free) == 112, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, files_changed) == 120, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, bibliography_files) == 128, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, bibliography_entries) == 136, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, font_data) == 144, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, font_face) == 152, "PRRenderAPI layout is part of the ABI");
_Static_assert(offsetof(PRRenderAPI, font_info) == 160, "PRRenderAPI layout is part of the ABI");
_Static_assert(sizeof(PRRenderAPI) == 168, "PRRenderAPI layout is part of the ABI");
_Static_assert(PR_NO_FONT == 0xFFFFFFFFu, "PR_NO_FONT must match the Rust library");
_Static_assert(PR_RENDER_ABI_VERSION == 6u, "PR_RENDER_ABI_VERSION must match the Rust library");
