import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

private func thesisFixture() throws -> URL {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("project-folder-" + UUID().uuidString)
        .appendingPathComponent("Thesis")
    let manager = FileManager.default
    for folder in ["sections", "figures", "Feedback", ".git"] {
        try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try Data("#include \"sections/method.typ\"".utf8).write(to: root.appendingPathComponent("main.typ"))
    try Data("= Method\n== Participants".utf8).write(to: root.appendingPathComponent("sections/method.typ"))
    try Data("@book{a}".utf8).write(to: root.appendingPathComponent("references.bib"))
    try Data("png".utf8).write(to: root.appendingPathComponent("figures/Figure 10.png"))
    try Data("png".utf8).write(to: root.appendingPathComponent("figures/Figure 2.png"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    try manager.createSymbolicLink(
        at: root.appendingPathComponent("linked.typ"),
        withDestinationURL: root.appendingPathComponent("main.typ"),
    )
    return root
}

@Test func projectTreeListsFoldersFirstInFinderOrderWithoutHiddenOrLinkedItems() throws {
    let root = try thesisFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let top = try ProjectTree.children(of: root)
    #expect(top.map(\.name) == ["Feedback", "figures", "sections", "main.typ", "references.bib"])
    #expect(top.map(\.isDirectory) == [true, true, true, false, false])
    #expect(top.filter(\.isTypst).map(\.name) == ["main.typ"])
    let figures = try ProjectTree.children(of: root.appendingPathComponent("figures"))
    #expect(figures.map(\.name) == ["Figure 2.png", "Figure 10.png"])
    #expect(throws: ProjectError.unavailable) { try ProjectTree.children(of: root.appendingPathComponent("gone")) }
    #expect(ProjectError.unavailable.errorDescription?.isEmpty == false)
}

@Test func projectTreeChoosesTheMainEntry() throws {
    let root = try thesisFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    #expect(ProjectTree.defaultMainEntry(in: root)?.lastPathComponent == "main.typ")
    try FileManager.default.removeItem(at: root.appendingPathComponent("main.typ"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("linked.typ"))
    // The only Typst file in the project, even in a subfolder.
    #expect(try ProjectTree.relativePath(of: #require(ProjectTree.defaultMainEntry(in: root)), in: root)
        == "sections/method.typ")
    try Data("= Book".utf8).write(to: root.appendingPathComponent("book.typ"))
    try Data("= Notes".utf8).write(to: root.appendingPathComponent("notes.typ"))
    #expect(ProjectTree.defaultMainEntry(in: root)?.lastPathComponent == "book.typ")
    let empty = root.deletingLastPathComponent().appendingPathComponent("Empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(ProjectTree.defaultMainEntry(in: empty) == nil)
}

@Test func projectSourcesKeepListingAfterASymbolicLink() throws {
    let root = try thesisFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    // The fixture's linked.typ sits beside folders that are listed after it.
    try Data("#figure[]".utf8).write(to: root.appendingPathComponent("figures/plot.typ"))
    #expect(try ProjectSources.list(in: root).map(\.lastPathComponent) == ["plot.typ", "main.typ", "method.typ"])
}

@Test func projectTreeSearchMatchesNamesAcrossFolders() throws {
    let root = try thesisFixture()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    #expect(ProjectTree.search("FIGURE", in: root).map(\.name) == ["Figure 2.png", "Figure 10.png"])
    #expect(ProjectTree.search("method", in: root).map(\.name) == ["method.typ"])
    #expect(ProjectTree.search("  ", in: root).isEmpty)
    #expect(ProjectTree.search("DS_Store", in: root).isEmpty)
    #expect(ProjectTree.search(".typ", in: root, limit: 1).count == 1)
}

@Test func projectTreeCreatesRenamesAndTrashesInsideTheRootOnly() throws {
    let root = try thesisFixture()
    let outside = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: outside) }
    let sections = root.appendingPathComponent("sections")
    let file = try ProjectTree.createFile(named: "Résumé 结果", in: sections, root: root)
    #expect(file.lastPathComponent == "Résumé 结果.typ")
    #expect(try ProjectTree.relativePath(of: file, in: root) == "sections/Résumé 结果.typ")
    #expect(try ProjectTree.createFile(named: "notes.md", in: root, root: root).lastPathComponent == "notes.md")
    #expect(throws: ProjectError.exists) { try ProjectTree.createFile(named: "main", in: root, root: root) }
    for name in ["", " ", ".hidden", "a/b", "a:b"] {
        #expect(throws: ProjectError.invalidName) { try ProjectTree.createFile(named: name, in: root, root: root) }
    }
    #expect(throws: ProjectError.outsideProject) { try ProjectTree.createFile(named: "x", in: outside, root: root) }

    #expect(ProjectTree.availableName("main", extension: "typ", in: root) == "main 2.typ")
    #expect(ProjectTree.availableName("Untitled", extension: "typ", in: root) == "Untitled.typ")
    #expect(ProjectTree.availableName("sections", in: root) == "sections 2")
    let folder = try ProjectTree.createFolder(named: "appendix", in: root, root: root)
    #expect(try ProjectTree.children(of: root).contains { $0.name == "appendix" && $0.isDirectory })
    #expect(throws: ProjectError.exists) { try ProjectTree.createFolder(named: "appendix", in: root, root: root) }

    let renamed = try ProjectTree.rename(file, to: "results.typ", root: root)
    #expect(renamed.lastPathComponent == "results.typ")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(throws: ProjectError.exists) { try ProjectTree.rename(renamed, to: "method.typ", root: root) }
    #expect(throws: ProjectError.outsideProject) { try ProjectTree.rename(root, to: "Other", root: root) }

    try ProjectTree.trash(folder, root: root)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(throws: ProjectError.outsideProject) { try ProjectTree.trash(outside, root: root) }
}

@Test func projectStoreRemembersFoldersMainEntriesAndMoves() throws {
    let root = try thesisFixture()
    let base = root.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = ProjectStore(directory: base.appendingPathComponent("State/Projects"))
    #expect(store.recent().isEmpty)

    var record = try store.remember(root, now: Date(timeIntervalSince1970: 10))
    #expect(record.name == "Thesis")
    #expect(record.mainEntry == "main.typ")
    #expect(try store.resolve(record).path == root.standardizedFileURL.path)

    record.mainEntry = "sections/method.typ"
    record.expanded = ["sections"]
    try store.update(record)
    let again = try store.remember(root, now: Date(timeIntervalSince1970: 20))
    #expect(again.id == record.id)
    #expect(again.mainEntry == "sections/method.typ")
    #expect(again.expanded == ["sections"])
    #expect(store.recent().count == 1)

    let other = base.appendingPathComponent("Article")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try store.remember(other, now: Date(timeIntervalSince1970: 30))
    #expect(store.recent().map(\.name) == ["Article", "Thesis"])

    // A moved folder is found through its bookmark.
    let moved = base.appendingPathComponent("Thesis (final)")
    try FileManager.default.moveItem(at: root, to: moved)
    let thesis = try #require(store.recent().first { $0.id == record.id })
    #expect(try store.resolve(thesis).lastPathComponent == "Thesis (final)")
    #expect(store.recent().first { $0.id == record.id }?.name == "Thesis (final)")

    // A deleted folder cannot be resolved; forgetting removes it.
    try FileManager.default.removeItem(at: moved)
    #expect(throws: ProjectError.unavailable) { try store.resolve(#require(store.recent().first {
        $0.id == record.id
    })) }
    try store.forget(record.id)
    #expect(store.recent().map(\.name) == ["Article"])
    try store.update(record) // Unknown records are ignored.
    #expect(store.recent().count == 1)
}

@Test func projectStoreKeepsOnlyTheMostRecentFolders() throws {
    let base = TestPaths.temporaryDirectory.appendingPathComponent("project-recent-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = ProjectStore(directory: base.appendingPathComponent("State"))
    for index in 0 ..< ProjectStore.recentLimit + 3 {
        let folder = base.appendingPathComponent("Folder \(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.remember(folder, now: Date(timeIntervalSince1970: Double(index)))
    }
    let recent = store.recent()
    #expect(recent.count == ProjectStore.recentLimit)
    #expect(recent.first?.name == "Folder \(ProjectStore.recentLimit + 2)")
    #expect(!ProjectStore.isSandboxed)
}

@Test func compileStatusFollowsTheServiceAndTheLastCompile() {
    func status(
        ready: Bool = true,
        _ service: String = "Preview Updated",
        errors: Int = 0,
        stale: Bool = false,
        succeeded: Bool = true,
    ) -> CompileStatus {
        CompileStatus.resolve(
            serviceReady: ready,
            serviceStatus: service,
            errors: errors,
            previewStale: stale,
            hasSuccessfulPreview: succeeded,
        )
    }
    #expect(status() == .succeeded)
    #expect(status(ready: false, "Connecting") == .offline)
    #expect(status(ready: false, errors: 2) == .offline)
    #expect(status("Typesetting", stale: true) == .compiling)
    #expect(status(stale: true) == .compiling)
    #expect(status("Ready", succeeded: false) == .compiling)
    #expect(status(errors: 1) == .failed)
    #expect(status("Document Needs Attention", succeeded: false) == .failed)
    #expect(status("Showing Last Preview · Check Source", stale: true) == .failed)
    for state in [CompileStatus.succeeded, .compiling, .failed, .offline] {
        #expect(!state.label.isEmpty)
    }
}

@Test func outlineAncestryGivesTheBreadcrumbPath() {
    let navigation = OutlineNavigation(items: [
        OutlineItem(title: "Introduction", level: 1, offset: 0),
        OutlineItem(title: "Method", level: 1, offset: 10),
        OutlineItem(title: "Procedure", level: 2, offset: 20),
        OutlineItem(title: "Adaptive staircase", level: 3, offset: 30),
        OutlineItem(title: "Results", level: 1, offset: 40),
    ])
    #expect(navigation.ancestry(of: 3).map { navigation.items[$0].title }
        == ["Method", "Procedure", "Adaptive staircase"])
    #expect(navigation.ancestry(of: 4) == [4])
    #expect(navigation.ancestry(of: 9).isEmpty)
}
