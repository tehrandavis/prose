import AppKit
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

/// Phase 7 step B: the blank page, `⌘N` and the templates button
/// (`docs/plans/2026-11-15-quiet-home-window.md`, decisions 2 and 6).
extension WritingFlowTests {
    /// Acceptance test 5.
    @Test func newDocumentReusesTheUntouchedBlankPage() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        let menu = try installBlankPageMenu(app)
        defer { menu.restore() }
        for _ in 0 ..< 3 {
            #expect(menu.menu.performKeyEquivalent(with: app.key("n", code: 45, modifiers: .command)))
            try await app.wait { !library.busy && app.workspace.managedDocumentID != nil }
        }
        let documents = try await library.store.list(includeTrashed: true)
        #expect(documents.count == 1)
        let page = try #require(documents.first)
        #expect(page.title == L10n.text("Untitled"))
        #expect(app.workspace.managedDocumentID == page.id)
        #expect(library.blankPageID == page.id)
        #expect(app.workspace.text == DocumentTemplate.blank.source)
        #expect(app.workspace.editorMode == .writing)
        let editor = try #require(app.workspace.editor)
        #expect(editor.string == DocumentTemplate.blank.source)
        let end = DocumentTemplate.blank.source.utf16.count
        #expect(editor.selectedRange() == NSRange(location: end, length: 0))
        #expect(app.workspace.selection == NSRange(location: end, length: 0))
        #expect(editor.isEditable)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= Existing\n")

        // The first edit keeps the page; the next `⌘N` makes a second one.
        editor.insertSnippet(Snippet(text: "A first line"), replacing: NSRange(location: end, length: 0))
        #expect(library.blankPageID == nil)
        let typed = app.workspace.text
        #expect(menu.menu.performKeyEquivalent(with: app.key("n", code: 45, modifiers: .command)))
        try await app.wait { !library.busy && app.workspace.managedDocumentID != page.id }
        let second = try #require(app.workspace.managedDocumentID)
        #expect(library.blankPageID == second)
        #expect(try await library.store.list().count == 2)
        #expect(try await library.store.read(page.id).text == typed)
        #expect(app.workspace.text == DocumentTemplate.blank.source)
        #expect(library.recentDocumentIDs.first == page.id, "A kept page is a recent like any other")
    }

    /// Acceptance test 6.
    @Test func leavingAnUntouchedBlankPageDeletesIt() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        let notes = try await library.store.create(title: "Notes", text: "= Notes\n")
        await library.refresh()

        // To another document.
        try await library.openBlankPage()
        let first = try #require(library.blankPageID)
        let firstFolder = try #require(library.documents.first { $0.id == first }?.folderURL)
        try await library.open(notes.id)
        #expect(library.blankPageID == nil)
        try await app.wait {
            !FileManager.default.fileExists(atPath: firstFolder.path) && !library.documents.contains { $0.id == first }
        }
        try await expectNoUntitledDocument(library)

        // To a folder.
        try await library.openBlankPage()
        let second = try #require(library.blankPageID)
        #expect(second != first)
        let secondFolder = try #require(library.documents.first { $0.id == second }?.folderURL)
        let folder = app.root.appendingPathComponent("Thesis")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("= Thesis\n".utf8).write(to: folder.appendingPathComponent("main.typ"))
        #expect(app.workspace.openFolder(folder))
        try await app.wait {
            !FileManager.default.fileExists(atPath: secondFolder.path) && !library.documents
                .contains { $0.id == second }
        }
        try await expectNoUntitledDocument(library)
        #expect(app.workspace.fileURL?.lastPathComponent == "main.typ")
        #expect(try await library.store.read(notes.id).text == "= Notes\n")
        #expect(!FileManager.default.fileExists(
            atPath: app.workspace.stateDirectory.appendingPathComponent("blank-page.json").path,
        ))
    }

    /// Acceptance test 7.
    @Test func aBlankPageThatWasTypedInIsKept() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let library = app.workspace.library
        let notes = try await library.store.create(title: "Notes", text: "= Notes\n")
        await library.refresh()

        // One typed word, then another document.
        try await library.openBlankPage()
        let typedPage = try #require(library.blankPageID)
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Word"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        #expect(library.blankPageID == nil)
        try await library.open(notes.id)
        await app.layout()
        #expect(try await library.store.read(typedPage).text == DocumentTemplate.blank.source + "Word")

        // A renamed untouched page is kept too.
        try await library.openBlankPage()
        let renamedPage = try #require(library.blankPageID)
        #expect(renamedPage != typedPage)
        try await library.rename(renamedPage, title: "Plan")
        #expect(library.blankPageID == nil)
        try await library.open(notes.id)
        await app.layout()
        let renamed = try await library.store.read(renamedPage)
        #expect(renamed.document.title == "Plan")
        #expect(renamed.text == DocumentTemplate.blank.source)

        // Both are listed in "Your writing…".
        app.workspace.openLibrary()
        try await app.wait { app.window.attachedSheet != nil }
        let rows = app.workspace.libraryRows
        try await app.wait {
            Set(rows.rows.map(\.id)).isSuperset(of: [
                LibraryRow.documentID(typedPage), LibraryRow.documentID(renamedPage), LibraryRow.documentID(notes.id),
            ])
        }
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }
    }

    /// Acceptance test 8.
    @Test func theUntouchedBlankPageIsHiddenFromEveryList() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let library = app.workspace.library
        let notes = try await library.store.create(title: "Notes", text: "= Notes\n")
        await library.refresh()
        try await library.open(notes.id)
        try await library.openBlankPage()
        let page = try #require(library.blankPageID)
        #expect(app.workspace.managedDocumentID == page)
        #expect(library.documents.contains { $0.id == page })
        #expect(!library.listedDocuments.contains { $0.id == page })
        #expect(library.isUntouchedBlankPage(page))
        #expect(!library.reopenableRecentIDs.contains(page))
        #expect(!library.recentDocumentIDs.contains(page))
        #expect(library.reopenableRecentIDs == [notes.id])

        app.workspace.openLibrary()
        try await app.wait { app.window.attachedSheet != nil }
        let rows = app.workspace.libraryRows
        try await app.wait { rows.rows.contains { $0.id == LibraryRow.documentID(notes.id) } }
        #expect(!rows.rows.contains { $0.id == LibraryRow.documentID(page) })
        // No folders here, so the rows are the documents the footer counts.
        #expect(rows.rows.count == 1)
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }
    }

    /// The toolbar's templates button and `⌘⇧N` open the gallery as a sheet
    /// over the document and make nothing; `⌘J` `new` does the same.
    @Test func templatesButtonAndShortcutOpenTheGalleryOverADocument() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let menu = try installBlankPageMenu(app)
        defer { menu.restore() }
        await app.layout()

        let documents = try #require(menu.menu.items.first { $0.submenu?.title == L10n.text("Documents") }?.submenu)
        let titles = documents.items.map(\.title)
        let newIndex = try #require(titles.firstIndex(of: L10n.text("New Document")))
        #expect(titles[newIndex + 1] == L10n.text("New from Template…"))
        #expect(menu.menu.performKeyEquivalent(with: app.key("N", code: 45, modifiers: [.command, .shift])))
        #expect(app.workspace.discoveryMode == .templates)
        #expect(app.workspace.libraryOpen)
        try await app.wait { app.window.attachedSheet != nil }
        app.workspace.discoveryMode = nil
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }

        let toolbar = try #require(app.window.toolbar)
        let anchors = toolbar.items.flatMap { blankPageDescendants($0.view) }.compactMap { $0 as? HelpAnchor }
        let templates = try #require(anchors.first { $0.title == L10n.text("Templates") })
        #expect(templates.shortcut == "⇧⌘N")
        let point = templates.convert(NSPoint(x: templates.bounds.midX, y: templates.bounds.midY), to: nil)
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
        try await app.wait { app.workspace.discoveryMode == .templates && app.window.attachedSheet != nil }
        #expect(app.workspace.libraryOpen)
        app.workspace.discoveryMode = nil
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }

        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "new" }))
        #expect(app.workspace.discoveryMode == .templates)
        #expect(app.workspace.libraryOpen)
        app.workspace.discoveryMode = nil
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }

        #expect(try await app.workspace.library.store.list(includeTrashed: true).isEmpty)
        #expect(app.workspace.fileURL == app.document)
        #expect(app.workspace.text == "= Existing\n")
        #expect(app.workspace.library.blankPageID == nil)
    }

    /// The gallery's "Blank page" and `⌘J` "New Blank Page" follow the reuse rule.
    @Test func everyBlankPageRouteReusesTheUntouchedPage() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        try await library.create(builtIn: .blank)
        let page = try #require(library.blankPageID)
        try await library.create(builtIn: .blank)
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "newBlank" }))
        try await app.wait { !library.busy }
        #expect(app.workspace.managedDocumentID == page)
        #expect(try await library.store.list().map(\.id) == [page])
        let restarted = LibraryController(workspace: app.workspace)
        #expect(restarted.blankPageID == page, "The id survives a restart in blank-page.json")
    }

    /// Trashing the open document shows a blank page in its place.
    @Test func trashingTheOpenDocumentShowsABlankPage() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        try await library.create(title: "Notes", text: "= Notes\n")
        let notes = try #require(app.workspace.managedDocumentID)
        try await library.moveToTrash(notes)
        let page = try #require(library.blankPageID)
        #expect(app.workspace.managedDocumentID == page)
        #expect(!app.workspace.isLibraryHome)
        #expect(!app.workspace.libraryOpen)
        #expect(app.workspace.discoveryMode == nil)
        #expect(app.workspace.text == DocumentTemplate.blank.source)
        #expect(app.workspace.editorMode == .writing)
        #expect(try await library.store.read(notes).document.isTrashed)

        // Trashing the untouched blank page itself makes a new one; the old
        // one is an ordinary trashed document.
        try await library.moveToTrash(page)
        let next = try #require(library.blankPageID)
        #expect(next != page)
        #expect(app.workspace.managedDocumentID == next)
        #expect(try await library.store.read(page).document.isTrashed)
    }
}

extension WritingFlowTests {
    /// An agent that trashes the open document leaves a blank page in its
    /// place; an agent's rename of the untouched blank page keeps it.
    @Test func agentTrashShowsABlankPageAndAgentRenameKeepsIt() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace, library = workspace.library
        let document = try await library.store.create(title: "Agent", text: "= Draft\n")
        try await library.open(document.id)
        let tools = AgentToolDispatcher(library: library.store, history: workspace.history.store, host: workspace)
        let access = AgentToolAccess(documentIDs: nil, canWrite: true)
        let trashed = await tools.call("trash_document", arguments: .object([
            "document_id": .string(document.id.uuidString),
            "expected_metadata_revision": .string(document.metadataRevision),
            "request_id": .string("trash-open-document"),
        ]), access: access)
        #expect(!trashed.isError)
        let page = try #require(library.blankPageID)
        #expect(workspace.managedDocumentID == page)
        #expect(!workspace.isLibraryHome && !workspace.agentMetadataChangeInProgress)
        #expect(workspace.text == DocumentTemplate.blank.source)
        #expect(workspace.editor?.isEditable == true)

        let current = try await library.store.read(page).document
        let renamed = await tools.call("rename_document", arguments: .object([
            "document_id": .string(page.uuidString), "title": .string("Agent notes"),
            "expected_metadata_revision": .string(current.metadataRevision),
            "request_id": .string("rename-blank-page"),
        ]), access: access)
        #expect(!renamed.isError)
        #expect(library.blankPageID == nil)
        #expect(library.listedDocuments.contains { $0.id == page })
    }
}

@MainActor
private struct BlankPageMenu {
    let menu: NSMenu
    let previousMenu: NSMenu?
    let previousWindowsMenu: NSMenu?
    let delegate: AppDelegate

    func restore() {
        NSApp.mainMenu = previousMenu
        NSApp.windowsMenu = previousWindowsMenu
    }
}

@MainActor
private func installBlankPageMenu(_ app: WritingFixture) throws -> BlankPageMenu {
    let delegate = AppDelegate(workspace: app.workspace)
    let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
    delegate.installMenu()
    return try BlankPageMenu(
        menu: #require(NSApp.mainMenu),
        previousMenu: previousMenu,
        previousWindowsMenu: previousWindowsMenu,
        delegate: delegate,
    )
}

@MainActor
private func expectNoUntitledDocument(_ library: LibraryController) async throws {
    let all = try await library.store.list(includeTrashed: true)
    #expect(!all.contains { $0.title == L10n.text("Untitled") })
    #expect(try await library.store.trashSnapshot().isEmpty)
}

@MainActor
private func blankPageDescendants(_ view: NSView?) -> [NSView] {
    guard let view else {
        return []
    }
    return [view] + view.subviews.flatMap { blankPageDescendants($0) }
}
