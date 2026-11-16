import AppKit
@testable import ProseApp
import ProseCore
import Testing

/// `⌘W`, the red close button and `⌘Q` (Phase 7, decision 7). Tests never
/// call `performClose` on the writing window or click its close button: once
/// the delegate refuses, that ends the test host's run loop. They call
/// `closeFront` and `windowShouldClose` directly, and replace the terminator.
extension WritingFlowTests {
    /// `⌘W` closes Settings, an auxiliary window or a sheet when one of them is
    /// in front, and leaves the document open.
    @Test func closeCommandUsesTheWindowResponder() async throws {
        let source = "= Keep this document open\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        var terminations = 0
        delegate.terminateApplication = { terminations += 1 }
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
            app.window.delegate = nil
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        delegate.installMenu()
        app.window.delegate = delegate
        app.window.orderFront(nil)
        let menu = try #require(NSApp.mainMenu)
        let close = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.keyEquivalent == "w" })
        #expect(close.title == L10n.text("Close Document"))
        // Its own action, so `⌘W` and the red button can differ.
        #expect(close.target === delegate)
        #expect(close.action == #selector(AppDelegate.closeFront(_:)))
        #expect(delegate.validateMenuItem(close))
        let action = try #require(close.action)
        #expect(menu.performKeyEquivalent(with: app.key(",", code: 43, modifiers: .command)))
        let settings = try #require(NSApp.windows.first {
            $0 !== app.window && $0.isVisible && $0.title == L10n.text("Settings")
        })
        defer { settings.close() }
        // A test host's windows cannot become key; the delegate is told which one is.
        delegate.keyWindow = { settings }
        #expect(NSApp.sendAction(action, to: close.target, from: close))
        #expect(!settings.isVisible)
        #expect(app.window.isVisible)
        #expect(!app.workspace.isLibraryHome)
        #expect(app.workspace.fileURL == app.document)
        #expect(app.workspace.text == source)

        // A different auxiliary window uses the same action, without a settings special case.
        let auxiliary = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false,
        )
        auxiliary.isReleasedWhenClosed = false
        placeOnTestScreen(auxiliary)
        auxiliary.orderFront(nil)
        defer { auxiliary.close() }
        delegate.keyWindow = { auxiliary }
        #expect(NSApp.sendAction(action, to: close.target, from: close))
        #expect(!auxiliary.isVisible)
        #expect(app.workspace.fileURL == app.document)

        // A sheet on the writing window closes, as Escape does; the document stays.
        app.workspace.openLibrary()
        try await app.wait { app.window.attachedSheet != nil }
        let sheet = try #require(app.window.attachedSheet)
        delegate.keyWindow = { sheet }
        delegate.closeFront(nil)
        try await app.wait { app.window.attachedSheet == nil }
        #expect(!app.workspace.libraryOpen)
        #expect(app.workspace.fileURL == app.document)
        #expect(app.workspace.text == source)
        app.workspace.newFromTemplate()
        try await app.wait { app.window.attachedSheet != nil }
        delegate.keyWindow = { app.window.attachedSheet }
        delegate.closeFront(nil)
        try await app.wait { app.window.attachedSheet == nil }
        #expect(app.workspace.discoveryMode == nil)
        #expect(app.workspace.fileURL == app.document)
        #expect(terminations == 0)
    }

    /// Acceptance test 9. With nothing to step back to, `⌘W` saves the document
    /// and shows a blank page; it no longer returns to the document opened
    /// before, which stays in recents.
    @Test func closeCommandOnADocumentShowsABlankPage() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        var ids: [String: UUID] = [:]
        for name in ["First", "Second"] {
            try await library.create(title: name, text: "= \(name)\n")
            let id = try #require(app.workspace.managedDocumentID)
            ids[name] = id
        }
        let first = try #require(ids["First"]), second = try #require(ids["Second"])
        try await library.open(first)
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved ending.\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let delegate = AppDelegate(workspace: app.workspace)
        var terminations = 0
        delegate.terminateApplication = { terminations += 1 }
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
        }
        delegate.installMenu()

        // Settings in front: `⌘W` closes Settings and leaves the document open.
        let menu = try #require(NSApp.mainMenu)
        #expect(menu.performKeyEquivalent(with: app.key(",", code: 43, modifiers: .command)))
        let settings = try #require(NSApp.windows.first {
            $0 !== app.window && $0.isVisible && $0.title == L10n.text("Settings")
        })
        defer { settings.close() }
        delegate.keyWindow = { settings }
        delegate.closeFront(nil)
        #expect(!settings.isVisible)
        #expect(app.workspace.managedDocumentID == first)
        #expect(app.workspace.editor?.string.hasSuffix("Unsaved ending.\n") == true)

        // The writing window in front: the document closes to a blank page.
        delegate.keyWindow = { app.window }
        delegate.closeFront(nil)
        try await app.wait {
            library.blankPageID != nil && app.workspace.managedDocumentID == library.blankPageID &&
                !app.workspace.documentTransitionInProgress
        }
        #expect(terminations == 0)
        #expect(!app.workspace.isLibraryHome)
        #expect(!app.workspace.libraryOpen)
        #expect(app.workspace.discoveryMode == nil)
        #expect(app.workspace.text == DocumentTemplate.blank.source)
        #expect(app.workspace.editorMode == .writing)
        #expect(app.workspace.editor?.isEditable == true)
        #expect(try await library.store.read(first).text == "= First\nUnsaved ending.\n")
        #expect(try await library.store.read(second).text == "= Second\n")
        #expect(Array(library.recentDocumentIDs.prefix(2)) == [first, second], "Close keeps the document in recents")
        #expect(try await library.store.list().count == 3, "Closing never removes writing from the library")
        #expect(library.listedDocuments.count == 2, "Only the hidden blank page is new")
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= External\n")
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("document.closeToBlankPage"))
    }

    /// `⌘W` after a relaunch, with no navigation history: a blank page, and the
    /// recent list (from disk) keeps every entry; documents that were trashed or
    /// removed elsewhere are not offered as reopenable.
    @Test func closeDocumentAfterARelaunchShowsABlankPageAndKeepsRecents() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        var ids: [UUID] = []
        for name in ["First", "Second", "Third"] {
            try await library.create(title: name, text: "= \(name)\n")
            try ids.append(#require(app.workspace.managedDocumentID))
        }
        let (first, second, third) = (ids[0], ids[1], ids[2])
        #expect(library.recentDocumentIDs == [third, second, first])
        // Trashed elsewhere (another Mac or an agent) without this window noticing.
        _ = try await library.store.trash(second)
        let missing = UUID()
        try JSONEncoder().encode([third, missing, second, first]).write(
            to: app.workspace.stateDirectory.appendingPathComponent("recent-documents.json"),
        )
        #expect(app.workspace.prepareToClose())
        library.stop()

        // Restores the snapshot as saved (not the launch setting) to reach the
        // document after a relaunch.
        let relaunched = Workspace(stateDirectory: app.workspace.stateDirectory)
        defer { relaunched.shutdown() }
        await relaunched.library.start()
        #expect(relaunched.managedDocumentID == third)
        #expect(relaunched.library.reopenableRecentIDs == [third, first])
        relaunched.closeDocument()
        try await app.wait {
            relaunched.library.blankPageID != nil &&
                relaunched.managedDocumentID == relaunched.library.blankPageID &&
                !relaunched.documentTransitionInProgress
        }
        #expect(!relaunched.isLibraryHome)
        #expect(relaunched.discoveryMode == nil)
        #expect(relaunched.text == DocumentTemplate.blank.source)
        #expect(relaunched.library.recentDocumentIDs == [third, missing, second, first])
        #expect(try await relaunched.library.store.read(third).text == "= Third\n")
        #expect(try await relaunched.library.store.read(first).text == "= First\n")
    }

    /// Acceptance test 10. `⌘W` on an untouched blank page quits; the red close
    /// button quits from a document with unsaved text, and the quit path saves it.
    @Test func closeCommandOnABlankPageAndTheCloseButtonQuit() async throws {
        let source = "= Close me\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        var terminations = 0
        delegate.terminateApplication = { terminations += 1 }
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        delegate.keyWindow = { app.window }
        let guardian = TerminationGuard()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = guardian
        app.window.delegate = delegate
        defer { app.window.delegate = nil
            NSApp.delegate = previousDelegate
        }
        app.window.orderFront(nil)
        #expect(app.window.styleMask.contains(.closable))
        #expect(app.window.standardWindowButton(.closeButton)?.isEnabled == true)

        // The red button on a document with unsaved text.
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved."),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        #expect(app.workspace.text != app.workspace.savedText)
        #expect(!delegate.windowShouldClose(app.window))
        #expect(terminations == 1)
        #expect(guardian.requests == 0, "Only the injected terminator runs")
        #expect(app.window.isVisible, "The window stays until the app terminates")
        #expect(app.workspace.fileURL == app.document, "The close button does not close the document first")
        // The quit path saves.
        switch delegate.applicationShouldTerminate(NSApp) {
        case .terminateNow:
            break
        case .terminateLater:
            try await app.wait { replies == [true] }
        default:
            Issue.record("Quit was cancelled")
        }
        #expect(try String(contentsOf: app.document, encoding: .utf8) == source + "Unsaved.")

        // `⌘W` on an untouched blank page quits; so does the red button there.
        try await app.workspace.library.openBlankPage()
        #expect(app.workspace.isOnUntouchedBlankPage)
        delegate.closeFront(nil)
        #expect(terminations == 2)
        #expect(app.workspace.isOnUntouchedBlankPage, "Quit leaves the page for the next launch")
        #expect(!delegate.windowShouldClose(app.window))
        #expect(terminations == 3)
        #expect(guardian.requests == 0)

        // Once typed in, the page is a document: `⌘W` closes it to a new blank page.
        let page = try #require(app.workspace.managedDocumentID)
        editor.insertSnippet(Snippet(text: "Kept"), replacing: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(!app.workspace.isOnUntouchedBlankPage)
        delegate.closeFront(nil)
        try await app.wait {
            app.workspace.library.blankPageID != nil && app.workspace.managedDocumentID != page &&
                !app.workspace.documentTransitionInProgress
        }
        #expect(terminations == 3)
        #expect(try await app.workspace.library.store.read(page).text.hasSuffix("Kept"))
    }

    /// Command-Q in the fallback home state, with the template gallery open in
    /// place, passes the window and the palette and reaches the Quit menu item.
    @Test func commandQOnTheLibraryHomeReachesTheQuitItem() async throws {
        let app = try WritingFixture(text: "= Quit from home\n", startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
            app.window.delegate = nil
        }
        delegate.installMenu()
        delegate.terminateApplication = {}
        app.window.delegate = delegate
        app.window.orderFront(nil)
        // The home state is the fallback when the library cannot give a blank page.
        app.workspace.showLibraryHome()
        app.workspace.openDiscovery(.templates)
        await app.layout()
        #expect(app.workspace.isLibraryHome && app.workspace.discoveryMode == .templates)

        let menu = try #require(NSApp.mainMenu)
        let quit = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command })
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target == nil, "A nil target sends Quit to NSApp")
        // NSApp.terminate asks its delegate first; this one cancels, so the
        // real Quit path runs and the test process does not exit.
        let guardian = TerminationGuard()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = guardian
        defer { NSApp.delegate = previousDelegate }

        let event = app.key("q", code: 12, modifiers: .command)
        // AppKit offers a key equivalent to the key window, then to the main menu.
        #expect(!app.window.performKeyEquivalent(with: event))
        #expect(!app.workspace.handlePaletteKey(event))
        #expect(guardian.requests == 0)
        #expect(menu.performKeyEquivalent(with: event))
        #expect(guardian.requests == 1)

        // The same on a document with the command palette open.
        app.workspace.discoveryMode = nil
        #expect(app.workspace.open(app.document))
        await app.layout()
        app.workspace.togglePalette()
        #expect(app.workspace.paletteOpen)
        #expect(!app.window.performKeyEquivalent(with: event))
        #expect(!app.workspace.handlePaletteKey(event))
        #expect(guardian.requests == 1)
        #expect(menu.performKeyEquivalent(with: event))
        #expect(guardian.requests == 2)
        app.workspace.closePalette()
    }
}

/// Stands in for the app delegate while a test sends Quit: counts the
/// termination requests and cancels each one.
@MainActor
final class TerminationGuard: NSObject, NSApplicationDelegate {
    private(set) var requests = 0

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requests += 1
        return .terminateCancel
    }
}
