import AppKit
import CoreGraphics
import Foundation
@testable import ProseCore
import Testing

// Reading styles on a real TextKit 2 text view (NSTextView).

private let sample = """
#let item(id, title, s) = [#id #title #s]
= 第一章 Heading
== Section with `code`
=== Third level
Text *粗体 bold* and _emph_ with `code` and *_both_*.
Before #item("LB-001", "标题", "done") after.
- list item
Inline $φ = (1+√5)/2 ≈ 1.618$ math and #image("figure.png").

"""

@MainActor
private final class Harness {
    let window: NSWindow
    let view: NSTextView
    let styler: SourceStyler
    let manager: NSTextLayoutManager
    let content: NSTextContentStorage
    private var forwarder: Forwarder?

    init(_ text: String = sample) throws {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: CGRect(x: -8000, y: -8000, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view = NSTextView(usingTextLayoutManager: true)
        view.frame = scroll.bounds
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        window.contentView = scroll
        window.orderFrontRegardless()
        content = try #require(view.textContentStorage)
        view.string = text
        manager = try #require(view.textLayoutManager)
        styler = SourceStyler(contentStorage: content, textLayoutManager: manager, fontSize: 14, textColor: .black)
        styler.hasMarkedText = { [view] in Self.hasMarkedText(view) }
        forwarder = Forwarder(styler: styler)
        storage.delegate = forwarder
        styler.open(fontSize: 14, textColor: .black, isEnabled: true)
        select(NSRange(location: string.length, length: 0))
    }

    var storage: NSTextStorage {
        view.textStorage ?? NSTextStorage()
    }

    var string: NSString {
        storage.string as NSString
    }

    var selection: NSRange {
        view.selectedRange()
    }

    func close() {
        window.close()
    }

    func select(_ range: NSRange) {
        view.setSelectedRange(range)
        styler.selectionDidChange()
    }

    func settle() async {
        await styler.settled()
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
    }

    func font(_ offset: Int) -> PlatformFont? {
        storage.attribute(.font, at: offset, effectiveRange: nil) as? PlatformFont
    }

    func font(of substring: String) -> PlatformFont? {
        font(string.range(of: substring).location)
    }

    func width(_ offset: Int) -> CGFloat {
        TextKit2Geometry.segments(NSRange(location: offset, length: 1), type: .standard, in: manager)
            .reduce(0) { $0 + $1.width }
    }

    /// The text TextKit lays out, paragraph by paragraph.
    func displayed() -> NSAttributedString {
        let result = NSMutableAttributedString()
        content.enumerateTextElements(from: content.documentRange.location) { element in
            if let paragraph = element as? NSTextParagraph {
                result.append(paragraph.attributedString)
            }
            return true
        }
        return result
    }

    func replace(_ range: NSRange, with text: String) {
        view.insertText(text, replacementRange: range)
    }

    func setMarkedText(_ text: String) {
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
    }

    func commitMarkedText(_ text: String) {
        view.insertText(text, replacementRange: view.markedRange())
    }

    static func hasMarkedText(_ view: NSTextView) -> Bool {
        view.hasMarkedText()
    }

    var undoManager: UndoManager? {
        view.undoManager
    }
}

@MainActor
private final class Forwarder: NSObject, @preconcurrency NSTextStorageDelegate {
    let styler: SourceStyler
    init(styler: SourceStyler) {
        self.styler = styler
    }

    func textStorage(
        _: NSTextStorage,
        didProcessEditing editedMask: StorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int,
    ) {
        if editedMask.contains(.editedCharacters) {
            styler.textDidChange(edited: editedRange, delta: delta)
        }
    }
}

private func isBold(_ font: PlatformFont?) -> Bool {
    font?.fontDescriptor.symbolicTraits.contains(.bold) == true
}

private func isItalic(_ font: PlatformFont?) -> Bool {
    font?.fontDescriptor.symbolicTraits.contains(.italic) == true
}

private func isMonospaced(_ font: PlatformFont?) -> Bool {
    font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
}

@MainActor
@Suite(.serialized) struct SourceStylingTests {
    @Test func headingsGrowByLevelAndStrongEmphasisAndRawChangeOnlyFonts() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let body = try #require(harness.font(of: "Text"))
        #expect(body.pointSize == 14 && isMonospaced(body))
        let sizes = try ["第一章", "Section", "Third"].map { try #require(harness.font(of: $0)).pointSize }
        #expect(sizes == [20, 18, 16])
        for heading in ["第一章", "Section", "Third", "= 第一章"] {
            #expect(isBold(harness.font(of: heading)), "\(heading) is bold")
        }
        // Raw text inside a heading keeps the heading's size, in monospace.
        let headingCode = harness.font(harness.string.range(of: "`code`\n").location + 1)
        #expect(headingCode?.pointSize == 18 && isMonospaced(headingCode))
        #expect(isBold(harness.font(of: "粗体 bold")) && isBold(harness.font(of: "*粗体")))
        #expect(isItalic(harness.font(of: "emph")) && !isBold(harness.font(of: "emph")))
        let both = harness.font(of: "both")
        #expect(isBold(both) && isItalic(both))
        let code = harness.font(harness.string.range(of: "`code` and").location + 1)
        #expect(isMonospaced(code) && code?.pointSize == 14 && !isBold(code))
        #expect(harness.styler.style(at: harness.string.range(of: "both").location)
            == SourceStyle(strong: true, emphasis: true))
        // Calls, lists and equations are plain source.
        for plain in ["#item(\"LB-001\"", "- list", "$φ", "1.618", "#image"] {
            #expect(harness.font(of: plain) == body, "\(plain) is plain")
        }
    }

    @Test func theLaidOutTextIsTheSourceWithEveryMarkerVisible() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let displayed = harness.displayed()
        #expect(displayed.string == sample)
        var attachments = 0
        displayed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: displayed.length)) { value, _, _ in
            attachments += value == nil ? 0 : 1
        }
        harness.storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: harness.storage.length),
        ) { value, _, _ in
            attachments += value == nil ? 0 : 1
        }
        #expect(attachments == 0)
        let text = harness.string
        for marker in ["= 第一章", "== ", "*粗体", "_emph", "`code` and", "#item", "- list", "$φ", "#image"] {
            #expect(harness.width(text.range(of: marker).location) > 1, "\(marker) is drawn")
        }
    }

    @Test func editsRestyleWhatTheyReparseAndMatchAFreshStyle() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        // Typing inside strong text keeps it bold; closing a new strong run styles it.
        harness.replace(NSRange(location: text.range(of: " bold*").location, length: 0), with: "加")
        harness.replace(NSRange(location: text.range(of: "Before").location, length: 0), with: "*new* ")
        // A new heading, and a heading turned into plain text.
        harness.replace(NSRange(location: text.range(of: "- list").location, length: 0), with: "== Added\n")
        harness.replace(NSRange(location: text.range(of: "=== Third").location, length: 4), with: "")
        await harness.settle()
        #expect(isBold(harness.font(of: "加")))
        #expect(isBold(harness.font(of: "new")))
        #expect(harness.font(of: "Added")?.pointSize == 18)
        #expect(harness.font(of: "Third level")?.pointSize == 14)
        #expect(!isBold(harness.font(of: "Third level")))

        // Seeded edits, styled incrementally, end exactly as styling from scratch.
        var generator = SeededGenerator(seed: 19)
        let pieces = ["*", "_", "`", "= ", "\n", "$", "字", "x", "😀", "#f(", ")"]
        for _ in 0 ..< 60 {
            let length = harness.string.length
            let location = Int.random(in: 0 ... length, using: &generator)
            let removed = min(Int.random(in: 0 ... 3, using: &generator), length - location)
            var range = NSRange(location: location, length: removed)
            range = harness.string.rangeOfComposedCharacterSequences(for: range)
            harness.replace(range, with: pieces.randomElement(using: &generator) ?? "x")
            if Bool.random(using: &generator) {
                await harness.styler.settled()
            }
        }
        await harness.settle()
        let incremental = (0 ..< harness.string.length).map { harness.styler.style(at: $0) }
        harness.styler.open(fontSize: 14, textColor: .black, isEnabled: true)
        let fresh = (0 ..< harness.string.length).map { harness.styler.style(at: $0) }
        #expect(incremental == fresh)
    }

    @Test func stylesNeverMoveTheSelectionOrCreateUndoSteps() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let start = harness.string.range(of: "Before").location
        harness.select(NSRange(location: start, length: 0))
        harness.replace(NSRange(location: start, length: 0), with: "*x* ")
        let selection = harness.selection
        await harness.settle()
        #expect(isBold(harness.font(start + 1)))
        #expect(harness.selection == selection)
        harness.undoManager?.undo()
        await harness.settle()
        #expect(harness.string as String == sample)
        #expect(!isBold(harness.font(start)))
    }

    @Test func compositionDefersStylesUntilItEnds() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let end = harness.string.length
        harness.select(NSRange(location: end, length: 0))
        harness.replace(NSRange(location: end, length: 0), with: "*abc")
        await harness.settle()
        // A composed closing marker would bold the run; it waits for the commit.
        harness.setMarkedText("*")
        await harness.styler.settled()
        #expect(Harness.hasMarkedText(harness.view))
        #expect(!isBold(harness.font(end + 1)), "Nothing restyles under marked text")
        harness.commitMarkedText("*")
        harness.select(harness.selection)
        await harness.settle()
        #expect(harness.string.substring(from: end) == "*abc*")
        #expect(isBold(harness.font(end + 1)))
    }

    @Test func readingStylesOffShowsOneFont() async throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.styler.open(fontSize: 14, textColor: .black, isEnabled: false)
        await harness.settle()
        let body = harness.font(0)
        for text in ["第一章", "粗体", "emph", "`code` and"] {
            #expect(harness.font(of: text) == body, "\(text)")
        }
        harness.replace(NSRange(location: 0, length: 0), with: "= New\n")
        await harness.settle()
        #expect(harness.font(of: "New") == body)
        harness.styler.open(fontSize: 16, textColor: .black, isEnabled: true)
        #expect(harness.font(of: "New")?.pointSize == 22)
    }
}

/// A small deterministic generator, so a failing edit sequence reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
