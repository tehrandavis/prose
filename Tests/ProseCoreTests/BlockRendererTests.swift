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

@Test func blockRendererBlocksCoverTheFileAsUTF16Ranges() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    let text = try thesis.text(thesis.main) as NSString
    let blocks = try await renderer.blocks(in: thesis.main)
    let shown = blocks.map { text.substring(with: $0.range) }
    // Context lines and #include lines are blocks of their own kinds.
    #expect(blocks.first?.kind == .context)
    #expect(shown.first { !$0.hasPrefix("#") } == "= Introduction <intro>")
    #expect(zip(shown, blocks).allSatisfy { shown, block in
        let pill = ["#set", "#show", "#let", "#import"].contains { shown.hasPrefix($0) }
        return pill == (block.kind == .context) && shown.hasPrefix("#include") == (block.kind == .include)
    })
    #expect(blocks.contains { $0.kind == .include })
    #expect(blocks.filter { !$0.kind.renders }.allSatisfy { [.context, .include, .comment].contains($0.kind) })
    // Everything other than whitespace is in a block.
    var rest = text as String
    for block in blocks.reversed() {
        rest = (rest as NSString).replacingCharacters(in: block.range, with: "")
    }
    #expect(rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    let first = try #require(await renderer.blocks(in: thesis.main).first(where: \.kind.renders))
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
    var options = table
    options.options_size += 8
    #expect(!BlockRenderer.isCompatible(options))
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
        #expect(abs(image.size.width - rendered.drawnRect.width) < 1)
    }
}

@Test func blockRendererServesConcurrentRenders() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    _ = await renderer.refresh()
    let files = [thesis.main, thesis.method]
    var work: [(URL, RenderBlock)] = []
    for file in files {
        work += try await renderer.blocks(in: file).filter(\.kind.renders).map { (file, $0) }
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

@Test func blockRendererDefaultDirectoriesIncludeBundledPackages() throws {
    let cache = URL(fileURLWithPath: "/tmp/prose-package-cache")
    let packages = BlockRenderer.defaultPackageDirectories(packageCache: cache)
    #expect(packages.contains(cache))
    #expect(packages.contains { $0.path.hasSuffix("Library/Caches/typst/packages") })
    let bundled = try #require(packages.first)
    #expect(FileManager.default.fileExists(atPath: bundled.appendingPathComponent("preview/cetz").path))
    #expect(!BlockRenderer.defaultPackageDirectories().contains(cache))
}

/// Prose bundles no CJK font. Typst's fallback finds one among the system fonts,
/// so two different characters draw two different shapes. Without fallback the
/// document font has neither, and both draw the same missing-glyph box.
@Test func blockRendererDrawsCJKTextWithSystemFontsAlone() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    let draft = thesis.root.appendingPathComponent("cjk.typ")
    func svg(_ source: String) async throws -> Data {
        try await renderer.setText(source, of: draft)
        let block = try #require(try await renderer.blocks(in: draft).first)
        let rendered = try await renderer.render(block.range, in: draft, width: 300).get()
        #expect(rendered.ink.width > 0)
        #expect(rendered.glyphs.count == 2)
        return rendered.svg
    }
    #expect(try await svg("中文") != svg("中中"))
    #expect(try await svg("#text(fallback: false)[中文]") == svg("#text(fallback: false)[中中]"))
}

@Test func blockRendererKindsIncludeContextIncludeRawListAndComment() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    let draft = thesis.root.appendingPathComponent("kinds.typ")
    let source = """
    // Notes for later.
    #set text(size: 11pt) // body size

    = A heading

    ```swift
    let x = 1
    ```

    - one
    + two
    / Term: description

    #include "sections/method.typ"

    A paragraph.

    $ x = y $
    """
    try await renderer.setText(source, of: draft)
    let blocks = try await renderer.blocks(in: draft)
    let text = source as NSString
    #expect(blocks.map(\.kind) == [.comment, .context, .heading, .raw, .list, .include, .paragraph, .equation])
    #expect(text.substring(with: blocks[1].range) == "#set text(size: 11pt) // body size")
    #expect(blocks.map(\.kind.renders) == [false, false, true, true, true, false, true, true])
    // A list and a raw block render.
    for block in blocks where block.kind == .raw || block.kind == .list {
        let rendered = try await renderer.render(block.range, in: draft, width: 300).get()
        #expect(rendered.ink.width > 0)
    }
}

/// The premultiplied RGBA bytes of an image, drawn into an sRGB context of its size.
private func pixels(of image: CGImage) throws -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    try data.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(
            data: buffer.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
}

@Test func blockRendererMakesATransparentBitmapOfTheDrawnArea() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    _ = await renderer.refresh()
    let text = try thesis.text(thesis.main)
    let blocks = try await renderer.blocks(in: thesis.main)
    let paragraph = try block(startingWith: "Perception and action", in: text, of: blocks)
    let plain = try await renderer.render(paragraph.range, in: thesis.main, width: 450).get()
    #expect(plain.bitmap == nil)
    #expect(plain.drawnRect.minX <= 0 && plain.drawnRect.minY <= 0)
    #expect(plain.drawnRect.maxX >= plain.size.width && plain.drawnRect.maxY >= plain.size.height)
    #expect(plain.drawnRect.contains(plain.ink.insetBy(dx: 0.01, dy: 0.01)))

    let scale = 2.6
    let rendered = try await renderer.render(
        paragraph.range,
        in: thesis.main,
        width: 450,
        options: RenderOptions(bitmapScale: scale),
    ).get()
    // The bitmap comes from the cached vector result.
    #expect(rendered.cached && rendered.svg == plain.svg && rendered.drawnRect == plain.drawnRect)
    let image = try #require(rendered.bitmap)
    #expect(image.width == Int((rendered.drawnRect.width * scale).rounded(.up)))
    #expect(image.height == Int((rendered.drawnRect.height * scale).rounded(.up)))
    #expect(image.alphaInfo == .premultipliedLast && image.bitsPerPixel == 32)
    let bytes = try pixels(of: image)
    let corners = [0, image.width - 1, (image.height - 1) * image.width, image.width * image.height - 1]
    #expect(corners.allSatisfy { bytes[$0 * 4 + 3] == 0 })
    #expect(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 200 })

    // Scales out of range fail; zero gives no bitmap.
    for bad in [-1, Double.nan, RenderOptions.maximumBitmapScale + 1] {
        if case .success = await renderer.render(
            paragraph.range,
            in: thesis.main,
            width: 450,
            options: RenderOptions(bitmapScale: bad),
        ) {
            Issue.record("A bitmap scale of \(bad) rendered")
        }
    }
}

@Test func blockRendererDarkAppearanceMapsTheDocumentsColoursAndIsInTheCacheKey() async throws {
    let thesis = try ThesisCopy()
    let renderer = try await thesis.renderer()
    let draft = thesis.root.appendingPathComponent("colour.typ")
    try await renderer.setText("#set text(fill: rgb(\"#1A1918\"))\n\nPlain words.\n", of: draft)
    let blocks = try await renderer.blocks(in: draft)
    let words = try #require(blocks.first { $0.kind == .paragraph })
    let dark = try await renderer.render(
        words.range,
        in: draft,
        width: 300,
        options: RenderOptions(dark: true, bitmapScale: 1),
    )
    .get()
    #expect(!dark.cached)
    #expect(try !(#require(String(data: dark.svg, encoding: .utf8)).lowercased().contains("#1a1918")))
    // In light appearance it is another cache entry, in the document's ink.
    let light = try await renderer.render(words.range, in: draft, width: 300).get()
    #expect(!light.cached)
    #expect(try #require(String(data: light.svg, encoding: .utf8)).lowercased().contains("#1a1918"))
    // The bitmap's ink is light.
    let image = try #require(dark.bitmap)
    let bytes = try pixels(of: image)
    let solid = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] >= 250 }
    #expect(!solid.isEmpty)
    let straight = { (at: Int, channel: Int) in Int(bytes[at + channel]) * 255 / Int(bytes[at + 3]) }
    #expect(solid.allSatisfy { at in (0 ..< 3).allSatisfy { straight(at, $0) >= 0xA0 } })
}

@Test func blockRendererReadsFilesChangedOnDiskAndShowsCitations() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("block-renderer-bib-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let main = root.appendingPathComponent("main.typ")
    let bibliography = root.appendingPathComponent("refs.bib")
    let text = "See @a here.\n\n#bibliography(\"refs.bib\")\n"
    try Data(text.utf8).write(to: main)
    try Data("@book{a, title={Old Title}, author={Writer, Ann}, year={2020}}\n".utf8).write(to: bibliography)
    let renderer = try await BlockRenderer(root: root, main: main)
    #expect(await renderer.refresh().succeeded)
    let blocks = try await renderer.blocks(in: main)
    try #require(blocks.count == 2)
    func shown(_ index: Int) async throws -> RenderedBlock {
        try await renderer.render(blocks[index].range, in: main, width: 400).get()
    }
    #expect(try await shown(0).text.contains("[1]"))
    #expect(try await shown(1).text.contains("Old Title"))

    try Data("@book{a, title={New Title}, author={Writer, Ann}, year={2020}}\n".utf8).write(to: bibliography)
    // Until told, the engine keeps the file it read.
    #expect(await renderer.refresh().succeeded)
    #expect(try await shown(1).text.contains("Old Title"))
    let unrelated = root.appendingPathComponent("notes.txt")
    let outside = TestPaths.temporaryDirectory.appendingPathComponent("outside.bib")
    #expect(await renderer.filesChanged([unrelated, outside]) == 0)
    #expect(await renderer.filesChanged([bibliography, unrelated]) == 1)
    #expect(await renderer.refresh().succeeded)
    let changed = try await shown(1)
    #expect(changed.text.contains("New Title") && !changed.cached)
    #expect(await renderer.filesChanged([]) == 0)
}
