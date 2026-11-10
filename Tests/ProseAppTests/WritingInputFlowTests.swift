import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 3 step G: input methods and VoiceOver in Writing mode, acceptance
/// tests 9 to 13 of the Phase 3 note, on the real window, editor and engine.
/// Compositions go through `setMarkedText(_:selectedRange:replacementRange:)`,
/// `insertText(_:replacementRange:)` and `unmarkText()`, as an input method
/// sends them, with Pinyin typed letter by letter. Accessibility is read
/// through NSTextView's accessibility methods and through
/// `accessibilityAttributeValue(_:forParameter:)`, which assistive apps use.
extension WritingFlowTests {
    // MARK: - Input methods

    @Test func writingModeAcceptance9MarkedTextHoldsRendersAndSwapsUntilItIsCommitted() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        var text = NSString(string: editor.string)
        let heading = text.range(of: "= Numbered heading").location
        #expect(role(model, text, heading).isRendered)

        // Type in the heading, then move into the short paragraph: the
        // heading waits for its render.
        editor.setSelectedRange(NSRange(location: heading + 2, length: 0))
        editor.insertText("X", replacementRange: editor.selectedRange())
        text = NSString(string: editor.string)
        let caret = text.range(of: "A short").location + 7
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        #expect(role(model, text, heading) == .source)
        #expect(role(model, text, caret) == .source)

        // Once the engine holds the new text it asks for the heading's render
        // in the same turn. The composition starts before the result arrives.
        let syncs = model.syncReplies, renders = model.renderReplies
        let deadline = ContinuousClock.now + .seconds(10)
        while model.syncReplies == syncs, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(model.syncReplies > syncs, "The engine never received the edited text")
        try #require(model.renderReplies == renders, "The heading's render arrived before the composition began")
        let before = writingFragments(manager)
        let swaps = editor.writing.swapCount
        typePinyin(editor, "zhong'wen")
        #expect(editor.hasMarkedText())
        let marked = editor.markedRange()
        #expect((editor.string as NSString).substring(with: marked) == "zhong'wen")

        // The render arrives while the text is marked; then the caret, the
        // viewport and the controller ask for swaps.
        try await app.wait { model.renderReplies > renders }
        let math = text.range(of: "A paragraph with inline math").location + marked.length
        model.selectionDidChange(caret: math + 3)
        editor.writing.selectionDidChange()
        editor.writing.viewportDidChange()
        editor.writing.flush()
        await model.idle()
        await app.layout()
        let during = writingFragments(manager)
        #expect(fragmentDifference(before, during) == nil, "\(fragmentDifference(before, during) ?? "")")
        #expect(editor.writing.swapCount == swaps, "A swap ran while text was marked")
        #expect(model.syncReplies == syncs + 1, "The marked text reached the engine")
        #expect(role(model, editor.string as NSString, heading) == .source)
        #expect(editor.hasMarkedText() && editor.markedRange() == marked)
        let held = editor.writing.swapCount - swaps

        // Commit: the held render swaps in, and the text is there once.
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        let committed = editor.string as NSString
        let expected = text.replacingCharacters(in: NSRange(location: caret, length: 0), with: "中文")
        #expect(committed as String == expected)
        #expect(committed.components(separatedBy: "中文").count == 2)
        #expect(!committed.contains("zhong") && !committed.contains("'wen"))
        #expect(editor.selectedRange() == NSRange(location: caret + 2, length: 0))
        #expect(editor.writing.swapCount > swaps)
        guard case let .rendered(headingRender, _) = role(model, committed, heading) else {
            Issue.record("The heading's held render did not swap in after the composition")
            return
        }
        #expect(headingRender.glyphs.contains { headingRender.offset(of: $0, blockAt: heading) == heading + 2 })
        #expect(role(model, committed, caret) == .source)
        print("WRITING composition: \(model.renderReplies - renders) render held while marked, " +
            "\(held) swaps while marked, \(editor.writing.swapCount - swaps) after the commit")

        // The caret leaves: the paragraph renders the committed text.
        park(editor)
        await model.idle()
        await app.layout()
        let short = committed.range(of: "A short").location
        guard case let .rendered(shortRender, block) = role(model, committed, short) else {
            Issue.record("The composed paragraph did not render after the caret left")
            return
        }
        let sources = Set(shortRender.glyphs.compactMap { shortRender.offset(of: $0, blockAt: block.location) })
        #expect(sources.contains(caret) && sources.contains(caret + 1), "No glyphs for 中文: \(sources.sorted())")
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance9ACompositionOverAPointerSelectionOpensTheBlockItEdits() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = NSString(string: editor.string)
        let paragraph = text.range(of: "A paragraph with inline math").location
        let word = text.range(of: "paragraph", options: [], range: NSRange(location: paragraph, length: 20))

        // A drag inside the rendered paragraph selects most of a word and
        // opens nothing.
        try writingPress(
            editor,
            at: glyphCentre(manager, block: paragraph, offset: word.location),
            through: [glyphCentre(manager, block: paragraph, offset: NSMaxRange(word) - 1)],
        )
        let selection = NSRange(location: word.location, length: word.length - 1)
        #expect(editor.selectedRange() == selection)
        #expect(role(model, text, paragraph).isRendered)
        let swaps = editor.writing.swapCount

        // The composition replaces the selection: the paragraph opens at
        // once, so NSTextView lays out and draws the marked text.
        typePinyin(editor, "zhong'wen")
        #expect(editor.hasMarkedText())
        #expect(role(model, editor.string as NSString, paragraph) == .source)
        #expect(editor.writing.swapCount > swaps)
        let fragment = try #require(writingFragments(manager).first { $0.offset == paragraph })
        #expect(fragment.role == .source && fragment.frame.height > 20)
        let caret = try #require(TextKit2Geometry.caretRect(at: editor.selectedRange().location, in: manager))
        #expect(caret.midY >= fragment.frame.minY && caret.midY <= fragment.frame.maxY)
        let candidate = editor.firstRect(forCharacterRange: editor.markedRange(), actualRange: nil)
        let line = try onScreen(editor, caret)
        #expect(candidate.minY <= line.midY && candidate.maxY >= line.midY, "\(candidate) is not on \(line)")

        // Commit and leave: the block renders the committed text.
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        #expect(editor.string == text.replacingCharacters(in: selection, with: "中文"))
        park(editor)
        await model.idle()
        #expect(role(model, editor.string as NSString, paragraph).isRendered)
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance10MarkedTextAtTheViewportEdgeSurvivesAScroll() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = NSString(string: editor.string)

        // The last rendered block that starts in view lies at its bottom edge.
        let start = editor.containerVisibleRect()
        let edge = try #require(writingFragments(manager).last { $0.isRendered && $0.frame.minY < start.maxY - 4 })
        #expect(edge.frame.maxY > start.maxY - 60, "Block \(edge.offset) at \(edge.frame) is not near \(start.maxY)")
        let caret = edge.offset + 6
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        #expect(role(model, text, edge.offset) == .source)
        await model.idle()
        let renders = model.renderReplies, syncs = model.syncReplies
        typePinyin(editor, "zhong'wen")
        let marked = editor.markedRange()
        let composing = NSString(string: editor.string) as String
        let swaps = editor.writing.swapCount
        func expectComposition(_ stage: String) throws {
            #expect(editor.hasMarkedText() && editor.markedRange() == marked, "\(stage): composition lost")
            #expect(editor.string == composing, "\(stage): the text changed")
            #expect(editor.selectedRange() == NSRange(location: NSMaxRange(marked), length: 0), "\(stage)")
            #expect(role(model, composing as NSString, edge.offset) == .source, "\(stage): the block closed")
            #expect(editor.writing.swapCount == swaps, "\(stage): a swap ran")
            let caretRect = try #require(TextKit2Geometry.caretRect(at: NSMaxRange(marked), in: manager))
            // Out of view NSTextView answers no rectangle; the candidate
            // window then has nothing to follow.
            guard editor.containerVisibleRect().intersects(caretRect) else {
                return
            }
            let line = try onScreen(editor, caretRect)
            var actual = NSRange()
            let candidate = editor.firstRect(forCharacterRange: marked, actualRange: &actual)
            #expect(candidate.minY <= line.midY && candidate.maxY >= line.midY, "\(stage): \(candidate) off \(line)")
            #expect(actual.location == marked.location && actual.length > 0, "\(stage): actual range \(actual)")
        }
        try expectComposition("before scrolling")

        // Down until the block is at the top edge and new rendered blocks
        // come into view, then past it, and back.
        var visible = start
        var entered = 0
        for target in [edge.frame.minY - 20, edge.frame.maxY + 120, start.minY] {
            editor.scrollContainer(to: target)
            await app.layout()
            await model.idle()
            let now = editor.containerVisibleRect()
            #expect(abs(now.minY - visible.minY) > 100, "The view did not scroll to \(target): \(now)")
            let shown = writingFragments(manager).filter {
                $0.isRendered && $0.frame.maxY > now.minY && $0.frame.minY < now.maxY
            }
            entered += shown.count(where: { $0.frame.minY >= visible.maxY || $0.frame.maxY <= visible.minY })
            visible = now
            try expectComposition("scrolled to \(now.minY)")
        }
        print("WRITING composition at the viewport edge: block \(edge.offset), \(entered) rendered blocks " +
            "came into view over three scrolls, \(editor.writing.swapCount - swaps) swaps")
        #expect(entered >= 4, "Only \(entered) rendered blocks came into view")
        #expect(abs(visible.minY - start.minY) < 1)
        #expect(model.renderReplies == renders && model.syncReplies == syncs, "The engine worked while text was marked")

        // Commit; once the caret leaves, the block renders the committed text.
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        let committed = editor.string as NSString
        #expect(committed as String == text.replacingCharacters(in: NSRange(location: caret, length: 0), with: "中文"))
        park(editor)
        await model.idle()
        await app.layout()
        guard case let .rendered(rendering, block) = role(model, committed, edge.offset) else {
            Issue.record("The composed block did not render after the caret left")
            return
        }
        let sources = Set(rendering.glyphs.compactMap { rendering.offset(of: $0, blockAt: block.location) })
        #expect(sources.contains(caret) && sources.contains(caret + 1))
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance11TheCandidateWindowLiesOnTheCaretsLine() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = NSString(string: editor.string)
        let source = text as String
        var checked = 0
        // Between rendered blocks, on a later source line of a rendered
        // block, and further down once scrolled.
        let places = [("short paragraph", false), ("continues on a second", false), ("Filler paragraph 9,", true)]
        for (needle, scroll) in places {
            park(editor)
            await model.idle()
            writingScrollToTop(editor)
            let caret = text.range(of: needle).location + 5
            if scroll {
                editor.reveal(NSRange(location: caret, length: 0))
                await app.layout()
            }
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            #expect(role(model, text, caret) == .source)
            let pinyin = "zhong'wen"
            for end in 1 ... pinyin.count {
                let prefix = String(pinyin.prefix(end))
                editor.setMarkedText(
                    prefix,
                    selectedRange: NSRange(location: prefix.utf16.count, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0),
                )
                let marked = editor.markedRange()
                let insertion = editor.selectedRange()
                let caretRect = try #require(TextKit2Geometry.caretRect(at: insertion.location, in: manager))
                let startRect = try #require(TextKit2Geometry.caretRect(at: marked.location, in: manager))
                let line = try onScreen(editor, caretRect), lineStart = try onScreen(editor, startRect)
                var actual = NSRange()
                let candidate = editor.firstRect(forCharacterRange: marked, actualRange: &actual)
                let point = editor.firstRect(forCharacterRange: insertion, actualRange: nil)
                let place = "\(needle) \(prefix)"
                #expect(candidate.height > 0 && candidate.width > 0, "\(place): \(candidate)")
                #expect(
                    candidate.minY <= line.midY && candidate.maxY >= line.midY,
                    "\(place): \(candidate) off \(line)",
                )
                #expect(abs(candidate.minX - lineStart.minX) < 1, "\(place): \(candidate) starts off \(lineStart)")
                #expect(NSIntersectionRange(actual, marked) == actual && actual.location == marked.location)
                #expect(
                    abs(point.minX - line.minX) < 1 && point.minY <= line.midY && point.maxY >= line.midY,
                    "\(place): insertion point \(point) off \(line)",
                )
                checked += 1
            }
            editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.unmarkText()
            #expect(editor.string == text.replacingCharacters(in: NSRange(location: caret, length: 0), with: "中文"))
            editor.undoManager?.undo()
            #expect(editor.string == source)
        }

        // A range inside a rendered block, as a lookup asks for it: the first
        // drawn line of its glyphs.
        park(editor)
        await model.idle()
        writingScrollToTop(editor)
        let paragraph = text.range(of: "A paragraph with inline math").location
        let shown = try #require(renderedBlock(manager, at: paragraph))
        let range = NSRange(location: paragraph + 2, length: 80)
        var actual = NSRange()
        let first = editor.firstRect(forCharacterRange: range, actualRange: &actual)
        let box = try #require(glyphBoxes(shown).first { $0.offset == paragraph + 2 })
        let glyph = try onScreen(editor, box.box)
        #expect(first.insetBy(dx: -0.5, dy: -0.5).contains(glyph), "\(first) does not hold \(glyph)")
        #expect(first.height < 30, "\(first) is taller than one drawn line")
        #expect(actual.location == range.location && actual.length > 0 && NSMaxRange(actual) <= NSMaxRange(range))
        print("WRITING candidate windows: \(checked) compositions on the caret's line; lookup \(first) for \(actual)")
        expectPlainStorage(editor)
    }

    // MARK: - VoiceOver

    @Test func writingModeAcceptance12AccessibilityValueIsTheSourceAndFramesLieOnTheGlyphs() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = NSString(string: editor.string)
        let source = text as String
        #expect(editor.accessibilityValue() == source)
        #expect(editor.accessibilityNumberOfCharacters() == text.length)
        let whole = NSValue(range: NSRange(location: 0, length: text.length))
        #expect(legacy(editor, .stringForRange, whole) as? String == source)

        var characters = 0, glyphs = 0
        var problems: [String] = []
        for needle in ["A paragraph with inline math", "= Numbered heading", "$ integral"] {
            let start = text.range(of: needle).location
            let shown = try #require(renderedBlock(manager, at: start), "\(needle) is not rendered")
            #expect(editor.accessibilityString(for: shown.block) == text.substring(with: shown.block))
            let fragment = try onScreen(editor, shown.info.frame)
            let boxes = glyphBoxes(shown)
            // Every character, glyph or not, has a frame on a drawn line in
            // the rendered fragment; a character with glyphs, on its glyphs.
            var index = shown.block.location
            while index < NSMaxRange(shown.block) {
                let character = text.rangeOfComposedCharacterSequence(at: index)
                index = NSMaxRange(character)
                characters += 1
                let frame = editor.accessibilityFrame(for: character)
                let bounds = (legacy(editor, .boundsForRange, NSValue(range: character)) as? NSValue)?.rectValue
                if bounds != frame {
                    problems.append("\(character): AXBoundsForRange \(String(describing: bounds)), frame \(frame)")
                }
                if frame.height <= 0 || frame.minY < fragment.minY - 0.5 || frame.maxY > fragment.maxY + 0.5 {
                    problems.append("\(character) \(text.substring(with: character).debugDescription): \(frame) " +
                        "outside the fragment \(fragment)")
                }
                let own = boxes.filter { $0.offset == character.location }
                guard let first = own.first else {
                    continue
                }
                glyphs += 1
                let union = try onScreen(editor, own.dropFirst().reduce(first.box) { $0.union($1.box) })
                let glyph = try onScreen(editor, first.box)
                if !union.insetBy(dx: -0.5, dy: -0.5).contains(frame) || !frame.insetBy(dx: -0.5, dy: -0.5)
                    .contains(glyph)
                {
                    problems.append("\(character): frame \(frame), glyph boxes \(union)")
                }
            }
            // The range for a point maps through the glyph boxes, as a click.
            for box in boxes {
                let centre = try onScreen(editor, box.box)
                let point = NSPoint(x: centre.midX, y: centre.midY)
                let expected = text.rangeOfComposedCharacterSequence(at: box.offset ?? shown.block.location)
                let found = editor.accessibilityRange(for: point)
                let position = (legacy(editor, .rangeForPosition, NSValue(point: point)) as? NSValue)?.rangeValue
                let character = editor.characterIndex(for: point)
                if found != expected || position != expected || character != expected.location {
                    problems.append("point \(point) on \(String(describing: box.offset)): range \(found), " +
                        "AXRangeForPosition \(String(describing: position)), character \(character)")
                }
            }
            #expect(role(model, text, start).isRendered, "\(needle) opened")
        }

        // A pill's frame is the pill; a range from source into a pill holds
        // both.
        let pills = writingFragments(manager).filter(\.isPill)
        #expect(pills.count >= 2)
        let column = try #require(editor.textContainer).size.width
        // Since Phase 6 the `#set` lines are a setup row and the comment a
        // margin mark: their frames are the row's icon and label, and the
        // mark's icon.
        for pill in pills {
            guard case let .pill(shown) = pill.role, let block = model.blockRange(holding: pill.offset) else {
                continue
            }
            let local = switch shown.style {
            case .plain: WritingMetrics.pillRect(label: shown.text, column: column)
            case .setup: WritingMetrics.setupRowRect(label: shown.text, column: column)
            case .mark: try #require(pill.fragment?.marginIconRect)
            }
            let expected = try onScreen(editor, local.offsetBy(dx: pill.frame.minX, dy: pill.frame.minY))
            let frame = editor.accessibilityFrame(for: block)
            #expect(
                abs(frame.minX - expected.minX) < 0.5 && abs(frame.minY - expected.minY) < 0.5
                    && abs(frame.width - expected.width) < 0.5 && abs(frame.height - expected.height) < 0.5,
                "Pill \(block): frame \(frame), pill \(expected)",
            )
            guard !shown.isMark else {
                // A mark takes no height in the column; no point lies on it.
                continue
            }
            let centre = NSPoint(x: expected.midX, y: expected.midY)
            #expect(editor.accessibilityRange(for: centre) == text.rangeOfComposedCharacterSequence(at: pill.offset))
        }
        let raw = text.range(of: "def raw()")
        let comment = text.range(of: "// A comment")
        let across = NSRange(location: raw.location, length: NSMaxRange(comment) - raw.location)
        let frame = editor.accessibilityFrame(for: across)
        let rawLine = editor.accessibilityFrame(for: raw)
        let commentPill = editor.accessibilityFrame(for: comment)
        #expect(rawLine.height > 10 && commentPill.height > 10)
        #expect(frame.contains(rawLine) && frame.contains(commentPill), "\(frame): \(rawLine), \(commentPill)")

        print("WRITING accessibility frames: \(characters) characters, \(glyphs) with glyphs, " +
            "\(problems.count) problems")
        #expect(characters > 150 && glyphs > 100)
        #expect(problems.isEmpty, "\(problems.prefix(12))")
        #expect(editor.accessibilityValue() == source)
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance13ReadingByLineThroughARenderedBlockReadsItsSourceLines() async throws {
        // A paragraph of four source lines, one of which wraps in the source
        // layout, between a heading and a paragraph.
        let long = (1 ... 40).map { "word\($0)" }.joined(separator: " ")
        let source = "= Reading heading\n\nFirst source line of the block,\n\(long) ends the long line,\n" +
            "a third line with $x^2$ in it,\nand the last line.\n\nThe paragraph after it.\n\n```py\nraw\n```\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let text = source as NSString
        let blockStart = text.range(of: "First source").location
        let block = NSRange(location: blockStart, length: NSMaxRange(text.range(of: "the last line.")) - blockStart)
        let span = text.paragraphRange(for: block)
        let after = text.range(of: "The paragraph after").location
        func readLines() -> [AccessibilityLine] {
            let first = editor.accessibilityLine(for: span.location)
            let last = editor.accessibilityLine(for: NSMaxRange(span) - 1)
            return (first ... max(first, last)).map { number in
                let range = editor.accessibilityRange(forLine: number)
                return AccessibilityLine(number: number, range: range, string: editor.accessibilityString(for: range))
            }
        }
        writingScrollToTop(editor)
        let code = readLines()
        let codeAfter = editor.accessibilityLine(for: after)

        let raw = text.range(of: "raw\n").location
        editor.setSelectedRange(NSRange(location: raw + 1, length: 0))
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        await app.layout()
        let shown = try #require(renderedBlock(manager, at: block.location), "The paragraph is not rendered")
        let fragment = try onScreen(editor, shown.info.frame)
        let lines = readLines()
        #expect(lines == code, "Writing mode reads \(lines), Code mode \(code)")
        #expect(editor.accessibilityLine(for: after) == codeAfter)

        // In order, every character once, the source's own text, no empty
        // line, and each source line whole across its pieces.
        var cursor = span.location
        var pieces: [String] = []
        var readSourceLines: [String] = []
        for line in lines {
            #expect(
                line.range.location == cursor,
                "Line \(line.number) starts at \(line.range.location), not \(cursor)",
            )
            #expect(line.range.length > 0 && line.string == text.substring(with: line.range))
            #expect(line.string?.trimmingCharacters(in: .newlines).isEmpty == false, "Line \(line.number) is empty")
            cursor = NSMaxRange(line.range)
            pieces.append(line.string ?? "")
            if line.string?.hasSuffix("\n") == true {
                readSourceLines.append(pieces.joined().trimmingCharacters(in: .newlines))
                pieces = []
            }
            // The parameterized attributes answer the same.
            #expect(legacy(editor, .lineForIndex, NSNumber(value: line.range.location)) as? Int == line.number)
            #expect((legacy(editor, .rangeForLine, NSNumber(value: line.number)) as? NSValue)?.rangeValue == line.range)
            // Its frame lies in the rendered fragment, on drawn glyphs.
            let frame = editor.accessibilityFrame(for: line.range)
            #expect(
                frame.height > 10 && frame.minY >= fragment.minY - 0.5 && frame.maxY <= fragment.maxY + 0.5,
                "Line \(line.number): \(frame) outside \(fragment)",
            )
        }
        #expect(cursor == NSMaxRange(span))
        #expect(readSourceLines == text.substring(with: block).components(separatedBy: "\n"))
        #expect(lines.count > readSourceLines.count, "The long source line does not wrap in the source layout")

        // The insertion point reads the same line numbers when the caret
        // stands on each line, which opens the block.
        for line in lines {
            editor.setSelectedRange(NSRange(location: line.range.location + 1, length: 0))
            #expect(role(model, text, block.location) == .source)
            #expect(editor.accessibilityInsertionPointLineNumber() == line.number)
            #expect(legacy(editor, .lineForIndex, NSNumber(value: line.range.location + 1)) as? Int == line.number)
            editor.setSelectedRange(NSRange(location: raw + 1, length: 0))
            #expect(role(model, text, block.location).isRendered)
        }
        print("WRITING reading by line: \(lines.count) lines for \(readSourceLines.count) source lines")
        #expect(editor.accessibilityValue() == source)
        expectPlainStorage(editor)
    }
}

// MARK: - Helpers

/// Types `pinyin` letter by letter as marked text, as the Pinyin input method
/// does, replacing the selection with the first letter.
@MainActor
private func typePinyin(_ editor: ManuscriptTextView, _ pinyin: String) {
    for end in 1 ... pinyin.count {
        let prefix = String(pinyin.prefix(end))
        editor.setMarkedText(
            prefix,
            selectedRange: NSRange(location: prefix.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
    }
}

/// `rect` in container coordinates, on the screen.
@MainActor
private func onScreen(_ editor: ManuscriptTextView, _ rect: CGRect) throws -> CGRect {
    let window = try #require(editor.window)
    let local = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
    return window.convertToScreen(editor.convert(local, to: nil))
}

/// What an assistive app gets for a parameterized attribute: the answer to
/// `accessibilityAttributeValue(_:forParameter:)`, called by selector because
/// Swift marks the method deprecated.
@MainActor
private func legacy(
    _ editor: ManuscriptTextView,
    _ attribute: NSAccessibility.ParameterizedAttribute,
    _ parameter: Any,
) -> Any? {
    editor.perform(
        NSSelectorFromString("accessibilityAttributeValue:forParameter:"),
        with: attribute.rawValue,
        with: parameter,
    )?.takeUnretainedValue()
}

private struct AccessibilityLine: Equatable, CustomStringConvertible {
    let number: Int
    let range: NSRange
    let string: String?

    var description: String {
        "\(number) \(range)"
    }
}

/// Whether two roles draw the same thing; a rendered block's range moves
/// with edits before it.
private func sameRole(_ old: WritingRole, _ new: WritingRole) -> Bool {
    if case let .rendered(before, _) = old, case let .rendered(after, _) = new {
        return before == after
    }
    return old == new
}

/// The first fragment whose role or frame differs, in order.
private func fragmentDifference(_ before: [WritingFragmentInfo], _ after: [WritingFragmentInfo]) -> String? {
    guard before.count == after.count else {
        return "\(before.count) fragments before, \(after.count) after"
    }
    for (index, (old, new)) in zip(before, after).enumerated() {
        let same = sameRole(old.role, new.role) && abs(old.frame.minY - new.frame.minY) < 0.01
            && abs(old.frame.height - new.frame.height) < 0.01
        if !same {
            return "Fragment \(index) at \(new.offset): \(old.role) \(old.frame) became \(new.role) \(new.frame)"
        }
    }
    return nil
}
