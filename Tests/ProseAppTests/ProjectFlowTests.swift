import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import ProseTestSupport
import SwiftUI
import Testing

/// A three-file thesis opened in place, with the real editor, window and
/// Tinymist process.
@Suite(.serialized)
@MainActor
struct ProjectFlowTests {
    private func thesis(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Thesis")
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("sections"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("figures"), withIntermediateDirectories: true)
        try Data("= Thesis\n\n#include \"sections/method.typ\"\n".utf8)
            .write(to: folder.appendingPathComponent("main.typ"))
        try Data("= Method\n\n== Participants\n\n== Procedure\n\nText.\n".utf8)
            .write(to: folder.appendingPathComponent("sections/method.typ"))
        try Data("@book{a, title={A}}".utf8).write(to: folder.appendingPathComponent("references.bib"))
        try Data("png".utf8).write(to: folder.appendingPathComponent("figures/plot.png"))
        return folder.standardizedFileURL
    }

    @Test func folderOpensInPlaceAndCompilesItsMainEntryFromAnyFile() async throws {
        let app = try WritingFixture(text: "= Loose file\n")
        defer { app.close() }
        try await app.ready()
        let folder = try thesis(in: app.root)
        let main = folder.appendingPathComponent("main.typ")
        let method = folder.appendingPathComponent("sections/method.typ")
        var previewed: [URL] = []
        app.workspace.previewFile = { previewed.append($0) }

        #expect(app.workspace.openFolder(folder))
        await app.layout()
        #expect(app.workspace.project?.root.path == folder.path)
        #expect(app.workspace.project?.name == "Thesis")
        #expect(app.workspace.sidebarVisible)
        #expect(app.workspace.fileURL == main)
        #expect(app.workspace.compilationURL == main)
        let rows = app.workspace.sidebarRows.compactMap { row -> String? in
            if case let .item(node, _) = row {
                return node.name
            }
            return nil
        }
        #expect(rows == ["figures", "sections", "main.typ", "references.bib"])

        // Opening a chapter keeps compiling the thesis.
        app.workspace.toggleProjectFolder(folder.appendingPathComponent("sections"))
        #expect(app.workspace.project?.expanded == ["sections"])
        app.workspace.openProjectFile(method)
        #expect(app.workspace.fileURL == method)
        #expect(app.workspace.mainFileURL == main)
        #expect(app.workspace.compilationURL == main)
        try await app.wait { app.workspace.outline.count == 3 }
        let headings = app.workspace.sidebarRows.filter {
            if case .heading = $0 {
                return true
            }
            return false
        }
        #expect(headings.count == 3, "The open file shows its headings under its row")
        app.workspace.openProjectFile(method) // Already open: nothing happens.
        #expect(app.workspace.fileURL == method)

        // Other files open in Quick Look, not the editor.
        app.workspace.openProjectFile(folder.appendingPathComponent("references.bib"))
        #expect(previewed.map(\.lastPathComponent) == ["references.bib"])
        #expect(app.workspace.fileURL == method)

        // The main entry can move to any Typst file and is remembered.
        app.workspace.setMainEntry(method)
        #expect(app.workspace.project?.main == method)
        #expect(app.workspace.mainFileURL == nil)
        #expect(app.workspace.compilationURL == method)
        app.workspace.setMainEntry(folder.appendingPathComponent("references.bib")) // Not Typst: ignored.
        #expect(app.workspace.project?.main == method)
        #expect(app.workspace.projectStore.recent().first?.mainEntry == "sections/method.typ")
        #expect(app.workspace.projectStore.recent().first?.expanded == ["sections"])
        app.workspace.setMainEntry(main)
        #expect(app.workspace.mainFileURL == main)

        // A loose file outside the folder leaves the project.
        #expect(app.workspace.open(app.document))
        #expect(app.workspace.project == nil)
        #expect(app.workspace.mainFileURL == nil)

        // Reopening a file inside the folder restores the project and its main entry.
        #expect(app.workspace.open(method))
        #expect(app.workspace.project?.root.path == folder.path)
        #expect(app.workspace.mainFileURL == main)
    }

    @Test func sidebarCreatesRenamesAndTrashesFilesInTheFolder() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let folder = try thesis(in: app.root)
        let main = folder.appendingPathComponent("main.typ")
        #expect(app.workspace.openFolder(folder))
        let sections = folder.appendingPathComponent("sections")

        app.workspace.createProjectFile(in: sections, named: "results")
        let results = sections.appendingPathComponent("results.typ")
        #expect(FileManager.default.fileExists(atPath: results.path))
        #expect(app.workspace.fileURL == results, "A new Typst file opens for writing")
        #expect(app.workspace.mainFileURL == main)

        app.workspace.renameProjectItem(results, to: "findings.typ")
        let findings = sections.appendingPathComponent("findings.typ")
        #expect(!FileManager.default.fileExists(atPath: results.path))
        #expect(app.workspace.fileURL == findings, "Renaming the open file keeps it open")

        app.workspace.createProjectFolder(in: folder, named: "appendix")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("appendix").path))
        app.workspace.createProjectFolder(in: folder, named: "appendix")
        #expect(app.workspace.message == ProjectError.exists.errorDescription)

        app.workspace.trashProjectItem(main)
        #expect(FileManager.default.fileExists(atPath: main.path), "The main entry is never trashed")
        #expect(app.workspace.message == ProjectActionError.mainEntry.errorDescription)
        app.workspace.trashProjectItem(findings)
        #expect(FileManager.default.fileExists(atPath: findings.path), "The open file is never trashed")
        #expect(app.workspace.message == ProjectActionError.openFile.errorDescription)
        app.workspace.trashProjectItem(folder.appendingPathComponent("appendix"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("appendix").path))

        // Renaming the main entry keeps it the main entry.
        #expect(app.workspace.open(main))
        app.workspace.renameProjectItem(main, to: "thesis.typ")
        let thesis = folder.appendingPathComponent("thesis.typ")
        #expect(app.workspace.project?.main == thesis)
        #expect(app.workspace.fileURL == thesis)
    }

    @Test func foldersWithoutTypstFilesAndFoldersThatMoved() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let empty = app.root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(app.workspace.openFolder(empty))
        #expect(app.workspace.project?.main == nil)
        #expect(app.workspace.fileURL == app.document, "The open document stays open")
        #expect(app.workspace.message != nil)
        app.workspace.createProjectFile(in: empty, named: "notes")
        let notes = empty.appendingPathComponent("notes.typ").standardizedFileURL
        #expect(app.workspace.project?.main == notes, "The first Typst file becomes the main entry")
        #expect(app.workspace.fileURL == notes)

        let record = try #require(app.workspace.projectStore.recent().first)
        try FileManager.default.removeItem(at: empty)
        #expect(!app.workspace.openRecentFolder(record))
        #expect(app.workspace.message == ProjectError.unavailable.errorDescription)
        #expect(app.workspace.projectStore.recent().isEmpty, "A missing folder leaves the recent list")
        #expect(!app.workspace.openFolder(app.root.appendingPathComponent("Missing")))
    }

    @Test func libraryHomeListsRecentFoldersAndReopensThem() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let folder = try thesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        app.workspace.showLibraryHome()
        await app.layout()
        #expect(app.workspace.isLibraryHome)
        #expect(app.workspace.project == nil)
        let record = try #require(app.workspace.projectStore.recent().first)
        #expect(record.name == "Thesis")
        #expect(app.workspace.openRecentFolder(record))
        await app.layout()
        #expect(!app.workspace.isLibraryHome)
        #expect(app.workspace.fileURL == folder.appendingPathComponent("main.typ"))
        #expect(app.workspace.sidebarVisible)
    }

    @Test func changesOnDiskRefreshTheSidebar() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let folder = try thesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        let revision = app.workspace.projectRevision
        try Data("= Added elsewhere".utf8).write(to: folder.appendingPathComponent("added.typ"))
        try await app.wait { app.workspace.projectRevision > revision }
        #expect(app.workspace.sidebarRows.contains {
            if case let .item(node, _) = $0 {
                return node.name == "added.typ"
            }
            return false
        })
    }

    @Test func sidebarTogglesFromTheMenuAndHidesTheFloatingOutline() async throws {
        let app = try WritingFixture(text: "= First\n\n== Second\n", startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let menu = try #require(NSApp.mainMenu)
        app.workspace.outline = [
            .init(title: "First", level: 1, offset: 0),
            .init(title: "Second", level: 2, offset: 9),
        ]
        #expect(!app.workspace.sidebarVisible)
        #expect(menu.performKeyEquivalent(with: app.key("0", code: 29, modifiers: .command)))
        await app.layout()
        #expect(app.workspace.sidebarVisible)
        #expect(app.workspace.project == nil)
        // Without a folder, the sidebar holds only the outline.
        #expect(app.workspace.sidebarRows == [.heading(0, depth: 0), .heading(1, depth: 0)])
        let open = try #require(WritingCommand.all.first { $0.id == "openFolder" })
        #expect(open.shortcuts.first?.label == "⌥⌘O")
        #expect(open.keyPath == "f f")
        #expect(menu.performKeyEquivalent(with: app.key("0", code: 29, modifiers: .command)))
        #expect(!app.workspace.sidebarVisible)
    }
}
