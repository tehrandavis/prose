import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 3 step F: keyboard navigation and undo in Writing mode, acceptance
/// tests 6 to 8 of the Phase 3 note, and the selection colour in a window
/// that is not key, on the real window, editor and engine. Keys go through
/// `doCommand(by:)` and the responder methods, as NSTextView's key bindings
/// send them; no test posts events (Phase 3 spike).
extension WritingFlowTests {
    // MARK: - Keys with an empty selection

    @Test func writingModeKeysWithACaretLandWhereTheyLandInCodeMode() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let text = editor.string as NSString
        // The pill, the numbered heading, the paragraphs (one with inline math
        // over three source lines), the display equation, the raw block, the
        // comment pill and the first fillers.
        let end = text.range(of: "Filler paragraph 3,").location
        writingScrollToTop(editor)
        let code = keyboardDestinations(editor, through: end)
        let codeRuns = keyboardRuns(editor)
        park(editor)
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        var hidden: [String] = []
        var entered = 0
        let writing = keyboardDestinations(editor, through: end, before: { start, command in
            // Where Code mode goes is drawn rendered or as a pill until the move.
            if let expected = code[command]?[start], expected.length == 0,
               role(model, text, expected.location) != .source
            {
                entered += 1
            }
        }, after: { start, command, selection in
            if let problem = caretProblem(editor, manager, model, selection) {
                hidden.append("\(NSStringFromSelector(command)) from \(start): \(problem)")
            }
        })
        let writingRuns = keyboardRuns(editor) { name, selection in
            if let problem = caretProblem(editor, manager, model, selection) {
                hidden.append("\(name): \(problem)")
            }
        }
        var differences: [String] = []
        for (command, destinations) in code {
            for (start, expected) in destinations where writing[command]?[start] != expected {
                differences.append(
                    "\(NSStringFromSelector(command)) from \(start): code \(expected), " +
                        "writing \(String(describing: writing[command]?[start]))",
                )
            }
        }
        for (name, steps) in codeRuns where writingRuns[name] != steps {
            differences.append("\(name): code \(steps), writing \(String(describing: writingRuns[name]))")
        }
        let moves = code.values.reduce(0) { $0 + $1.count } + codeRuns.values.reduce(0) { $0 + $1.count }
        print("WRITING keys: \(moves) moves, \(entered) into blocks drawn rendered or as pills, " +
            "\(differences.count) differ from Code mode, \(hidden.count) carets not shown")
        #expect(entered > 200, "Too few moves entered a rendered block or a pill: \(entered)")
        #expect(differences.isEmpty, "\(differences.prefix(12))")
        #expect(hidden.isEmpty, "\(hidden.prefix(12))")
        expectPlainStorage(editor)
    }

    // MARK: - Keys extending a selection the pointer made

    @Test func writingModeShiftKeysExtendAPointerSelectionThroughDrawnLines() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let text = editor.string as NSString
        let heading = text.range(of: "= Numbered heading").location
        let short = text.range(of: "A short paragraph").location
        let long = text.range(of: "A paragraph with inline math").location
        let equation = text.range(of: "$ integral").location
        let rendered = [heading, short, long, equation]
        let active = model.activeBlock
        func expectRendered(_ step: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
            for offset in rendered {
                #expect(
                    role(model, text, offset).isRendered,
                    "\(step) opened block \(offset)",
                    sourceLocation: sourceLocation,
                )
            }
            #expect(model.activeBlock == active, "\(step) changed the active block", sourceLocation: sourceLocation)
        }

        // A drag from "short" into the first drawn line of the paragraph.
        let start = text.range(of: "short paragraph").location + 1
        let inline = text.range(of: "inline math").location + 2
        try writingPress(
            editor,
            at: glyphCentre(manager, block: short, offset: start),
            through: [glyphCentre(manager, block: long, offset: inline)],
        )
        #expect(editor.selectedRange() == NSRange(location: start, length: inline - start))
        expectRendered("The drag")
        let paragraph = try #require(renderedBlock(manager, at: long))
        // Three source lines, set by Typst in two drawn lines at this width.
        let lines = drawnLines(paragraph)
        #expect(lines.count >= 2, "The paragraph has \(lines.count) drawn lines")
        let goal = try #require(lines.first?.first { $0.offset == inline }).box.minX

        // Down through every drawn line at the nearest x, not through the
        // three source lines; the selection stays a source range from `start`.
        for (index, line) in lines.enumerated().dropFirst() {
            editor.moveDownAndModifySelection(nil)
            let moving = nearest(line, x: goal, text)
            #expect(
                editor.selectedRange() == NSRange(location: start, length: moving - start),
                "Shift-down to drawn line \(index)",
            )
            expectRendered("Shift-down \(index)")
        }
        // Out of the block: the blank line, then the equation's drawn line.
        editor.moveDownAndModifySelection(nil)
        let blank = NSMaxRange(text.paragraphRange(for: paragraph.block))
        #expect(editor.selectedRange() == NSRange(location: start, length: blank - start))
        editor.moveDownAndModifySelection(nil)
        let formula = try #require(renderedBlock(manager, at: equation))
        let formulaLine = try #require(drawnLines(formula).first)
        let inFormula = nearest(formulaLine, x: goal, text)
        #expect(editor.selectedRange() == NSRange(location: start, length: inFormula - start))
        expectRendered("Shift-down into the equation")
        // And back up to the paragraph's last drawn line.
        editor.moveUpAndModifySelection(nil)
        #expect(editor.selectedRange() == NSRange(location: start, length: blank - start))
        editor.moveUpAndModifySelection(nil)
        let lastLine = try #require(lines.last)
        let last = nearest(lastLine, x: goal, text)
        #expect(editor.selectedRange() == NSRange(location: start, length: last - start))

        // Line ends are the drawn line's; paragraph ends are the block's.
        editor.moveToBeginningOfLineAndModifySelection(nil)
        let lineStart = lastLine.compactMap(\.offset).min() ?? -1
        #expect(editor.selectedRange() == NSRange(location: start, length: lineStart - start))
        editor.moveToEndOfLineAndModifySelection(nil)
        let lineEnd = (lastLine.compactMap(\.offset).max() ?? -2) + 1
        #expect(editor.selectedRange() == NSRange(location: start, length: lineEnd - start))
        editor.moveToBeginningOfParagraphAndModifySelection(nil)
        #expect(editor.selectedRange() == NSRange(location: start, length: long - start))
        editor.moveToEndOfParagraphAndModifySelection(nil)
        #expect(editor.selectedRange() == NSRange(location: start, length: NSMaxRange(paragraph.block) - start))
        // Other keys are TextKit's, from the moving end.
        editor.moveLeftAndModifySelection(nil)
        #expect(editor.selectedRange() == NSRange(location: start, length: NSMaxRange(paragraph.block) - 1 - start))
        expectRendered("The line and paragraph keys")

        // The highlight follows the selection inside the rendered paragraph.
        let restoreKey = giveKeyAppearance(app.window)
        await app.layout()
        writingScrollToTop(editor)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        restoreKey()
        try writingSave(bitmap, "writing-keyboard-pointer-extension.png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        let boxes = glyphBoxes(paragraph).filter { $0.offset != nil }
        let chosen = boxes.filter { NSLocationInRange($0.offset ?? -1, editor.selectedRange()) }
        let tint = chosen.reduce(0) { $0 + canvas.selected(in: $1.box) }
        let area = chosen.reduce(0) { $0 + canvas.count(in: $1.box) }
        #expect(chosen.count > 40 && tint * 10 > area * 3, "Selected glyphs: \(tint) of \(area) tinted")

        // A drag upward: the keyboard moves its moving end, not its fixed end.
        park(editor)
        writingScrollToTop(editor)
        let second = text.range(of: "second source line").location + 3
        let first = text.range(of: "first source line").location + 2
        try writingPress(
            editor,
            at: glyphCentre(manager, block: long, offset: second),
            through: [glyphCentre(manager, block: long, offset: first)],
        )
        #expect(editor.selectedRange() == NSRange(location: first, length: second - first))
        let firstBox = try #require(glyphBoxes(paragraph).first { $0.offset == first })
        let below = try #require(lines.firstIndex { line in line.contains { $0.offset == first } }) + 1
        editor.moveDownAndModifySelection(nil)
        let target = nearest(lines[below], x: firstBox.box.minX, text)
        #expect(editor.selectedRange() == NSRange(location: min(target, second), length: abs(second - target)))
        expectRendered("Shift-down after an upward drag")
        // A plain arrow collapses the selection and opens the caret's block.
        editor.moveDown(nil)
        #expect(editor.selectedRange().length == 0)
        expectCaretInSource(editor, manager, model)
        expectPlainStorage(editor)
    }

    // MARK: - Page up and down

    @Test func writingModePageKeysMoveTheCaretAboutOneViewportAndScrollWithIt() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let length = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        writingScrollToTop(editor)
        let page = editor.containerVisibleRect().height - (editor.enclosingScrollView?.verticalPageScroll ?? 0)
        func caretY() throws -> CGFloat {
            try #require(TextKit2Geometry.caretRect(at: editor.selectedRange().location, in: manager)).midY
        }
        // The bottom of the view, in container coordinates.
        func bottom() -> CGFloat {
            editor.frame.height - editor.textContainerOrigin.y
        }
        var downs = 0
        while editor.selectedRange().location < length, downs < 20 {
            let top = editor.containerVisibleRect().minY
            let before = try caretY() - top
            let offset = editor.selectedRange().location
            editor.pageDown(nil)
            downs += 1
            let visible = editor.containerVisibleRect()
            #expect(editor.selectedRange().length == 0 && editor.selectedRange().location > offset)
            guard editor.selectedRange().location < length else {
                // The text's end: the last page is in view.
                #expect(abs(visible.maxY - bottom()) < 2, "Page down \(downs) ended at \(visible.maxY) of \(bottom())")
                break
            }
            let after = try caretY()
            expectCaretInSource(editor, manager, model)
            #expect(
                after >= visible.minY && after <= visible.maxY,
                "Page down \(downs): caret \(after) out of \(visible)",
            )
            if visible.maxY < bottom() - 1 {
                // Swaps above the caret move the text by a line or so; the
                // caret keeps its place in the view.
                #expect(abs(visible.minY - top - page) < 40, "Page down \(downs) scrolled \(visible.minY - top)")
                #expect(
                    abs(after - visible.minY - before) < 40,
                    "Page down \(downs): caret \(before) -> \(after - visible.minY) from the top",
                )
            } else {
                // The view stops at the text's end; the caret moves on down it.
                #expect(after - visible.minY > before, "Page down \(downs) did not move the caret down the view")
            }
        }
        print("WRITING page down: \(downs) pages of \(page) pt to the end")
        #expect(downs >= 2 && editor.selectedRange() == NSRange(location: length, length: 0))
        var ups = 0
        while editor.selectedRange().location > 0, ups < 20 {
            editor.pageUp(nil)
            ups += 1
            let caret = try caretY()
            let visible = editor.containerVisibleRect()
            expectCaretInSource(editor, manager, model)
            #expect(caret >= visible.minY && caret <= visible.maxY, "Page up \(ups): caret out of view")
        }
        #expect(ups >= 2 && editor.selectedRange() == NSRange(location: 0, length: 0))

        // With shift the selection grows and shrinks from its fixed end.
        let anchor = (editor.string as NSString).range(of: "Filler paragraph 2,").location
        editor.setSelectedRange(NSRange(location: anchor, length: 0))
        editor.pageDownAndModifySelection(nil)
        let grown = editor.selectedRange()
        #expect(grown.location == anchor && grown.length > 200, "Shift-page down: \(grown)")
        editor.pageUpAndModifySelection(nil)
        let shrunk = editor.selectedRange()
        #expect(shrunk.location <= anchor && NSMaxRange(shrunk) <= anchor + 2, "Shift-page up: \(shrunk)")
        expectPlainStorage(editor)
    }

    // MARK: - Undo across swaps

    @Test func writingModeAcceptance6UndoAfterTheEditedBlockRenderedRestoresItsText() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let undo = try #require(editor.undoManager)
        let source = editor.string
        let text = source as NSString
        let blockA = text.range(of: "A short paragraph").location
        let blockB = text.range(of: "A paragraph with inline math").location
        let typed = blockA + 8
        let edited = text.replacingCharacters(in: NSRange(location: typed, length: 0), with: "quite ")
        // Types in block A, then moves the caret into block B.
        func typeInAThenMoveToB() {
            editor.setSelectedRange(NSRange(location: typed, length: 0))
            for character in "quite " {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
            }
            editor.setSelectedRange(NSRange(location: blockB + 6 + 4, length: 0))
        }

        // Code mode first: NSTextView keeps the caret where it is across an
        // undo or a redo, moved by the change.
        typeInAThenMoveToB()
        await app.layout()
        undo.undo()
        let codeUndo = editor.selectedRange()
        editor.setSelectedRange(NSRange(location: blockB + 3, length: 0))
        undo.redo()
        let codeRedo = editor.selectedRange()
        undo.undo()
        #expect(editor.string == source)
        print("WRITING Code mode selection after undo \(codeUndo), after redo \(codeRedo)")

        // Writing mode: block A renders the edited text once the caret leaves.
        park(editor)
        let model = try await enterWritingMode(app)
        typeInAThenMoveToB()
        #expect(editor.string == edited)
        await model.idle()
        await app.layout()
        guard case let .rendered(renderedEdit, _) = role(model, edited as NSString, blockA) else {
            Issue.record("Block A did not render after the caret left it")
            return
        }
        #expect(renderedEdit.glyphs.count > 30)

        // Undo: the text comes back, the selection is where Code mode puts it,
        // and A draws source at once, never the render of the edited text.
        undo.undo()
        #expect(editor.string == source && app.workspace.text == source)
        #expect(editor.selectedRange() == codeUndo)
        #expect(role(model, text, blockA) == .source, "Block A kept the edited text's render")
        expectCaretInSource(editor, manager, model)
        // Its render for the restored text follows; every fragment draws what
        // a new engine renders for that text.
        await model.idle()
        await app.layout()
        #expect(role(model, text, blockA).isRendered)
        try await expectFreshRenders(app, editor, manager, model)

        // Redo returns the edit, the same way.
        editor.setSelectedRange(NSRange(location: blockB + 3, length: 0))
        undo.redo()
        #expect(editor.string == edited && app.workspace.text == edited)
        #expect(editor.selectedRange() == codeRedo)
        #expect(role(model, edited as NSString, blockA) == .source)
        await model.idle()
        await app.layout()
        #expect(role(model, edited as NSString, blockA).isRendered)
        try await expectFreshRenders(app, editor, manager, model)

        // Undo with the caret still in A: A stays open as the active block.
        undo.undo()
        editor.setSelectedRange(NSRange(location: typed, length: 0))
        for character in "very " {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        undo.undo()
        #expect(editor.string == source)
        #expect(editor.selectedRange() == NSRange(location: typed, length: 0))
        #expect(role(model, text, blockA) == .source)
        let active = try #require(model.activeBlock)
        #expect(model.state(ofBlockAt: active) == .source(.active))
        #expect(model.blocks[active].range.location == blockA)
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance7SwapsModeSwitchesAndRendersAddNoUndoRecords() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openSelectionDocument(app)
        let undo = try #require(editor.undoManager)
        for (index, word) in ["One. ", "Two. ", "Three. "].enumerated() {
            let end = (editor.string as NSString).range(of: "The last paragraph.").location
            editor.insertSnippet(Snippet(text: word), replacing: NSRange(location: end, length: 0), focus: false)
            await app.layout()
            #expect(undoDepth(undo) == index + 1)
        }
        park(editor)
        await model.idle()
        let depth = undoDepth(undo)
        await model.idle()
        let before = (undo.canUndo, undo.canRedo, undo.undoActionName, undo.redoActionName, editor.string)
        let swaps = editor.writing.swapCount
        let renders = model.renderReplies

        // Ten swaps, two mode round trips and the renders they cause, with
        // every undo group the undo manager opens or closes counted.
        var groups = 0
        let center = NotificationCenter.default
        let observers = [Notification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup].map {
            center.addObserver(forName: $0, object: undo, queue: nil) { _ in
                MainActor.assumeIsolated { groups += 1 }
            }
        }
        defer { observers.forEach(center.removeObserver) }
        let text = editor.string as NSString
        let heading = text.range(of: "= Numbered heading").location
        let long = text.range(of: "A paragraph with inline math").location
        for step in 0 ..< 10 {
            editor.setSelectedRange(NSRange(location: (step.isMultiple(of: 2) ? heading : long) + 3, length: 0))
            await app.layout()
        }
        await model.idle()
        for _ in 0 ..< 2 {
            app.workspace.setMode(.code)
            await app.layout()
            _ = try await enterWritingMode(app)
        }
        await model.idle()
        print("WRITING undo records: \(editor.writing.swapCount - swaps) swaps, " +
            "\(model.renderReplies - renders) renders, \(groups) undo groups")
        #expect(editor.writing.model === model)
        #expect(editor.writing.swapCount - swaps >= 10)
        #expect(model.renderReplies > renders)
        #expect(groups == 0, "Swaps opened or closed \(groups) undo groups")
        #expect(undo.canUndo == before.0 && undo.canRedo == before.1)
        #expect(undo.undoActionName == before.2 && undo.redoActionName == before.3)
        #expect(editor.string == before.4)
        #expect(undoDepth(undo) == depth, "The undo stack grew from \(depth)")
        undo.undo()
        #expect(!editor.string.contains("Three. ") && editor.string.contains("Two. "))
        #expect(app.workspace.text == editor.string)
        expectCaretInSource(editor, manager, model)
        expectPlainStorage(editor)
    }

    @Test func writingModeAcceptance8UndoThatMergesTwoBlocksMatchesTheEnginesList() async throws {
        let source = """
        = Merging

        Alpha line one, the first source line of a paragraph,
        alpha line two, the second source line of the same paragraph.

        Omega paragraph after it.

        \(selectionFiller)
        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let undo = try #require(editor.undoManager)
        let text = source as NSString
        let alpha = text.range(of: "Alpha line one").location
        let omega = text.range(of: "Omega paragraph").location
        let split = NSMaxRange(text.range(of: "first source line of a paragraph,"))
        editor.setSelectedRange(NSRange(location: omega + 2, length: 0))
        let model = try await enterWritingMode(app)
        let merged = try #require(model.blocks.first { $0.range.location == alpha })
        #expect(NSLocationInRange(split + 2, merged.range))

        // A blank line splits the paragraph into two blocks; both render.
        editor.setSelectedRange(NSRange(location: split, length: 0))
        editor.insertNewline(nil)
        await model.idle()
        let two = try await engineBlocks(app, editor.string)
        #expect(model.blocks == two)
        #expect(two.count == model.blocks.count && two.contains { $0.range.location == split + 2 })
        editor.setSelectedRange(NSRange(location: omega + 4, length: 0))
        await model.idle()
        await app.layout()
        #expect(role(model, editor.string as NSString, alpha).isRendered)
        #expect(role(model, editor.string as NSString, split + 2).isRendered)

        // Undo removes the blank line: one block again, as the engine lists it.
        undo.undo()
        #expect(editor.string == source)
        await model.idle()
        let one = try await engineBlocks(app, editor.string)
        #expect(model.blocks == one, "Model \(model.blocks.map(\.range)), engine \(one.map(\.range))")
        #expect(one.contains { $0.range == merged.range })
        #expect(model.blocks.count == two.count - 1)
        // The merged block renders as one fragment over both source lines.
        await app.layout()
        #expect(role(model, text, alpha).isRendered)
        #expect(role(model, text, split + 1) == .collapsed)
        try await expectFreshRenders(app, editor, manager, model)
        expectPlainStorage(editor)
    }

    // MARK: - Selection colour

    @Test func writingModeSelectionHighlightUsesTheNativeColourInEachKeyState() async throws {
        let app = try WritingFixture(text: selectionSource, startService: false)
        defer { app.close() }
        let (editor, manager, _) = try await openSelectionDocument(app)
        let text = editor.string as NSString
        let long = text.range(of: "A paragraph with inline math").location
        let raw = text.range(of: "def raw(): return 1")
        // From the rendered paragraph into the raw block, which is source.
        let from = text.range(of: "continues").location
        editor.setSelectedRange(NSRange(location: from, length: NSMaxRange(raw) - from))
        writingScrollToTop(editor)
        let paragraph = try #require(renderedBlock(manager, at: long))
        let chosen = glyphBoxes(paragraph).filter { NSLocationInRange($0.offset ?? -1, editor.selectedRange()) }
        let native = try #require(TextKit2Geometry.segments(raw, type: .selection, in: manager).first)

        func colours(_ name: String) async throws -> (native: [Int], rendered: [Int]) {
            // NSTextView rebuilds its selection views in `layout`
            // (`_updateTextLayoutManagerSelectionLayers`).
            editor.needsLayout = true
            await app.layout()
            writingScrollToTop(editor)
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            try writingSave(bitmap, name)
            let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
            let rendered = chosen.compactMap { canvas.commonColor(in: $0.box) }
            return try (#require(canvas.commonColor(in: native)), #require(mostCommon(rendered)))
        }
        func expected(_ color: NSColor) -> [Int] {
            var components: [Int] = []
            editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let sRGB = color.usingColorSpace(.sRGB) {
                    components = [sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent].map { Int($0 * 255) }
                }
            }
            return components
        }
        func near(_ left: [Int], _ right: [Int], within tolerance: Int = 3) -> Bool {
            left.count == 3 && right.count == 3 && zip(left, right).allSatisfy { abs($0 - $1) <= tolerance }
        }
        // The bitmap holds display colours: allow for the profile's shift.
        let grey = expected(.unemphasizedSelectedTextBackgroundColor)
        let violet = expected(Theme.selection)
        var redraws = editor.writing.highlightRedraws
        func redrew(sourceLocation: Testing.SourceLocation = #_sourceLocation) -> Bool {
            defer { redraws = editor.writing.highlightRedraws }
            return editor.writing.highlightRedraws > redraws
        }

        // Not key (the test process cannot become active): NSTextView's grey.
        #expect(!app.window.isKeyWindow && app.window.firstResponder === editor)
        let inactive = try await colours("writing-selection-inactive.png")
        print("WRITING inactive selection: native \(inactive.native), rendered \(inactive.rendered), grey \(grey)")
        #expect(near(inactive.native, grey, within: 8), "NSTextView draws \(inactive.native), not \(grey)")
        #expect(near(inactive.rendered, inactive.native), "Rendered \(inactive.rendered), native \(inactive.native)")

        // Key: the background of `selectedTextAttributes`; the change redraws.
        let restoreKey = giveKeyAppearance(app.window)
        #expect(redrew(), "Becoming key did not redraw the highlight")
        let active = try await colours("writing-selection-active.png")
        print("WRITING active selection: native \(active.native), rendered \(active.rendered), violet \(violet)")
        #expect(near(active.native, violet, within: 8), "NSTextView draws \(active.native), not \(violet)")
        #expect(near(active.rendered, active.native), "Rendered \(active.rendered), native \(active.native)")

        // Key, but the editor is not the first responder: grey again.
        app.window.makeFirstResponder(nil)
        #expect(redrew(), "Resigning first responder did not redraw the highlight")
        let elsewhere = try await colours("writing-selection-not-first-responder.png")
        #expect(
            near(elsewhere.native, inactive.native) && near(elsewhere.rendered, elsewhere.native),
            "Not first responder: \(elsewhere)",
        )
        app.window.makeFirstResponder(editor)
        #expect(redrew(), "Becoming first responder did not redraw the highlight")
        let back = try await colours("writing-selection-active-again.png")
        #expect(near(back.native, active.native) && near(back.rendered, back.native), "Again: \(back)")

        // Resigning key goes back to grey.
        restoreKey()
        #expect(redrew(), "Resigning key did not redraw the highlight")
        let again = try await colours("writing-selection-inactive-again.png")
        #expect(near(again.native, inactive.native) && near(again.rendered, again.native))
        expectPlainStorage(editor)
    }
}

// MARK: - Helpers

/// Movement commands as NSTextView's key bindings send them, without and with
/// shift.
private let keyboardCommands: [Selector] = [
    #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
    #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
    #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)),
    #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
    #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
    #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
    #selector(NSResponder.moveBackward(_:)), #selector(NSResponder.moveForward(_:)),
    #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
]

private let shiftedKeyboardCommands: [Selector] = [
    #selector(NSResponder.moveLeftAndModifySelection(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)),
    #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)),
    #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
    #selector(NSResponder.moveWordRightAndModifySelection(_:)),
    #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
    #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
    #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)),
    #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:)),
    #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)),
    #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)),
    #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)),
    #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)),
]

/// For every command, the selection it makes from a caret at each offset up
/// to `end`: every offset without shift, every third with it. `before` sees
/// each start and command once the caret is there, `after` the selection the
/// command made.
@MainActor
private func keyboardDestinations(
    _ editor: ManuscriptTextView,
    through end: Int,
    before: ((Int, Selector) -> Void)? = nil,
    after: ((Int, Selector, NSRange) -> Void)? = nil,
) -> [Selector: [Int: NSRange]] {
    var result: [Selector: [Int: NSRange]] = [:]
    for (commands, step) in [(keyboardCommands, 1), (shiftedKeyboardCommands, 3)] {
        for command in commands {
            var row: [Int: NSRange] = [:]
            for start in stride(from: 0, through: end, by: step) {
                editor.setSelectedRange(NSRange(location: start, length: 0))
                before?(start, command)
                editor.doCommand(by: command)
                row[start] = editor.selectedRange()
                after?(start, command, editor.selectedRange())
            }
            result[command] = row
        }
    }
    return result
}

/// Runs of up and down keys, with and without shift, through the whole text:
/// down from the start and up from the end. `after` sees each step.
@MainActor
private func keyboardRuns(
    _ editor: ManuscriptTextView,
    after: ((String, NSRange) -> Void)? = nil,
) -> [String: [NSRange]] {
    let length = (editor.string as NSString).length
    let runs: [(String, Int, Selector)] = [
        ("down", 0, #selector(NSResponder.moveDown(_:))),
        ("up", length, #selector(NSResponder.moveUp(_:))),
        ("down from the middle of a line", 21, #selector(NSResponder.moveDown(_:))),
        ("shift-down", 0, #selector(NSResponder.moveDownAndModifySelection(_:))),
        ("shift-up", length, #selector(NSResponder.moveUpAndModifySelection(_:))),
    ]
    var result: [String: [NSRange]] = [:]
    for (name, start, command) in runs {
        editor.setSelectedRange(NSRange(location: start, length: 0))
        var steps: [NSRange] = []
        for step in 0 ..< 200 {
            editor.doCommand(by: command)
            let selection = editor.selectedRange()
            if steps.last == selection {
                break
            }
            steps.append(selection)
            after?("\(name) step \(step)", selection)
        }
        result[name] = steps
    }
    return result
}

/// Why an empty selection is not drawn where the reader can see it: its
/// paragraph draws rendered or as a pill, or its caret lies out of view.
@MainActor
private func caretProblem(
    _ editor: ManuscriptTextView,
    _ manager: NSTextLayoutManager,
    _ model: WritingLayout,
    _ selection: NSRange,
) -> String? {
    guard selection.length == 0 else {
        return nil
    }
    let text = editor.string as NSString
    let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
    let drawn = model.role(forParagraph: paragraph)
    if drawn != .source {
        return "caret \(selection.location) in a paragraph drawn \(drawn)"
    }
    guard let rect = TextKit2Geometry.caretRect(at: selection.location, in: manager) else {
        return "no caret rectangle at \(selection.location)"
    }
    let visible = editor.containerVisibleRect()
    if rect.midY < visible.minY || rect.midY > visible.maxY {
        return "caret \(selection.location) at \(rect.midY), view \(visible.minY) to \(visible.maxY)"
    }
    return nil
}

/// A rendered block's glyph boxes with sources, grouped into drawn lines
/// (boxes whose vertical extents overlap), each from left to right.
private func drawnLines(_ shown: RenderedBlockInfo) -> [[GlyphBox]] {
    var lines: [[GlyphBox]] = []
    var bottom = -CGFloat.infinity
    for box in glyphBoxes(shown).sorted(by: { $0.box.minY < $1.box.minY }) {
        if box.box.minY < bottom - 0.5, !lines.isEmpty {
            lines[lines.count - 1].append(box)
            bottom = max(bottom, box.box.maxY)
        } else {
            lines.append([box])
            bottom = box.box.maxY
        }
    }
    return lines.map { $0.filter { $0.offset != nil }.sorted { $0.box.minX < $1.box.minX } }.filter { !$0.isEmpty }
}

/// The insertion offset nearest `x` on a drawn line: before the nearest
/// glyph's character, or after it when `x` lies right of its middle.
private func nearest(_ line: [GlyphBox], x: CGFloat, _ text: NSString) -> Int {
    func score(_ box: CGRect) -> (CGFloat, CGFloat) {
        (max(box.minX - x, 0, x - box.maxX), abs(box.midX - x))
    }
    guard let best = line.min(by: { score($0.box) < score($1.box) }), let offset = best.offset else {
        return -1
    }
    return x > best.box.midX + 0.5 ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset
}

/// How many undo groups the undo manager holds: undoes them all, counting,
/// and redoes them all again.
@MainActor
private func undoDepth(_ undo: UndoManager) -> Int {
    var depth = 0
    while undo.canUndo, depth < 100 {
        undo.undo()
        depth += 1
    }
    for _ in 0 ..< depth {
        undo.redo()
    }
    return depth
}

/// A new engine for the fixture's project, holding `text`, refreshed.
@MainActor
private func freshEngine(_ app: WritingFixture, _ text: String) async throws -> BlockRenderer {
    let engine = try await BlockRenderer(
        root: app.document.deletingLastPathComponent(),
        main: app.document,
        packageDirectories: BlockRenderer.defaultPackageDirectories(),
    )
    try await engine.setText(text, of: app.document)
    _ = await engine.refresh()
    return engine
}

/// The block list a new engine gives for `text`.
@MainActor
private func engineBlocks(_ app: WritingFixture, _ text: String) async throws -> [RenderBlock] {
    try await freshEngine(app, text).blocks(in: app.document)
}

/// Every rendered fragment draws what a new engine renders for the editor's
/// text at the same width and colour: the same drawn area, glyph boxes and
/// pixels.
@MainActor
private func expectFreshRenders(
    _ app: WritingFixture,
    _ editor: ManuscriptTextView,
    _ manager: NSTextLayoutManager,
    _ model: WritingLayout,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) async throws {
    let engine = try await freshEngine(app, editor.string)
    let blocks = try await engine.blocks(in: app.document)
    #expect(blocks == model.blocks, sourceLocation: sourceLocation)
    var compared = 0
    for fragment in writingFragments(manager) {
        guard case let .rendered(rendering, block) = fragment.role else {
            continue
        }
        let appearance = rendering.appearance
        let options = RenderOptions(textColor: appearance.textColor, bitmapScale: appearance.bitmapScale)
        let fresh = try await engine.render(block, in: app.document, width: appearance.renderWidth, options: options)
            .get()
        #expect(fresh.drawnRect == rendering.drawnRect, "Block \(block) drawn area", sourceLocation: sourceLocation)
        // A render kept across edits holds the sources of its own text.
        let sources = rendering.glyphs.map { rendering.offset(of: $0, blockAt: block.location) }
        #expect(
            fresh.glyphs.map(\.rect) == rendering.glyphs.map(\.rect),
            "Block \(block) glyph boxes",
            sourceLocation: sourceLocation,
        )
        #expect(fresh.glyphs.map(\.source) == sources, "Block \(block) glyph sources", sourceLocation: sourceLocation)
        if let image = rendering.image, let freshImage = fresh.bitmap {
            #expect(pixels(image) == pixels(freshImage), "Block \(block) pixels", sourceLocation: sourceLocation)
        }
        compared += 1
    }
    #expect(compared >= 4, "Only \(compared) rendered fragments", sourceLocation: sourceLocation)
}

private func pixels(_ image: CGImage) -> Data? {
    image.dataProvider?.data.map { $0 as Data }
}

private func mostCommon(_ colours: [[Int]]) -> [Int]? {
    Dictionary(grouping: colours) { $0 }.max { $0.value.count < $1.value.count }?.key
}
