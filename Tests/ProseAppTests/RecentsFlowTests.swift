import AppKit
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

/// Phase 7 step D: recents in the sidebar of a blank page and Documents ›
/// Open Recent (`docs/plans/2026-11-15-quiet-home-window.md`, decisions 4
/// and 6).
extension WritingFlowTests {
    /// Acceptance test 13.
    @Test func aBlankPageListsRecentsInTheSidebar() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        app.window.appearance = NSAppearance(named: .aqua)
        app.workspace.sidebarVisible = true
        let workspace = app.workspace, library = workspace.library
        await library.start()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let thesis = try recentFolder("Thesis", in: app.root, workspace: workspace, at: start)
        let grant = try recentFolder("Grant", in: app.root, workspace: workspace, at: start + 60)
        let old = try await library.store.create(title: "Old", text: "= Old\n")
        _ = try await library.store.trash(old.id)
        let alpha = try await createSpaced("Alpha", library)
        let beta = try await createSpaced("Beta", library)
        let gamma = try await createSpaced("Gamma", library)
        await library.refresh()
        try await library.open(beta)
        try await library.openBlankPage()
        let page = try #require(library.blankPageID)
        #expect(workspace.showsSidebarRecents)
        #expect(workspace.project != nil, "A blank page has its own library folder")

        // The model: folders, most recent first; documents, the opened one
        // first, then by date; never the page or a trashed document.
        let recents = workspace.recents()
        #expect(recents.folders.map(\.path) == [grant.path, thesis.path])
        #expect(recents.documents.map(\.id) == [beta, gamma, alpha])
        #expect(!recents.documents.contains { $0.id == page || $0.id == old.id })

        // The view: the same rows in the same order, "All writing…" last,
        // and no file tree.
        await app.layout()
        let root = try #require(app.window.contentView)
        let expected = recents.folders.map { "recent.folder:" + $0.id.uuidString }
            + recents.documents.map { "recent.document:" + $0.id.uuidString } + ["recent.all"]
        let areas = openRowAreas(root)
        #expect(sidebarOrder(areas) == expected, "Sidebar rows: \(sidebarOrder(areas))")
        #expect(!areas.keys.contains { $0.hasPrefix("item:") })
        for id in expected {
            #expect(areas[id]?.bounds.height == 26, "\(id) is \(areas[id]?.bounds.height ?? 0) pt high")
        }

        // Hover: the row draws the hover wash; no other row changes.
        let hover = workspace.sidebarHover
        let pageColour = try swatch(Theme.nativeBackground, in: root)
        let hoverFill = try swatch(Theme.nativeHover, in: root, over: Theme.nativeBackground)
        let gammaRow = "recent.document:" + gamma.uuidString
        let betaRow = "recent.document:" + beta.uuidString
        #expect(try near(rowColour(root, #require(areas[gammaRow])), pageColour))
        hover.set(gammaRow)
        await app.layout()
        let hovered = try rowColour(root, #require(openRowAreas(root)[gammaRow]))
        #expect(near(hovered, hoverFill), "Hovered recents row \(hovered), not \(hoverFill)")
        #expect(try near(rowColour(root, #require(openRowAreas(root)[betaRow])), pageColour))
        hover.set(nil)

        // One click on a document row opens it; the sidebar shows its folder.
        try openRowClick(app.window, #require(openRowAreas(root)[betaRow]), x: 0.5)
        try await app.wait { workspace.managedDocumentID == beta && !library.busy }
        #expect(workspace.project?.kind == .library(beta))
        #expect(!workspace.showsSidebarRecents)
        try await app.wait { !library.documents.contains { $0.id == page } }
        await app.layout()
        let documentAreas = openRowAreas(root)
        #expect(documentAreas.keys.contains { $0.hasPrefix("item:") })
        #expect(!documentAreas.keys.contains { $0.hasPrefix("recent.") })

        // Back on a blank page, one typed word shows the page's own folder.
        try await library.openBlankPage()
        let typed = try #require(library.blankPageID)
        await app.layout()
        #expect(openRowAreas(root).keys.contains("recent.all"))
        let editor = try #require(workspace.editor)
        editor.insertSnippet(Snippet(text: "Word"), replacing: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(library.blankPageID == nil)
        try await app.wait {
            root.layoutSubtreeIfNeeded()
            let keys = openRowAreas(root).keys
            return keys.contains { $0.hasPrefix("item:") } && !keys.contains { $0.hasPrefix("recent.") }
        }
        #expect(workspace.project?.kind == .library(typed))

        // "All writing…" opens the "Your writing…" sheet.
        try await library.openBlankPage()
        await app.layout()
        #expect(workspace.recents().documents.first?.id == typed, "The kept page is the latest recent")
        try openRowClick(app.window, #require(openRowAreas(root)["recent.all"]), x: 0.5)
        try await app.wait { workspace.libraryOpen && app.window.attachedSheet != nil }
        workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }

        // The limits: 5 folders and 8 documents, whatever the library holds.
        for index in 0 ..< 5 {
            _ = try recentFolder("Older \(index)", in: app.root, workspace: workspace, at: start - Double(index + 1))
        }
        for index in 0 ..< 8 {
            _ = try await library.store.create(title: "Extra \(index)", text: "= Extra\n")
        }
        await library.refresh()
        let full = workspace.recents()
        #expect(full.folders.count == SidebarRecents.folderLimit)
        #expect(full.folders.prefix(2).map(\.path) == [grant.path, thesis.path])
        #expect(full.documents.count == SidebarRecents.sidebarDocumentLimit)
        #expect(Array(full.documents.prefix(2).map(\.id)) == [typed, beta])
        await app.layout()
        let limited = sidebarOrder(openRowAreas(root))
        #expect(limited.count(where: { $0.hasPrefix("recent.folder:") }) == 5)
        #expect(limited.count(where: { $0.hasPrefix("recent.document:") }) == 8)
        #expect(limited.last == "recent.all")
    }

    /// Acceptance test 14.
    @Test func openRecentMenuListsFoldersAndDocuments() async throws {
        let app = try WritingFixture(text: "= Existing\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace, library = workspace.library
        let delegate = AppDelegate(workspace: workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let documents = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == L10n.text("File") }?
            .submenu)
        let titles = documents.items.map(\.title)
        let recentIndex = try #require(titles.firstIndex(of: L10n.text("Open Recent")))
        #expect(titles[recentIndex - 1] == L10n.text("Open Folder…"))
        #expect(titles[recentIndex + 1] == L10n.text("Open external file…"))
        let menu = try #require(documents.items[recentIndex].submenu)
        #expect(menu.delegate === delegate)

        // With no recents, one disabled item.
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == [L10n.text("No Recent Items")])
        #expect(menu.items.first?.isEnabled == false)

        // Documents only: no separator.
        await library.start()
        var ids: [UUID] = []
        for index in 0 ..< 12 {
            try await ids.append(createSpaced("Note \(index)", library))
        }
        await library.refresh()
        try await library.open(ids[3])
        delegate.menuNeedsUpdate(menu)
        let hasSeparator = menu.items.contains(where: \.isSeparatorItem)
        #expect(!hasSeparator)
        #expect(menu.items.count == SidebarRecents.menuDocumentLimit)
        #expect(menu.items.first?.title == "Note 3", "The opened document comes first")

        // Folders, a separator, then documents, in the recents' order.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var folders: [URL] = []
        for index in 0 ..< 6 {
            let date = start + Double(index)
            try folders.append(recentFolder("Folder \(index)", in: app.root, workspace: workspace, at: date))
        }
        delegate.menuNeedsUpdate(menu)
        let recents = workspace.recents(documentLimit: SidebarRecents.menuDocumentLimit)
        #expect(recents.folders.count == 5 && recents.documents.count == 10)
        let expected = recents.folders.map(\.name) + [""] + recents.documents.map(\.title)
        #expect(menu.items.map { $0.isSeparatorItem ? "" : $0.title } == expected)
        #expect(menu.items.first?.title == "Folder 5")
        #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled })
        #expect(menu.items.first?.toolTip == SidebarRecents.parentPath(recents.folders[0]))

        // An item opens its document; another opens its folder.
        let noteItem = try #require(menu.items.first { $0.title == "Note 7" })
        delegate.openRecentItem(noteItem)
        try await app.wait { workspace.managedDocumentID == ids[7] && !library.busy }
        let folderItem = try #require(menu.items.first { $0.title == "Folder 2" })
        delegate.openRecentItem(folderItem)
        try await app.wait { workspace.project?.root.path == folders[2].path }
        #expect(workspace.fileURL?.lastPathComponent == "main.typ")

        // The menu is current when it opens: the folder and the note lead.
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "Folder 2")
        let firstDocument = try #require(menu.items.firstIndex { $0.isSeparatorItem }).advanced(by: 1)
        #expect(menu.items[firstDocument].title == "Note 7")
    }
}

/// A folder with a main entry, remembered as opened at `date`.
@MainActor
private func recentFolder(_ name: String, in root: URL, workspace: Workspace, at date: Date) throws -> URL {
    let folder = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("= \(name)\n".utf8).write(to: folder.appendingPathComponent("main.typ"))
    try workspace.projectStore.remember(folder, now: date)
    return folder.standardizedFileURL
}

/// Creates a library document a little after the one before, so the order
/// by date is certain.
@MainActor
private func createSpaced(_ title: String, _ library: LibraryController) async throws -> UUID {
    try await Task.sleep(for: .milliseconds(15))
    return try await library.store.create(title: title, text: "= \(title)\n").id
}

/// The sidebar's open rows from top to bottom.
@MainActor
private func sidebarOrder(_ areas: [String: NSView]) -> [String] {
    areas.filter { $0.key.hasPrefix("recent.") }
        .sorted { $0.value.convert($0.value.bounds, to: nil).midY > $1.value.convert($1.value.bounds, to: nil).midY }
        .map(\.key)
}
