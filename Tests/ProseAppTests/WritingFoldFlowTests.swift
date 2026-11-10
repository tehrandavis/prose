import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 6 step B: folds drawn and used in Writing and Focus mode,
/// acceptance tests 1 to 7 of the Quiet Writing note, on the real window,
/// editor and engine. Presses call `mouseDown(with:)` with a constructed
/// event (`foldPress`); keys call the editor's command methods. Every test
/// also checks that the storage holds only the source, that TextKit 2 is
/// still on, and that the undo stack is unchanged unless the test edits.
extension WritingFlowTests {
    /// Acceptance test 1: the welcome guide's first 17 lines draw as one
    /// setup row above its first rendered block, with no pill anywhere, and
    /// the caret at offset 0 rests on the closed row.
    @Test func writingFoldWelcomeGuideDrawsOneClosedSetupRow() async throws {
        let app = try WritingFixture(text: WelcomeDocument.source(), startService: false)
        defer { app.close() }
        try WelcomeDocument.prepareAssets(in: app.root)
        let (editor, manager, model) = try await openFoldDocument(app, caret: 0)
        let undo = UndoState(editor)
        let text = editor.string as NSString
        let grid = text.range(of: "#grid(").location
        // `#codly(...)` joins the fold once its render shows it has no ink.
        try await app.wait { model.fold(holding: 0)?.pill.text == "Document setup · 16 lines" }
        await app.layout()
        let fold = try #require(model.fold(holding: 0))
        #expect(!fold.isOpen && !fold.isHidden)
        #expect(fold.pill.style == .setup(lines: 16, document: true))
        #expect(text.substring(with: foldRange(fold, text)).hasSuffix("zebra-fill: none)"))
        #expect(NSMaxRange(fold.span) < grid)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))

        let fragments = writingFragments(manager)
        let row = try #require(fragments.first { $0.offset == 0 })
        #expect(row.role == .pill(fold.pill))
        #expect(row.frame.height == WritingMetrics.pillFragmentHeight)
        for fragment in fragments where fragment.offset > 0 && fragment.offset < NSMaxRange(fold.span) {
            #expect(fragment.role == .collapsed && fragment.frame.height == 0, "Line \(fragment.offset) of the fold")
        }
        let plain = fragments.filter { fragment in
            if case let .pill(pill) = fragment.role {
                return pill.style == .plain
            }
            return false
        }
        #expect(plain.isEmpty, "Pills in the welcome guide: \(plain.map(\.offset))")
        let first = try #require(fragments.first { $0.offset == grid })
        #expect(first.isRendered, "The first rendered block is \(first.role)")
        #expect(row.frame.maxY <= first.frame.minY)

        // The row draws its icon and label in the muted colour, no fill.
        let canvas = try foldCanvas(editor, "fold-welcome-row.png")
        let rowRect = setupRowRect(row)
        #expect(canvas.ink(in: rowRect) > 40, "No icon or label on the row")
        let icon = CGRect(x: rowRect.minX, y: rowRect.midY - 6, width: 12, height: 12)
        #expect(canvas.ink(in: icon) > 10, "No caret-right icon")
        #expect(canvas.ink(in: rowRect) * 3 < canvas.count(in: rowRect), "The row has a fill")
        let beside = CGRect(x: rowRect.maxX + 4, y: row.frame.minY, width: 200, height: row.frame.height)
        #expect(canvas.ink(in: beside) == 0, "Ink beside the row")
        let between = CGRect(x: 0, y: row.frame.maxY, width: rowRect.width, height: first.frame.minY - row.frame.maxY)
        #expect(canvas.ink(in: between.insetBy(dx: 0, dy: 1)) == 0, "Source drawn under the row")

        // The caret rests at the row's left edge, as tall as the label.
        let caret = try #require(TextKit2Geometry.caretRect(at: 0, in: manager))
        #expect(abs(caret.minX - rowRect.minX) < 0.5 && abs(caret.midY - rowRect.midY) < 0.5, "Caret \(caret)")
        #expect(caret.height > 10 && caret.height < WritingMetrics.pillHeight)
        // NSTextView's own insertion indicator stands there too.
        let restoreKey = giveKeyAppearance(app.window)
        defer { restoreKey() }
        editor.updateInsertionPointStateAndRestartTimer(true)
        await app.layout()
        let indicators = editor.subviews.filter { String(describing: type(of: $0)).contains("InsertionIndicator") }
        let indicator = try #require(indicators.first, "No insertion indicator")
        let origin = editor.textContainerOrigin
        #expect(
            abs(indicator.frame.minY - origin.y - caret.minY) < 0.5 && abs(indicator.frame.minX - origin.x) < 1,
            "Indicator \(indicator.frame), caret \(caret)",
        )
        expectFoldInvariants(editor, undo)
    }

    /// Acceptance test 2: a click on the row opens the fold as source, a
    /// click on `caret-down` closes it, and ten round trips change nothing
    /// stored, keep the selection, and keep the row's top in place.
    @Test func writingFoldClicksOpenAndCloseTheFoldWithTheRowInPlace() async throws {
        let app = try WritingFixture(text: WelcomeDocument.source(), startService: false)
        defer { app.close() }
        try WelcomeDocument.prepareAssets(in: app.root)
        let start = (WelcomeDocument.source() as NSString).range(of: "A sentence, a sketch").location
        let (editor, manager, model) = try await openFoldDocument(app, caret: start + 4)
        try await app.wait { model.fold(holding: 0)?.pill.isSetup == true }
        let storage = try #require(editor.textStorage)
        let attributed = NSAttributedString(attributedString: storage)
        let selection = editor.selectedRange()
        let undo = UndoState(editor)
        // The row is the first thing in view, its top 4 pt above the view.
        editor.scrollContainer(to: 4)
        editor.prepareForPointerInteraction()
        let rowTop = try #require(writingFragments(manager).first { $0.offset == 0 }).frame.minY
        let viewTop = editor.containerVisibleRect().minY
        for trip in 0 ..< 10 {
            let row = try #require(writingFragments(manager).first { $0.offset == 0 })
            let rect = setupRowRect(row)
            try foldPress(editor, at: CGPoint(x: rect.midX, y: max(rect.midY, viewTop + 2)))
            let opened = try #require(model.fold(holding: 0))
            #expect(opened.isOpen, "Trip \(trip): the click did not open the fold")
            let open = writingFragments(manager).filter { $0.offset < NSMaxRange(opened.span) }
            #expect(open.allSatisfy { $0.role == .source }, "Trip \(trip): the open fold is not source")
            let first = try #require(open.first)
            #expect(abs(first.frame.minY - editor.containerVisibleRect().minY - (rowTop - viewTop)) < 0.5)
            #expect(first.fragment?.marginIcon == .close)
            #expect(editor.selectedRange() == selection)
            if trip == 0 {
                let canvas = try foldCanvas(editor, "fold-welcome-open.png")
                let icon = try #require(first.fragment?.marginIconRect).offsetBy(dx: 0, dy: first.frame.minY)
                #expect(canvas.ink(in: icon) > 10, "No caret-down icon in the margin")
                #expect(canvas.ink(in: first.frame) > 40, "No source on the fold's first line")
            }
            let icon = try #require(first.fragment?.marginIconRect).offsetBy(dx: 0, dy: first.frame.minY)
            try foldPress(editor, at: CGPoint(x: icon.midX, y: icon.midY))
            #expect(model.fold(holding: 0)?.isOpen == false, "Trip \(trip): caret-down did not close the fold")
            let closed = try #require(writingFragments(manager).first { $0.offset == 0 })
            #expect(closed.role.isSetupRow)
            #expect(abs(closed.frame.minY - editor.containerVisibleRect().minY - (rowTop - viewTop)) < 0.5)
            #expect(editor.selectedRange() == selection)
        }
        #expect(storage.isEqual(to: attributed), "The round trips changed the storage's attributes")
        expectFoldInvariants(editor, undo)
    }

    /// Acceptance test 3: Down rests on the row and then passes it, Up does
    /// the same in reverse, Right from the resting position opens the fold
    /// until the caret leaves, and typing at the resting position opens it
    /// with the new character first.
    @Test func writingFoldArrowKeysRestOnTheRowAndStepOverIt() async throws {
        let app = try WritingFixture(text: foldSource, startService: false)
        defer { app.close() }
        let raw = (foldSource as NSString).range(of: "def raw()").location + 2
        let (editor, _, model) = try await openFoldDocument(app, caret: raw)
        let text = editor.string as NSString
        let undo = UndoState(editor)
        let setup = text.range(of: "#set par").location
        let above = text.range(of: "A paragraph above").location
        let below = text.range(of: "A paragraph below").location
        try await app.wait { model.fold(holding: setup)?.pill.text == "Setup · 3 lines" }
        let fold = try #require(model.fold(holding: setup))
        #expect(fold.restingPosition == setup && !fold.isOpen)

        // Down from the paragraph above: its blank line, then the row.
        editor.setSelectedRange(NSRange(location: above + 3, length: 0))
        editor.moveDown(nil)
        #expect(editor.selectedRange().location == setup - 1, "Down from the paragraph: \(editor.selectedRange())")
        editor.moveDown(nil)
        #expect(editor.selectedRange() == NSRange(location: setup, length: 0), "Down onto the row")
        #expect(model.fold(holding: setup)?.isOpen == false)
        editor.moveDown(nil)
        #expect(editor.selectedRange() == NSRange(location: fold.end, length: 0), "Down off the row")
        #expect(model.fold(holding: setup)?.isOpen == false)
        editor.moveDown(nil)
        #expect(editor.selectedRange().location == below, "Down to the paragraph below")
        // Up reverses both steps.
        editor.moveUp(nil)
        #expect(editor.selectedRange() == NSRange(location: fold.end, length: 0))
        editor.moveUp(nil)
        #expect(editor.selectedRange() == NSRange(location: setup, length: 0), "Up onto the row")
        #expect(model.fold(holding: setup)?.isOpen == false)
        editor.moveUp(nil)
        #expect(editor.selectedRange().location == setup - 1, "Up off the row")
        // From inside the paragraph below, Up lands on the row too.
        editor.setSelectedRange(NSRange(location: below + 6, length: 0))
        editor.moveUp(nil)
        editor.moveUp(nil)
        #expect(editor.selectedRange() == NSRange(location: setup, length: 0), "Up from the paragraph below")
        // Shift-arrows keep TextKit's behaviour: no stop at the row.
        editor.setSelectedRange(NSRange(location: setup - 1, length: 0))
        editor.moveDownAndModifySelection(nil)
        #expect(editor.selectedRange().location == setup - 1 && editor.selectedRange().length > 0)

        // Right from the resting position opens the fold; leaving closes it.
        editor.setSelectedRange(NSRange(location: setup, length: 0))
        editor.moveRight(nil)
        #expect(editor.selectedRange() == NSRange(location: setup + 1, length: 0))
        #expect(model.fold(holding: setup)?.isOpen == true)
        editor.setSelectedRange(NSRange(location: below + 2, length: 0))
        #expect(model.fold(holding: setup)?.isOpen == false)
        // Left from just after the fold goes inside and opens it.
        editor.setSelectedRange(NSRange(location: fold.end, length: 0))
        editor.moveLeft(nil)
        #expect(model.fold(holding: setup)?.isOpen == true)
        editor.setSelectedRange(NSRange(location: below + 2, length: 0))
        expectFoldInvariants(editor, undo)

        // A character typed at the resting position lands first in the fold,
        // which opens.
        editor.setSelectedRange(NSRange(location: setup, length: 0))
        #expect(model.fold(holding: setup)?.isOpen == false)
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect((editor.string as NSString).substring(with: NSRange(location: setup, length: 9)) == "x#set par")
        // The typed line is no longer a setup line, so it leaves the fold;
        // the rest of the fold opens with it, and every line draws source.
        func typedLines() -> [WritingRole] {
            let typed = editor.string as NSString
            return [setup, typed.range(of: "#set heading").location, typed.range(of: "// A comment among").location]
                .map { role(model, typed, $0) }
        }
        #expect(typedLines() == [.source, .source, .source], "\(typedLines())")
        #expect(model.fold(holding: setup + 1).map(\.isOpen) != false)
        #expect(model.fold(holding: (editor.string as NSString).range(of: "#set heading").location)?.isOpen == true)
        await model.idle()
        await app.layout()
        #expect(typedLines() == [.source, .source, .source], "After the engine's blocks: \(typedLines())")
        #expect(editor.undoManager?.canUndo == true)
        expectPlainStorage(editor)
    }

    /// Acceptance test 4: a pointer selection across a closed fold keeps it
    /// closed, highlights the whole row and copies the source; a selection
    /// inside it, as the find bar makes, opens it; so does an undo that
    /// changes its text.
    @Test func writingFoldSelectionsHighlightTheRowAndFindAndUndoOpenIt() async throws {
        let app = try WritingFixture(text: foldSource, startService: false)
        defer { app.close() }
        let raw = (foldSource as NSString).range(of: "def raw()").location + 2
        let (editor, manager, model) = try await openFoldDocument(app, caret: raw)
        let restoreKey = giveKeyAppearance(app.window)
        defer { restoreKey() }
        let text = editor.string as NSString
        let undo = UndoState(editor)
        let setup = text.range(of: "#set par").location
        let above = text.range(of: "A paragraph above").location
        let below = text.range(of: "A paragraph below").location
        try await app.wait {
            model.fold(holding: setup)?.pill.isSetup == true && renderedBlock(manager, at: above) != nil
                && renderedBlock(manager, at: below) != nil
        }
        let from = text.range(of: "paragraph above").location
        let to = text.range(of: "below the setup").location
        try writingPress(
            editor,
            at: glyphCentre(manager, block: above, offset: from),
            through: [glyphCentre(manager, block: below, offset: to)],
        )
        let selection = NSRange(location: from, length: to - from)
        #expect(editor.selectedRange() == selection)
        #expect(model.fold(holding: setup)?.isOpen == false, "The pointer selection opened the fold")
        // NSTextView draws no selection in any paragraph of the closed fold.
        let fold = try #require(model.fold(holding: setup))
        var native = 0
        let span = try #require(TextKit2Geometry.textRange(fold.span, in: manager))
        manager.enumerateTextSegments(in: span, type: .selection, options: .rangeNotRequired) { _, _, _, _ in
            native += 1
            return true
        }
        #expect(native == 0, "NSTextView draws \(native) selection segments in the closed fold")
        await app.layout()
        let row = try #require(writingFragments(manager).first { $0.offset == setup })
        let canvas = try foldCanvas(editor, "fold-selection-row.png")
        let rowRect = setupRowRect(row)
        #expect(
            canvas.selected(in: rowRect) * 2 > canvas.count(in: rowRect),
            "The row is not highlighted: \(canvas.selected(in: rowRect)) of \(canvas.count(in: rowRect))",
        )
        let general = NSPasteboard.general
        let saved = general.string(forType: .string)
        defer {
            general.clearContents()
            if let saved {
                general.setString(saved, forType: .string)
            }
        }
        editor.copy(nil)
        #expect(general.string(forType: .string) == text.substring(with: selection))

        // A match inside the closed fold, selected as the find bar selects it.
        park(editor)
        #expect(model.fold(holding: setup)?.isOpen == false)
        let match = text.range(of: "justify")
        editor.setSelectedRange(match)
        editor.showFindIndicator(for: match)
        #expect(model.fold(holding: setup)?.isOpen == true, "Selecting a match in the fold did not open it")
        park(editor)
        #expect(model.fold(holding: setup)?.isOpen == false)
        expectFoldInvariants(editor, undo)

        // An undo that changes text inside the closed fold opens it.
        let numbering = text.range(of: "\"1.\"")
        editor.insertSnippet(Snippet(text: "\"A.\""), replacing: numbering, focus: false)
        park(editor)
        await model.idle()
        #expect(model.setFold(open: false, at: setup))
        #expect(model.fold(holding: setup)?.isOpen == false)
        editor.undoManager?.undo()
        #expect(editor.string == text as String)
        #expect(model.fold(holding: setup)?.isOpen == true, "The undo inside the fold did not open it")
        expectPlainStorage(editor)
    }

    /// Acceptance test 5: a comment and a `#v(7mm)` between paragraphs each
    /// draw a margin mark and no pill, keep one blank line's gap, and open
    /// on a click on the mark.
    @Test func writingFoldMarginMarksKeepTheGapAndOpenOnAClick() async throws {
        let app = try WritingFixture(text: markSource, startService: false)
        defer { app.close() }
        let raw = (markSource as NSString).range(of: "def raw()").location + 2
        let (editor, manager, model) = try await openFoldDocument(app, caret: raw)
        let text = editor.string as NSString
        let undo = UndoState(editor)
        let comment = text.range(of: "// A comment").location
        let spacing = text.range(of: "#v(7mm)").location
        let paragraphs = ["First paragraph", "Second paragraph", "Third paragraph", "Fourth paragraph",
                          "Fifth paragraph", "Sixth paragraph"].map { text.range(of: $0).location }
        try await app.wait {
            model.fold(holding: spacing) != nil && paragraphs.allSatisfy { renderedBlock(manager, at: $0) != nil }
        }
        await app.layout()
        #expect(model.fold(holding: comment)?.pill.style == .mark(.comment))
        #expect(model.fold(holding: spacing)?.pill.style == .mark(.code))
        let fragments = writingFragments(manager)
        let pills = fragments.filter(\.role.isPlainPill)
        #expect(pills.isEmpty, "Pills are drawn at \(pills.map(\.offset))")
        let canvas = try foldCanvas(editor, "fold-margin-marks.png")
        func frame(_ offset: Int) throws -> CGRect {
            try #require(fragments.first { $0.offset == offset }).frame
        }
        // The gap around each mark is one blank line's.
        let plainGap = try frame(paragraphs[5]).minY - frame(paragraphs[4]).maxY
        for (above, below, name) in [(0, 1, "comment"), (2, 3, "spacing")] {
            let gap = try frame(paragraphs[below]).minY - frame(paragraphs[above]).maxY
            #expect(
                abs(gap - plainGap) <= 1,
                "The gap around the \(name) is \(gap), between plain paragraphs \(plainGap)",
            )
        }
        for (offset, name) in [(comment, "comment"), (spacing, "spacing")] {
            let mark = try #require(fragments.first { $0.offset == offset })
            #expect(mark.frame.height == 0, "The \(name)'s mark takes height")
            let icon = try #require(mark.fragment?.marginIconRect, "No mark for the \(name)")
                .offsetBy(dx: mark.frame.minX, dy: mark.frame.minY)
            #expect(icon.maxX < WritingMetrics.staleBar.minX && icon.minX >= -ManuscriptLayout.minimumInset)
            #expect(canvas.ink(in: icon) > 10, "No ink for the \(name)'s mark in the margin")
            // Level with the middle of the gap above the next paragraph.
            let gapMiddle = try (frame(paragraphs[offset == comment ? 0 : 2]).maxY + mark.frame.minY) / 2
            #expect(abs(icon.midY - gapMiddle) < 1, "The \(name)'s mark is not level with the gap")
            let column = CGRect(x: 0, y: icon.minY, width: 300, height: icon.height)
            #expect(canvas.ink(in: column) == 0, "Ink in the column at the \(name)")
        }

        // A click on the mark opens the fold and leaves the caret.
        let mark = try #require(fragments.first { $0.offset == comment })
        let icon = try #require(mark.fragment?.marginIconRect).offsetBy(dx: 0, dy: mark.frame.minY)
        let selection = editor.selectedRange()
        try foldPress(editor, at: CGPoint(x: icon.midX, y: icon.midY))
        #expect(model.fold(holding: comment)?.isOpen == true, "The click on the mark did not open it")
        #expect(editor.selectedRange() == selection)
        let opened = try #require(writingFragments(manager).first { $0.offset == comment })
        #expect(opened.role == .source && opened.frame.height > 4)
        #expect(opened.fragment?.marginIcon == .close)
        // A press in the margin away from any icon is not for a fold.
        let fifth = try #require(writingFragments(manager).first { $0.offset == paragraphs[4] })
        #expect(editor.writing.foldControl(at: CGPoint(x: -20, y: fifth.frame.midY)) == nil)
        expectFoldInvariants(editor, undo)
    }

    /// Acceptance test 6: in Focus a closed setup row takes no height, shows
    /// while the caret rests on it, and Up and Down pass it in one step; a
    /// margin mark draws at 45 percent outside the focus blocks. The
    /// typewriter line holds with the caret on the row and in an open fold.
    @Test func writingFoldFocusHidesTheRowAndDimsTheMark() async throws {
        let source = foldSource.replacingOccurrences(
            of: "A paragraph below the setup lines.",
            with: "A paragraph below the setup lines.\n\n// A comment between two paragraphs.\n\nThe paragraph after it.",
        )
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        editor.insertionPointColor = .clear
        let text = editor.string as NSString
        park(editor)
        let undo = UndoState(editor)
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.isRunning && editor.writing.focused }
        let model = try #require(editor.writing.model)
        try await app.wait { editor.writing.enteredWithRenders != nil }
        await model.idle()
        await app.layout()
        #expect(model.hidesSetupRows)
        let setup = text.range(of: "#set par").location
        let comment = text.range(of: "// A comment between").location
        try await app.wait { model.fold(holding: setup)?.isHidden == true && model.fold(holding: comment) != nil }
        let fold = try #require(model.fold(holding: setup))

        // Hidden: every line of the fold collapsed.
        let hidden = writingFragments(manager).filter { NSLocationInRange($0.offset, fold.span) }
        #expect(hidden.allSatisfy { $0.role == .collapsed && $0.frame.height == 0 })
        // Up and Down pass it in one step.
        editor.setSelectedRange(NSRange(location: setup - 1, length: 0))
        expectTypewriter(editor, "the line above the fold")
        editor.moveDown(nil)
        #expect(editor.selectedRange() == NSRange(location: fold.end, length: 0), "Down did not pass the fold")
        editor.moveUp(nil)
        #expect(editor.selectedRange() == NSRange(location: setup - 1, length: 0), "Up did not pass the fold")
        #expect(model.fold(holding: setup)?.isHidden == true)
        // The caret at the resting position shows the row.
        editor.setSelectedRange(NSRange(location: setup, length: 0))
        await app.layout()
        let row = try #require(writingFragments(manager).first { $0.offset == setup })
        #expect(row.role.isSetupRow && row.frame.height == WritingMetrics.pillFragmentHeight)
        expectTypewriter(editor, "the caret on the row")
        #expect(!editor.writing.dims(paragraphAt: setup))
        // Inside, the fold opens and the typewriter line holds.
        editor.moveRight(nil)
        #expect(model.fold(holding: setup)?.isOpen == true)
        expectTypewriter(editor, "the caret in the open fold")
        #expect(!editor.writing.dims(paragraphAt: setup) && !editor.writing.dims(paragraphAt: fold.end - 1))

        // The mark dims to 45 percent outside the focus blocks.
        park(editor)
        await app.layout()
        func markInk(_ label: String) throws -> Double {
            let mark = try #require(writingFragments(manager).first { $0.offset == comment })
            let icon = try #require(mark.fragment?.marginIconRect).offsetBy(dx: 0, dy: mark.frame.minY)
            editor.scrollContainer(to: icon.minY - 200)
            editor.prepareForPointerInteraction()
            let canvas = try foldCanvas(editor, "fold-focus-mark-\(label).png")
            return canvas.peak(in: icon)
        }
        #expect(editor.writing.dims(paragraphAt: comment))
        let dimmed = try markInk("dimmed")
        editor.setSelectedRange(NSRange(location: comment, length: 0))
        await app.layout()
        #expect(!editor.writing.dims(paragraphAt: comment) && model.fold(holding: comment)?.isOpen == false)
        let full = try markInk("focus")
        #expect(full > 60, "The mark has no ink: \(full)")
        #expect(abs(dimmed / full - 0.45) <= 0.04, "The mark dims to \(dimmed / full)")
        app.workspace.setMode(.writing)
        #expect(!model.hidesSetupRows)
        expectFoldInvariants(editor, undo)
    }

    /// Acceptance test 7: the accessibility frame of a range in a closed
    /// fold is the row's rectangle, or the mark's; with marked text a click
    /// on a row and a render that would fold a block change nothing until
    /// the composition ends.
    @Test func writingFoldAccessibilityFramesAndMarkedText() async throws {
        let app = try WritingFixture(text: markSource, startService: false)
        defer { app.close() }
        let raw = (markSource as NSString).range(of: "def raw()").location + 2
        let (editor, manager, model) = try await openFoldDocument(app, caret: raw)
        var text = editor.string as NSString
        let comment = text.range(of: "// A comment").location
        try await app.wait { model.fold(holding: comment) != nil }

        // A setup row, made by a `#set` line at the top.
        editor.insertSnippet(
            Snippet(text: "#set par(justify: false)\n\n"),
            replacing: NSRange(location: 0, length: 0),
            focus: false,
        )
        park(editor)
        await model.idle()
        try await app.wait { model.fold(holding: 0)?.pill.isSetup == true }
        await app.layout()
        text = editor.string as NSString
        let row = try #require(writingFragments(manager).first { $0.offset == 0 })
        let rowRect = setupRowRect(row)
        let range = NSRange(location: 5, length: 10)
        let frame = editor.accessibilityFrame(for: range)
        let expected = try #require(editor.screenRect(fromContainer: rowRect))
        #expect(frame.equalTo(expected), "Frame \(frame), row \(expected)")
        let movedComment = text.range(of: "// A comment").location
        let mark = try #require(writingFragments(manager).first { $0.offset == movedComment })
        let icon = try #require(mark.fragment?.marginIconRect).offsetBy(dx: 0, dy: mark.frame.minY)
        let markFrame = editor.accessibilityFrame(for: NSRange(location: movedComment + 3, length: 4))
        let expectedMark = try #require(editor.screenRect(fromContainer: icon))
        #expect(markFrame.equalTo(expectedMark), "Frame \(markFrame), mark \(expectedMark)")
        // The value stays the source.
        #expect(editor.accessibilityValue() == editor.string)

        // An edit makes a new `#v` block, which folds when its render shows
        // no ink. Text is marked before the engine has the edit.
        let fifth = text.range(of: "Fifth paragraph").location
        editor.insertSnippet(Snippet(text: "#v(5mm)\n\n"), replacing: NSRange(location: fifth, length: 0), focus: false)
        let spacing = fifth
        let sixth = (editor.string as NSString).range(of: "Sixth paragraph").location
        editor.setSelectedRange(NSRange(location: sixth + 5, length: 0))
        editor.setMarkedText(
            "zh",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        #expect(editor.hasMarkedText())
        let marked = editor.selectedRange()
        let before = writingFragments(manager).map(\.role)
        let swaps = editor.writing.swapCount
        // A click on the row does nothing while text is marked.
        try foldPress(editor, at: CGPoint(x: rowRect.midX, y: rowRect.midY))
        #expect(model.fold(holding: 0)?.isOpen == false)
        #expect(!model.setFold(open: true, at: 0))
        #expect(editor.hasMarkedText() && editor.selectedRange() == marked)
        try await Task.sleep(for: .milliseconds(400))
        await model.idle()
        await app.layout()
        #expect(model.fold(holding: spacing) == nil, "A fold changed while text was marked")
        #expect(writingFragments(manager).map(\.role) == before)
        #expect(editor.writing.swapCount == swaps)
        // The composition ends: the edit reaches the engine and the block folds.
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        park(editor)
        try await app.wait { model.fold(holding: spacing)?.pill.style == .mark(.code) }
        #expect(editor.undoManager?.canUndo == true)
        expectPlainStorage(editor)
    }

    /// Plain `#include` pills keep their look and behaviour: a pill, not a
    /// fold, drawn with its fill, and a press puts the caret at its start.
    @Test func writingFoldIncludeLinesStayPills() async throws {
        let source = "= Book\n\nA paragraph before the chapter.\n\n#include \"chapter.typ\"\n\nA paragraph after it.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        try Data("= Chapter\n\nChapter text.\n".utf8).write(to: app.root.appendingPathComponent("chapter.typ"))
        let (editor, manager, model) = try await openFoldDocument(app, caret: (source as NSString).length)
        let include = (source as NSString).range(of: "#include").location
        try await app.wait { writingFragments(manager).first { $0.offset == include }?.role.isPlainPill == true }
        #expect(model.fold(holding: include) == nil)
        let pill = try #require(writingFragments(manager).first { $0.offset == include })
        #expect(pill.frame.height == WritingMetrics.pillFragmentHeight)
        #expect(pill.fragment?.marginIcon == nil)
        try writingPress(editor, at: CGPoint(x: 20, y: pill.frame.midY))
        #expect(editor.selectedRange() == NSRange(location: include, length: 0))
        expectPlainStorage(editor)
    }
}

// MARK: - Unit tests

@Test @MainActor func writingFoldMetricsPlaceTheRowCaretAndMarginIcons() {
    let row = WritingMetrics.setupRowRect(label: "Document setup · 16 lines", column: 600)
    #expect(row.minX == 0 && row.minY == WritingMetrics.pillSpacing && row.height == WritingMetrics.pillHeight)
    #expect(row.width > WritingMetrics.foldIconSize + WritingMetrics.foldIconGap + 100 && row.width < 300)
    #expect(WritingMetrics.setupRowRect(label: "Document setup · 16 lines", column: 50).width == 50)
    let caret = WritingMetrics.setupCaretRect
    #expect(caret.minX == 0 && abs(caret.midY - row.midY) < 0.01 && caret.height < row.height)
    let icon = WritingMetrics.marginIconRect(midY: 10)
    #expect(icon.midY == 10 && icon.width == 12 && icon.height == 12)
    #expect(icon.maxX < WritingMetrics.staleBar.minX)
    #expect(icon.minX - WritingMetrics.marginHitSlop >= -ManuscriptLayout.minimumInset)
    #expect(WritingMarginIcon.mark(.comment).iconName == "chat-text")
    #expect(WritingMarginIcon.mark(.code).iconName == "code-simple")
    #expect(WritingMarginIcon.close.iconName == "caret-right")
    for name in ["chat-text", "code-simple", "caret-right"] {
        #expect(IconStore.image(name) != nil, "\(name) is not bundled")
    }
}

// MARK: - Fixture text and helpers

private let foldFiller = (1 ... 24)
    .map { "Filler paragraph \($0), plain text that fills the column so the document scrolls.\n\n" }
    .joined()

/// A fold of three quiet blocks between two paragraphs: "Setup · 3 lines".
private let foldSource = """
= Fold heading

A paragraph above the setup lines.

#set par(justify: false)
#set heading(numbering: "1.")
// A comment among the setup lines.

A paragraph below the setup lines.

```py
def raw(): return 1
```

\(foldFiller)The last paragraph.

"""

/// A comment and a `#v(7mm)` between paragraphs, and two paragraphs with
/// one blank line between them to compare the gaps with.
private let markSource = """
= Mark heading

First paragraph before the comment.

// A comment between two paragraphs.

Second paragraph after the comment.

Third paragraph before the spacing.

#v(7mm)

Fourth paragraph after the spacing.

Fifth paragraph, one blank line below.

Sixth paragraph, one blank line above.

```py
def raw(): return 1
```

\(foldFiller)The last paragraph.

"""

/// Opens `app`'s document in Writing mode, light, scrolled to the top, with
/// the caret at `caret`.
@MainActor
private func openFoldDocument(
    _ app: WritingFixture,
    caret: Int,
) async throws -> (ManuscriptTextView, NSTextLayoutManager, WritingLayout) {
    app.window.appearance = NSAppearance(named: .aqua)
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let manager = try #require(editor.textLayoutManager)
    editor.setSelectedRange(NSRange(location: caret, length: 0))
    let model = try await enterWritingMode(app)
    #expect(model.foldsEnabled)
    writingScrollToTop(editor)
    await app.layout()
    await model.idle()
    writingScrollToTop(editor)
    await app.layout()
    return (editor, manager, model)
}

/// What a test that does not edit must leave as it was.
@MainActor
private struct UndoState: Equatable {
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String

    init(_ editor: ManuscriptTextView) {
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
    }
}

@MainActor
private func expectFoldInvariants(
    _ editor: ManuscriptTextView,
    _ undo: UndoState,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) {
    #expect(UndoState(editor) == undo, "The undo stack changed", sourceLocation: sourceLocation)
    expectPlainStorage(editor)
}

/// The row's icon and label in container coordinates.
@MainActor
private func setupRowRect(_ row: WritingFragmentInfo) -> CGRect {
    guard case let .pill(pill) = row.role, let fragment = row.fragment else {
        Issue.record("Not a setup row: \(row.role)")
        return .zero
    }
    return WritingMetrics.setupRowRect(label: pill.text, column: fragment.columnWidth)
        .offsetBy(dx: row.frame.minX, dy: row.frame.minY)
}

private func foldRange(_ fold: WritingFold, _ text: NSString) -> NSRange {
    var end = NSMaxRange(fold.span)
    while end > fold.span.location, text.character(at: end - 1) == 0x0A {
        end -= 1
    }
    return NSRange(location: fold.span.location, length: end - fold.span.location)
}

/// Presses once at `point` (container coordinates) through `mouseDown(with:)`
/// and lets go there; a press that would enter AppKit's tracking is refused.
@MainActor
private func foldPress(_ editor: ManuscriptTextView, at point: CGPoint) throws {
    let window = try #require(editor.window)
    let origin = editor.textContainerOrigin
    let location = editor.convert(CGPoint(x: point.x + origin.x, y: point.y + origin.y), to: nil)
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
    }
    var script = try [event(.leftMouseUp)]
    editor.pointerEvents = { script.isEmpty ? nil : script.removeFirst() }
    defer { editor.pointerEvents = nil }
    let unhandled = editor.unhandledScriptedClicks
    try editor.mouseDown(with: event(.leftMouseDown))
    #expect(editor.unhandledScriptedClicks == unhandled, "The press at \(point) went to AppKit's tracking")
}

/// In Focus, the middle of the caret's line lies on the typewriter line.
@MainActor
private func expectTypewriter(
    _ editor: ManuscriptTextView,
    _ label: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) {
    let caret = editor.selectedRange().location
    guard let middle = editor.writing.caretMiddle(caret) else {
        Issue.record("\(label): no caret line", sourceLocation: sourceLocation)
        return
    }
    let visible = editor.containerVisibleRect()
    let line = visible.minY + visible.height * WritingController.typewriterFraction
    #expect(
        abs(middle - line) <= 1,
        "\(label): caret line \(middle), typewriter line \(line)",
        sourceLocation: sourceLocation,
    )
}

/// A picture of the editor's visible rect on the light page.
@MainActor
private func foldCanvas(_ editor: ManuscriptTextView, _ name: String) throws -> WritingCanvas {
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
    editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
    try writingSave(bitmap, name)
    return WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
}

extension WritingCanvas {
    /// The strongest ink in `rect`: the 99th percentile of each pixel's
    /// largest channel difference from the page. Dimming to an opacity
    /// scales it by that opacity.
    func peak(in rect: CGRect) -> Double {
        var differences: [Int] = []
        _ = matching(in: rect) { red, green, blue in
            differences.append(max(abs(red - background.0), abs(green - background.1), abs(blue - background.2)))
            return true
        }
        let sorted = differences.sorted()
        return sorted.isEmpty ? 0 : Double(sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
    }
}

extension WritingRole {
    var isSetupRow: Bool {
        if case let .pill(pill) = self {
            return pill.isSetup
        }
        return false
    }

    var isPlainPill: Bool {
        if case let .pill(pill) = self {
            return pill.style == .plain
        }
        return false
    }
}
