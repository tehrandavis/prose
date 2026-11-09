import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

/// Phase 4 step E: the floating toolbar (acceptance tests 7 and 8 of
/// `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`), on the real
/// window, editor, engine and Tinymist.
extension WritingFlowTests {
    /// Acceptance test 7: the toolbar shows in Writing and Focus mode, not in
    /// Code mode or with the editor pane hidden. Each button makes the same
    /// calls as its `⌘J` keys, with the same records; `equation` and `table`
    /// (default parameters, form confirmed) give the same text and selection
    /// as the panel on the same document and selection.
    @Test func floatingToolbarRunsTheSameCommandsAsTheCommandPanel() async throws {
        let app = try WritingFixture(text: toolbarSource)
        defer { app.close() }
        app.window.orderFront(nil)
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let undo = try #require(editor.undoManager)

        // Code mode: no toolbar, and the text has the usual space below it.
        #expect(!app.workspace.showsFloatingToolbar)
        #expect(toolbarAnchors(app).isEmpty && toolbarButtons(app).isEmpty)
        #expect(editor.textContainerOrigin.y == ManuscriptLayout.verticalInset)
        #expect(editor.bottomInset == ManuscriptLayout.verticalInset)

        let start = (toolbarSource as NSString).range(of: "words").location
        editor.setSelectedRange(NSRange(location: start, length: 0))
        _ = try await enterWritingMode(app)
        #expect(app.workspace.showsFloatingToolbar)
        expectToolbar(app, shown: true, "Writing mode")
        // Writing mode: 64 pt below the text for the toolbar, the top unchanged.
        #expect(editor.textContainerOrigin.y == ManuscriptLayout.verticalInset)
        #expect(editor.bottomInset == ManuscriptLayout.toolbarClearance)
        #expect(editor.textContainerInset.height == (ManuscriptLayout.verticalInset + 64) / 2)
        let manager = try #require(editor.textLayoutManager)
        let end = (editor.string as NSString).length
        editor.reveal(NSRange(location: end, length: 0))
        editor.scrollContainer(to: .greatestFiniteMagnitude)
        let last = try #require(TextKit2Geometry.caretRect(at: end, in: manager))
        // NSTextView sizes the view to its text height (the last line and
        // about 1.4 pt) plus the insets.
        let below = editor.frame.height - (last.maxY + editor.textContainerOrigin.y)
        #expect(
            below >= ManuscriptLayout.toolbarClearance && below < ManuscriptLayout.toolbarClearance + 2,
            "\(below) pt below the last line; frame \(editor.frame), last line \(last)",
        )
        // At the end of the text the last line clears the toolbar.
        let buttons = toolbarButtons(app)
        let style = try #require(buttons[.style])
        let toolbarTop = style.convert(style.bounds, to: editor).minY - FloatingToolbar.padding
        #expect(last.maxY + editor.textContainerOrigin.y < toolbarTop, "last line \(last), toolbar at \(toolbarTop)")
        editor.setSelectedRange(NSRange(location: start, length: 0))

        // The editor pane hidden: no toolbar.
        app.workspace.layout = .preview
        await app.layout()
        #expect(!app.workspace.showsFloatingToolbar)
        expectToolbar(app, shown: false, "preview layout")
        app.workspace.layout = .split
        await app.layout()
        expectToolbar(app, shown: true, "split layout")

        // Each button against its keys in the panel. The group buttons open
        // the panel at their group; the command buttons select their command.
        let keys: [ToolbarAction: [(String, UInt16)]] = [
            .style: [("s", 1)], .insert: [("i", 34)],
            .table: [("i", 34), ("t", 17)], .equation: [("i", 34), ("e", 14)], .image: [("i", 34), ("i", 34)],
        ]
        for action in ToolbarAction.allCases {
            let source = editor.string
            let selection = NSRange(location: (source as NSString).range(of: "Last paragraph").location, length: 0)
            func run(_ path: () -> Void) async throws -> ToolbarOutcome {
                editor.setSelectedRange(selection)
                app.window.makeFirstResponder(editor)
                let mark = commandEvents(app).count
                path()
                await app.layout()
                if action == .table, let table = action.command {
                    #expect(app.workspace.activeCommand?.id == "table")
                    app.workspace.execute(table)
                }
                if action == .table || action == .equation {
                    try await app.wait { !app.workspace.applyingCommand && !app.workspace.paletteOpen }
                    await app.layout()
                }
                let outcome = ToolbarOutcome(
                    text: editor.string,
                    selection: editor.selectedRange(),
                    group: app.workspace.paletteGroup,
                    command: app.workspace.activeCommand?.id,
                    paletteOpen: app.workspace.paletteOpen,
                    events: Array(commandEvents(app).dropFirst(mark)),
                )
                if app.workspace.paletteOpen {
                    app.workspace.closePalette()
                }
                if editor.string != source {
                    undo.undo()
                }
                #expect(editor.string == source, "\(action): undo restores the text")
                return outcome
            }
            let panel = try await run {
                app.window.sendEvent(app.key(app.workspace.commandKey, code: 38, modifiers: .command))
                for (key, code) in keys[action] ?? [] {
                    app.window.sendEvent(app.key(key, code: code))
                }
            }
            // The button's own press, as VoiceOver or a click makes it.
            let toolbar = try await run {
                #expect(toolbarButtons(app)[action]?.accessibilityPerformPress() == true)
            }
            #expect(panel == toolbar, "\(action): panel \(panel), toolbar \(toolbar)")
            #expect(!panel.events.isEmpty, "\(action)")
            switch action {
            case .style, .insert:
                #expect(toolbar.paletteOpen && toolbar.group == action.group?.id && toolbar.command == nil)
                #expect(toolbar.events.contains("palette.group \(action.group?.id ?? "")"))
            case .image:
                #expect(toolbar.paletteOpen && toolbar.command == "image")
                #expect(toolbar.events.contains("command.selected image"))
            case .table, .equation:
                #expect(!toolbar.paletteOpen && toolbar.text != source, "\(action) inserted")
                #expect(toolbar.events.contains("command.execute \(action.rawValue)"))
                #expect(toolbar.events.contains("insertion.finished \(action.rawValue)"))
            }
            #expect(app.window.firstResponder === editor, "\(action): the editor is first responder again")
        }
        #expect(app.workspace.layout == .split)
        #expect(editor.string == toolbarSource)
        expectPlainStorage(editor)

        // Focus mode shows it; leaving for Code mode removes it and its space.
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.enteredWithRenders != nil }
        await app.layout()
        expectToolbar(app, shown: true, "Focus mode")
        app.workspace.setMode(.code)
        await app.layout()
        expectToolbar(app, shown: false, "Code mode again")
        #expect(editor.bottomInset == ManuscriptLayout.verticalInset)
        #expect(editor.string == toolbarSource)
        expectPlainStorage(editor)
    }

    /// Acceptance test 8: a click on a toolbar button leaves the editor first
    /// responder (the click itself takes no focus) and the command uses the
    /// editor's selection: Text style, then Bold, wraps it. Each button has
    /// its label, identifier and help with the key path. In Focus mode the
    /// toolbar hides while the user types, comes back when the pointer
    /// moves, sits above the status bar while that shows, and a command from
    /// it leaves the caret line on the typewriter line.
    @Test func floatingToolbarKeepsTheEditorFocusedAndFollowsFocusMode() async throws {
        let app = try WritingFixture(text: toolbarSource)
        defer { app.close() }
        app.window.orderFront(nil)
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        _ = try await enterWritingMode(app)
        expectToolbar(app, shown: true, "Writing mode")

        // Label, identifier and help of each button.
        let anchors = toolbarAnchors(app)
        #expect(anchors.count == ToolbarAction.allCases.count)
        for action in ToolbarAction.allCases {
            let anchor = try #require(anchors[action], "\(action)")
            #expect(anchor.title == action.title)
            #expect(anchor.shortcut == "⌘\(app.workspace.commandKey.uppercased()) → \(action.keyPath)")
            #expect(anchor.detail == action.detail && !action.detail.isEmpty)
            anchor.showHelp()
            #expect(anchor.popover != nil)
            anchor.dismiss()
            let button = try #require(toolbarButtons(app)[action], "\(action.identifier)")
            #expect(button.accessibilityLabel() == action.title)
            #expect(button.accessibilityIdentifier() == action.identifier)
            #expect(button.accessibilityRole() == .button)
            #expect(button.accessibilityHelp() == "\(action.detail) · \(app.workspace.toolbarShortcut(for: action))")
            #expect(!button.acceptsFirstResponder && !button.canBecomeKeyView)
            #expect(!app.window.makeFirstResponder(button) || app.window.firstResponder !== button)
            #expect(button.bounds.size == NSSize(width: 30, height: 30))
        }
        #expect(ToolbarAction.style.title == "Text Style" && ToolbarAction.style.keyPath == "s")
        #expect(ToolbarAction.table.keyPath == "i t" && ToolbarAction.equation.keyPath == "i e")
        #expect(ToolbarAction.image.keyPath == "i i" && ToolbarAction.insert.keyPath == "i")
        #expect(ToolbarAction.allCases.map(\.icon) == ["text-aa", "table", "function", "image", "plus"])
        #expect(ToolbarAction.allCases.allSatisfy { IconStore.image($0.icon) != nil })

        // A real click on Text style: the click leaves the editor first
        // responder until the panel opens; Bold then wraps the selection.
        let words = (editor.string as NSString).range(of: "words to style")
        editor.setSelectedRange(words)
        app.window.makeFirstResponder(editor)
        try click(app, #require(toolbarButtons(app)[.style]))
        #expect(app.workspace.paletteOpen && app.workspace.paletteGroup == "style")
        let record = try #require(commandRecords(app).last { $0.event == "toolbar.action" })
        #expect(record.fields["action"] == "style")
        #expect(record.fields["editorFirstResponder"] == "true", "The click made something else first responder")
        #expect(!(app.window.firstResponder is NSHostingView<ContentView>))
        app.window.sendEvent(app.key("b", code: 11))
        try await app.wait { !app.workspace.applyingCommand && !app.workspace.paletteOpen }
        await app.layout()
        #expect(editor.string.contains("*words to style*"))
        #expect(app.window.firstResponder === editor)
        try #require(editor.undoManager).undo()
        #expect(editor.string == toolbarSource)

        // Every button's click keeps the editor first responder at the click.
        for action in ToolbarAction.allCases {
            editor.setSelectedRange(NSRange(location: words.location, length: 0))
            app.window.makeFirstResponder(editor)
            try click(app, #require(toolbarButtons(app)[action]))
            let record = try #require(commandRecords(app).last { $0.event == "toolbar.action" })
            #expect(record.fields["action"] == action.rawValue)
            #expect(record.fields["editorFirstResponder"] == "true", "\(action)")
            try await app.wait { !app.workspace.applyingCommand }
            if app.workspace.paletteOpen {
                app.workspace.closePalette()
            }
            if editor.string != toolbarSource {
                try #require(editor.undoManager).undo()
            }
            #expect(editor.string == toolbarSource)
            #expect(app.window.firstResponder === editor)
        }

        // Writing mode: always shown, 16 pt above the pane's bottom edge, which
        // lies on the status bar.
        let chrome = app.workspace.focusChrome
        editor.keyDown(with: app.key("\u{f701}", code: 125))
        #expect(!chrome.toolbarHidden)
        let writingBottom = try toolbarBottom(app)
        #expect(abs(writingBottom - ContentView.statusBarHeight - FloatingToolbar.bottomMargin) < 1)

        // Focus mode: hides on typing, shows on pointer movement.
        chrome.hideDelay = .milliseconds(150)
        editor.setSelectedRange(NSRange(location: words.location, length: 0))
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.enteredWithRenders != nil }
        await app.layout()
        let tracker = try #require(chrome.tracker)
        #expect(!chrome.toolbarHidden)
        let focusBottom = try toolbarBottom(app)
        #expect(abs(focusBottom - FloatingToolbar.bottomMargin) < 1, "\(focusBottom)")
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
        editor.keyDown(with: app.key("x", code: 7))
        #expect(chrome.toolbarHidden)
        #expect(editor.string != toolbarSource)
        await app.layout()
        expectToolbar(app, shown: false, "typing in Focus")
        // A command shortcut is not typing.
        try move(300)
        #expect(!chrome.toolbarHidden)
        chrome.keyTyped(app.key("c", code: 8, modifiers: .command))
        #expect(!chrome.toolbarHidden)
        editor.keyDown(with: app.key("\u{f702}", code: 123))
        #expect(chrome.toolbarHidden)
        try move(300)
        #expect(!chrome.toolbarHidden)
        await app.layout()
        expectToolbar(app, shown: true, "pointer moved in Focus")
        try #require(editor.undoManager).undo()
        #expect(editor.string == toolbarSource)

        // With Focus mode's status bar shown, the toolbar sits above it.
        try move(10)
        #expect(!chrome.hidesStatusBar)
        await app.layout()
        let raised = try toolbarBottom(app)
        #expect(abs(raised - ContentView.statusBarHeight - FloatingToolbar.bottomMargin) < 1, "\(raised)")
        try move(300)
        try await app.wait { chrome.hidesStatusBar }

        // A command from the toolbar in Focus scrolls as keys do: once the
        // panel has closed and the pane has its full height again, the caret
        // line lies on the typewriter line. With a selection the equation
        // wraps it and leaves an empty selection after it.
        let target = (editor.string as NSString).range(of: "x + y")
        editor.setSelectedRange(NSRange(location: target.location, length: 0))
        await app.layout()
        editor.setSelectedRange(target)
        app.workspace.performToolbarAction(.equation)
        try await app.wait { !app.workspace.applyingCommand && !app.workspace.paletteOpen }
        await app.layout()
        await app.layout()
        #expect(editor.string.contains("$ x + y $"))
        let caret = editor.selectedRange()
        #expect(caret.length == 0)
        let middle = try #require(editor.writing.caretMiddleInView(caret.location))
        let line = WritingController.typewriterFraction * editor.containerVisibleRect().height
        #expect(abs(middle - line) <= 1, "caret line \(middle), typewriter line \(line)")
        #expect(app.window.firstResponder === editor)
        try #require(editor.undoManager).undo()
        #expect(editor.string == toolbarSource)

        // Leaving Focus shows the toolbar whatever typing did.
        editor.keyDown(with: app.key("\u{f701}", code: 125))
        #expect(chrome.toolbarHidden)
        app.workspace.setMode(.writing)
        #expect(!chrome.toolbarHidden)
        #expect(editor.string == toolbarSource)
        expectPlainStorage(editor)
    }
}

private let toolbarSource = """
= Toolbar

Some words to style here, in a paragraph long enough to read as prose.

\(selectionFiller)Last paragraph, with x + y in it.

"""

/// What a button or its keys left behind.
private struct ToolbarOutcome: Equatable {
    let text: String
    let selection: NSRange
    let group: String?
    let command: String?
    let paletteOpen: Bool
    /// The panel's records, as "event detail".
    let events: [String]
}

private struct CommandRecord {
    let event: String
    let fields: [String: String]
}

@MainActor
private func commandRecords(_ app: WritingFixture) -> [CommandRecord] {
    let log = app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl")
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["event"] as? String
        else {
            return nil
        }
        return CommandRecord(event: event, fields: object["fields"] as? [String: String] ?? [:])
    }
}

/// The panel's records, without the toolbar's own and without the fields
/// (document version, selection) that differ between two runs.
@MainActor
private func commandEvents(_ app: WritingFixture) -> [String] {
    let names: Set = [
        "palette.toggle", "palette.group", "palette.close", "command.selected", "command.execute",
        "insertion.begin", "insertion.finished", "insertion.cancelled", "insertion.failed",
    ]
    return commandRecords(app).filter { names.contains($0.event) }.map { record in
        let detail = record.fields["group"] ?? record.fields["command"] ?? ""
        return detail.isEmpty ? record.event : "\(record.event) \(detail)"
    }
}

@MainActor
private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else {
        return []
    }
    return [view] + view.subviews.flatMap { descendants($0) }
}

/// The toolbar buttons' help anchors, which lie over the buttons.
@MainActor
private func toolbarAnchors(_ app: WritingFixture) -> [ToolbarAction: HelpAnchor] {
    var anchors: [ToolbarAction: HelpAnchor] = [:]
    for anchor in descendants(app.window.contentView).compactMap({ $0 as? HelpAnchor }) {
        guard let action = ToolbarAction.allCases.first(where: {
            $0.title == anchor.title && anchor.shortcut == app.workspace.toolbarShortcut(for: $0)
        }) else {
            continue
        }
        anchors[action] = anchor
    }
    return anchors
}

/// The toolbar's buttons, by action.
@MainActor
private func toolbarButtons(_ app: WritingFixture) -> [ToolbarAction: ToolbarButtonView] {
    Dictionary(
        descendants(app.window.contentView).compactMap { $0 as? ToolbarButtonView }.map { ($0.action, $0) },
        uniquingKeysWith: { first, _ in first },
    )
}

/// Checks that the toolbar is or is not usable: its five buttons on top
/// under the pointer, pressable and in the accessibility tree; or absent, or
/// present but hidden from both.
@MainActor
private func expectToolbar(
    _ app: WritingFixture,
    shown: Bool,
    _ label: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) {
    let buttons = toolbarButtons(app)
    if shown {
        #expect(buttons.count == ToolbarAction.allCases.count, "\(label)", sourceLocation: sourceLocation)
    }
    for (action, button) in buttons {
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = app.window.contentView?.superview?.hitTest(center)
        #expect(button.enabled == shown, "\(label): \(action)", sourceLocation: sourceLocation)
        #expect(button.isAccessibilityElement() == shown, "\(label): \(action)", sourceLocation: sourceLocation)
        #expect(button.isAccessibilityHidden() == !shown, "\(label): \(action)", sourceLocation: sourceLocation)
        #expect(
            (hit === button) == shown,
            "\(label): \(action) hit \(String(describing: hit))",
            sourceLocation: sourceLocation,
        )
    }
}

/// The toolbar's bottom edge above the window's bottom, from its buttons and
/// its padding.
@MainActor
private func toolbarBottom(_ app: WritingFixture) throws -> CGFloat {
    let button = try #require(toolbarButtons(app)[.style])
    return button.convert(button.bounds, to: nil).minY - FloatingToolbar.padding
}

/// A click in the middle of `view`, through the window as AppKit delivers it.
@MainActor
private func click(_ app: WritingFixture, _ view: NSView) throws {
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        try app.window.sendEvent(#require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: app.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1,
        )))
    }
}
