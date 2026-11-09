import CoreGraphics
import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

/// A project in the test folder with a small main file. The model's file,
/// `draft.typ`, lives only in memory. Removed when the test ends.
private final class Draft {
    let root: URL

    init() throws {
        root = TestPaths.temporaryDirectory.appendingPathComponent("writing-layout-" + UUID().uuidString)
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

    func renderer() async throws -> BlockRenderer {
        try await BlockRenderer(root: root, main: main)
    }
}

/// The real engine, with calls that can be held, scripted or failed.
private actor GatedRenderer: WritingRenderer {
    let inner: BlockRenderer
    private(set) var renders: [NSRange] = []
    private(set) var refreshes = 0
    private var holdingRenders = false
    private var holdingBlocks = false
    private var heldRenders: [CheckedContinuation<Void, Never>] = []
    private var heldBlocks: [CheckedContinuation<Void, Never>] = []
    private var text: [URL: NSString] = [:]
    private var scripted: [String: Result<RenderedBlock, BlockRendererError>] = [:]
    private var refreshResult: RenderRefresh?
    private var setTextError: BlockRendererError?

    init(_ inner: BlockRenderer) {
        self.inner = inner
    }

    var heldRenderCount: Int {
        heldRenders.count
    }

    var heldBlockCount: Int {
        heldBlocks.count
    }

    func holdRenders(_ hold: Bool) {
        holdingRenders = hold
        if !hold {
            heldRenders.forEach { $0.resume() }
            heldRenders = []
        }
    }

    func holdBlocks(_ hold: Bool) {
        holdingBlocks = hold
        if !hold {
            heldBlocks.forEach { $0.resume() }
            heldBlocks = []
        }
    }

    func releaseRender() {
        if !heldRenders.isEmpty {
            heldRenders.removeFirst().resume()
        }
    }

    func releaseBlocks() {
        if !heldBlocks.isEmpty {
            heldBlocks.removeFirst().resume()
        }
    }

    func script(_ blockText: String, _ result: Result<RenderedBlock, BlockRendererError>) {
        scripted[blockText] = result
    }

    func failRefresh(_ result: RenderRefresh?) {
        refreshResult = result
    }

    func failSetText(_ error: BlockRendererError?) {
        setTextError = error
    }

    func setText(_ text: String, of file: URL) async throws {
        if let setTextError {
            throw setTextError
        }
        self.text[file] = text as NSString
        try await inner.setText(text, of: file)
    }

    func blocks(in file: URL) async throws -> [RenderBlock] {
        if holdingBlocks {
            await withCheckedContinuation { heldBlocks.append($0) }
        }
        return try await inner.blocks(in: file)
    }

    func render(
        _ range: NSRange,
        in file: URL,
        width: Double,
        options: RenderOptions,
    ) async -> Result<RenderedBlock, BlockRendererError> {
        renders.append(range)
        if holdingRenders {
            await withCheckedContinuation { heldRenders.append($0) }
        }
        if let source = text[file], NSMaxRange(range) <= source.length,
           let result = scripted[source.substring(with: range)]
        {
            return result
        }
        return await inner.render(range, in: file, width: width, options: options)
    }

    func refresh() async -> RenderRefresh {
        refreshes += 1
        if let refreshResult {
            return refreshResult
        }
        return await inner.refresh()
    }
}

/// The ranges `onChange` reported, call by call.
@MainActor
private final class ChangeLog {
    var calls: [[NSRange]] = []

    var all: [NSRange] {
        calls.flatMap(\.self)
    }

    func covers(_ location: Int) -> Bool {
        all.contains { NSLocationInRange(location, $0) }
    }
}

/// SplitMix64, so every seed gives the same edits on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private let fast = WritingTiming(settle: .milliseconds(5), refreshPause: nil)
private let appearance = WritingAppearance(columnWidth: 520, bitmapScale: 2.6, scale: 1.3)

private let threeParagraphs = """
First paragraph with several words in it.

Second paragraph with several words in it.

Third paragraph with several words in it.

"""

/// Waits for `condition`, failing the test after about five seconds.
@MainActor
private func eventually(_ what: String, _ condition: @MainActor () async -> Bool) async {
    for _ in 0 ..< 1000 {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(what)")
}

/// Replaces `range` of `text` with `replacement` and tells the model, as the
/// text storage delegate would.
@MainActor
private func edit(_ text: NSMutableString, _ range: NSRange, _ replacement: String, _ layout: WritingLayout) {
    text.replaceCharacters(in: range, with: replacement)
    let length = (replacement as NSString).length
    layout.textDidChange(
        edited: NSRange(location: range.location, length: length),
        delta: length - range.length,
        in: text,
    )
}

/// The offset just after the first occurrence of `needle`.
private func offset(after needle: String, in text: NSString) -> Int {
    NSMaxRange(text.range(of: needle))
}

@MainActor
private func renderedEverywhere(_ layout: WritingLayout) -> Bool {
    layout.blocks.indices.allSatisfy { layout.state(ofBlockAt: $0).rendering?.image != nil }
}

@MainActor
private func started(
    _ text: String,
    _ renderer: any WritingRenderer,
    _ draft: Draft,
    timing: WritingTiming = fast,
) async -> (WritingLayout, ChangeLog) {
    let layout = WritingLayout(renderer: renderer, timing: timing)
    let log = ChangeLog()
    layout.onChange = { log.calls.append($0) }
    layout.setAppearance(appearance)
    layout.setVisibleRange(NSRange(location: 0, length: (text as NSString).length))
    layout.start(file: draft.file, text: text)
    await layout.idle()
    return (layout, log)
}

// MARK: - Rebasing

private let randomBase = """
// Notes for the draft.
#set text(size: 11pt)

= Opening heading

The first paragraph has several plain words
and a second line with more words in it.

$ x = y + z $

```swift
let value = compute(input)
```

- first item here
- second item there

Closing paragraph with words, 结果 and 😀 inside it.

"""

private let snippets = ["New words 😀 here.", "\n", "结果 é ", "= Heading\n", "- item\n", "\n\n$ y $\n\n", " ", "ß"]
private let insertions = ["ab", "é", "ß", "结果", "😀", "Zq"]

private func isLetter(_ unit: unichar) -> Bool {
    (0x41 ... 0x5A).contains(unit) || (0x61 ... 0x7A).contains(unit)
}

/// A position that does not split a surrogate pair.
private func boundary(_ location: Int, in text: NSString) -> Int {
    var location = min(max(location, 0), text.length)
    while location > 0, location < text.length, UTF16.isTrailSurrogate(text.character(at: location)) {
        location -= 1
    }
    return location
}

/// An edit strictly inside a word of a block whose kind cannot change: the
/// rebased list stays the engine's.
private func wordEdit(
    _ text: NSString,
    _ blocks: [RenderBlock],
    _ random: inout SplitMix,
) -> (range: NSRange, replacement: String)? {
    let candidates = blocks.filter { block in
        let source = text.substring(with: block.range)
        return block.kind == .raw || [.paragraph, .heading, .list, .comment].contains(block.kind)
            && !source.contains("#") && !source.contains("$")
    }
    var positions: [(Int, Bool)] = []
    for block in candidates where block.range.length >= 3 {
        for index in block.range.location + 1 ..< NSMaxRange(block.range) - 1
            where isLetter(text.character(at: index - 1)) && isLetter(text.character(at: index))
        {
            positions.append((index, isLetter(text.character(at: index + 1))))
        }
    }
    guard let (location, deletable) = positions.randomElement(using: &random) else {
        return nil
    }
    if deletable, Bool.random(using: &random) {
        return (NSRange(location: location, length: 1), "")
    }
    return (NSRange(location: location, length: 0), insertions.randomElement(using: &random) ?? "ab")
}

/// Blank lines added and removed, line breaks, new text and deletions.
private func structuralEdit(_ text: NSString, _ random: inout SplitMix) -> (range: NSRange, replacement: String) {
    let anywhere = boundary(Int.random(in: 0 ... text.length, using: &random), in: text)
    switch Int.random(in: 0 ..< 4, using: &random) {
    case 0:
        return (NSRange(location: anywhere, length: 0), "\n\n")
    case 1:
        var breaks: [Int] = []
        var search = NSRange(location: 0, length: text.length)
        while case let found = text.range(of: "\n\n", range: search), found.location != NSNotFound {
            breaks.append(found.location)
            search = NSRange(location: found.location + 1, length: text.length - found.location - 1)
        }
        if let location = breaks.randomElement(using: &random) {
            return (NSRange(location: location, length: 1), "")
        }
        return (NSRange(location: anywhere, length: 0), "\n\n")
    case 2:
        return (NSRange(location: anywhere, length: 0), snippets.randomElement(using: &random) ?? " ")
    default:
        let end = boundary(min(text.length, anywhere + Int.random(in: 1 ... 12, using: &random)), in: text)
        return (NSRange(location: anywhere, length: max(0, end - anywhere)), "")
    }
}

@MainActor
private func expectOrdered(_ blocks: [RenderBlock], within length: Int) {
    #expect(blocks.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= length })
    #expect(zip(blocks, blocks.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
}

@Test @MainActor func writingLayoutRebasesSeededRandomEditsToTheEnginesBlocks() async throws {
    let draft = try Draft()
    let engine = try await draft.renderer()
    let oracle = try await draft.renderer()
    let layout = WritingLayout(renderer: engine, timing: fast)
    func fresh(_ text: NSString) async throws -> [RenderBlock] {
        try await oracle.setText(text as String, of: draft.file)
        return try await oracle.blocks(in: draft.file)
    }
    var edits = 0
    for seed: UInt64 in [1, 2, 3, 4] {
        var random = SplitMix(state: seed)
        let text = NSMutableString(string: randomBase)
        layout.start(file: draft.file, text: text as String)
        await layout.idle()
        #expect(try await layout.blocks == fresh(text))
        for _ in 0 ..< 6 {
            for _ in 0 ..< 5 {
                let blocks = try await fresh(text)
                guard let (range, replacement) = wordEdit(text, blocks, &random) else {
                    continue
                }
                edit(text, range, replacement, layout)
                edits += 1
            }
            // Without a new list from the engine, the rebased one is exact.
            #expect(try await layout.blocks == fresh(text), "seed \(seed) after word edits")
            for _ in 0 ..< 5 {
                let (range, replacement) = structuralEdit(text, &random)
                edit(text, range, replacement, layout)
                edits += 1
                expectOrdered(layout.blocks, within: text.length)
            }
            await layout.idle()
            #expect(layout.source == text as String)
            #expect(try await layout.blocks == fresh(text), "seed \(seed) after settling")
        }
    }
    #expect(edits >= 200)
}

// MARK: - Active block

@Test @MainActor func writingLayoutOpensTheCaretsBlockAtOnceAndClosesItOnlyWithARender() async throws {
    let draft = try Draft()
    let text = NSMutableString(string: threeParagraphs)
    let (layout, log) = try await started(text as String, draft.renderer(), draft)
    #expect(layout.blocks.count == 3 && renderedEverywhere(layout))
    #expect(layout.activeBlock == nil)

    // Entry opens the block in the same call, and reports its paragraphs.
    let second = layout.blocks[1].range
    layout.selectionDidChange(caret: second.location + 3)
    #expect(layout.activeBlock == 1)
    #expect(layout.state(ofBlockAt: 1) == .source(.active))
    #expect(log.calls.last == [text.paragraphRange(for: second)])
    #expect(layout.state(ofBlockAt: 0).rendering != nil && layout.state(ofBlockAt: 2).rendering != nil)

    // Typing drops the block's render; leaving waits for a new one.
    edit(text, NSRange(location: offset(after: "Second para", in: text), length: 0), "xyz", layout)
    #expect(layout.state(ofBlockAt: 1) == .source(.active))
    layout.selectionDidChange(caret: layout.blocks[2].range.location)
    #expect(layout.activeBlock == 2)
    #expect(layout.state(ofBlockAt: 1) == .source(.waiting))
    await layout.idle()
    let rendering = try #require(layout.state(ofBlockAt: 1).rendering)
    #expect(rendering.origin == layout.blocks[1].range.location && rendering.image != nil)
    #expect(log.covers(layout.blocks[1].range.location))

    // Leaving a block that was not edited closes it at once.
    layout.selectionDidChange(caret: 0)
    #expect(layout.activeBlock == 0 && layout.state(ofBlockAt: 2).rendering != nil)

    // A selection across all three blocks opens only the block of its moving end.
    layout.selectionDidChange(caret: NSMaxRange(layout.blocks[2].range))
    #expect(layout.activeBlock == 2)
    #expect(layout.state(ofBlockAt: 0).rendering != nil && layout.state(ofBlockAt: 1).rendering != nil)
    // A caret on a blank line between blocks opens nothing.
    layout.selectionDidChange(caret: NSMaxRange(layout.blocks[0].range) + 1)
    #expect(layout.activeBlock == nil && renderedEverywhere(layout))
}

@Test @MainActor func writingLayoutFreezesStatesWhileTextIsMarked() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let text = NSMutableString(string: threeParagraphs)
    let (layout, log) = await started(text as String, gate, draft)
    var marked = false
    layout.hasMarkedText = { marked }
    #expect(renderedEverywhere(layout))

    layout.selectionDidChange(caret: layout.blocks[1].range.location + 2)
    edit(text, NSRange(location: offset(after: "Second para", in: text), length: 0), "xyz", layout)
    await gate.holdRenders(true)
    layout.selectionDidChange(caret: layout.blocks[2].range.location + 2)
    #expect(layout.state(ofBlockAt: 1) == .source(.waiting))
    // The block the caret left renders first.
    await eventually("a held render") { await gate.heldRenderCount == 1 }
    #expect(await gate.renders.last == layout.blocks[1].range)

    marked = true
    let reported = log.calls.count
    let replies = layout.renderReplies
    await gate.releaseRender()
    await eventually("the render reply") { layout.renderReplies == replies + 1 }
    // The result waits, the caret opens nothing, edits report nothing.
    #expect(layout.state(ofBlockAt: 1) == .source(.waiting))
    layout.selectionDidChange(caret: 0)
    #expect(layout.activeBlock == 2 && layout.state(ofBlockAt: 0).rendering != nil)
    edit(text, NSRange(location: layout.blocks[2].range.location + 2, length: 0), "拼", layout)
    await layout.idle()
    #expect(log.calls.count == reported)
    #expect(layout.state(ofBlockAt: 2) == .source(.active))

    // When the composition ends, everything that waited applies.
    marked = false
    await gate.holdRenders(false)
    layout.selectionDidChange(caret: 0)
    #expect(layout.activeBlock == 0)
    #expect(layout.state(ofBlockAt: 1).rendering != nil)
    #expect(log.calls.count == reported + 1)
    #expect(log.covers(layout.blocks[0].range.location) && log.covers(layout.blocks[1].range.location))
    await layout.idle()
    #expect(layout.state(ofBlockAt: 2).rendering != nil)
    #expect(layout.source == text as String)
}

@Test @MainActor func writingLayoutHoldsABlockListThatArrivesDuringAComposition() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let text = NSMutableString(string: threeParagraphs)
    let (layout, _) = await started(text as String, gate, draft)
    var marked = false
    layout.hasMarkedText = { marked }

    await gate.holdBlocks(true)
    edit(text, NSRange(location: text.length, length: 0), "\nFourth paragraph.\n", layout)
    await eventually("a held block list") { await gate.heldBlockCount == 1 }
    marked = true
    let replies = layout.syncReplies
    await gate.holdBlocks(false)
    await eventually("the block list") { layout.syncReplies == replies + 1 }
    #expect(layout.blocks.count == 3)
    marked = false
    layout.selectionDidChange(caret: 0)
    #expect(layout.blocks.count == 4)
    await layout.idle()
    #expect(layout.activeBlock == 0 && (1 ..< 4).allSatisfy { layout.state(ofBlockAt: $0).rendering != nil })

    // A list sent while marked text exists waits for the composition too.
    marked = true
    edit(text, NSRange(location: text.length, length: 0), "\nFifth.\n", layout)
    await layout.idle()
    #expect(layout.blocks.count == 4)
    marked = false
    layout.selectionDidChange(caret: 0)
    await layout.idle()
    #expect(layout.blocks.count == 5)
}

// MARK: - Paragraph roles

@Test @MainActor func writingLayoutGivesEachParagraphItsRole() async throws {
    let draft = try Draft()
    let long = (0 ..< 450).map { "line \($0)" }.joined(separator: "\n")
    let source = """
    = A heading

    First line of a paragraph
    second line of it
    third line of it.

    $ x = y $

    ```swift
    let x = 1
    ```

    #set text(size: 11pt)

    // Only a comment.

    - one
    - two

    \(long)

    """
    let text = source as NSString
    let (layout, _) = try await started(source, draft.renderer(), draft)
    #expect(layout.blocks.map(\.kind) == [.heading, .paragraph, .equation, .raw, .context, .comment, .list, .paragraph])
    #expect(layout.state(ofBlockAt: 3) == .source(.raw))
    #expect(layout.state(ofBlockAt: 7) == .source(.long))

    var paragraphs: [(String, NSRange)] = []
    text
        .enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: .byParagraphs,
        ) { line, _, range, _ in
            paragraphs.append((line ?? "", range))
        }
    let roles = paragraphs.map { ($0.0, layout.role(forParagraph: $0.1)) }
    func role(_ line: String) -> WritingRole? {
        roles.first { $0.0 == line }?.1
    }
    func height(_ role: WritingRole?) -> Double? {
        if case let .rendered(rendering, _) = role {
            return rendering.height
        }
        return nil
    }
    for line in ["= A heading", "First line of a paragraph", "$ x = y $", "- one"] {
        let height = try #require(height(role(line)), "\(line)")
        #expect(height > 0)
    }
    if case let .rendered(rendering, block)? = role("First line of a paragraph") {
        #expect(block == layout.blocks[1].range)
        #expect(abs(rendering.height - rendering.drawnRect.height * 1.3) < 0.001)
        #expect(rendering.size.width == rendering.drawnRect.width * 1.3)
        let glyph = try #require(rendering.glyphs.first { $0.source != nil })
        #expect(rendering.offset(of: glyph, blockAt: block.location) == block.location)
    }
    for line in ["second line of it", "third line of it.", "- two"] {
        #expect(role(line) == .collapsed)
    }
    for line in ["```swift", "let x = 1", "```", "", "line 0", "line 200", "line 449"] {
        #expect(role(line) == .source, "\(line)")
    }
    #expect(role("#set text(size: 11pt)") == .pill(WritingPill(text: "#set text(size: 11pt)", muted: false)))
    #expect(role("// Only a comment.") == .pill(WritingPill(text: "// Only a comment.", muted: true)))
    #expect(layout.role(forParagraph: NSRange(location: text.length, length: 0)) == .source)
    #expect(layout.bytesHeld > 0)

    // The paragraphs NSTextView draws no selection over, and block lookup.
    let whole = NSRange(location: 0, length: text.length)
    let drawn = layout.blocks.indices.filter { !layout.state(ofBlockAt: $0).isSource }
    #expect(layout.drawnSpans(intersecting: whole) == drawn.map { text.paragraphRange(for: layout.blocks[$0].range) })
    let paragraph = layout.blocks[1].range
    #expect(layout.drawnSpans(intersecting: NSRange(location: paragraph.location + 3, length: 2)) == [
        text.paragraphRange(for: paragraph),
    ])
    #expect(layout.drawnSpans(intersecting: layout.blocks[3].range).isEmpty)
    #expect(layout.blockRange(holding: paragraph.location + 30) == paragraph)
    #expect(layout.blockRange(holding: NSMaxRange(paragraph) + 1) == nil)
}

@Test @MainActor func writingLayoutKeepsBlocksThatShareALineAsSource() async throws {
    let draft = try Draft()
    let source = "Intro words #set text(fill: red) more words.\n\nNext paragraph.\n"
    let text = source as NSString
    let (layout, _) = try await started(source, draft.renderer(), draft)
    let blocks = layout.blocks
    try #require(blocks.count == 4)
    #expect(blocks[1].kind == .context)
    for index in 0 ..< 3 {
        #expect(layout.state(ofBlockAt: index) == .source(.unaligned))
    }
    #expect(layout.role(forParagraph: text.paragraphRange(for: NSRange(location: 0, length: 0))) == .source)
    #expect(layout.state(ofBlockAt: 3).rendering != nil)
    // A caret in the shared line opens nothing that renders.
    layout.selectionDidChange(caret: 3)
    #expect(layout.state(ofBlockAt: 3).rendering != nil)
}

// MARK: - Timing

@Test @MainActor func writingLayoutDropsABlockListForOlderText() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let oracle = try await draft.renderer()
    let text = NSMutableString(string: threeParagraphs)
    let (layout, _) = await started(text as String, gate, draft)
    await gate.holdBlocks(true)
    edit(text, NSRange(location: text.length, length: 0), "\nAlpha.\n", layout)
    await eventually("a held block list") { await gate.heldBlockCount == 1 }
    edit(text, NSRange(location: 0, length: 0), "Zed. ", layout)
    let replies = layout.syncReplies
    await gate.releaseBlocks()
    await eventually("the stale list") { layout.syncReplies == replies + 1 }
    // The list for the text before "Zed. " has four blocks starting at 0.
    #expect(layout.blocks.count == 3 && layout.blocks[0].range.location == 5)
    await gate.holdBlocks(false)
    await layout.idle()
    try await oracle.setText(text as String, of: draft.file)
    #expect(try await layout.blocks == oracle.blocks(in: draft.file))
    #expect(layout.blocks.count == 4 && layout.blocks[0].range.location == 0)
}

@Test @MainActor func writingLayoutDropsARenderForChangedText() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    await gate.holdRenders(true)
    let text = NSMutableString(string: threeParagraphs)
    let layout = WritingLayout(renderer: gate, timing: fast)
    layout.setAppearance(appearance)
    layout.setVisibleRange(NSRange(location: 0, length: text.length))
    layout.start(file: draft.file, text: text as String)
    await eventually("a held render") { await gate.heldRenderCount == 1 }
    // Nearest first, and in order within the viewport.
    #expect(await gate.renders == [layout.blocks[0].range])
    edit(text, NSRange(location: offset(after: "First para", in: text), length: 0), "😀", layout)
    await gate.releaseRender()
    await eventually("the render reply") { layout.renderReplies == 1 }
    #expect(layout.state(ofBlockAt: 0) == .source(.waiting))
    await gate.holdRenders(false)
    await layout.idle()
    let rendering = try #require(layout.state(ofBlockAt: 0).rendering)
    #expect(rendering.image != nil && renderedEverywhere(layout))
    #expect(await gate.renders.first != layout.blocks[0].range)
    #expect(await gate.renders.contains(layout.blocks[0].range))
}

@Test @MainActor func writingLayoutEvictsImagesBeyondThreeScreensAndKeepsTheirHeights() async throws {
    let draft = try Draft()
    let source = (0 ..< 120).map { "Paragraph number \($0) with a few words." }.joined(separator: "\n\n") + "\n"
    let text = source as NSString
    let gate = try await GatedRenderer(draft.renderer())
    let layout = WritingLayout(renderer: gate, timing: fast)
    layout.setAppearance(appearance)
    layout.start(file: draft.file, text: source)
    await layout.idle()
    // No viewport, no renders.
    #expect(await gate.renders.isEmpty && layout.bytesHeld == 0)

    func screen(at paragraph: Int) -> NSRange {
        let start = text.range(of: "Paragraph number \(paragraph) ").location
        let end = text.range(of: "Paragraph number \(paragraph + 10) ").location
        return NSRange(location: start, length: end - start)
    }
    func held() -> Int {
        layout.blocks.indices.reduce(0) { total, index in
            let image = layout.state(ofBlockAt: index).rendering?.image
            return total + (image.map { $0.bytesPerRow * $0.height } ?? 0)
        }
    }
    layout.setVisibleRange(screen(at: 0))
    await layout.idle()
    // The screen and one more below it render.
    let first = Set(layout.blocks.indices.filter { layout.state(ofBlockAt: $0).rendering != nil })
    #expect(first.isSuperset(of: 0 ... 18) && first.isSubset(of: 0 ... 21))
    #expect(layout.bytesHeld == held() && layout.bytesHeld > 0)
    let height = try #require(layout.state(ofBlockAt: 0).rendering?.height)

    layout.setVisibleRange(screen(at: 100))
    #expect(layout.state(ofBlockAt: 0).rendering?.image == nil)
    #expect(layout.state(ofBlockAt: 0).rendering?.height == height)
    await layout.idle()
    let images = Set(layout.blocks.indices.filter { layout.state(ofBlockAt: $0).rendering?.image != nil })
    #expect(images.isSuperset(of: 91 ... 119) && images.isSubset(of: 88 ... 119))
    #expect(layout.bytesHeld == held())
    #expect(layout.role(forParagraph: text.paragraphRange(for: layout.blocks[0].range)) != .source)

    // Back at the top, evicted blocks render again with the same picture.
    let log = ChangeLog()
    layout.onChange = { log.calls.append($0) }
    layout.setVisibleRange(screen(at: 0))
    await layout.idle()
    #expect(layout.state(ofBlockAt: 0).rendering?.image != nil)
    #expect(log.covers(layout.blocks[0].range.location))
    #expect(layout.state(ofBlockAt: 119).rendering?.image == nil)
}

@Test @MainActor func writingLayoutReRendersForANewWidthOrColourAndKeepsOldImagesMeanwhile() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let (layout, log) = await started(threeParagraphs, gate, draft)
    let before = layout.blocks.indices.compactMap { layout.state(ofBlockAt: $0).rendering }
    #expect(before.count == 3)
    let renders = await gate.renders.count

    await gate.holdRenders(true)
    var narrow = appearance
    narrow.columnWidth = 200
    layout.setAppearance(narrow)
    layout.setAppearance(narrow)
    await eventually("a held render") { await gate.heldRenderCount == 1 }
    #expect(layout.blocks.indices.compactMap { layout.state(ofBlockAt: $0).rendering } == before)
    await gate.holdRenders(false)
    await layout.idle()
    let after = layout.blocks.indices.compactMap { layout.state(ofBlockAt: $0).rendering }
    #expect(after.count == 3 && zip(before, after).allSatisfy { $0 != $1 && $1.height > $0.height })
    #expect(await gate.renders.count == renders + 3)
    #expect(log.covers(layout.blocks[2].range.location))

    var dark = narrow
    dark.textColor = RenderColor(red: 0xE8 / 255, green: 0xE4 / 255, blue: 0xDE / 255)
    layout.setAppearance(dark)
    await layout.idle()
    let darkened = layout.blocks.indices.compactMap { layout.state(ofBlockAt: $0).rendering }
    #expect(darkened.count == 3 && zip(after, darkened).allSatisfy { $0 != $1 && $0.height == $1.height })
    #expect(await gate.renders.count == renders + 6)

    // An appearance that cannot render asks for nothing.
    var empty = dark
    empty.columnWidth = 0
    layout.setAppearance(empty)
    await layout.idle()
    #expect(await gate.renders.count == renders + 6)
}

@Test @MainActor func writingLayoutReRendersEveryBlockWhenAContextLineChanges() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let text = NSMutableString(string: "#set text(size: 11pt)\n\nAlpha words.\n\nBeta words.\n")
    let (layout, _) = await started(text as String, gate, draft)
    let before = try #require(layout.state(ofBlockAt: 1).rendering)
    let renders = await gate.renders.count
    edit(text, text.range(of: "11"), "16", layout)
    await layout.idle()
    let after = try #require(layout.state(ofBlockAt: 1).rendering)
    #expect(after.height > before.height)
    #expect(await gate.renders.count == renders + 2)
}

// MARK: - Refresh

@Test @MainActor func writingLayoutRefreshFailureMarksStaleAndKeepsFragments() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    await gate.failRefresh(RenderRefresh(
        succeeded: false,
        errors: 1,
        warnings: 0,
        pages: 0,
        headings: 0,
        equations: 0,
        references: 0,
        message: "unknown variable",
    ))
    let text = NSMutableString(string: threeParagraphs)
    let timing = WritingTiming(settle: .milliseconds(5), refreshPause: .milliseconds(20))
    var staleness: [Bool] = []
    let layout = WritingLayout(renderer: gate, timing: timing)
    layout.onStaleChange = { staleness.append($0) }
    layout.setAppearance(appearance)
    layout.setVisibleRange(NSRange(location: 0, length: text.length))
    layout.start(file: draft.file, text: text as String)
    await layout.idle()
    #expect(await gate.refreshes == 1)
    #expect(layout.stale && staleness == [true])
    #expect(renderedEverywhere(layout))
    let renders = await gate.renders.count

    // After edits pause, a good compile clears it and the viewport renders again.
    await gate.failRefresh(nil)
    edit(text, NSRange(location: text.length, length: 0), "Fourth.\n", layout)
    await layout.idle()
    #expect(await gate.refreshes == 2)
    #expect(!layout.stale && staleness == [true, false])
    #expect(await gate.renders.count >= renders + 4)
    #expect(renderedEverywhere(layout))
}

// MARK: - Lifecycle and failures

@Test @MainActor func writingLayoutDoesNoWorkWhileStoppedAndSwitchesFiles() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let text = NSMutableString(string: threeParagraphs)
    let (layout, _) = await started(text as String, gate, draft)
    #expect(layout.isRunning && layout.file == draft.file && layout.bytesHeld > 0)

    layout.stop()
    layout.stop()
    let renders = await gate.renders.count, refreshes = await gate.refreshes
    #expect(!layout.isRunning && layout.file == nil && layout.blocks.isEmpty && layout.bytesHeld == 0)
    edit(text, NSRange(location: 0, length: 0), "More. ", layout)
    layout.selectionDidChange(caret: 0)
    layout.setVisibleRange(NSRange(location: 0, length: 3))
    layout.setAppearance(WritingAppearance(columnWidth: 300, bitmapScale: 2))
    layout.switchFile(to: draft.main, text: "Other.")
    await layout.idle()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await gate.renders.count == renders)
    #expect(await gate.refreshes == refreshes)
    #expect(!layout.isRunning && layout.blocks.isEmpty)

    layout.setAppearance(appearance)
    layout.setVisibleRange(NSRange(location: 0, length: 1000))
    layout.start(file: draft.file, text: text as String)
    await layout.idle()
    #expect(layout.blocks.count == 3 && renderedEverywhere(layout))
    let other = draft.root.appendingPathComponent("other.typ")
    layout.switchFile(to: other, text: "= Other\n\nOne paragraph.\n")
    #expect(layout.blocks.isEmpty && layout.file == other)
    await layout.idle()
    #expect(layout.blocks.map(\.kind) == [.heading, .paragraph] && renderedEverywhere(layout))
}

@Test @MainActor func writingLayoutReportsFailedBlocksAndEngineErrors() async throws {
    let draft = try Draft()
    let gate = try await GatedRenderer(draft.renderer())
    let pixel = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )?.makeImage())
    func scripted(ink: CGRect, bitmap: CGImage?) -> RenderedBlock {
        RenderedBlock(
            svg: Data("<svg/>".utf8),
            size: CGSize(width: 10, height: 10),
            baseline: 5,
            ink: ink,
            drawnRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            glyphs: [],
            bitmap: bitmap,
            cached: false,
        )
    }
    await gate.script("Huge block.", .success(scripted(ink: CGRect(x: 0, y: 0, width: 5, height: 5), bitmap: nil)))
    await gate.script("#h(1em)", .success(scripted(ink: .zero, bitmap: pixel)))
    let source = "Fine words.\n\nBroken #(1 + ) here.\n\nHuge block.\n\n#h(1em)\n"
    let text = NSMutableString(string: source)
    let (layout, log) = await started(source, gate, draft)
    try #require(layout.blocks.count == 4)
    #expect(layout.state(ofBlockAt: 0).rendering != nil)
    guard case let .source(.failed(message)) = layout.state(ofBlockAt: 1) else {
        Issue.record("A broken block rendered")
        return
    }
    #expect(!message.isEmpty)
    #expect(layout.state(ofBlockAt: 2) == .source(.failed("The block is too large to draw.")))
    #expect(layout.state(ofBlockAt: 3) == .pill(WritingPill(text: "#h(1em)", muted: true)))
    let renders = await gate.renders.count
    // Failures are not retried for the same text and appearance.
    layout.setVisibleRange(NSRange(location: 1, length: text.length))
    await layout.idle()
    #expect(await gate.renders.count == renders)

    // An edit that does not fit the text held starts over from the given text.
    let calls = log.calls.count
    text.setString("Replaced text.\n")
    layout.textDidChange(edited: NSRange(location: 0, length: 5), delta: 99, in: text)
    #expect(layout.blocks.isEmpty && log.calls.count == calls + 1)
    await layout.idle()
    #expect(layout.source == text as String && layout.blocks.count == 1)

    // The engine refusing the text keeps the rebased list and says why.
    await gate.failSetText(BlockRendererError("The text could not be set."))
    edit(text, NSRange(location: text.length, length: 0), "\nMore.\n", layout)
    await layout.idle()
    #expect(layout.lastError == "The text could not be set.")
    #expect(layout.blocks.count == 1)
    await gate.failSetText(nil)
    edit(text, NSRange(location: 0, length: 0), "A ", layout)
    await layout.idle()
    #expect(layout.lastError == nil && layout.blocks.count == 2)
}
