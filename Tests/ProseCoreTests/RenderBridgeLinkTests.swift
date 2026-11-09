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
        #expect(MemoryLayout<PRRenderResult>.size == 168 && MemoryLayout<PRRenderOptions>.size == 16)
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
    }
}
