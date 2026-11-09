import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 4 step B: Focus mode's view state (acceptance tests 1, 2, 5 and 6 of
/// `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`), on the real
/// window, editor and engine.
extension WritingFlowTests {
    /// Acceptance test 1: `⌘3`, the Focus segment and the `modeFocus` command
    /// each enter Focus from Code and from Writing; `⌘2` and `Esc` leave it and
    /// restore the sidebar and the layout, for all four pane combinations.
    @Test func focusModeEntersByEveryRouteAndRestoresThePanes() async throws {
        let app = try WritingFixture(text: focusSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let menu = try installFocusMenu(app)
        defer { menu.restore() }
        let frame = app.window.frame
        let routes: [(name: String, enter: () throws -> Void)] = [
            ("⌘3", { #expect(menu.menu.performKeyEquivalent(with: app.key("3", code: 20, modifiers: .command))) }),
            ("segment", { app.workspace.setMode(.focus) }),
            ("command", { try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "modeFocus" })) }),
        ]
        let panes = [
            FocusPanes(sidebarVisible: false, layout: .writing),
            FocusPanes(sidebarVisible: true, layout: .writing),
            FocusPanes(sidebarVisible: false, layout: .split),
            FocusPanes(sidebarVisible: true, layout: .split),
        ]
        // Eight runs cover the four pane combinations with each way out, and
        // the three routes in from Code and from Writing.
        for run in 0 ..< 8 {
            let pane = panes[run % 4], route = routes[run % 3]
            let fromWriting = !run.isMultiple(of: 2), escape = run >= 4
            let label = "run \(run): \(route.name) from \(fromWriting ? "Writing" : "Code"), \(pane)"
            if fromWriting {
                _ = try await enterWritingMode(app)
            } else {
                app.workspace.setMode(.code)
            }
            app.workspace.sidebarVisible = pane.sidebarVisible
            app.workspace.layout = pane.layout
            #expect(app.workspace.editorMode == (fromWriting ? .writing : .code), "\(label)")
            await app.layout()
            let model = try await enterFocus(app, route.enter)
            #expect(!app.workspace.sidebarVisible && app.workspace.layout == .writing, "\(label)")
            #expect(app.workspace.focusSavedPanes == pane, "\(label)")
            #expect(app.window.frame == frame, "\(label): the window changed size")
            expectFocusColumn(editor, label)
            expectFocusRenders(editor, model, label)
            expectPlainStorage(editor)

            if escape {
                app.window.makeFirstResponder(editor)
                app.window.sendEvent(app.key("\u{1b}", code: 53))
            } else {
                #expect(menu.menu.performKeyEquivalent(with: app.key("2", code: 19, modifiers: .command)))
            }
            #expect(app.workspace.editorMode == .writing, "\(label)")
            #expect(app.workspace.sidebarVisible == pane.sidebarVisible, "\(label): sidebar")
            #expect(app.workspace.layout == pane.layout, "\(label): layout")
            #expect(app.workspace.focusSavedPanes == nil)
            #expect(!editor.writing.focused && editor.writing.isRunning && editor.writing.model === model)
            await app.layout()
            #expect(app.window.frame == frame, "\(label): the window changed size")
            let width = editor.frame.width
            #expect(editor.textContainerInset.width == ManuscriptLayout.horizontalInset(for: width), "\(label)")
            expectPlainStorage(editor)
        }
    }

    /// Decision 2: a pane shown while Focus is on (`⌘0`, `⌘⇧P`, a command)
    /// leaves Focus for Writing mode and shows it; the other pane comes back
    /// as it was before Focus.
    @Test func focusModeEndsWhenAPaneIsShown() async throws {
        let app = try WritingFixture(text: focusSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let menu = try installFocusMenu(app)
        defer { menu.restore() }
        _ = try await enterWritingMode(app)

        // ⌘0: the sidebar shows; the preview that was there comes back.
        app.workspace.layout = .split
        app.workspace.sidebarVisible = false
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        #expect(menu.menu.performKeyEquivalent(with: app.key("0", code: 29, modifiers: .command)))
        #expect(app.workspace.editorMode == .writing)
        #expect(app.workspace.sidebarVisible && app.workspace.layout == .split)

        // ⌘⇧P: the preview shows beside the text; the sidebar comes back.
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        #expect(!app.workspace.sidebarVisible && !app.workspace.previewShown)
        try menu.choose("Show or Hide Preview")
        #expect(app.workspace.editorMode == .writing)
        #expect(app.workspace.sidebarVisible && app.workspace.layout == .split)

        // Commands: "preview" reads the preview, "outline" shows the sidebar.
        app.workspace.sidebarVisible = false
        app.workspace.layout = .writing
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "preview" }))
        #expect(app.workspace.editorMode == .writing && app.workspace.layout == .preview)
        #expect(!app.workspace.sidebarVisible)
        app.workspace.layout = .writing
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "outline" }))
        #expect(app.workspace.editorMode == .writing && app.workspace.sidebarVisible)
        #expect(app.workspace.layout == .writing)

        // Showing what is already shown, the editor alone, keeps Focus.
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "writing" }))
        #expect(app.workspace.editorMode == .focus)
        app.workspace.setMode(.code)
        #expect(app.workspace.editorMode == .code && app.workspace.sidebarVisible)
        #expect(app.workspace.layout == .writing)
        try expectPlainStorage(#require(app.workspace.editor))
    }

    /// Acceptance test 2: ten trips in and out of Focus leave the storage, its
    /// attributes, the selection and the undo stack as they were; rendered
    /// blocks in Focus are the engine's height times the Focus scale.
    @Test func focusModeRoundTripsLeaveTheStorageSelectionAndUndoUntouched() async throws {
        let app = try WritingFixture(text: focusSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let undo = try #require(editor.undoManager)
        let original = editor.string
        let end = (editor.string as NSString).length
        editor.insertSnippet(Snippet(text: "One. "), replacing: NSRange(location: end, length: 0), focus: false)
        await app.layout()
        editor.insertSnippet(Snippet(text: "Two. "), replacing: NSRange(location: end + 5, length: 0), focus: false)
        await app.layout()
        let selection = (editor.string as NSString).range(of: "on its first source line")
        editor.setSelectedRange(NSRange(location: selection.location, length: 12))
        _ = try await enterWritingMode(app)
        let storage = try #require(editor.textStorage)
        let attributed = NSAttributedString(attributedString: storage)
        let before = FocusSnapshot(editor)
        let revision = app.workspace.revision

        for trip in 0 ..< 10 {
            let model = try await enterFocus(app) { app.workspace.setMode(.focus) }
            if trip == 0 || trip == 9 {
                expectFocusRenders(editor, model, "trip \(trip)")
            }
            let toCode = !trip.isMultiple(of: 2)
            app.workspace.setMode(toCode ? .code : .writing)
            if toCode {
                _ = try await enterWritingMode(app)
            }
            #expect(FocusSnapshot(editor) == before, "trip \(trip)")
            #expect(storage.isEqual(to: attributed), "trip \(trip): the storage's attributes changed")
            #expect(app.workspace.revision == revision)
            expectPlainStorage(editor)
        }

        // The undo stack is the same: two undos remove both snippets.
        undo.undo()
        undo.undo()
        #expect(editor.string == original)
        #expect(!undo.canUndo)
        #expect(app.workspace.text == editor.string)
    }

    /// Acceptance test 5: `Esc` leaves Focus only when nothing else owns it.
    /// Marked text, the command panel, the completion panel, a placeholder
    /// and the checks popup keep it, as in Code and Writing mode.
    @Test func focusModeEscapeComesAfterEveryOtherOwner() async throws {
        let app = try WritingFixture(text: focusSource + "#rec")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let escape = app.key("\u{1b}", code: 53)
        let end = (editor.string as NSString).length

        // Writing mode: Escape does what it did before Focus existed.
        _ = try await enterWritingMode(app)
        app.window.makeFirstResponder(editor)
        app.window.sendEvent(escape)
        #expect(app.workspace.editorMode == .writing)
        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        app.window.makeFirstResponder(editor)

        // Marked text: the input method keeps the key.
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.setMarkedText(
            "zhong",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: editor.selectedRange(),
        )
        #expect(editor.hasMarkedText())
        app.window.sendEvent(escape)
        #expect(app.workspace.editorMode == .focus, "Escape with marked text left Focus")
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.markedRange())
        editor.unmarkText()
        #expect((editor.string as NSString).length == end)

        // The command panel: Escape closes it, Focus stays.
        app.workspace.togglePalette()
        #expect(app.workspace.paletteOpen)
        app.window.sendEvent(escape)
        #expect(!app.workspace.paletteOpen)
        #expect(app.workspace.editorMode == .focus)
        await app.layout()
        app.window.makeFirstResponder(editor)

        // The completion panel after `#rec`: Escape closes it, Focus stays.
        let rec = (editor.string as NSString).range(of: "#rec", options: .backwards)
        editor.setSelectedRange(NSRange(location: NSMaxRange(rec), length: 0))
        editor.scheduleTypingAssistance()
        try await app.wait { editor.typingPanel != nil && editor.typingTask == nil }
        app.window.sendEvent(escape)
        #expect(editor.typingPanel == nil)
        #expect(app.workspace.editorMode == .focus)

        // A placeholder: Escape leaves it, Focus stays.
        editor.setCompletionPlaceholders([NSRange(location: rec.location + 1, length: 3)])
        editor.setSelectedRange(NSRange(location: rec.location + 1, length: 3))
        app.window.sendEvent(escape)
        #expect(editor.selectedRange() == NSRange(location: NSMaxRange(rec), length: 0))
        #expect(app.workspace.editorMode == .focus)

        // The checks popup: Escape closes it, Focus stays.
        app.workspace.checksOpen = true
        app.window.sendEvent(escape)
        #expect(!app.workspace.checksOpen)
        #expect(app.workspace.editorMode == .focus)

        // Nothing else: Escape leaves Focus for Writing mode.
        app.window.sendEvent(escape)
        #expect(app.workspace.editorMode == .writing)
        #expect(editor.string == app.workspace.text)
        expectPlainStorage(editor)
    }

    /// Acceptance test 6: in Focus the title row shows only the breadcrumb and
    /// the status dot until the pointer is over it; the status bar shows while
    /// the pointer is near the bottom edge and hides a moment after it leaves.
    /// The command panel and the message bar keep working.
    @Test func focusModeShowsTheTitleRowAndStatusBarOnHover() async throws {
        let app = try WritingFixture(text: focusSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let chrome = app.workspace.focusChrome
        chrome.hideDelay = .milliseconds(150)
        #expect(!chrome.active && !chrome.hidesTitle && !chrome.hidesStatusBar && chrome.tracker == nil)

        _ = try await enterFocus(app) { app.workspace.setMode(.focus) }
        #expect(chrome.active && chrome.hidesTitle && chrome.hidesStatusBar)
        let tracker = try #require(chrome.tracker)
        let frameView = try #require(app.window.contentView?.superview)
        #expect(frameView.trackingAreas.contains { $0.owner === tracker })
        let top = app.window.contentLayoutRect.maxY
        func move(_ y: CGFloat) throws {
            try tracker.mouseMoved(with: #require(NSEvent.mouseEvent(
                with: .mouseMoved,
                location: CGPoint(x: app.window.frame.width / 2, y: y),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: app.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0,
            )))
        }

        // The title row: shown while the pointer is over it.
        try move(top + 10)
        #expect(chrome.titleShown && !chrome.hidesTitle)
        #expect(chrome.hidesStatusBar)
        try move(top - 40)
        #expect(chrome.hidesTitle)
        try move(top + 4)
        #expect(!chrome.hidesTitle)
        try tracker.mouseExited(with: #require(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0,
        )))
        #expect(chrome.hidesTitle)

        // The status bar: shown within 34 pt of the bottom edge, hidden a
        // moment after the pointer leaves, kept while it comes back in time.
        try move(FocusChrome.statusBarReach + 20)
        #expect(chrome.hidesStatusBar)
        try move(FocusChrome.statusBarReach - 2)
        #expect(!chrome.hidesStatusBar)
        try move(200)
        #expect(!chrome.hidesStatusBar, "The status bar hid before the delay")
        try move(10)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!chrome.hidesStatusBar, "Coming back did not cancel the hide")
        try move(200)
        try await app.wait { chrome.hidesStatusBar }
        try move(10)
        #expect(!chrome.hidesStatusBar)

        // The command panel and the message bar work in Focus.
        app.workspace.togglePalette()
        #expect(app.workspace.paletteOpen && app.workspace.editorMode == .focus)
        app.workspace.closePalette()
        app.workspace.showMessage("A message in Focus")
        #expect(app.workspace.message == "A message in Focus" && app.workspace.editorMode == .focus)
        app.workspace.message = nil

        // Leaving Focus shows everything and stops following the pointer.
        app.workspace.setMode(.writing)
        #expect(!chrome.active && !chrome.hidesTitle && !chrome.hidesStatusBar && chrome.tracker == nil)
        #expect(!frameView.trackingAreas.contains { $0.owner === tracker })
        try move(top + 10)
        #expect(!chrome.titleShown)
        try expectPlainStorage(#require(app.workspace.editor))
    }

    /// Acceptance test 3: in Focus every paragraph outside the focus block is
    /// drawn at 45 percent of its contrast against the page, a rendered
    /// block, a pill and a raw block alike, in light and dark appearance;
    /// moving the caret moves full contrast with it, a pointer selection
    /// across three blocks draws all three at full contrast, and Code and
    /// Writing mode dim nothing. Each block is measured against itself at
    /// full contrast, because source text and rendered ink have different
    /// colours.
    @Test func focusModeDimsEveryBlockButTheFocusBlocks() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await expectFocusDimming(appearance)
        }
    }

    /// Acceptance test 4: after each of 40 caret changes the middle of the
    /// caret's line lies on the typewriter line, 40 percent down the visible
    /// height, at the first and last lines of the file too. A free scroll
    /// moves the view; the next key brings the line back. Marked text
    /// scrolls without a swap. Nothing reaches the storage or undo.
    @Test func focusModeKeepsTheCaretLineOnTheTypewriterLine() async throws {
        let app = try WritingFixture(text: focusSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let undo = try #require(editor.undoManager)
        let storage = try #require(editor.textStorage)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let model = try await enterFocus(app) { app.workspace.setMode(.focus) }
        let clip = try #require(editor.enclosingScrollView?.contentView)
        #expect(editor.textContainerInset.height == (clip.bounds.height * 0.6).rounded())

        var checks = 0
        func check(_ label: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
            checks += 1
            let caret = editor.selectedRange()
            #expect(caret.length == 0, "\(label)", sourceLocation: sourceLocation)
            guard let middle = typewriterMiddle(editor, manager, model) else {
                Issue.record("\(label): no caret line at \(caret.location)", sourceLocation: sourceLocation)
                return
            }
            let visible = editor.containerVisibleRect()
            let line = visible.minY + visible.height * 0.4
            #expect(
                abs(middle - line) <= 1,
                "\(label): caret \(caret.location) line middle \(middle), typewriter line \(line), view \(visible)",
                sourceLocation: sourceLocation,
            )
        }

        // Arrows through source and rendered blocks change nothing stored.
        let attributed = NSAttributedString(attributedString: storage)
        #expect(!undo.canUndo)
        for step in 0 ..< 18 {
            editor.moveDown(nil)
            check("down \(step)")
            expectCaretInSource(editor, manager, model)
        }
        for step in 0 ..< 6 {
            editor.moveUp(nil)
            check("up \(step)")
        }
        editor.moveToBeginningOfDocument(nil)
        #expect(editor.selectedRange().location == 0)
        check("the first line")
        editor.moveToEndOfDocument(nil)
        check("the last line")
        #expect(storage.isEqual(to: attributed), "Scrolling changed the storage's attributes")
        #expect(!undo.canUndo)
        #expect(editor.writing.typewriterAnimation == nil)

        // Typing, Return, undo, delete, page down and a command's text.
        let text = editor.string as NSString
        let middle = text.range(of: "Filler paragraph 12,")
        editor.setSelectedRange(NSRange(location: middle.location + 6, length: 0))
        check("a caret set in the text")
        editor.insertNewline(nil)
        check("Return")
        editor.insertText("Typed words in Focus.", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("typing")
        undo.undo()
        check("undo")
        #expect(!editor.string.contains("Typed words"))
        for step in 0 ..< 3 {
            editor.deleteBackward(nil)
            check("delete \(step)")
        }
        // The edited block renders after the caret leaves it: a swap above
        // the caret, later, keeps the caret's line on the typewriter line.
        let edited = (editor.string as NSString).paragraphRange(for: editor.selectedRange()).location
        let swapsBefore = editor.writing.swapCount
        editor.moveDown(nil)
        check("down from the edited paragraph")
        editor.moveDown(nil)
        check("down again")
        #expect(!role(model, editor.string as NSString, edited).isRendered)
        try await app.wait { role(model, editor.string as NSString, edited).isRendered }
        await app.layout()
        #expect(editor.writing.swapCount > swapsBefore)
        check("after the block above rendered")
        for step in 0 ..< 2 {
            editor.pageDown(nil)
            check("page down \(step)")
        }
        // The divider command's text, through the path every command takes.
        editor.insertSnippet(Snippet(text: "#line(length: 100%, stroke: 0.5pt)"), replacing: editor.selectedRange())
        check("a command's text")

        // A click in a rendered block far below the typewriter line scrolls
        // its line there over 0.2 s.
        editor.moveToBeginningOfDocument(nil)
        check("the first line again")
        await model.idle()
        await app.layout()
        let visible = editor.containerVisibleRect()
        let target = try #require(
            writingFragments(manager).last { fragment in
                fragment.isRendered && visible.contains(fragment.frame) && fragment.frame.minY > visible.midY
            },
            "No rendered block below the typewriter line",
        )
        try writingPress(editor, at: glyphCentre(manager, block: target.offset, offset: target.offset + 4))
        #expect(editor.selectedRange().length == 0)
        #expect((target.offset + 4 ... target.offset + 5).contains(editor.selectedRange().location))
        #expect(editor.writing.typewriterAnimation != nil, "The click did not animate")
        try await app.wait { editor.writing.typewriterAnimation == nil }
        check("a click")

        // A free scroll moves the view; the next key brings the line back.
        editor.moveToEndOfDocument(nil)
        check("the last line again")
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - 150))
        editor.enclosingScrollView?.reflectScrolledClipView(clip)
        let scrolled = try #require(typewriterMiddle(editor, manager, model))
        let free = editor.containerVisibleRect()
        #expect(abs(scrolled - free.minY - free.height * 0.4) > 100, "The free scroll did not move the view")
        editor.moveUp(nil)
        check("a key after a free scroll")

        // Marked text: the typewriter scroll swaps nothing, and the input
        // method's rectangle stays on the caret's line.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - 120))
        editor.enclosingScrollView?.reflectScrolledClipView(clip)
        let swaps = editor.writing.swapCount
        editor.setMarkedText(
            "zh",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        #expect(editor.hasMarkedText())
        check("marked text")
        #expect(editor.writing.swapCount == swaps, "A typewriter scroll swapped while text was marked")
        let marked = editor.firstRect(forCharacterRange: editor.markedRange(), actualRange: nil)
        let caretLine = try #require(TextKit2Geometry.caretRect(at: editor.selectedRange().location, in: manager))
        let window = try #require(editor.window)
        let screenCaret = window.convertToScreen(editor.convert(
            caretLine.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y),
            to: nil,
        ))
        #expect(abs(marked.midY - screenCaret.midY) <= 2, "Marked text \(marked), caret line \(screenCaret)")
        await app.layout()
        #expect(editor.writing.swapCount == swaps)
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        check("the composition committed")
        #expect(checks >= 40, "\(checks) caret changes")

        // The space above and below the text follows the visible height,
        // the caret line stays on the typewriter line (step E), and leaving
        // Focus restores Writing mode's space: 42 pt above the text, and
        // 64 pt below it for the floating toolbar.
        var size = try #require(app.window.contentView?.frame.size)
        size.height -= 120
        app.window.setContentSize(size)
        await app.layout()
        #expect(editor.textContainerInset.height == (clip.bounds.height * 0.6).rounded())
        check("the window got shorter")
        app.workspace.setMode(.writing)
        #expect(editor.textContainerOrigin.y == ManuscriptLayout.verticalInset)
        #expect(editor.bottomInset == ManuscriptLayout.toolbarClearance)
        #expect(editor.string == app.workspace.text)
        expectPlainStorage(editor)
    }
}

// MARK: - Fixture text and helpers

private let focusFiller = (1 ... 30)
    .map { "Filler paragraph \($0), plain text that fills the column so the document scrolls.\n\n" }
    .joined()

let focusSource = """
#set par(justify: false)

= Focus heading

A paragraph with inline math $a^2 + b^2 = c^2$ on its first source line, long enough
that Typst wraps it, then continues on a second source line with more words for the
engine to set, and ends on a third source line.

$ integral_0^1 x^2 dif x = 1/3 $

```py
def raw(): return 1
```

Plain paragraph after the code.

\(focusFiller)The last paragraph.

"""

/// Enters Focus mode through `route` and waits for the engine, the entry
/// window and the renders in view.
@MainActor
private func enterFocus(_ app: WritingFixture, _ route: () throws -> Void) async throws -> WritingLayout {
    let editor = try #require(app.workspace.editor)
    try route()
    #expect(app.workspace.editorMode == .focus)
    try await app.wait { editor.writing.isRunning && editor.writing.focused }
    let model = try #require(editor.writing.model)
    try await app.wait { editor.writing.enteredWithRenders != nil }
    await app.layout()
    await model.idle()
    await app.layout()
    await model.idle()
    return model
}

/// The column is the Focus width: 60 average characters of New York at
/// 18 pt, or the pane less 36 pt on each side.
@MainActor
private func expectFocusColumn(_ editor: ManuscriptTextView, _ label: String) {
    let width = editor.frame.width
    let column = min(ManuscriptLayout.focusColumnWidth, width - 2 * ManuscriptLayout.minimumInset)
    #expect(editor.textContainerInset.width == ManuscriptLayout.horizontalInset(for: width, focus: true), "\(label)")
    #expect(
        abs((editor.textContainer?.size.width ?? 0) - column) < 1,
        "\(label): column \(String(describing: editor.textContainer?.size)) of \(width)",
    )
}

/// Every rendered block draws at the Focus scale, for the Focus column, at
/// the engine's height times 1.4625.
@MainActor
private func expectFocusRenders(_ editor: ManuscriptTextView, _ model: WritingLayout, _ label: String) {
    guard let manager = editor.textLayoutManager, let container = editor.textContainer else {
        Issue.record("No TextKit 2 stack")
        return
    }
    var rendered = 0
    for fragment in writingFragments(manager) {
        guard case let .rendered(rendering, _) = fragment.role else {
            continue
        }
        rendered += 1
        #expect(rendering.scale == WritingMetrics.focusScale, "\(label): block at \(fragment.offset)")
        #expect(abs(rendering.scale - 1.4625) < 1e-9)
        #expect(abs(fragment.frame.height - rendering.drawnRect.height * 1.4625) < 0.5, "\(label): height")
        #expect(rendering.appearance.columnWidth == Double(container.size.width), "\(label): render width")
    }
    #expect(rendered >= 3, "\(label): \(rendered) rendered blocks in Focus")
}

/// What entering and leaving Focus mode must not change.
@MainActor
private struct FocusSnapshot: Equatable {
    let text: String
    let selection: NSRange
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String

    init(_ editor: ManuscriptTextView) {
        text = editor.string
        selection = editor.selectedRange()
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
    }
}

/// The app's menu, installed for a test, and how to put the old one back.
@MainActor
private struct FocusMenu {
    let menu: NSMenu
    let previous: (main: NSMenu?, windows: NSMenu?)
    let delegate: AppDelegate

    func choose(_ title: String) throws {
        let entries = menu.items.flatMap { $0.submenu?.items ?? [] }
        let item = try #require(entries.first { $0.title == L10n.text(title) })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    func restore() {
        NSApp.mainMenu = previous.main
        NSApp.windowsMenu = previous.windows
    }
}

@MainActor
private func installFocusMenu(_ app: WritingFixture) throws -> FocusMenu {
    let delegate = AppDelegate(workspace: app.workspace)
    let previous = (NSApp.mainMenu, NSApp.windowsMenu)
    delegate.installMenu()
    return try FocusMenu(menu: #require(NSApp.mainMenu), previous: previous, delegate: delegate)
}

// MARK: - Dimming and typewriter helpers

/// The middle of the caret's line in container coordinates: TextKit's caret
/// in source, the drawn glyph line in a rendered block.
@MainActor
private func typewriterMiddle(
    _ editor: ManuscriptTextView,
    _ manager: NSTextLayoutManager,
    _ model: WritingLayout,
) -> CGFloat? {
    let caret = editor.selectedRange().location
    if role(model, editor.string as NSString, caret) == .source {
        return TextKit2Geometry.caretRect(at: caret, in: manager)?.midY
    }
    return editor.writing.caretMiddle(caret)
}

/// Selects `range` as a pointer drag does: AppKit's tracking holds the
/// selection's updates, and the editor reports it once the drag ends.
@MainActor
private func pointerSelect(_ editor: ManuscriptTextView, _ range: NSRange) {
    editor.selectingWithMouse = true
    editor.setSelectedRange(range)
    editor.selectingWithMouse = false
    editor.selectionChanged(byPointer: true)
}

/// Ink contrast against the page in a picture of the editor's visible rect.
@MainActor
private struct FocusCanvas {
    let bitmap: NSBitmapImageRep
    let visible: CGRect
    let origin: CGPoint
    private(set) var page: [Double] = []

    init(_ editor: ManuscriptTextView) throws {
        visible = editor.visibleRect
        origin = editor.textContainerOrigin
        bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: visible))
        editor.cacheDisplay(in: visible, to: bitmap)
        // The page: the left margin, away from the stale bar.
        let margin = pixels(in: CGRect(x: -30, y: visible.minY - origin.y + 20, width: 8, height: 8))
        page = try #require(margin.first)
    }

    /// The colours of the pixels in `rect` (container coordinates), as red,
    /// green and blue from 0 to 255 in the picture's own colour space.
    func pixels(in rect: CGRect) -> [[Double]] {
        visit(rect) { [$0, $1, $2] }
    }

    private func visit<T>(_ rect: CGRect, _ body: (Double, Double, Double) -> T) -> [T] {
        let sx = CGFloat(bitmap.pixelsWide) / visible.width, sy = CGFloat(bitmap.pixelsHigh) / visible.height
        let view = rect.offsetBy(dx: origin.x - visible.minX, dy: origin.y - visible.minY)
        let minX = max(0, Int(view.minX * sx)), maxX = min(bitmap.pixelsWide - 1, Int(ceil(view.maxX * sx)) - 1)
        let minY = max(0, Int(view.minY * sy)), maxY = min(bitmap.pixelsHigh - 1, Int(ceil(view.maxY * sy)) - 1)
        guard minX <= maxX, minY <= maxY, bitmap.bitsPerSample == 8, !bitmap.isPlanar,
              let data = bitmap.bitmapData
        else {
            return []
        }
        let step = bitmap.bitsPerPixel / 8
        let first = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        var result: [T] = []
        result.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY ... maxY {
            let row = data + y * bitmap.bytesPerRow
            for x in minX ... maxX {
                let pixel = row + x * step + first
                result.append(body(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])))
            }
        }
        return result
    }

    /// The strongest ink in `rect`: the 99.9th percentile of each pixel's
    /// largest channel difference from the page.
    func peak(in rect: CGRect) -> Double {
        let page = page
        let all = visit(rect) { red, green, blue in
            max(abs(red - page[0]), abs(green - page[1]), abs(blue - page[2]))
        }.sorted()
        return all.isEmpty ? 0 : all[min(all.count - 1, all.count * 999 / 1000)]
    }

    /// The contrast of the ink in `rect`: each pixel's largest channel
    /// difference from the page; the median over the pixels with at least
    /// half the strongest contrast (the 98th percentile of the pixels that
    /// differ by more than 8 of 255). Scaling every
    /// pixel's contrast by a factor scales this by the same factor, and a
    /// selection highlight or a pill's fill, much fainter than ink, is not
    /// counted.
    func contrast(in rect: CGRect) -> Double {
        let page = page
        let all = visit(rect) { red, green, blue in
            max(abs(red - page[0]), abs(green - page[1]), abs(blue - page[2]))
        }.filter { $0 > 8 }.sorted()
        guard let strongest = all.isEmpty ? nil : all[min(all.count - 1, all.count * 98 / 100)] else {
            return 0
        }
        let ink = all.filter { $0 >= strongest / 2 }
        guard ink.count >= 40 else {
            return 0
        }
        return ink[ink.count / 2]
    }
}

/// The blocks acceptance test 3 measures, by where their text starts and ends.
@MainActor
private struct FocusBlocks {
    let pill: NSRange
    let paragraph: NSRange
    let equation: NSRange
    let raw: NSRange
    let plain: NSRange

    init(_ text: NSString) {
        func block(_ start: String, _ end: String) -> NSRange {
            let first = text.range(of: start).location
            return NSRange(location: first, length: NSMaxRange(text.range(of: end)) - first)
        }
        pill = text.range(of: "#set par(justify: false)")
        paragraph = block("A paragraph with inline math", "ends on a third source line.")
        equation = text.range(of: "$ integral_0^1 x^2 dif x = 1/3 $")
        raw = block("```py", "def raw(): return 1\n```")
        plain = text.range(of: "Plain paragraph after the code.")
    }
}

/// Where `block`'s fragments draw it: the union of its paragraphs' frames,
/// across the column (an equation's image is centred in it, beyond the
/// width of its source line).
@MainActor
private func drawnRect(_ manager: NSTextLayoutManager, _ block: NSRange) -> CGRect {
    let column = manager.textContainer?.size.width ?? 0
    return writingFragments(manager)
        .filter { $0.offset >= block.location && $0.offset < NSMaxRange(block) && $0.frame.height > 0 }
        .map { CGRect(x: 0, y: $0.frame.minY, width: column, height: $0.frame.height) }
        .reduce(CGRect.null) { $0.union($1) }
}

/// Acceptance test 3 in one appearance.
@MainActor
private func expectFocusDimming(_ appearance: NSAppearance.Name) async throws {
    let app = try WritingFixture(text: focusSource, startService: false)
    defer { app.close() }
    app.window.appearance = NSAppearance(named: appearance)
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let manager = try #require(editor.textLayoutManager)
    let storage = try #require(editor.textStorage)
    let text = editor.string as NSString
    let blocks = FocusBlocks(text)
    let name = appearance == .aqua ? "light" : "dark"
    // The caret is not ink of the block it is in.
    editor.insertionPointColor = .clear

    // The caret in the plain paragraph: it is the focus block.
    editor.setSelectedRange(NSRange(location: blocks.plain.location + 3, length: 0))
    let model = try await enterFocus(app) { app.workspace.setMode(.focus) }
    let attributed = NSAttributedString(attributedString: storage)
    let undoState = (editor.undoManager?.canUndo, editor.undoManager?.canRedo)

    // Shows the blocks from the pill down and measures each one's ink.
    func measure(_ label: String) async throws -> [String: Double] {
        await model.idle()
        await app.layout()
        editor.scrollContainer(to: drawnRect(manager, blocks.pill).minY - 8)
        editor.prepareForPointerInteraction()
        await app.layout()
        let canvas = try FocusCanvas(editor)
        try writingSave(canvas.bitmap, "focus-dimming-\(name)-\(label).png")
        var result: [String: Double] = [:]
        let named = [("pill", blocks.pill), ("paragraph", blocks.paragraph), ("equation", blocks.equation),
                     ("raw", blocks.raw), ("plain", blocks.plain)]
        for (key, block) in named {
            let rect = drawnRect(manager, block)
            #expect(
                canvas.visible.offsetBy(dx: -canvas.origin.x, dy: -canvas.origin.y).contains(rect),
                "\(name) \(label): \(key) \(rect) is not in view",
            )
            result[key] = canvas.contrast(in: rect)
            result["peak " + key] = canvas.peak(in: rect)
            #expect(result[key, default: 0] > 20, "\(name) \(label): no ink in \(key)")
        }
        return result
    }
    func dimmed(_ block: NSRange) -> Bool {
        let paragraph = text.paragraphRange(for: NSRange(location: block.location, length: 0))
        return editor.writing.dims(paragraphAt: paragraph.location)
    }
    func expectRatio(
        _ low: Double?,
        _ high: Double?,
        _ label: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation,
    ) {
        guard let low, let high, high > 0 else {
            Issue.record("\(name) \(label): no measurement", sourceLocation: sourceLocation)
            return
        }
        #expect(
            abs(low / high - 0.45) <= 0.03,
            "\(name) \(label): \(low) / \(high) = \(low / high)",
            sourceLocation: sourceLocation,
        )
    }

    // The plain paragraph is the focus block; the rest is dimmed.
    let rawIndex = try #require(model.blocks.firstIndex { $0.range.location == blocks.raw.location })
    #expect(model.state(ofBlockAt: rawIndex) == .source(.raw))
    #expect(!dimmed(blocks.plain))
    #expect(dimmed(blocks.pill) && dimmed(blocks.paragraph) && dimmed(blocks.raw) && dimmed(blocks.equation))
    let caretInPlain = try await measure("caret-in-plain")
    #expect(role(model, text, blocks.paragraph.location).isRendered)

    // The paragraph and the pill at full contrast, each through a pointer
    // selection of its last line's end, which draws no highlight over a
    // rendered block (the pill is highlighted whole; its label is ink).
    pointerSelect(editor, NSRange(location: NSMaxRange(blocks.paragraph), length: 1))
    #expect(!dimmed(blocks.paragraph) && dimmed(blocks.plain))
    #expect(role(model, text, blocks.paragraph.location).isRendered)
    let paragraphFocused = try await measure("paragraph-selected")
    expectRatio(caretInPlain["paragraph"], paragraphFocused["paragraph"], "rendered paragraph")
    pointerSelect(editor, NSRange(location: NSMaxRange(blocks.pill), length: 1))
    #expect(!dimmed(blocks.pill) && dimmed(blocks.paragraph))
    let pillFocused = try await measure("pill-selected")
    expectRatio(caretInPlain["pill"], pillFocused["pill"], "pill")

    // A pointer selection across three blocks: all three at full contrast.
    let across = NSRange(
        location: NSMaxRange(blocks.paragraph) - 4,
        length: blocks.raw.location + 3 - (NSMaxRange(blocks.paragraph) - 4),
    )
    pointerSelect(editor, across)
    #expect(editor.writing.pointerSelection == across)
    #expect(!dimmed(blocks.paragraph) && !dimmed(blocks.equation) && !dimmed(blocks.raw))
    #expect(dimmed(blocks.pill) && dimmed(blocks.plain))
    #expect(role(model, text, blocks.paragraph.location).isRendered)
    #expect(role(model, text, blocks.equation.location).isRendered)
    let threeSelected = try await measure("three-selected")
    // The highlight under the selected text is part of the picture, and the
    // equation is selected whole, so this compares the strongest ink.
    for key in ["paragraph", "equation", "raw"] {
        let ratio = (caretInPlain["peak " + key] ?? 0) / (threeSelected["peak " + key] ?? 1)
        #expect(abs(ratio - 0.45) <= 0.03, "\(name): \(key) dimmed at \(ratio) of a three-block selection")
    }

    // The caret into the raw block, which stays source: full contrast moves
    // with it in the next draw.
    editor.setSelectedRange(NSRange(location: text.range(of: "def raw()").location + 2, length: 0))
    #expect(!dimmed(blocks.raw) && dimmed(blocks.plain) && dimmed(blocks.paragraph))
    let caretInRaw = try await measure("caret-in-raw")
    expectRatio(caretInPlain["raw"], caretInRaw["raw"], "raw block")
    expectRatio(caretInRaw["paragraph"], paragraphFocused["paragraph"], "rendered paragraph, caret in the raw block")
    // The plain paragraph, the focus block before, now renders dimmed;
    // against itself rendered at full contrast (a pointer selection of its
    // line end keeps it rendered).
    #expect(role(model, text, blocks.plain.location).isRendered && dimmed(blocks.plain))
    pointerSelect(editor, NSRange(location: NSMaxRange(blocks.plain), length: 1))
    #expect(!dimmed(blocks.plain) && role(model, text, blocks.plain.location).isRendered)
    let plainFocused = try await measure("plain-selected")
    expectRatio(caretInRaw["plain"], plainFocused["plain"], "plain paragraph, the focus block before")

    // Back into the raw block. It stays source and the plain paragraph stays
    // rendered, so only the change of focus lays them out again
    // (`invalidateLayout(for:)`, as a swap does); blocks that stay dimmed
    // are left alone.
    let swaps = editor.writing.swapCount
    editor.setSelectedRange(NSRange(location: text.range(of: "def raw()").location + 2, length: 0))
    let laidOut = editor.writing.refocused
    for block in [blocks.raw, blocks.plain] {
        #expect(laidOut.contains { NSLocationInRange(block.location, $0) }, "\(name): \(block) not laid out again")
    }
    for block in [blocks.pill, blocks.paragraph, blocks.equation] {
        #expect(!laidOut.contains { NSLocationInRange(block.location, $0) }, "\(name): \(block) laid out again")
    }
    #expect(editor.writing.swapCount > swaps)

    // Dimming changed nothing stored.
    #expect(storage.isEqual(to: attributed), "\(name): dimming changed the storage's attributes")
    #expect((editor.undoManager?.canUndo, editor.undoManager?.canRedo) == undoState)

    // Writing and Code mode dim nothing.
    app.workspace.setMode(.writing)
    await app.layout()
    #expect(editor.writing.focusSpans == nil && !dimmed(blocks.paragraph) && !dimmed(blocks.plain))
    let writing = try await measure("writing")
    #expect(abs((writing["raw"] ?? 0) / (caretInRaw["raw"] ?? 1) - 1) <= 0.03, "\(name): raw block in Writing mode")
    #expect(
        (writing["paragraph"] ?? 0) / (paragraphFocused["paragraph"] ?? 1) > 0.9,
        "\(name): paragraph in Writing mode",
    )
    #expect((writing["pill"] ?? 0) / (pillFocused["pill"] ?? 1) > 0.9, "\(name): pill in Writing mode")
    app.workspace.setMode(.code)
    await app.layout()
    let code = try await measure("code")
    #expect(abs((code["raw"] ?? 0) / (caretInRaw["raw"] ?? 1) - 1) <= 0.03, "\(name): raw block in Code mode")
    #expect(
        abs((code["plain"] ?? 0) / (caretInPlain["plain"] ?? 1) - 1) <= 0.03,
        "\(name): plain paragraph in Code mode",
    )
    #expect(editor.string == app.workspace.text)
    expectPlainStorage(editor)
}
