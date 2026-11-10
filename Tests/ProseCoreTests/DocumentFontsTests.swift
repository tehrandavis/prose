import AppKit
import CoreText
import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

/// A project in the test folder whose main file is `text`. Removed when the
/// test ends.
private final class FontProject {
    let root: URL

    init(_ text: String) throws {
        root = TestPaths.temporaryDirectory.appendingPathComponent("document-fonts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: main, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var main: URL {
        root.appendingPathComponent("main.typ")
    }

    func renderer() async throws -> BlockRenderer {
        try await BlockRenderer(root: root, main: main)
    }
}

private let paragraphs = """
A short line.

A paragraph long enough to wrap onto a second line at this narrow measure, and then onto a third one.

"""

/// The text font of the block of `text` that starts with `prefix`.
private func textFont(
    startingWith prefix: String,
    in text: String,
    _ renderer: BlockRenderer,
    file: URL,
) async throws -> BlockTextFont? {
    let source = text as NSString
    let blocks = try await renderer.blocks(in: file)
    let block = try #require(blocks.first { source.substring(with: $0.range).hasPrefix(prefix) })
    return try await renderer.render(block.range, in: file, width: 300).get().textFont
}

@Test func blockRendererReportsTheTextFontItsFacesAndItsBytes() async throws {
    let project = try FontProject(paragraphs)
    let renderer = try await project.renderer()
    let short = try #require(await textFont(startingWith: "A short", in: paragraphs, renderer, file: project.main))
    #expect(short.size == 11 && short.linePitch == nil)
    let long = try #require(await textFont(startingWith: "A paragraph", in: paragraphs, renderer, file: project.main))
    #expect(long.id == short.id && long.size == 11)
    let pitch = try #require(long.linePitch)
    #expect(pitch > 11 && pitch < 22)

    let info = try #require(await renderer.fontInfo(short.id))
    #expect(info == BlockFontInfo(family: "Libertinus Serif", weight: 400, style: .normal, embedded: true))
    let bold = try #require(await renderer.fontFace(short.id, strong: true, emphasis: false))
    let italic = try #require(await renderer.fontFace(short.id, strong: false, emphasis: true))
    #expect(await renderer.fontInfo(bold)?.weight == 700)
    #expect(await renderer.fontInfo(italic)?.style == .italic)
    #expect(await renderer.fontFace(short.id, strong: false, emphasis: false) == short.id)

    let data = try #require(await renderer.fontData(short.id))
    #expect(data.data.count > 100_000 && data.faceIndex == 0)

    for unknown in [-1, Int(UInt32.max), Int(UInt32.max) + 1] {
        #expect(await renderer.fontData(unknown) == nil)
        #expect(await renderer.fontFace(unknown, strong: true, emphasis: false) == nil)
        #expect(await renderer.fontInfo(unknown) == nil)
    }
}

@Test func blockRendererReportsNoTextFontForGeneratedTextAlone() async throws {
    let text = "#set heading(numbering: \"1.\")\n\n= End <end>\n\n@end\n"
    let project = try FontProject(text)
    let renderer = try await project.renderer()
    #expect(await renderer.refresh().succeeded)
    let font = try await textFont(startingWith: "@end", in: text, renderer, file: project.main)
    #expect(font == nil)
}

/// The PostScript names of the fonts a line of `text` set in `font` uses.
private func runFonts(_ text: String, _ font: NSFont) -> Set<String> {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    return Set(runs.compactMap { run in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return (attributes[NSAttributedString.Key.font] as? NSFont)?.fontName
    })
}

@Test @MainActor func documentFontsMakeLibertinusSerifFromTheEnginesBytes() async throws {
    let project = try FontProject(paragraphs)
    let renderer = try await project.renderer()
    let base = try #require(await textFont(startingWith: "A short", in: paragraphs, renderer, file: project.main))
    let fonts = DocumentFonts()

    // Nothing until the bytes are loaded.
    #expect(fonts.font(base.id, size: 11, in: renderer) == nil)
    let started = ContinuousClock.now
    #expect(await fonts.load(base.id, in: renderer))
    let loadTime = ContinuousClock.now - started
    let font = try #require(fonts.font(base.id, size: 11, in: renderer))
    #expect(font.familyName == "Libertinus Serif")
    #expect(font.pointSize == 11)
    #expect(fonts.facesMade == 1)

    // Latin text in it has no fallback run.
    let name = CTFontCopyPostScriptName(font) as String
    #expect(name.hasPrefix("LibertinusSerif"))
    #expect(runFonts("The quick brown fox jumps over the lazy dog, 0123456789 (and) 'quotes'.", font) == [name])

    // Reused: the same object again, a new size from the same face, and no
    // second face from bytes.
    #expect(fonts.font(base.id, size: 11, in: renderer) === font)
    #expect(await fonts.load(base.id, in: renderer))
    #expect(fonts.facesMade == 1)
    let large = try #require(fonts.font(base.id, size: 32, in: renderer))
    #expect(large.pointSize == 32 && large.familyName == "Libertinus Serif")
    #expect(fonts.facesMade == 1)

    // Bold and italic faces through the engine's font book.
    #expect(fonts.font(base.id, size: 11, in: renderer, strong: true) == nil)
    #expect(await fonts.load(base.id, in: renderer, strong: true))
    #expect(await fonts.load(base.id, in: renderer, emphasis: true))
    let bold = try #require(fonts.font(base.id, size: 11, in: renderer, strong: true))
    let italic = try #require(fonts.font(base.id, size: 11, in: renderer, emphasis: true))
    #expect(fonts.facesMade == 3)
    #expect(bold.familyName == "Libertinus Serif" && italic.familyName == "Libertinus Serif")
    #expect(bold.fontName != font.fontName && italic.fontName != font.fontName && bold.fontName != italic.fontName)
    #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))
    #expect(!CTFontGetSymbolicTraits(bold).contains(.traitItalic))
    #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
    #expect(!CTFontGetSymbolicTraits(font).contains(.traitBold))
    #expect(runFonts("Bold words.", bold) == [bold.fontName])

    // Concurrent loads of one face make it once.
    let other = try #require(await renderer.fontFace(base.id, strong: true, emphasis: true))
    async let firstLoad = fonts.load(other, in: renderer)
    async let secondLoad = fonts.load(other, in: renderer)
    let both = await [firstLoad, secondLoad]
    #expect(both == [true, true])
    #expect(fonts.facesMade == 4)

    // An unknown face cannot be made, and is not asked for again.
    #expect(await !fonts.load(Int(UInt32.max) - 1, in: renderer))
    #expect(fonts.font(Int(UInt32.max) - 1, size: 11, in: renderer) == nil)

    // Another engine's identifiers are its own.
    let otherEngine = try await project.renderer()
    #expect(fonts.font(base.id, size: 11, in: otherEngine) == nil)
    fonts.forget(renderer)
    #expect(fonts.font(base.id, size: 11, in: renderer) == nil)
    let bytes = await renderer.fontData(base.id)?.data.count ?? 0
    print("Made Libertinus Serif (font \(base.id), \(bytes) bytes) in \(loadTime)")
}

@Test @MainActor func writingLayoutAnswersTheTextFontForAnOffset() async throws {
    let text = """
    #show heading: set text(size: 20pt)

    = A Heading

    A paragraph of body text.

    ```
    raw code
    ```

    """
    let project = try FontProject(text)
    let renderer = try await project.renderer()
    let layout = WritingLayout(renderer: renderer, timing: WritingTiming(settle: .milliseconds(5), refreshPause: nil))
    let source = NSMutableString(string: text)
    layout.setAppearance(WritingAppearance(columnWidth: 520, bitmapScale: 2.6, scale: 1.3))
    layout.setVisibleRange(NSRange(location: 0, length: source.length))
    layout.start(file: project.root.appendingPathComponent("draft.typ"), text: text)
    await layout.idle()

    let heading = source.range(of: "A Heading").location
    let paragraph = source.range(of: "body").location
    let raw = source.range(of: "raw code").location
    let headingFont = try #require(layout.textFont(at: heading))
    let paragraphFont = try #require(layout.textFont(at: paragraph))
    #expect(headingFont.size == 20 && paragraphFont.size == 11)
    #expect(layout.state(ofBlockAt: 1).rendering?.textFont == headingFont)
    // A raw block never renders: the paragraph above lends its font.
    #expect(layout.state(ofBlockAt: 3).rendering == nil)
    #expect(layout.textFont(at: raw) == paragraphFont)
    // Between blocks: the paragraph above.
    #expect(layout.textFont(at: NSMaxRange(source.range(of: "text.")) + 1) == paragraphFont)
    // Nothing above the heading is a paragraph with a font.
    #expect(layout.textFont(at: 0) == nil)

    // An edit drops the paragraph's render but not its font.
    source.insert("More ", at: paragraph)
    layout.textDidChange(edited: NSRange(location: paragraph, length: 5), delta: 5, in: source)
    #expect(layout.state(ofBlockAt: 2).rendering == nil)
    #expect(layout.textFont(at: paragraph) == paragraphFont)
    await layout.idle()
    #expect(layout.textFont(at: paragraph) == paragraphFont)
    layout.stop()
}
