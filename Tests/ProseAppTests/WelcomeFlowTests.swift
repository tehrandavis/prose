import AppKit
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

/// The welcome screen: the flag, Window › Welcome to Prose, Escape, the
/// actions, the recents and when launch shows it.
extension WritingFlowTests {
    @Test func welcomeScreenShowsFromTheMenuAndClosesForEachAction() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace, library = workspace.library
        #expect(!workspace.showsWelcome, "A workspace never shows the welcome screen by itself")
        let delegate = AppDelegate(workspace: workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()

        // Launch over a real document: no welcome screen.
        delegate.showWelcomeAfterLaunch()
        #expect(!workspace.showsWelcome)

        // Window › Welcome to Prose shows it; Escape closes it.
        let windowMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == L10n.text("Window") }?
            .submenu)
        let title = L10n.format("Welcome to %@", AppDistribution.current.applicationName)
        let item = try #require(windowMenu.items.first { $0.title == title })
        #expect(try NSApp.sendAction(#require(item.action), to: item.target, from: item))
        #expect(workspace.showsWelcome)
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(!workspace.showsWelcome)

        // No recents: no rows.
        #expect(workspace.welcomeRows.isEmpty)

        // Recents: at most eight rows, in the blank page's order.
        await library.start()
        var ids: [UUID] = []
        for index in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(15))
            try await ids.append(library.store.create(title: "Note \(index)", text: "= Note \(index)\n").id)
        }
        await library.refresh()
        let rows = workspace.welcomeRows
        #expect(rows.count == Workspace.welcomeRecentLimit)
        #expect(rows == Array(workspace.recents(documentLimit: Workspace.welcomeRecentLimit).rows.prefix(8)))
        workspace.showWelcome()
        await app.layout()
        let areas = openRowAreas(app.window.contentView)
        #expect(areas.keys.contains("welcome.action.new"))
        #expect(areas.keys.count(where: { $0.hasPrefix("welcome.document:") }) == 8)

        // New from Template: the screen closes, the gallery opens.
        workspace.performWelcome(.newFromTemplate)
        #expect(!workspace.showsWelcome)
        #expect(workspace.libraryOpen && workspace.discoveryMode == .templates)
        workspace.libraryOpen = false
        workspace.discoveryMode = nil

        // A recent opens its document and closes the screen.
        workspace.showWelcome()
        let row = try #require(rows.first)
        guard case let .document(document) = row else {
            Issue.record("The first recent is a document")
            return
        }
        workspace.performWelcome(.recent(row))
        #expect(!workspace.showsWelcome)
        try await app.wait { !library.busy && workspace.managedDocumentID == document.id }

        // Launch on the untouched blank page shows it, once a file was not opened.
        try await library.openBlankPage()
        try await app.wait { !library.busy && workspace.isOnUntouchedBlankPage }
        delegate.showWelcomeAfterLaunch()
        #expect(workspace.showsWelcome)
        workspace.closeWelcome()
        delegate.application(NSApp, openFiles: [app.document.path])
        #expect(delegate.openedFile)
        delegate.showWelcomeAfterLaunch()
        #expect(!workspace.showsWelcome)

        #expect(WelcomeRecent.abbreviated(NSHomeDirectory() + "/Writing") == "~/Writing")
        #expect(WelcomeRecent.abbreviated("/tmp/Writing") == "/tmp/Writing")
    }
}
