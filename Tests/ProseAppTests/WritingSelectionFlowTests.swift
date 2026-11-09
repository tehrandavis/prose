import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 3 step E: pointer and selection in Writing mode, acceptance tests 1
/// to 5 of the Phase 3 note, on the real window, editor and engine.
///
/// No test posts events: `NSApp.postEvent` stops the main run loop, which ends
/// a `swift test` run with status 0 and no report (Phase 3 spike). Presses on
/// rendered blocks call the editor's `mouseDown(with:)` with a constructed
/// event; Prose's own tracking loop then reads its drags and the release from
/// `pointerEvents`, which the test scripts (`writingPress`). A press that
/// would enter AppKit's tracking loop instead is refused while a script is
/// set and counted in `unhandledScriptedClicks`, which every press checks.
/// Drags that start in source stay with AppKit and are driven through the
/// selection navigation calls its tracking makes, as the spike did.
extension WritingFlowTests {
    @Test func writingModeClickPutsTheCaretAtEveryGlyphsSourceAndOpensTheBlock() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = editor.string as NSString
        #expect(manager.textSelectionNavigation is WritingSelectionNavigation)
        var clicks = 0, generated = 0
        var mismatches: [String] = []
        for needle in ["A paragraph with inline math", "= Numbered heading", "$ integral"] {
            let start = text.range(of: needle).location
            park(editor)
            let first = try #require(renderedBlock(manager, at: start), "\(needle) is not rendered")
            let count = glyphBoxes(first).count
            #expect(count > 5, "\(needle) has \(count) glyph boxes")
            for index in 0 ..< count {
                park(editor)
                writingScrollToTop(editor)
                guard let shown = renderedBlock(manager, at: start) else {
                    Issue.record("\(needle) did not render again after the caret left")
                    break
                }
                let glyph = glyphBoxes(shown)[index]
                let expected = glyph.offset ?? shown.block.location
                generated += glyph.offset == nil ? 1 : 0
                try writingPress(editor, at: CGPoint(x: glyph.box.midX, y: glyph.box.midY))
                clicks += 1
                if editor.selectedRange() != NSRange(location: expected, length: 0) {
                    mismatches.append("\(needle) glyph \(index) source \(String(describing: glyph.offset)) " +
                        "box \(glyph.box): caret \(editor.selectedRange())")
                }
                #expect(role(model, text, start) == .source, "\(needle) did not open on a click")
                expectCaretInSource(editor, manager, model)
            }
        }
        print("WRITING clicks: \(clicks) glyph boxes, \(generated) generated, \(mismatches.count) mismatches")
        #expect(mismatches.isEmpty, "\(mismatches.prefix(12))")
        #expect(generated >= 1, "The heading number has no generated glyph box")
        expectPlainStorage(editor)
    }

    @Test func writingModeShiftSelectionsAcrossRenderedBlocksKeepThemRenderedAndHighlighted() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        // The highlight is checked in the key window's colour (step F).
        let restoreKey = giveKeyAppearance(app.window)
        defer { restoreKey() }
        let text = editor.string as NSString
        let pill = text.range(of: "#set par").location
        let heading = text.range(of: "= Numbered heading").location
        let short = text.range(of: "A short paragraph").location
        let long = text.range(of: "A paragraph with inline math").location
        let equation = text.range(of: "$ integral").location
        let rendered = [heading, short, long]

        // Shift-click: the anchor in the pill, which opens as source; the click
        // on "third" in the paragraph's last source line.
        editor.setSelectedRange(NSRange(location: pill + 3, length: 0))
        #expect(role(model, text, pill) == .source)
        writingScrollToTop(editor)
        for offset in rendered {
            #expect(role(model, text, offset).isRendered, "Block \(offset) is not rendered")
        }
        let target = text.range(of: "third source line").location + 2
        let paragraph = try #require(renderedBlock(manager, at: long))
        let clicked = try #require(glyphBoxes(paragraph).first { $0.offset == target })
        try writingPress(editor, at: CGPoint(x: clicked.box.midX, y: clicked.box.midY), modifiers: .shift)
        #expect(editor.selectedRange() == NSRange(location: pill + 3, length: target - pill - 3))
        for offset in rendered {
            #expect(role(model, text, offset).isRendered, "The shift-click opened block \(offset)")
        }

        // NSTextView gets no selection segments inside the rendered paragraph.
        var native = 0
        let blockRange = try #require(TextKit2Geometry.textRange(paragraph.block, in: manager))
        manager.enumerateTextSegments(in: blockRange, type: .selection, options: .rangeNotRequired) { _, _, _, _ in
            native += 1
            return true
        }
        #expect(native == 0, "NSTextView draws \(native) selection segments inside a rendered block")

        await app.layout()
        writingScrollToTop(editor)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-selection-shift-click.png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        for offset in [heading, short] {
            let block = try #require(renderedBlock(manager, at: offset))
            let frame = block.info.frame
            #expect(
                canvas.selected(in: frame) * 2 > canvas.count(in: frame),
                "Block \(offset) is selected but not highlighted: \(canvas.selected(in: frame)) of \(canvas.count(in: frame))",
            )
        }
        let shown = try #require(renderedBlock(manager, at: long))
        let selection = editor.selectedRange()
        let boxes = glyphBoxes(shown).filter { $0.offset != nil }
        let chosen = boxes.filter { NSLocationInRange($0.offset ?? -1, selection) }
        let others = boxes.filter { ($0.offset ?? 0) > target }
        let chosenTint = chosen.reduce(0) { $0 + canvas.selected(in: $1.box) }
        let chosenArea = chosen.reduce(0) { $0 + canvas.count(in: $1.box) }
        let otherTint = others.reduce(0) { $0 + canvas.selected(in: $1.box.insetBy(dx: 1, dy: 1)) }
        let otherArea = others.reduce(0) { $0 + canvas.count(in: $1.box.insetBy(dx: 1, dy: 1)) }
        print(
            "WRITING shift-click highlight: selected glyphs \(chosenTint) of \(chosenArea), others \(otherTint) of \(otherArea)",
        )
        #expect(chosen.count > 20 && others.count > 5)
        #expect(chosenTint * 10 > chosenArea * 3, "Selected glyphs are not highlighted")
        #expect(otherTint * 100 <= otherArea, "Unselected glyphs are highlighted")
        let formula = try #require(renderedBlock(manager, at: equation))
        #expect(canvas.selected(in: formula.info.frame) == 0, "The equation after the selection is highlighted")
        // NSTextView drew the collapsed lines' selection over the blank line
        // below the block before step E (spike).
        let blank = try #require(writingFragments(manager).first { $0.offset > NSMaxRange(shown.block) })
        #expect(blank.role == .source && blank.frame.height > 4)
        #expect(canvas.ink(in: blank.frame.insetBy(dx: 0, dy: 1)) == 0, "Selection drawn below the block")
        #expect(canvas.selected(in: blank.frame) == 0)

        // Shift-arrow from the same anchor down past the paragraph.
        editor.setSelectedRange(NSRange(location: pill + 3, length: 0))
        writingScrollToTop(editor)
        var steps = 0
        while NSMaxRange(editor.selectedRange()) <= NSMaxRange(shown.block) + 1, steps < 40 {
            editor.moveDownAndModifySelection(nil)
            steps += 1
        }
        let arrowed = editor.selectedRange()
        print("WRITING shift-down: \(steps) steps to \(arrowed)")
        #expect(arrowed.location == pill + 3)
        #expect(NSMaxRange(arrowed) > NSMaxRange(shown.block) + 1 && NSMaxRange(arrowed) <= equation + 34)
        for offset in rendered {
            #expect(role(model, text, offset).isRendered, "Block \(offset) is open after shift-down")
        }
        await app.layout()
        writingScrollToTop(editor)
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-selection-shift-down.png")
        let after = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        for offset in rendered {
            let frame = try #require(renderedBlock(manager, at: offset)).info.frame
            #expect(
                after.selected(in: frame) * 2 > after.count(in: frame),
                "Block \(offset) is not highlighted after shift-down: \(after.selected(in: frame)) of \(after.count(in: frame))",
            )
        }
        expectPlainStorage(editor)
    }

    @Test func writingModeDragsExtendThroughGlyphBoxesFromRenderedAndSourceBlocks() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = editor.string as NSString
        let pill = text.range(of: "#set par").location
        let short = text.range(of: "A short paragraph").location
        let long = text.range(of: "A paragraph with inline math").location
        let equation = text.range(of: "$ integral").location
        let plain = text.range(of: "Plain paragraph after the code").location
        let comment = text.range(of: "// A comment").location
        let start = text.range(of: "short paragraph").location + 1
        let second = text.range(of: "second source line").location + 3
        let formula = text.range(of: "x^2 dif").location
        // "after": a ligature's glyph has the source of its first character.
        let after = text.range(of: "after the code").location
        let raw = text.range(of: "return 1").location
        let rawActive = try #require(model.blocks.firstIndex { NSLocationInRange(raw, $0.range) })

        // (a) Prose's loop: a press on "short", drags over a collapsed line's
        // glyph, the equation and the raw source, released on the paragraph
        // after the code. Each step ends where the pointer is.
        park(editor)
        writingScrollToTop(editor)
        let points = try [
            glyphCentre(manager, block: short, offset: start),
            glyphCentre(manager, block: long, offset: second),
            glyphCentre(manager, block: equation, offset: formula),
            sourcePoint(manager, offset: raw),
            glyphCentre(manager, block: plain, offset: after),
        ]
        var steps: [NSRange] = []
        try writingPress(editor, at: points[0], through: Array(points.dropFirst())) { steps.append($0) }
        let expected = [start, second, formula, raw, after].map { NSRange(location: start, length: $0 - start) }
        #expect(steps == expected, "Drag steps \(steps), expected \(expected)")
        #expect(editor.selectedRange() == NSRange(location: start, length: after - start))
        for offset in [short, long, equation, plain] {
            #expect(role(model, text, offset).isRendered, "The drag opened block \(offset)")
        }
        #expect(model.activeBlock == rawActive)

        // Up onto a pill gives the pill's start; down onto one, its end.
        park(editor)
        writingScrollToTop(editor)
        let upFrom = try glyphCentre(manager, block: plain, offset: after)
        try writingPress(editor, at: upFrom, through: [fragmentCentre(manager, at: pill)])
        #expect(editor.selectedRange() == NSRange(location: pill, length: after - pill))
        park(editor)
        writingScrollToTop(editor)
        let downFrom = try glyphCentre(manager, block: long, offset: second)
        let commentEnd = try NSMaxRange(#require(model.blocks.first { $0.range.location == comment }).range)
        try writingPress(editor, at: downFrom, through: [fragmentCentre(manager, at: comment)])
        #expect(editor.selectedRange() == NSRange(location: second, length: commentEnd - second))

        // (b) AppKit's tracking from source: the selection navigation calls
        // its loop makes, from "Plain paragraph" (open) up into rendered blocks.
        let anchorOffset = plain + 6
        editor.setSelectedRange(NSRange(location: anchorOffset, length: 0))
        #expect(role(model, text, plain) == .source)
        writingScrollToTop(editor)
        let navigation = manager.textSelectionNavigation
        let origin = manager.documentRange.location
        let anchors = try navigation.textSelections(
            interactingAt: sourcePoint(manager, offset: anchorOffset),
            inContainerAt: origin,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: .infinite,
        )
        #expect(selectedRange(anchors, manager) == NSRange(location: anchorOffset, length: 0))
        var tracked: [NSRange] = []
        let path = try [
            sourcePoint(manager, offset: raw),
            glyphCentre(manager, block: equation, offset: formula),
            glyphCentre(manager, block: long, offset: second),
            fragmentCentre(manager, at: pill),
        ]
        for point in path {
            let selections = navigation.textSelections(
                interactingAt: point,
                inContainerAt: origin,
                anchors: anchors,
                modifiers: [.extend],
                selecting: true,
                bounds: .infinite,
            )
            tracked.append(selectedRange(selections, manager) ?? NSRange(location: NSNotFound, length: 0))
        }
        let ends = [raw, formula, second, pill]
        #expect(tracked == ends.map { NSRange(location: $0, length: anchorOffset - $0) }, "Tracked \(tracked)")
        // AppKit applies the last one, then the mouse-up updates once: a
        // selection made by the pointer opens no block.
        editor.selectingWithMouse = true
        editor.setSelectedRange(NSRange(location: second, length: anchorOffset - second))
        editor.selectingWithMouse = false
        editor.selectionChanged(byPointer: true)
        #expect(role(model, text, long).isRendered)
        expectPlainStorage(editor)
    }

    @Test func writingModeCopyCutAndDragWriteTheSourceOfTheSelection() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        // The highlight is checked in the key window's colour (step F).
        let restoreKey = giveKeyAppearance(app.window)
        defer { restoreKey() }
        let text = editor.string as NSString
        let general = NSPasteboard.general
        let restorePasteboard = savedPasteboard(general)
        defer { restorePasteboard() }

        editor.selectAll(nil)
        #expect(editor.selectedRange() == NSRange(location: 0, length: text.length))
        await app.layout()
        writingScrollToTop(editor)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-selection-all.png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        let paragraph = try #require(renderedBlock(manager, at: text.range(of: "A paragraph with inline").location))
        #expect(canvas.selected(in: paragraph.info.frame) * 2 > canvas.count(in: paragraph.info.frame))
        editor.copy(nil)
        #expect(general.string(forType: .string) == editor.string)
        #expect(general.types?.contains { [.rtf, .tiff, .png, .pdf].contains($0) } == false)

        // A range inside a rendered block, selected by a drag so that it
        // stays rendered.
        park(editor)
        writingScrollToTop(editor)
        let from = text.range(of: "inline math").location
        let to = text.range(of: "wraps it").location
        let long = paragraph.block.location
        try writingPress(
            editor,
            at: glyphCentre(manager, block: long, offset: from),
            through: [glyphCentre(manager, block: long, offset: to)],
        )
        let range = NSRange(location: from, length: to - from)
        let copied = text.substring(with: range)
        #expect(editor.selectedRange() == range)
        #expect(role(model, text, long).isRendered)
        editor.copy(nil)
        #expect(general.string(forType: .string) == copied)
        // Dragging the selection writes it with the same call and types.
        let drag = NSPasteboard(name: NSPasteboard.Name("Prose.writing.drag." + UUID().uuidString))
        defer { drag.releaseGlobally() }
        drag.clearContents()
        #expect(editor.writablePasteboardTypes == [NSPasteboard.PasteboardType("NSStringPboardType")])
        #expect(editor.writeSelection(to: drag, types: editor.writablePasteboardTypes))
        #expect(drag.string(forType: .string) == copied)

        let source = editor.string
        editor.cut(nil)
        #expect(general.string(forType: .string) == copied)
        #expect(editor.string == (source as NSString).replacingCharacters(in: range, with: ""))
        editor.undoManager?.undo()
        #expect(editor.string == source)
        expectPlainStorage(editor)
    }

    @Test func writingModeDoubleClickSelectsTheWordAndTripleClickTheBlock() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = editor.string as NSString
        let long = text.range(of: "A paragraph with inline math").location
        let word = text.range(of: "continues")

        // One press after another at the same point: the first opens the
        // block, the second and third map through the glyph the first hit.
        let point = try glyphCentre(manager, block: long, offset: word.location + 3)
        let block = try #require(renderedBlock(manager, at: long)).block
        let origin = editor.textContainerOrigin
        let inWindow = editor.convert(CGPoint(x: point.x + origin.x, y: point.y + origin.y), to: nil)
        try writingPress(editor, at: point)
        #expect(editor.selectedRange() == NSRange(location: word.location + 3, length: 0))
        #expect(role(model, text, long) == .source)
        // The pointer stays where it was in the window while the opened block
        // keeps the caret's line still.
        let again = try editor.containerPoint(of: #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1,
        )))
        try writingPress(editor, at: again, clicks: 2)
        #expect(editor.selectedRange() == word)
        try writingPress(editor, at: again, clicks: 3)
        #expect(editor.selectedRange() == block)
        #expect(role(model, text, long) == .source)

        // A double-click straight on a rendered block keeps it rendered.
        park(editor)
        editor.lastWritingClick = nil
        writingScrollToTop(editor)
        let short = text.range(of: "A short paragraph").location
        let shortWord = text.range(of: "short paragraph")
        try writingPress(editor, at: glyphCentre(manager, block: short, offset: shortWord.location + 2), clicks: 2)
        #expect(editor.selectedRange() == NSRange(location: shortWord.location, length: 5))
        #expect(role(model, text, short).isRendered)
        expectPlainStorage(editor)
    }
}

// MARK: - Helpers

/// Just inside the left edge of the source character at `offset`.
@MainActor
private func sourcePoint(_ manager: NSTextLayoutManager, offset: Int) throws -> CGPoint {
    let rect = try #require(TextKit2Geometry.segments(
        NSRange(location: offset, length: 1),
        type: .standard,
        in: manager,
    )
    .first)
    return CGPoint(x: rect.minX + 1, y: rect.midY)
}

@MainActor
private func fragmentCentre(_ manager: NSTextLayoutManager, at offset: Int) throws -> CGPoint {
    let frame = try #require(writingFragments(manager).first { $0.offset == offset }).frame
    return CGPoint(x: min(frame.midX, 40), y: frame.midY)
}

@MainActor
private func selectedRange(_ selections: [NSTextSelection], _ manager: NSTextLayoutManager) -> NSRange? {
    guard let range = selections.first?.textRanges.first else {
        return nil
    }
    let start = TextKit2Geometry.offset(of: range.location, in: manager)
    return NSRange(location: start, length: TextKit2Geometry.offset(of: range.endLocation, in: manager) - start)
}

/// Saves a pasteboard's items and returns a closure that puts them back.
@MainActor
private func savedPasteboard(_ board: NSPasteboard) -> () -> Void {
    let items = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    return {
        board.clearContents()
        let restored = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            board.writeObjects(restored)
        }
    }
}
