import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Dark appearance in Writing mode: the engine maps the document's own
/// colours onto the dark page, so a document that sets dark ink and light
/// fills still reads, and images keep their pixels.
extension WritingFlowTests {
    @Test func darkWritingModeShowsTheWelcomeGuidesOwnInkLightOnThePage() async throws {
        let app = try WritingFixture(text: WelcomeDocument.source(), startService: false)
        defer { app.close() }
        try WelcomeDocument.prepareAssets(in: app.root)
        let (editor, canvas) = try await darkWritingCanvas(app, name: "writing-mode-dark-welcome.png")
        let text = editor.string as NSString
        // The title, in the first screen.
        let paragraph = text.range(of: "= Write in Typst").location
        let manager = try #require(editor.textLayoutManager)
        let block = try #require(writingFragments(manager).first { $0.offset == paragraph })
        #expect(block.isRendered)
        // The guide's ink is #253238. Mapped, its glyphs are light: at least
        // 4.5:1 against the page, and nothing is drawn darker than the page.
        #expect(canvas.contrasting(in: block.frame, atLeast: 4.5) > 100, "Rendered text does not reach 4.5:1")
        #expect(canvas.darkerThanPage(in: block.frame) == 0, "Dark ink is drawn on the dark page")
        // The muted line under the title, #66736D (5.0:1 on white), reads
        // too: its strongest ink reaches 4.5:1 against the page.
        let subtitle = text.range(of: "#text(size: 15pt, fill: muted)[Begin with a thought").location
        let muted = try #require(writingFragments(manager).first { $0.offset == subtitle })
        #expect(muted.isRendered)
        #expect(canvas.contrasting(in: muted.frame, atLeast: 4.5) > 100, "The muted line does not reach 4.5:1")
        #expect(canvas.darkerThanPage(in: muted.frame) == 0)
        expectPlainStorage(editor)
    }

    @Test func darkWritingModeKeepsImagesInsideAFilledBlock() async throws {
        let source = """
        #set text(fill: rgb("#1A1918"))

        Words in the document's own dark ink, long enough to run across the column of the page.

        #block(inset: 12pt, fill: rgb("#dbe6df").lighten(55%), width: 100%)[A light block. #box(image("red.png", width: 40pt))]
        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        try redSquare().write(to: app.root.appendingPathComponent("red.png"))
        let (editor, canvas) = try await darkWritingCanvas(app, name: "writing-mode-dark-image.png")
        let text = editor.string as NSString
        let manager = try #require(editor.textLayoutManager)
        let fragments = writingFragments(manager)
        let words = try #require(fragments.first { $0.offset == text.range(of: "Words in").location })
        let block = try #require(fragments.first { $0.offset == text.range(of: "#block").location })
        #expect(words.isRendered && block.isRendered)
        #expect(canvas.contrasting(in: words.frame, atLeast: 4.5) > 100, "Rendered text does not reach 4.5:1")
        #expect(canvas.darkerThanPage(in: words.frame) == 0)
        // The block's light fill fades into the page, its text stays light,
        // and the image keeps its pure red.
        #expect(canvas.contrasting(in: block.frame, atLeast: 4.5) > 20)
        #expect(canvas.pureRed(in: block.frame) > 200, "The image's pixels changed")
        expectPlainStorage(editor)
    }
}

/// Enters Writing mode in dark appearance with the top of the document in
/// view, and takes a picture of the editor.
@MainActor
private func darkWritingCanvas(
    _ app: WritingFixture,
    name: String,
) async throws -> (ManuscriptTextView, DarkCanvas) {
    app.window.orderFront(nil)
    app.window.appearance = NSAppearance(named: .darkAqua)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    let model = try await enterWritingMode(app)
    writingScrollToTop(editor)
    await app.layout()
    await model.idle()
    await app.layout()
    #expect(editor.writing.currentAppearance()?.dark == true)
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
    editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
    try writingSave(bitmap, name)
    return (editor, DarkCanvas(WritingCanvas(editor: editor, bitmap: bitmap, background: (0x26, 0x26, 0x26))))
}

/// A 32 by 32 pixel PNG of pure red.
private func redSquare() throws -> Data {
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32 * 4, bitsPerPixel: 32,
    ))
    let bytes = try #require(rep.bitmapData)
    for pixel in 0 ..< 32 * 32 {
        (bytes + pixel * 4).update(from: [255, 0, 0, 255], count: 4)
    }
    return try #require(rep.representation(using: .png, properties: [:]))
}

/// Contrast checks on a picture of the dark page.
@MainActor
private struct DarkCanvas {
    let canvas: WritingCanvas

    init(_ canvas: WritingCanvas) {
        self.canvas = canvas
    }

    /// WCAG relative luminance of an sRGB colour, components 0 to 255.
    static func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Double {
        func linear(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static let page = luminance(0x26, 0x26, 0x26)

    /// Pixels at least `ratio`:1 lighter than the page.
    func contrasting(in rect: CGRect, atLeast ratio: Double) -> Int {
        canvas.matching(in: rect) { (Self.luminance($0, $1, $2) + 0.05) / (Self.page + 0.05) >= ratio }
    }

    /// Pixels clearly darker than the page: dark ink drawn on it.
    func darkerThanPage(in rect: CGRect) -> Int {
        canvas.matching(in: rect) { max($0, $1, $2) < 0x18 }
    }

    /// The image's red as the screen shows it: the untagged PNG's pure red
    /// arrives near (234, 51, 35) after colour matching. The dark mapping
    /// would make it about (233, 98, 78), so a red channel of 215 or more
    /// with green at 80 or less means the image's pixels were not mapped.
    func pureRed(in rect: CGRect) -> Int {
        canvas.matching(in: rect) { $0 >= 215 && $1 <= 80 && $2 <= 70 }
    }
}
