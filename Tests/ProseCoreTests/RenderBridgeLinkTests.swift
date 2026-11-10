import ProseRenderFFI
import Testing

/// The app links one Rust library (Engine/RenderBridge) that exports the renderer's
/// function table next to the parser's. The parser's table is covered by SyntaxTreeTests.
struct RenderBridgeLinkTests {
    @Test func renderTableMatchesTheHeaderSwiftCompiledAgainst() {
        let api = prose_render_api().pointee
        #expect(api.abi_version == PR_RENDER_ABI_VERSION)
        #expect(Int(api.block_size) == MemoryLayout<PRBlock>.size)
        #expect(Int(api.glyph_size) == MemoryLayout<PRGlyphBox>.size)
        #expect(Int(api.result_size) == MemoryLayout<PRRenderResult>.size)
        #expect(Int(api.refresh_size) == MemoryLayout<PRRefreshInfo>.size)
        #expect(Int(api.stats_size) == MemoryLayout<PRCacheStats>.size)
        #expect(Int(api.options_size) == MemoryLayout<PRRenderOptions>.size)
        #expect(MemoryLayout<PRRenderResult>.size == 208 && MemoryLayout<PRRenderOptions>.size == 16)
        #expect(MemoryLayout<PRRenderAPI>.size == 168)
        #expect(PR_RENDER_ABI_VERSION == 6)
        #expect(PR_NO_FONT == UInt32.max)
    }

    @Test func callsWithoutAnEngineFailSafely() throws {
        let api = prose_render_api().pointee
        let stats = api.cache_stats(nil)
        #expect(stats.entries == 0 && stats.bytes == 0 && stats.hits == 0 && stats.misses == 0)
        var options = PRRenderOptions()
        options.bitmap_scale = 2
        let result = api.render(nil, "main.typ", 0, 1, 300, &options)
        defer { api.result_free(result) }
        let error = try #require(result.pointee.error)
        #expect(!String(cString: error).isEmpty)
        #expect(result.pointee.svg == nil && result.pointee.glyph_count == 0 && result.pointee.bitmap == nil)
        #expect(result.pointee.text == nil && result.pointee.text_length == 0)
        #expect(api.files_changed(nil, nil, 0) == 0)
        #expect(api.bibliography_files(nil) == nil)
        #expect(api.bibliography_entries(nil, nil, 0) == nil)
        #expect(result.pointee.font == PR_NO_FONT && result.pointee.font_size == 0)
        var bytes: UnsafePointer<UInt8>?
        var length = 1
        var index: UInt32 = 1
        #expect(!api.font_data(nil, 0, &bytes, &length, &index))
        #expect(bytes == nil && length == 0 && index == 0)
        #expect(api.font_face(nil, 0, true, true) == PR_NO_FONT)
        #expect(api.font_info(nil, 0) == nil)
    }
}
