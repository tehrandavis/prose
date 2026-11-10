import CoreGraphics
import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

// Phase 6 step A: the fold model of Quiet Writing mode
// (docs/plans/2026-11-09-quiet-writing-mode.md, decisions 1, 3 and 4).

/// A project in the test folder; the model's file lives only in memory.
private final class FoldDraft {
    let root: URL

    init() throws {
        root = TestPaths.temporaryDirectory.appendingPathComponent("writing-folds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "= Main\n\nBody text.\n".write(to: main, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var main: URL {
        root.appendingPathComponent("main.typ")
    }

    var file: URL {
        root.appendingPathComponent("draft.typ")
    }

    func renderer() async throws -> FoldRenderer {
        try await FoldRenderer(BlockRenderer(root: root, main: main))
    }
}

/// The engine's block lists with scripted renders: a block whose text starts
/// with one of `blankCalls` has no ink, every other block has some. Renders
/// can be held.
private actor FoldRenderer: WritingRenderer {
    static let blankCalls = ["#v(", "#codly(", "#pagebreak("]

    let inner: BlockRenderer
    private(set) var renders = 0
    private var text: [URL: NSString] = [:]
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ inner: BlockRenderer) {
        self.inner = inner
    }

    var heldCount: Int {
        held.count
    }

    func holdRenders(_ hold: Bool) {
        holding = hold
        if !hold {
            held.forEach { $0.resume() }
            held = []
        }
    }

    func setText(_ text: String, of file: URL) async throws {
        self.text[file] = text as NSString
        try await inner.setText(text, of: file)
    }

    func blocks(in file: URL) async throws -> [RenderBlock] {
        try await inner.blocks(in: file)
    }

    func render(
        _ range: NSRange,
        in file: URL,
        width _: Double,
        options _: RenderOptions,
    ) async -> Result<RenderedBlock, BlockRendererError> {
        renders += 1
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        let source = text[file].map { NSMaxRange(range) <= $0.length ? $0.substring(with: range) : "" } ?? ""
        let blank = Self.blankCalls.contains { source.hasPrefix($0) }
        let pixel = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )?.makeImage()
        return .success(RenderedBlock(
            svg: Data(source.utf8),
            size: CGSize(width: 10, height: 10),
            baseline: 5,
            ink: blank ? .zero : CGRect(x: 0, y: 0, width: 5, height: 5),
            drawnRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            glyphs: [],
            bitmap: pixel,
            cached: false,
            text: source,
        ))
    }

    func refresh() -> RenderRefresh {
        RenderRefresh(
            succeeded: true,
            errors: 0,
            warnings: 0,
            pages: 1,
            headings: 0,
            equations: 0,
            references: 0,
            message: nil,
        )
    }
}

@MainActor
private final class FoldLog {
    var calls: [[NSRange]] = []

    func covers(_ location: Int) -> Bool {
        calls.flatMap(\.self).contains { NSLocationInRange(location, $0) }
    }
}

/// What a paragraph draws, with renders compared by the block they draw
/// (two models never share a render's serial).
private enum Shape: Equatable, CustomStringConvertible {
    case source
    case collapsed
    case rendered(NSRange)
    case pill(WritingPill)

    init(_ role: WritingRole) {
        switch role {
        case .source: self = .source
        case .collapsed: self = .collapsed
        case let .rendered(_, block): self = .rendered(block)
        case let .pill(pill): self = .pill(pill)
        }
    }

    var description: String {
        switch self {
        case .source: "source"
        case .collapsed: "collapsed"
        case let .rendered(block): "rendered(\(block.location), \(block.length))"
        case let .pill(pill): "pill(\(pill.text), \(pill.style))"
        }
    }
}

private let foldTiming = WritingTiming(settle: .milliseconds(5), refreshPause: nil)
private let foldAppearance = WritingAppearance(columnWidth: 520, bitmapScale: 2.6, scale: 1.3)

/// The welcome guide's first 17 lines: comments, imports, `#let`, `#set`
/// and `#show` lines, and `#codly(...)`, which draws nothing.
private let welcomeSetup = """
// A Prose original. Keep, change or remove any part of this document.
// These pinned packages are included with Prose; this example works offline.
#import "@preview/cetz:0.5.2": canvas, draw
#import "@preview/codly:1.3.0": codly, codly-init

#let ink = rgb("253238")
#let muted = rgb("66736d")
#let sage = rgb("dbe6df")
#set document(title: "Write in Typst", author: "Prose")
#set page(paper: "a4", margin: (x: 25mm, y: 22mm), numbering: "01", number-align: center)
#set text(font: "Libertinus Serif", size: 11pt, fill: ink)
#set par(leading: 0.75em)
#set heading(numbering: none)
#show heading.where(level: 1): set text(size: 32pt, weight: "regular")
#show heading.where(level: 2): set text(size: 18pt, weight: "regular")
#show: codly-init.with()
#codly(display-name: false, display-icon: false, zebra-fill: none)

"""

private let mixed = """
#set text(size: 11pt)

// A comment.

First paragraph words.

#v(7mm)

#include "chapter.typ"

Second paragraph words.

"""

private let setupInside = """
Intro words here.

#set text(size: 11pt)
#let x = 1

Body words here.

"""

@MainActor
private func waitFor(_ what: String, _ condition: @MainActor () async -> Bool) async {
    for _ in 0 ..< 1000 {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(what)")
}

@MainActor
private func replace(_ text: NSMutableString, _ range: NSRange, _ replacement: String, _ layout: WritingLayout) {
    text.replaceCharacters(in: range, with: replacement)
    let length = (replacement as NSString).length
    layout.textDidChange(
        edited: NSRange(location: range.location, length: length),
        delta: length - range.length,
        in: text,
    )
}

private func paragraphs(_ text: NSString) -> [NSRange] {
    var result: [NSRange] = []
    var start = 0
    while start < text.length {
        let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
        result.append(paragraph)
        start = NSMaxRange(paragraph)
    }
    return result
}

@MainActor
private func shapes(_ layout: WritingLayout, _ text: NSString) -> [Shape] {
    paragraphs(text).map { Shape(layout.role(forParagraph: $0)) }
}

@MainActor
private func foldModel(
    _ text: String,
    _ renderer: FoldRenderer,
    _ draft: FoldDraft,
    folds: Bool = true,
    visible: NSRange? = nil,
) async -> (WritingLayout, FoldLog) {
    let layout = WritingLayout(renderer: renderer, timing: foldTiming)
    let log = FoldLog()
    layout.onChange = { log.calls.append($0) }
    layout.foldsEnabled = folds
    layout.setAppearance(foldAppearance)
    layout.setVisibleRange(visible ?? NSRange(location: 0, length: 1_000_000))
    layout.start(file: draft.file, text: text)
    await layout.idle()
    return (layout, log)
}

private func setupPill(_ lines: Int, document: Bool) -> WritingPill {
    let name = document ? "Document setup" : "Setup"
    return WritingPill(
        text: "\(name) · \(lines) \(lines == 1 ? "line" : "lines")",
        muted: true,
        style: .setup(lines: lines, document: document),
    )
}

private func markPill(_ text: String, _ mark: WritingPill.Mark) -> WritingPill {
    WritingPill(text: text, muted: true, style: .mark(mark))
}

// MARK: - Folds off

@Test @MainActor func writingFoldsOffKeepEveryRoleAsBefore() async throws {
    let draft = try FoldDraft()
    let text = mixed as NSString
    let (layout, _) = try await foldModel(mixed, draft.renderer(), draft, folds: false)
    #expect(layout.blocks.map(\.kind) == [.context, .comment, .paragraph, .paragraph, .include, .paragraph])
    let blocks = layout.blocks.map(\.range)
    #expect(shapes(layout, text) == [
        .pill(WritingPill(text: "#set text(size: 11pt)", muted: false)),
        .source,
        .pill(WritingPill(text: "// A comment.", muted: true)),
        .source,
        .rendered(blocks[2]),
        .source,
        .pill(WritingPill(text: "#v(7mm)", muted: true)),
        .source,
        .pill(WritingPill(text: "#include \"chapter.typ\"", muted: false)),
        .source,
        .rendered(blocks[5]),
    ])
    #expect(layout.fold(holding: 0) == nil)
    #expect(layout.folds(intersecting: NSRange(location: 0, length: text.length)).isEmpty)
    #expect(!layout.setFold(open: true, at: 0) && !layout.toggleFold(at: 0))
    let whole = NSRange(location: 0, length: text.length)
    #expect(layout.drawnSpans(intersecting: whole) == layout.blocks.indices.map { layout.span(ofBlockAt: $0) })
    #expect(layout.spans(intersecting: whole) == layout.blocks.indices.map { layout.span(ofBlockAt: $0) })
}

// MARK: - Fold shapes

@Test @MainActor func writingFoldsTurnTheWelcomeSetupIntoOneDocumentSetupRow() async throws {
    let draft = try FoldDraft()
    let source = welcomeSetup + "\nBody words here.\n"
    let text = source as NSString
    let (layout, log) = try await foldModel(source, draft.renderer(), draft)
    let body = try #require(layout.blocks.indices.last)
    let fold = try #require(layout.fold(holding: 0))
    #expect(fold.pill == setupPill(16, document: true))
    #expect(fold.pill.text == "Document setup · 16 lines")
    #expect(!fold.isOpen && !fold.isHidden && fold.restingPosition == 0)
    #expect(fold.end == NSMaxRange(text.range(of: "zebra-fill: none)\n")))

    let roles = shapes(layout, text)
    try #require(roles.count == 19)
    #expect(roles[0] == .pill(fold.pill))
    #expect(Array(roles[1 ..< 17]) == Array(repeating: .collapsed, count: 16), "\(roles)")
    #expect(roles[17] == .source)
    #expect(roles[18] == .rendered(layout.blocks[body].range))
    for index in 0 ..< body {
        #expect(layout.state(ofBlockAt: index) == .pill(fold.pill))
    }

    // The caret at the resting position keeps it closed, though its block is active.
    let reported = log.calls.count
    layout.selectionDidChange(caret: 0)
    #expect(layout.activeBlock == 0)
    #expect(shapes(layout, text) == roles)
    #expect(log.calls.count == reported)
    #expect(layout.fold(holding: 0)?.isOpen == false)
}

@Test @MainActor func writingFoldsMarkCommentsAndInklessCallsAndKeepIncludesAsPills() async throws {
    let draft = try FoldDraft()
    let renderer = try await draft.renderer()
    let text = mixed as NSString
    let (layout, _) = await foldModel(mixed, renderer, draft)
    let blocks = layout.blocks.map(\.range)
    let include = WritingPill(text: "#include \"chapter.typ\"", muted: false)
    #expect(shapes(layout, text) == [
        .pill(setupPill(2, document: true)),
        .collapsed,
        .collapsed,
        .source,
        .rendered(blocks[2]),
        .source,
        .pill(markPill("#v(7mm)", .code)),
        .collapsed,
        .pill(include),
        .source,
        .rendered(blocks[5]),
    ])
    #expect(layout.state(ofBlockAt: 4) == .pill(include))
    let mark = try #require(layout.fold(holding: blocks[3].location))
    // The mark takes the blank line after it, up to the include.
    #expect(mark.span == NSRange(location: blocks[3].location, length: blocks[4].location - blocks[3].location))
    #expect(layout.fold(holding: blocks[4].location) == nil)

    // A comment between paragraphs; an include breaks a run of comments.
    let between = "Before words.\n\n// A note.\n// Second line.\n\nAfter words.\n\n// One.\n\n#include \"c.typ\"\n\n// Two.\n"
    let other = between as NSString
    let (marks, _) = await foldModel(between, renderer, draft)
    let ranges = marks.blocks.map(\.range)
    #expect(marks.blocks.map(\.kind) == [.paragraph, .comment, .paragraph, .comment, .include, .comment])
    #expect(shapes(marks, other) == [
        .rendered(ranges[0]),
        .source,
        .pill(markPill("// A note.", .comment)),
        .collapsed,
        .collapsed,
        .rendered(ranges[2]),
        .source,
        .pill(markPill("// One.", .comment)),
        .collapsed,
        .pill(WritingPill(text: "#include \"c.typ\"", muted: false)),
        .source,
        .pill(markPill("// Two.", .comment)),
    ])
    #expect(marks.folds(intersecting: NSRange(location: 0, length: other.length)).count == 3)

    // A later setup row is not the document's.
    let later = "Words first.\n\n#set par(leading: 1em)\n// why\n\nMore words.\n"
    let (row, _) = await foldModel(later, renderer, draft)
    #expect(row.fold(holding: (later as NSString).range(of: "#set").location)?.pill == setupPill(2, document: false))
    #expect(setupPill(1, document: false).text == "Setup · 1 line")
}

// MARK: - Opening and closing

@Test @MainActor func writingFoldsOpenByCaretWithHysteresisAndByPointer() async throws {
    let draft = try FoldDraft()
    let text = NSMutableString(string: setupInside)
    let (layout, log) = try await foldModel(setupInside, draft.renderer(), draft)
    let start = text.range(of: "#set").location
    let fold = try #require(layout.fold(holding: start))
    #expect(fold.pill == setupPill(2, document: false) && !fold.isOpen)
    let body = text.range(of: "Body").location
    let row = paragraphs(text).firstIndex { $0.location == start } ?? 0
    func role() -> Shape {
        shapes(layout, text)[row]
    }

    // The resting position does not open it; a caret past it does, at once.
    layout.selectionDidChange(caret: start)
    #expect(role() == .pill(fold.pill))
    var reported = log.calls.count
    layout.selectionDidChange(caret: start + 3)
    #expect(role() == .source && layout.fold(holding: start)?.isOpen == true)
    #expect(log.calls.count == reported + 1 && log.covers(start) && log.covers(NSMaxRange(fold.span) - 1))
    let blocks = layout.blocks.indices.filter { layout.blocks[$0].kind == .context }
    #expect(blocks.allSatisfy { layout.state(ofBlockAt: $0) == .source(.fold) })
    // Back at the resting position and at the end of its last line it stays open.
    layout.selectionDidChange(caret: start)
    #expect(role() == .source)
    layout.selectionDidChange(caret: NSMaxRange(fold.span) - 1)
    #expect(role() == .source)
    // Leaving closes it; the next paragraph's first character is outside.
    reported = log.calls.count
    layout.selectionDidChange(caret: NSMaxRange(fold.span))
    #expect(role() == .pill(fold.pill) && log.calls.count == reported + 1)
    layout.selectionDidChange(caret: body)
    layout.selectionDidChange(caret: start)
    #expect(role() == .pill(fold.pill))

    // The pointer pins it open; the caret leaving does not close it.
    layout.selectionDidChange(caret: body)
    #expect(layout.toggleFold(at: start + 5))
    #expect(role() == .source)
    layout.selectionDidChange(caret: start + 2)
    layout.selectionDidChange(caret: body)
    #expect(role() == .source)
    #expect(layout.toggleFold(at: start))
    #expect(role() == .pill(fold.pill))
    #expect(!layout.toggleFold(at: body) && !layout.setFold(open: true, at: 0))

    // Closing with the caret inside holds it closed until the caret leaves
    // and comes back.
    layout.selectionDidChange(caret: start + 4)
    #expect(role() == .source)
    #expect(layout.setFold(open: false, at: start + 4))
    #expect(role() == .pill(fold.pill))
    layout.selectionDidChange(caret: start + 8)
    #expect(role() == .pill(fold.pill))
    layout.selectionDidChange(caret: body + 2)
    layout.selectionDidChange(caret: start + 8)
    #expect(role() == .source)
    // Closing an open fold by toggle from inside, then opening it again.
    #expect(layout.toggleFold(at: start))
    #expect(role() == .pill(fold.pill))
    #expect(layout.setFold(open: true, at: start))
    #expect(role() == .source)
    #expect(layout.setFold(open: false, at: start))
    layout.selectionDidChange(caret: body)
    #expect(role() == .pill(fold.pill))
}

@Test @MainActor func writingFoldsOpenAndPinOnAnEditInsideButNotOnAnEditElsewhere() async throws {
    let draft = try FoldDraft()
    let text = NSMutableString(string: setupInside)
    let (layout, log) = try await foldModel(setupInside, draft.renderer(), draft)
    let body = text.range(of: "Body").location
    layout.selectionDidChange(caret: body)

    // An edit before the fold moves it and opens nothing.
    replace(text, NSRange(location: 0, length: 0), "More ", layout)
    var start = text.range(of: "#set").location
    #expect(layout.fold(holding: start)?.isOpen == false)
    await layout.idle()
    #expect(layout.fold(holding: start)?.isOpen == false)
    #expect(layout.fold(holding: start)?.restingPosition == start)

    // An edit inside opens it at once and pins it, through the new block list.
    let reported = log.calls.count
    replace(text, text.range(of: "11pt"), "12pt", layout)
    #expect(layout.fold(holding: start)?.isOpen == true)
    #expect(log.calls.count > reported && log.covers(start))
    await layout.idle()
    layout.selectionDidChange(caret: text.range(of: "Body").location)
    #expect(layout.fold(holding: start)?.isOpen == true)
    #expect(layout.setFold(open: false, at: start))

    // A character typed at the resting position is inside it.
    replace(text, NSRange(location: start, length: 0), "\n", layout)
    start += 1
    #expect(layout.fold(holding: start)?.isOpen == true)
    await layout.idle()
    #expect(layout.fold(holding: start)?.isOpen == true)
    #expect(layout.setFold(open: false, at: start))
    // An edit right after the fold, on the next paragraph, opens nothing.
    let next = text.range(of: "Body").location
    replace(text, NSRange(location: next, length: 0), "Z", layout)
    #expect(layout.fold(holding: start)?.isOpen == false)
}

@Test @MainActor func writingFoldsWaitForACompositionExceptWhereItEdits() async throws {
    let draft = try FoldDraft()
    let text = NSMutableString(string: setupInside)
    let (layout, log) = try await foldModel(setupInside, draft.renderer(), draft)
    var marked = false
    layout.hasMarkedText = { marked }
    let start = text.range(of: "#set").location
    let body = text.range(of: "Body").location
    layout.selectionDidChange(caret: body)

    // A caret moved into the fold while text is marked opens nothing.
    marked = true
    let reported = log.calls.count
    layout.selectionDidChange(caret: start + 4)
    #expect(layout.fold(holding: start)?.isOpen == false)
    #expect(!layout.setFold(open: true, at: start))
    #expect(log.calls.count == reported)
    marked = false
    layout.selectionDidChange(caret: start + 4)
    #expect(layout.fold(holding: start)?.isOpen == true && log.calls.count == reported + 1)

    // Leaving while marked closes nothing until the composition ends.
    marked = true
    layout.selectionDidChange(caret: body + 1)
    #expect(layout.fold(holding: start)?.isOpen == true)
    marked = false
    layout.selectionDidChange(caret: body + 1)
    #expect(layout.fold(holding: start)?.isOpen == false)

    // A composition that changes text in a closed fold opens it at once.
    marked = true
    let before = log.calls.count
    replace(text, NSRange(location: start + 1, length: 3), "拼", layout)
    #expect(layout.fold(holding: start)?.isOpen == true)
    #expect(log.calls.count == before + 1 && log.covers(start))
    let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
    #expect(layout.role(forParagraph: paragraph) == .source)
    replace(text, NSRange(location: start + 1, length: 1), "set", layout)
    marked = false
    layout.selectionDidChange(caret: body + 1)
    await layout.idle()
    #expect(layout.fold(holding: start)?.isOpen == true)
    #expect(layout.source == text as String)
}

// MARK: - Membership

@Test @MainActor func writingFoldsTakeABlockWhenItsBlankRenderArrivesAndLetItGo() async throws {
    let draft = try FoldDraft()
    let renderer = try await draft.renderer()
    let source = "// A note.\n\n#v(7mm)\n\nBody words here.\n"
    let text = NSMutableString(string: source)
    await renderer.holdRenders(true)
    let layout = WritingLayout(renderer: renderer, timing: foldTiming)
    let log = FoldLog()
    layout.onChange = { log.calls.append($0) }
    layout.foldsEnabled = true
    layout.setAppearance(foldAppearance)
    layout.setVisibleRange(NSRange(location: 0, length: text.length))
    layout.start(file: draft.file, text: source)
    await waitFor("a held render") { await renderer.heldCount == 1 }
    let spacing = text.range(of: "#v(7mm)").location
    // The comment alone is a fold; the call draws source while it waits.
    #expect(layout.fold(holding: 0)?.span == NSRange(location: 0, length: spacing))
    #expect(layout.fold(holding: 0)?.pill == markPill("// A note.", .comment))
    #expect(layout.state(ofBlockAt: 1) == .source(.waiting))
    #expect(layout.role(forParagraph: text.paragraphRange(for: NSRange(location: spacing, length: 0))) == .source)

    await renderer.holdRenders(false)
    await layout.idle()
    let body = text.range(of: "Body").location
    let fold = try #require(layout.fold(holding: 0))
    #expect(fold.span == NSRange(location: 0, length: body))
    #expect(fold.pill == markPill("// A note.", .code))
    #expect(log.covers(spacing) && log.covers(spacing - 1))
    #expect(shapes(layout, text) == [
        .pill(fold.pill),
        .collapsed,
        .collapsed,
        .collapsed,
        .rendered(layout.blocks[2].range),
    ])

    // Edited into words, the call leaves the fold when the engine says so.
    replace(text, NSRange(location: spacing, length: 7), "Plain words.", layout)
    #expect(layout.fold(holding: 0)?.isOpen == true)
    await layout.idle()
    #expect(layout.blocks.map(\.kind) == [.comment, .paragraph, .paragraph])
    let words = text.range(of: "Plain").location
    #expect(layout.fold(holding: words) == nil)
    #expect(layout.fold(holding: 0)?.span == NSRange(location: 0, length: words))
    #expect(layout.state(ofBlockAt: 1).rendering != nil)
    // It stays pinned open from the edit until the pointer closes it.
    #expect(layout.fold(holding: 0)?.isOpen == true)
    #expect(layout.toggleFold(at: 0) && layout.fold(holding: 0)?.isOpen == false)
}

@Test @MainActor func writingFoldsFollowBlankTextBetweenBlocks() async throws {
    let draft = try FoldDraft()
    let source = "// One.\n\n// Two.\n\nBody words here.\n"
    let text = NSMutableString(string: source)
    let (layout, log) = try await foldModel(source, draft.renderer(), draft)
    let body = text.range(of: "Body").location
    layout.selectionDidChange(caret: body)
    #expect(layout.folds(intersecting: NSRange(location: 0, length: text.length)).count == 1)

    // A paragraph typed on the blank line between splits the fold and opens
    // both halves; the engine's list then has a paragraph between them.
    replace(text, NSRange(location: 8, length: 0), "\nMiddle words.\n", layout)
    #expect(log.covers(8))
    #expect(layout.role(forParagraph: NSRange(location: 9, length: 14)) == .source)
    let split = layout.folds(intersecting: NSRange(location: 0, length: text.length))
    #expect(split.count == 2 && split.allSatisfy(\.isOpen))
    await layout.idle()
    let folds = layout.folds(intersecting: NSRange(location: 0, length: text.length))
    #expect(folds.count == 2 && folds.allSatisfy(\.isOpen))
    // Removing them joins the halves again, and the join stays open.
    replace(text, NSRange(location: 8, length: 15), "", layout)
    await layout.idle()
    let joined = layout.folds(intersecting: NSRange(location: 0, length: text.length))
    #expect(joined.count == 1 && joined.first?.isOpen == true)
    #expect(joined.first?.span == NSRange(location: 0, length: text.range(of: "Body").location))
}

// MARK: - Focus

@Test @MainActor func writingFoldsHideSetupRowsInFocusExceptAtTheRestingPosition() async throws {
    let draft = try FoldDraft()
    let source = "#set text(size: 11pt)\n\n// Why.\n\nBody words.\n\n// A mark.\n\nMore words.\n"
    let text = source as NSString
    let (layout, log) = try await foldModel(source, draft.renderer(), draft)
    let body = text.range(of: "Body").location
    // The blank line after the body: no block holds the caret.
    let away = NSMaxRange(text.range(of: "Body words.\n"))
    layout.selectionDidChange(caret: away)
    let row = setupPill(2, document: true)
    let mark = markPill("// A mark.", .comment)
    let shown = shapes(layout, text)
    #expect(Array(shown[0 ... 3]) == [.pill(row), .collapsed, .collapsed, .source])
    #expect(shown[4] == .rendered(layout.blocks[2].range))
    #expect(shown[5 ... 7] == [.source, .pill(mark), .collapsed])

    let reported = log.calls.count
    layout.hidesSetupRows = true
    layout.hidesSetupRows = true
    #expect(log.calls.count == reported + 1 && log.covers(0) && log.calls.last?
        .allSatisfy { NSMaxRange($0) <= body } == true)
    var hidden = shown
    hidden[0] = .collapsed
    #expect(shapes(layout, text) == hidden)
    #expect(layout.fold(holding: 0)?.isHidden == true)
    // At the resting position the row shows; inside, the fold opens.
    layout.selectionDidChange(caret: 0)
    #expect(shapes(layout, text) == shown)
    layout.selectionDidChange(caret: 3)
    #expect(shapes(layout, text)[0 ... 2] == [.source, .source, .source])
    layout.selectionDidChange(caret: away)
    #expect(shapes(layout, text) == hidden)
    layout.hidesSetupRows = false
    #expect(shapes(layout, text) == shown)

    // Turned off and on while running, folds report what they change.
    let calls = log.calls.count
    layout.foldsEnabled = false
    #expect(log.calls.count == calls + 1 && log.covers(0) && log.covers(text.range(of: "// A mark").location))
    #expect(shapes(layout, text)[0] == .pill(WritingPill(text: "#set text(size: 11pt)", muted: false)))
    layout.hidesSetupRows = true
    #expect(log.calls.count == calls + 1)
    layout.hidesSetupRows = false
    layout.foldsEnabled = true
    #expect(shapes(layout, text) == shown)
}

// MARK: - Selection and focus spans

@Test @MainActor func writingFoldsDrawAndFocusAsOneSpan() async throws {
    let draft = try FoldDraft()
    let source = "Intro words.\n\n#set text(size: 11pt)\n\n// Why.\n\nBody words.\n"
    let text = source as NSString
    let (layout, _) = try await foldModel(source, draft.renderer(), draft)
    let whole = NSRange(location: 0, length: text.length)
    let start = text.range(of: "#set").location
    let fold = try #require(layout.fold(holding: start))
    #expect(fold.span == NSRange(location: start, length: text.range(of: "Body").location - 1 - start))
    let intro = layout.span(ofBlockAt: 0), body = layout.span(ofBlockAt: 3)
    #expect(layout.drawnSpans(intersecting: whole) == [intro, fold.span, body])
    // A range on the blank line inside the fold names the whole fold.
    let gap = NSRange(location: text.range(of: "\n\n// Why").location + 1, length: 1)
    #expect(layout.drawnSpans(intersecting: gap) == [fold.span])
    #expect(layout.spans(intersecting: gap) == [fold.span])
    #expect(layout.spans(intersecting: whole) == [intro, fold.span, body])
    // Open, it draws source: NSTextView draws its selection. It still focuses as one.
    #expect(layout.setFold(open: true, at: start))
    #expect(layout.drawnSpans(intersecting: whole) == [intro, body])
    #expect(layout.spans(intersecting: gap) == [fold.span])
    #expect(layout.spans(intersecting: NSRange(location: start, length: 0)).isEmpty)
    // Per block queries keep their meaning.
    #expect(layout.blockRange(holding: start + 2) == layout.blocks[1].range)
    #expect(layout.span(ofBlockAt: 1) == text.paragraphRange(for: layout.blocks[1].range))
}

// MARK: - Seeded random edits

private let foldBase = """
// Setup comment.
#set text(size: 11pt)
#let x = 1

= Heading words

First paragraph with plain words.

// A note between.

#v(7mm)

Second paragraph with words.

#include "chapter.typ"

// Last comment.

"""

private let foldSnippets = [
    "// c\n", "\n#set par(leading: 1em)\n", "#v(3mm)\n", "\n\n", "words ", "\nPlain line.\n", "// x", "\n",
]

private func foldEdit(_ text: NSString, _ random: inout SplitMixFolds) -> (NSRange, String) {
    let location = Int.random(in: 0 ... text.length, using: &random)
    if Bool.random(using: &random) {
        let end = min(text.length, location + Int.random(in: 1 ... 10, using: &random))
        return (NSRange(location: location, length: end - location), "")
    }
    return (NSRange(location: location, length: 0), foldSnippets.randomElement(using: &random) ?? "\n")
}

/// SplitMix64, so every seed gives the same edits on every run.
private struct SplitMixFolds: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// After random edits, caret moves and toggles, with the engine's list
/// applied and every block rendered, each paragraph's role equals that of a
/// fresh model given the same text and caret. Open state is compared by
/// making the fresh model's folds match: each fold the old model has open
/// is opened (`setFold(open: true)`) and each it has closed is closed
/// (`setFold(open: false)`), then the fold lists must be equal too.
@Test @MainActor func writingFoldsMatchAFreshModelAfterSeededRandomEdits() async throws {
    let draft = try FoldDraft()
    let renderer = try await draft.renderer()
    let oracle = try await draft.renderer()
    var rounds = 0
    var open = 0, closed = 0
    for seed: UInt64 in [11, 12, 13, 14] {
        var random = SplitMixFolds(state: seed)
        let text = NSMutableString(string: foldBase)
        let (layout, _) = await foldModel(text as String, renderer, draft)
        var caret = 0
        for _ in 0 ..< 8 {
            for _ in 0 ..< 4 {
                let (range, replacement) = foldEdit(text, &random)
                replace(text, range, replacement, layout)
                caret = min(max(0, caret + (replacement as NSString).length - range.length), text.length)
                if Bool.random(using: &random) {
                    caret = Int.random(in: 0 ... text.length, using: &random)
                    layout.selectionDidChange(caret: caret)
                }
            }
            await layout.idle()
            for _ in 0 ..< 3 {
                // Fragments keep a role until `roleRevision` changes.
                var seen = (layout.roleRevision, shapes(layout, text))
                func check(_ what: String) {
                    let now = shapes(layout, text)
                    if now != seen.1 {
                        #expect(layout.roleRevision != seen.0, "\(what) changed a role, seed \(seed)")
                    }
                    seen = (layout.roleRevision, now)
                }
                caret = Int.random(in: 0 ... text.length, using: &random)
                layout.selectionDidChange(caret: caret)
                check("A caret move")
                if Int.random(in: 0 ..< 3, using: &random) == 0 {
                    layout.toggleFold(at: Int.random(in: 0 ... text.length, using: &random))
                    check("A toggle")
                }
            }
            #expect(layout.source == text as String)
            let (fresh, _) = await foldModel(text as String, oracle, draft)
            fresh.selectionDidChange(caret: caret)
            let whole = NSRange(location: 0, length: text.length)
            for fold in layout.folds(intersecting: whole) {
                if fold.isOpen {
                    open += 1
                } else {
                    closed += 1
                }
                if fresh.fold(holding: fold.restingPosition)?.isOpen != fold.isOpen {
                    fresh.setFold(open: fold.isOpen, at: fold.restingPosition)
                }
            }
            #expect(fresh.blocks == layout.blocks, "seed \(seed)")
            #expect(fresh.folds(intersecting: whole) == layout.folds(intersecting: whole), "seed \(seed)")
            #expect(shapes(fresh, text) == shapes(layout, text), "seed \(seed) round \(rounds)")
            #expect(fresh.activeBlock == layout.activeBlock)
            fresh.stop()
            rounds += 1
        }
        layout.stop()
    }
    #expect(rounds == 32)
    // The runs met both kinds of fold.
    #expect(open >= 10 && closed >= 10, "open \(open), closed \(closed)")
}

// MARK: - Cost

/// Caret moves cost binary searches over the folds, never a walk over the
/// blocks: measured on 4,000 blocks, 2,000 of them folds.
@Test @MainActor func writingFoldsKeepCaretMovesCheapOnALongFile() async throws {
    let draft = try FoldDraft()
    let source = (0 ..< 2000).map { "Paragraph \($0) words.\n\n// Comment \($0).\n\n" }.joined()
    let text = source as NSString
    let (layout, _) = try await foldModel(source, draft.renderer(), draft, visible: NSRange(location: 0, length: 400))
    #expect(layout.blocks.count == 4000)
    #expect(layout.folds(intersecting: NSRange(location: 0, length: text.length)).count == 2000)
    var random = SplitMixFolds(state: 7)
    let moves = 2000
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for _ in 0 ..< moves {
            layout.selectionDidChange(caret: Int.random(in: 0 ... text.length, using: &random))
        }
    }
    let perMove = elapsed / moves
    print("Fold caret move on 4,000 blocks: \(perMove)")
    // Loose: the debug build under load. The release cost is far smaller.
    #expect(perMove < .milliseconds(2))
    // Role reads stay cheap too.
    let roles = clock.measure {
        for paragraph in paragraphs(text).prefix(4000) {
            _ = layout.role(forParagraph: paragraph)
        }
    }
    print("Role reads for 4,000 paragraphs: \(roles)")
    #expect(roles < .milliseconds(200))
}
