#if os(macOS)
    import AppKit
    import Foundation
    @testable import ProseCore
    import ProseRenderFFI
    import ProseTestSupport
    import Testing

    /// A copy of Engine/RenderBridge/fixtures/thesis in the test folder, so tests can
    /// change its files. Removed when the test ends.
    private final class ThesisCopy {
        let root: URL

        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            root = TestPaths.temporaryDirectory.appendingPathComponent("block-renderer-" + UUID().uuidString)
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("Engine/RenderBridge/fixtures/thesis"),
                to: root,
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        var main: URL {
            root.appendingPathComponent("main.typ")
        }

        var method: URL {
            root.appendingPathComponent("sections/method.typ")
        }

        func renderer() async throws -> BlockRenderer {
            try await BlockRenderer(root: root, main: main)
        }

        func text(_ file: URL) throws -> String {
            try String(contentsOf: file, encoding: .utf8)
        }
    }

    /// The block whose text starts with `prefix`.
    private func block(
        startingWith prefix: String,
        in text: String,
        of blocks: [RenderBlock],
    ) throws -> RenderBlock {
        let source = text as NSString
        return try #require(blocks.first { source.substring(with: $0.range).hasPrefix(prefix) })
    }

    /// Glyphs with a source lie inside the block's UTF-16 range.
    private func sourcesFallInside(_ rendered: RenderedBlock, _ block: RenderBlock) -> Bool {
        rendered.glyphs.compactMap(\.source).allSatisfy { NSLocationInRange($0, block.range) }
    }

    @Test func blockRendererRefreshCountsTheThesis() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        let refresh = await renderer.refresh()
        #expect(refresh.succeeded && refresh.errors == 0 && refresh.message == nil)
        #expect(refresh.pages >= 1)
        #expect(refresh.headings == 7)
        #expect(refresh.equations == 3)
        #expect(refresh.references > 0)
    }

    @Test func blockRendererBlocksAreUTF16RangesWithoutContextLines() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        let text = try thesis.text(thesis.main) as NSString
        let blocks = try await renderer.blocks(in: thesis.main)
        let shown = blocks.map { text.substring(with: $0.range) }
        #expect(shown.first == "= Introduction <intro>")
        #expect(!shown.contains { $0.hasPrefix("#set") || $0.hasPrefix("#let") || $0.hasPrefix("#include") })
        #expect(blocks.filter { $0.kind == .heading }.count == 2)
        #expect(blocks.filter { $0.kind == .equation }.count == 2)
        #expect(blocks.contains { $0.kind == .paragraph })
        #expect(blocks.allSatisfy { NSMaxRange($0.range) <= text.length && $0.range.length > 0 })
        #expect(zip(blocks, blocks.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
    }

    @Test func blockRendererRendersAHeadingAndAParagraphWithGeneratedReferences() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        _ = await renderer.refresh()
        let text = try thesis.text(thesis.method)
        let blocks = try await renderer.blocks(in: thesis.method)

        let heading = try block(startingWith: "=== Adaptive staircase", in: text, of: blocks)
        #expect(heading.kind == .heading)
        let title = try await renderer.render(heading.range, in: thesis.method, width: 450).get()
        #expect(!title.cached)
        #expect(title.size.width == 450 && title.size.height > 0)
        #expect(title.baseline > 0 && title.baseline < title.size.height)
        #expect(title.ink.width > 0 && title.ink.height > 0)
        #expect(sourcesFallInside(title, heading))
        // The number "2.2.2" maps to the heading as a whole; the title's letters to themselves.
        let adaptive = (text as NSString).range(of: "Adaptive").location
        #expect(title.glyphs.contains { $0.source == adaptive })
        #expect(title.glyphs.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })

        let paragraph = try block(startingWith: "The threshold was", in: text, of: blocks)
        #expect(paragraph.kind == .paragraph)
        let rendered = try await renderer.render(paragraph.range, in: thesis.method, width: 450).get()
        #expect(sourcesFallInside(rendered, paragraph))
        // The reference texts ("Equation (1)", "Equation (3)") are generated.
        #expect(rendered.glyphs.count { $0.source == nil } >= 4)
        let start = (text as NSString).range(of: "The threshold").location
        #expect(rendered.glyphs.first { $0.source != nil }?.source == start)
    }

    @Test func blockRendererServesASecondIdenticalRenderFromTheCache() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await BlockRenderer(root: thesis.root, main: thesis.main, cacheBudget: 8 << 20)
        _ = await renderer.refresh()
        let first = try #require(await renderer.blocks(in: thesis.main).first)
        let fresh = try await renderer.render(first.range, in: thesis.main, width: 300).get()
        let again = try await renderer.render(first.range, in: thesis.main, width: 300).get()
        #expect(!fresh.cached && again.cached)
        #expect(again.svg == fresh.svg && again.glyphs == fresh.glyphs && again.size == fresh.size)
        let stats = await renderer.cacheStats()
        #expect(stats.entries == 1 && stats.hits == 1 && stats.misses == 1)
        #expect(stats.bytes > 0 && stats.bytes <= stats.budget && stats.budget == 8 << 20)
        // Another width is another render.
        #expect(try await !renderer.render(first.range, in: thesis.main, width: 280).get().cached)
    }

    @Test func blockRendererShiftsRangesByUTF16AfterNonASCIIText() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        _ = await renderer.refresh()
        let original = try thesis.text(thesis.method)
        let before = try await renderer.blocks(in: thesis.method)
        let prefix = "结果 😀 é.\n\n"
        let edited = prefix + original
        try await renderer.setText(edited, of: thesis.method)
        let after = try await renderer.blocks(in: thesis.method)
        let shift = (prefix as NSString).length
        #expect(prefix.utf8.count != shift)
        // The new paragraph comes first; every other block moves by the prefix's UTF-16 length.
        #expect(after.count == before.count + 1)
        #expect(after[0].range == NSRange(
            location: 0,
            length: (prefix.trimmingCharacters(in: .newlines) as NSString)
                .length,
        ))
        #expect(zip(before, after.dropFirst()).allSatisfy {
            $1.range == NSRange(location: $0.range.location + shift, length: $0.range.length) && $1.kind == $0.kind
        })
        let paragraph = try block(startingWith: "We used a 2-down", in: edited, of: after)
        let rendered = try await renderer.render(paragraph.range, in: thesis.method, width: 450).get()
        #expect(sourcesFallInside(rendered, paragraph))
        #expect(rendered.glyphs.first?.source == paragraph.range.location)
        let opening = try await renderer.render(after[0].range, in: thesis.method, width: 450).get()
        // Each CJK glyph maps to its own UTF-16 offset, the emoji's to the first unit of its
        // surrogate pair (offset 3), never to the second.
        let sources = Set(opening.glyphs.compactMap(\.source))
        #expect(sources.isSuperset(of: [0, 1, 3]) && !sources.contains(4))
    }

    @Test func blockRendererReportsBrokenBlocksAndBadInputAsFailures() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        let draft = thesis.root.appendingPathComponent("draft.typ")
        try await renderer.setText("Fine.\n\nBroken #(1 + ) here.\n", of: draft)
        let blocks = try await renderer.blocks(in: draft)
        try #require(blocks.count == 2)
        _ = try await renderer.render(blocks[0].range, in: draft, width: 300).get()
        guard case let .failure(error) = await renderer.render(blocks[1].range, in: draft, width: 300) else {
            Issue.record("A broken block rendered")
            return
        }
        #expect(!error.message.isEmpty && error.errorDescription == error.message)

        // An unclosed `#let` is a context line, so it breaks every block of its file.
        try await renderer.setText("#let x = (\n\nFine.\n", of: draft)
        for block in try await renderer.blocks(in: draft) {
            if case .success = await renderer.render(block.range, in: draft, width: 300) {
                Issue.record("A block rendered under a broken context line")
            }
        }

        try await renderer.setText("Fine.\n", of: draft)
        let fine = NSRange(location: 0, length: 5)
        _ = try await renderer.render(fine, in: draft, width: 300).get()
        for range in [
            NSRange(location: 3, length: 0),
            NSRange(location: 0, length: 99999),
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: -1, length: 2),
            NSRange(location: 1, length: Int(UInt32.max)),
        ] {
            if case .success = await renderer.render(range, in: draft, width: 300) {
                Issue.record("\(range) rendered")
            }
        }
        if case .success = await renderer.render(fine, in: draft, width: .nan) {
            Issue.record("A width of NaN rendered")
        }
        let outside = URL(fileURLWithPath: "/elsewhere/outside.typ")
        if case .success = await renderer.render(fine, in: outside, width: 300) {
            Issue.record("A file outside the project rendered")
        }
        await #expect(throws: BlockRendererError.self) { try await renderer.blocks(in: outside) }
        await #expect(throws: BlockRendererError.self) { try await renderer.setText("Text", of: outside) }
        await #expect(throws: BlockRendererError.self) {
            try await renderer.blocks(in: thesis.root.appendingPathComponent("missing.typ"))
        }
    }

    @Test func blockRendererRefreshFailureKeepsTheLastContext() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        #expect(await renderer.refresh().succeeded)
        try await renderer.setText(thesis.text(thesis.main) + "\n#unknown-function()\n", of: thesis.main)
        let failed = await renderer.refresh()
        #expect(!failed.succeeded && failed.errors > 0 && failed.pages == 0)
        #expect(failed.message?.contains("unknown") == true)
        #expect(failed.headings == 7 && failed.equations == 3)
    }

    @Test func blockRendererInitFailsCleanly() async throws {
        let thesis = try ThesisCopy()
        // Directories that do not exist are skipped.
        let missing = thesis.root.appendingPathComponent("missing")
        _ = try await BlockRenderer(
            root: thesis.root,
            main: thesis.main,
            packageDirectories: [missing],
            fontDirectories: [missing],
        )
        await #expect(throws: BlockRendererError.self) {
            try await BlockRenderer(root: thesis.root.appendingPathComponent("nowhere"), main: thesis.main)
        }
        // The engine refuses a main file outside the project.
        let outside = try #require(await #expect(throws: BlockRendererError.self) {
            try await BlockRenderer(root: thesis.root.appendingPathComponent("sections"), main: thesis.main)
        })
        #expect(outside.message.contains("not in the project"))
        await #expect(throws: BlockRendererError.self) {
            try await BlockRenderer(root: thesis.root, main: thesis.root.appendingPathComponent("gone.typ"))
        }
        // A main file deleted later fails the refresh with a message.
        let renderer = try await thesis.renderer()
        try FileManager.default.removeItem(at: thesis.main)
        let refresh = await renderer.refresh()
        #expect(!refresh.succeeded && refresh.errors == 1 && refresh.message?.isEmpty == false)
    }

    @Test func blockRendererChecksTheTablesVersionAndLayout() {
        let table = prose_render_api().pointee
        #expect(BlockRenderer.isCompatible(table))
        var newer = table
        newer.abi_version += 1
        #expect(!BlockRenderer.isCompatible(newer))
        var resized = table
        resized.result_size += 8
        #expect(!BlockRenderer.isCompatible(resized))
    }

    @Test func blockRendererSVGDecodesToAnImage() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        _ = await renderer.refresh()
        let text = try thesis.text(thesis.main)
        let blocks = try await renderer.blocks(in: thesis.main)
        for prefix in ["Perception and action", "$ E = m c^2 $"] {
            let rendered = try await renderer.render(
                block(startingWith: prefix, in: text, of: blocks).range,
                in: thesis.main,
                width: 450,
            ).get()
            #expect(String(data: rendered.svg.prefix(4), encoding: .utf8) == "<svg")
            let image = try #require(NSImage(data: rendered.svg))
            #expect(image.size.width > 0 && image.size.height > 0)
            #expect(abs(image.size.width - rendered.size.width) < 1)
        }
    }

    @Test func blockRendererServesConcurrentRenders() async throws {
        let thesis = try ThesisCopy()
        let renderer = try await thesis.renderer()
        _ = await renderer.refresh()
        let files = [thesis.main, thesis.method]
        var work: [(URL, RenderBlock)] = []
        for file in files {
            work += try await renderer.blocks(in: file).map { (file, $0) }
        }
        let results = await withTaskGroup(of: Bool.self) { group in
            for (file, block) in work + work {
                group.addTask {
                    let result = await renderer.render(block.range, in: file, width: 400)
                    return (try? result.get()).map { sourcesFallInside($0, block) } ?? false
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.count == 2 * work.count && results.allSatisfy(\.self))
        let stats = await renderer.cacheStats()
        #expect(stats.misses == work.count && stats.hits == work.count)
    }

    @Test func blockRendererDefaultDirectoriesIncludeBundledPackagesAndFonts() throws {
        let cache = URL(fileURLWithPath: "/tmp/prose-package-cache")
        let packages = BlockRenderer.defaultPackageDirectories(packageCache: cache)
        #expect(packages.contains(cache))
        #expect(packages.contains { $0.path.hasSuffix("Library/Caches/typst/packages") })
        let bundled = try #require(packages.first)
        #expect(FileManager.default.fileExists(atPath: bundled.appendingPathComponent("preview/cetz").path))
        #expect(!BlockRenderer.defaultPackageDirectories().contains(cache))
        let fonts = BlockRenderer.defaultFontDirectories
        #expect(fonts.count == 1)
        #expect(fonts
            .allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("NotoSansSC.ttf").path) })
    }
#endif
