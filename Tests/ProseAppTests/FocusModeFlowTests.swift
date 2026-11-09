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
