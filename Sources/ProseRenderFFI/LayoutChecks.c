// Header-only module for the renderer C ABI. The implementation is Rust
// (Engine/RenderBridge); this file pins the layout Swift and Rust agree on.
#include "ProseRender.h"

_Static_assert(sizeof(PRBlock) == 12, "PRBlock layout is part of the ABI");
_Static_assert(offsetof(PRBlock, kind) == 8, "PRBlock layout is part of the ABI");
_Static_assert(sizeof(PRGlyphBox) == 20, "PRGlyphBox layout is part of the ABI");
_Static_assert(offsetof(PRGlyphBox, source) == 16, "PRGlyphBox layout is part of the ABI");
_Static_assert(sizeof(PRRect) == 32, "PRRect layout is part of the ABI");
_Static_assert(sizeof(PRRenderOptions) == 16, "PRRenderOptions layout is part of the ABI");
_Static_assert(offsetof(PRRenderOptions, text_color) == 1, "PRRenderOptions layout is part of the ABI");
_Static_assert(offsetof(PRRenderOptions, bitmap_scale) == 8, "PRRenderOptions layout is part of the ABI");
_Static_assert(sizeof(PRRenderResult) == 168, "PRRenderResult layout is part of the ABI");
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
_Static_assert(sizeof(PRRenderAPI) == 120, "PRRenderAPI layout is part of the ABI");
