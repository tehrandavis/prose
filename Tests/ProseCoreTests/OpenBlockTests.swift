import AppKit
import Foundation
@testable import ProseCore
import Testing

// Phase 6 step D: the open block's markers and code (`MarkerRanges`), its
// paragraphs in the document's fonts (`OpenBlockStyle`), and its colours
// (`RenderingAttributes.setOverlay`).

/// Every marker and code kind, nested as writers nest them.
private let markerFixture = """
= Heading with #emph[call] inside
Words *bold _both_* and #emph[a *b* c] here.
- list item with $x^2$ math
+ enum item
/ Term: description
See @key[p. 4] and <label> and \\* escape and a break \\
#text(size: 15pt, fill: muted)[content words] and #lorem(3) and `raw` code.
// a comment
"""

private func texts(_ ranges: [NSRange], _ source: NSString) -> [String] {
    ranges.map { source.substring(with: $0) }
}

@Test func markerRangesSplitMarkersCodeAndWords() throws {
    let source = markerFixture as NSString
    let result = MarkerRanges.ranges(ofBlock: markerFixture)
    #expect(texts(result.markers, source) == [
        "=", "#emph[", "]",
        "*", "_", "_*", "#emph[", "*", "*", "]",
        "-",
        "+",
        "/", ":",
        "@key[", "]", "<label>", "\\", "\\",
        "#text", "[", "]",
        "// a comment",
    ])
    #expect(texts(result.code, source) == ["$x^2$", "(size: 15pt, fill: muted)", "#lorem(3)", "`raw`"])
    // Markers and code never overlap.
    for marker in result.markers {
        #expect(!result.code.contains { NSIntersectionRange($0, marker).length > 0 })
    }
    // A block parsed alone gives the ranges the whole text gives, moved.
    let tree = try #require(SyntaxTree(markerFixture))
    #expect(MarkerRanges.ranges(tree.nodes() ?? [], source: source) == result)
    #expect(result.offset(by: 10).markers.first == NSRange(location: 10, length: 1))
    #expect(MarkerRanges.ranges([], source: source) == MarkerRanges.Result())
}

/// Spell check reads words only: no marker or code range is a checkable
/// range, in the fixture and in the welcome guide, with one exception.
/// Spell check reads the content blocks inside a call's arguments (a
/// caption, a table cell: `#figure(caption: [...])`); the open block draws
/// such a call, which has no trailing content block, as code whole.
@Test func markerRangesNeverCoverASpellCheckableRange() throws {
    var excepted = 0
    for text in [markerFixture, WelcomeDocument.source()] {
        let source = text as NSString
        let tree = try #require(SyntaxTree(text))
        let nodes = tree.nodes() ?? []
        let checkable = SpellCheckRanges.ranges(
            tree,
            source: source,
            within: NSRange(location: 0, length: source.length),
        )
        let result = MarkerRanges.ranges(nodes, source: source)
        let argumentBlocks = nodes.filter { node in
            node.kind == .contentBlock && result.code.contains { NSIntersectionRange($0, node.range) == node.range }
        }
        #expect(!checkable.isEmpty && !result.markers.isEmpty)
        for range in result.markers + result.code {
            for hit in checkable where NSIntersectionRange(hit, range).length > 0 {
                let inArguments = result.code.contains(range)
                    && argumentBlocks.contains { NSIntersectionRange($0.range, hit) == hit }
                excepted += inArguments ? 1 : 0
                #expect(
                    inArguments,
                    "\(source.substring(with: range)) meets the checkable \(source.substring(with: hit))",
                )
            }
        }
    }
    #expect(excepted > 0)
}

@Test func markerRangesTreatCallsWithoutContentAsCode() {
    let text = "Before #box(width: 1em) and #h(1em) and #x and #(1 + 2) and #{ 3 } after."
    let source = text as NSString
    let result = MarkerRanges.ranges(ofBlock: text)
    #expect(texts(result.code, source) == ["#box(width: 1em)", "#h(1em)", "#x", "#(1 + 2)", "#{ 3 }"])
    #expect(result.markers.isEmpty)
    // Two content blocks, and a call in a heading's content.
    let nested = "#grid[a][b] and #strong[x #emph[y] z]"
    let more = MarkerRanges.ranges(ofBlock: nested)
    #expect(texts(more.markers, nested as NSString) == ["#grid[", "][", "]", "#strong[", "#emph[", "]", "]"])
    #expect(more.code.isEmpty)
}

// MARK: - The open block's paragraphs

/// A TextKit 2 stack with no view, styled by `SourceStyler`.
@MainActor
private final class Stack {
    let content = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    let styler: SourceStyler

    init(_ text: String) {
        content.addTextLayoutManager(manager)
        manager.textContainer = NSTextContainer(size: CGSize(width: 600, height: 0))
        content.textStorage?.setAttributedString(NSAttributedString(string: text))
        styler = SourceStyler(contentStorage: content, textLayoutManager: manager, fontSize: 14, textColor: .black)
        styler.open(fontSize: 14, textColor: .black, isEnabled: true)
    }

    var storage: NSTextStorage {
        content.textStorage ?? NSTextStorage()
    }
}

@MainActor
private func testFonts(pitch: CGFloat = 24) throws -> OpenBlockStyle.Fonts {
    let base = try #require(NSFont(name: "Times New Roman", size: 18) ?? NSFont(name: "Times", size: 18))
    let manager = NSFontManager.shared
    let strong = manager.convert(base, toHaveTrait: .boldFontMask)
    let emphasis = manager.convert(base, toHaveTrait: .italicFontMask)
    return OpenBlockStyle.Fonts(
        base: base,
        strong: strong,
        emphasis: emphasis,
        strongEmphasis: manager.convert(strong, toHaveTrait: .italicFontMask),
        code: .monospacedSystemFont(ofSize: 16, weight: .regular),
        paragraphStyle: OpenBlockStyle.Fonts.paragraphStyle(pitch: pitch, font: base),
    )
}

@Test @MainActor func openBlockParagraphsKeepTheCharactersAndTakeTheDocumentFonts() throws {
    let text = "Above.\n\nPlain *strong* _emph_ *_both_* `raw` $x$ #text(fill: red)[red] 中文😀\nSecond line.\n\nBelow.\n"
    let stack = Stack(text)
    let source = text as NSString
    let block = source.range(of: "Plain")
    let span = source.paragraphRange(for: NSRange(
        location: block.location,
        length: source.range(of: "Second line.").location - block.location,
    ))
    let fonts = try testFonts()
    let style = OpenBlockStyle(span: span, fonts: fonts)
    let first = source.paragraphRange(for: NSRange(location: span.location, length: 0))
    let paragraph = try #require(style.paragraph(first, from: stack.storage))
    #expect(paragraph.string == source.substring(with: first))
    func font(_ needle: String, _ offset: Int = 1) -> NSFont? {
        let at = source.range(of: needle, range: first).location - first.location + offset
        return paragraph.attribute(.font, at: at, effectiveRange: nil) as? NSFont
    }
    #expect(font("Plain") == fonts.base)
    #expect(font("strong") == fonts.strong)
    #expect(font("emph_") == fonts.emphasis)
    #expect(font("both") == fonts.strongEmphasis)
    #expect(font("raw") == fonts.code)
    #expect(font("$x$") == fonts.code)
    #expect(font("(fill") == fonts.code)
    #expect(font("red]") == fonts.base)
    let cjk = try #require(font("中文", 0))
    #expect(cjk != fonts.base, "No fallback font for CJK")
    let emoji = try #require(font("😀", 0))
    #expect(emoji.fontName.contains("Emoji"))
    #expect(paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle == fonts
        .paragraphStyle)
    // Outside the span: the storage's own paragraph.
    #expect(style.paragraph(source.paragraphRange(for: NSRange(location: 0, length: 0)), from: stack.storage) == nil)
    // Without fonts: nothing changes.
    #expect(OpenBlockStyle(span: span, fonts: nil).paragraph(first, from: stack.storage) == nil)
    // The style follows edits through the styler.
    stack.styler.openBlock = style
    stack.storage.replaceCharacters(in: NSRange(location: span.location, length: 0), with: "New ")
    stack.styler.textDidChange(edited: NSRange(location: span.location, length: 4), delta: 4)
    #expect(style.span == NSRange(location: span.location, length: span.length + 4))
    let code = style.ranges(in: stack.storage.string as NSString).code
    #expect(code.contains(NSRange(location: source.range(of: "`raw`").location + 4, length: 5)))
    // The delegate hands TextKit the paragraph, and a whole text change
    // (another file) drops the open block.
    let built = SourceStyler.openParagraphsBuilt
    let asked = stack.styler.textContentStorage(
        stack.content,
        textParagraphWith: NSRange(location: span.location, length: first.length + 4),
    )
    #expect(asked != nil && SourceStyler.openParagraphsBuilt == built + 1)
    #expect(stack.styler.openParagraphRequests.count == 1)
    stack.styler.resetOpenParagraphRequests()
    stack.styler.rebuildParagraphs(in: style.span)
    stack.storage.setAttributedString(NSAttributedString(string: "Other text.\n"))
    stack.styler.open(fontSize: 14, textColor: .black, isEnabled: true, keepsSpelling: false)
    #expect(stack.styler.openBlock == nil)
}

@Test @MainActor func openBlockParagraphStyleSetsTheEnginesLinePitch() throws {
    let base = try #require(NSFont(name: "Times New Roman", size: 18) ?? NSFont(name: "Times", size: 18))
    let natural = ceil(base.ascender - base.descender + base.leading)
    let wide = OpenBlockStyle.Fonts.paragraphStyle(pitch: natural + 6, font: base)
    #expect(wide.lineSpacing == 6 && wide.maximumLineHeight == 0 && wide.paragraphSpacing == 0)
    let tight = OpenBlockStyle.Fonts.paragraphStyle(pitch: natural - 4, font: base)
    #expect(tight.lineSpacing == 0 && tight.maximumLineHeight == natural - 4)
    let fonts = try testFonts()
    #expect(fonts.font(forStyle: 0) == fonts.base && fonts.font(forStyle: 1) == fonts.base)
    #expect(fonts.font(forStyle: 8 | 2) == fonts.strong && fonts.font(forStyle: 32) == fonts.code)
    var sparse = fonts
    sparse.strong = nil
    sparse.strongEmphasis = nil
    #expect(sparse.font(forStyle: 8) == fonts.base && sparse.font(forStyle: 24) == fonts.emphasis)
}

// MARK: - Colours

@Test @MainActor func openBlockOverlayColoursOnlyItsBlockAndGivesTheColoursBack() {
    let text = "Above *a* here.\n\nWords *strong* and $x$ end.\n\nBelow.\n"
    let stack = Stack(text)
    let source = text as NSString
    let colors = stack.styler.colors
    let semantic = NSColor.systemBlue, maths = NSColor.systemGreen, ink = NSColor.black
    let faint = NSColor.black.withAlphaComponent(0.4)
    let firstStar = source.range(of: "*")
    let block = source.range(of: "Words *strong* and $x$ end.\n")
    let math = source.range(of: "$x$")
    let stars = [
        source.range(of: "*", range: block),
        NSRange(location: source.range(of: "strong").location + 6, length: 1),
    ]
    colors.setColors([(firstStar, semantic), (stars[0], semantic), (stars[1], semantic), (math, maths)])
    func colour(_ offset: Int) -> NSColor? {
        var range = NSRange()
        return colors.value(.foregroundColor, at: offset, effectiveRange: &range) as? NSColor
    }
    colors.logsWrites = true
    colors.resetWriteLog()
    let overlay = RenderingAttributes.Overlay(range: block, markers: stars, code: [math], text: ink, faint: faint)
    colors.setOverlay(overlay)
    colors.commit()
    #expect(colors.writeLog.allSatisfy { NSIntersectionRange($0, block) == $0 }, "\(colors.writeLog)")
    #expect(colour(block.location) == ink && colour(stars[0].location) == faint && colour(math.location) == maths)
    #expect(colour(firstStar.location) == semantic, "Outside the block the semantic colour stays")
    // The same overlay again writes nothing.
    colors.resetWriteLog()
    colors.setOverlay(overlay)
    #expect(colors.writeLog.isEmpty)

    // A semantic reply keeps the overlay and its colours for later.
    colors.setColors([(firstStar, maths), (stars[0], maths), (math, semantic)])
    #expect(colour(stars[0].location) == faint && colour(math.location) == semantic && colour(firstStar.location) ==
        maths)

    // Typing inside moves it; the typed text has no colour until it is set again.
    colors.replaceCharacters(in: NSRange(location: block.location, length: 0), length: 3)
    #expect(colors.overlay?.range == NSRange(location: block.location, length: block.length + 3))
    colors.replaceCharacters(in: NSRange(location: block.location, length: 3), length: 0)
    #expect(colors.overlay?.range == block)

    // Closing gives the block its semantic colours back, and writes only there.
    colors.resetWriteLog()
    colors.setOverlay(nil)
    colors.commit()
    #expect(colors.writeLog.allSatisfy { NSIntersectionRange($0, block) == $0 })
    #expect(colour(stars[0].location) == maths && colour(block.location) == nil && colour(math.location) == semantic)

    // A restyle of the same text keeps an overlay; new text drops it.
    colors.setOverlay(overlay)
    colors.removeAll(keepingSpelling: true)
    #expect(colors.overlay == overlay && colour(stars[0].location) == faint)
    colors.replaceCharacters(in: NSRange(location: 0, length: block.location + 4), length: 0)
    #expect(colors.overlay != nil)
    colors.removeAll(keepingSpelling: false)
    #expect(colors.overlay == nil)
    colors.setOverlay(RenderingAttributes.Overlay(
        range: NSRange(location: 0, length: 0),
        markers: [],
        code: [],
        text: ink,
        faint: faint,
    ))
    #expect(colors.overlay == nil)
}
