import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

private func libraryFixture() throws -> URL {
    #if os(iOS)
        // File coordination does not notify presenters for temporary sandbox files.
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
    #else
        let base = TestPaths.temporaryDirectory
    #endif
    let url = base.appendingPathComponent("Prose-library-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func emptyTrashRemovesConfirmedProjectsAndPreservesRestoredAndNewTrash() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DocumentLibrary(rootURL: root)
    let live = try await library.create(title: "Keep", text: "Live writing")
    let deleted = try await library.create(title: "Delete", text: "Old writing")
    let restored = try await library.create(title: "Restore", text: "Recovered writing")
    let later = try await library.create(title: "Later", text: "Not yet confirmed")
    let retrash = try await library.create(title: "Again", text: "A different trash generation")
    let attachment = deleted.folderURL.appendingPathComponent("figure.svg")
    try Data("<svg/>".utf8).write(to: attachment)
    for id in [deleted.id, restored.id, retrash.id] {
        _ = try await library.trash(id)
    }
    let snapshot = try await library.trashSnapshot()
    #expect(snapshot.count == 3)
    _ = try await library.restore(restored.id)
    _ = try await library.restore(retrash.id)
    _ = try await library.trash(retrash.id)
    _ = try await library.trash(later.id)
    let result = try await library.emptyTrash(snapshot)
    #expect(result.deletedCount == 1)
    #expect(result.issues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: deleted.folderURL.path))
    #expect(!FileManager.default.fileExists(atPath: attachment.path))
    #expect(try await library.read(live.id).text == "Live writing")
    #expect(try await library.read(restored.id).document.isTrashed == false)
    #expect(try await library.read(later.id).document.isTrashed)
    #expect(try await library.read(retrash.id).document.isTrashed)
    #expect(try await library.emptyTrash(snapshot).deletedCount == 0)
    #expect(try await library.emptyTrash(library.trashSnapshot()).deletedCount == 2)
    #expect(try await library.trashSnapshot().isEmpty)
    #expect(try await library.emptyTrash(library.trashSnapshot()).deletedCount == 0)
}

@Test func emptyTrashReportsFailuresAndRejectsChangedLibrary() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cloud = root.appendingPathComponent("Cloud")
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("Local"), cloudResolver: { cloud })
    let good = try await library.create(title: "Good", text: "Delete me")
    let corrupt = try await library.create(title: "Corrupt", text: "Preserve me")
    let linked = try await library.create(title: "Linked", text: "Outside library")
    for id in [good.id, corrupt.id, linked.id] {
        _ = try await library.trash(id)
    }
    let snapshot = try await library.trashSnapshot()
    try Data("broken".utf8).write(to: corrupt.folderURL.appendingPathComponent("document.json"))
    let outside = root.appendingPathComponent("Outside")
    try FileManager.default.moveItem(at: linked.folderURL, to: outside)
    try FileManager.default.createSymbolicLink(at: linked.folderURL, withDestinationURL: outside)
    let result = try await library.emptyTrash(snapshot)
    #expect(result.deletedCount == 1)
    #expect(result.issues.count == 2)
    #expect(try String(contentsOf: corrupt.sourceURL, encoding: .utf8) == "Preserve me")
    #expect(try String(contentsOf: outside.appendingPathComponent("main.typ"), encoding: .utf8) == "Outside library")
    _ = try await library.resumeICloud()
    await #expect(throws: LibraryError.self) { try await library.emptyTrash(snapshot) }
}

@Test func libraryCreateEditSearchRenameTrashRestore() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DocumentLibrary(rootURL: root)
    #expect(try await library.list().isEmpty)
    let initial = try await library.create(
        title: "  Café journal  ",
        text: "#set text(size: 11pt)\n// Writing notes\n= Spring\n\nHello 世界 👋",
    )
    #expect(initial.title == "Café journal")
    #expect(initial.sourceURL.lastPathComponent == "main.typ")
    #expect(initial.snippet == "Hello 世界 👋")
    #expect(initial.folderURL.lastPathComponent == initial.id.uuidString)
    let opened = try await library.read(initial.id)
    #expect(opened.text.contains("世界"))
    let saved = try await library.save(
        initial.id,
        text: opened.text + "\nA distant keyword: telescope",
        baseline: opened.baseline,
    )
    #expect(saved.baseline.data == Data(saved.text.utf8))
    #expect(try await library.list(query: "CAFE telescope").map(\.id) == [initial.id])
    #expect(try await library.list(query: "missing").isEmpty)
    let renamed = try await library.rename(initial.id, title: "Spring notes")
    #expect(renamed.id == initial.id)
    #expect(renamed.sourceURL == initial.sourceURL)
    #expect(renamed.snippet.contains("telescope"))
    #expect(try await library.documentID(for: initial.sourceURL) == initial.id)
    #expect(try await library.documentID(for: root.appendingPathComponent("outside.typ")) == nil)
    #expect(try await library.documentID(for: initial.folderURL.appendingPathComponent("other.typ")) == nil)
    let trashed = try await library.trash(initial.id)
    #expect(trashed.isTrashed)
    #expect(try await library.list().isEmpty)
    #expect(try await library.list(includeTrashed: true).count == 1)
    #expect(try String(contentsOf: initial.sourceURL, encoding: .utf8) == saved.text)
    #expect(try await library.trash(initial.id).trashedAt == trashed.trashedAt)
    #expect(try await library.restore(initial.id).isTrashed == false)
    let reopened = DocumentLibrary(rootURL: root)
    #expect(try await reopened.read(initial.id).text == saved.text)
    #expect(try await reopened.list().first?.title == "Spring notes")
    await #expect(throws: LibraryError.self) { try await library.rename(initial.id, title: " \n") }
    await #expect(throws: LibraryError.self) { try await library.create(title: String(repeating: "a", count: 201)) }
    await #expect(throws: LibraryError.self) { try await library.read(UUID()) }
    #expect(try await library.create().title.isEmpty == false)
}

@Test func libraryBaselineProtectsExternalEditsAndMissingFiles() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DocumentLibrary(rootURL: root)
    let document = try await library.create(title: "Shared", text: "Original")
    let opened = try await library.read(document.id)
    _ = try DocumentStorage.write("Other device", to: document.sourceURL, baseline: opened.baseline)
    await #expect(throws: DocumentStorageError.self) { try await library.save(
        document.id,
        text: "Local edit",
        baseline: opened.baseline,
    ) }
    #expect(try await library.read(document.id).text == "Other device")
    #expect(try await library.list().first?.snippet == "Other device")
    try FileManager.default.removeItem(at: document.sourceURL)
    await #expect(throws: DocumentStorageError.self) { try await library.save(
        document.id,
        text: "Do not recreate",
        baseline: opened.baseline,
    ) }
}

@Test func libraryImportsAndExportsSelfContainedProjectWithoutChangingOriginals() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Original")
    let main = project.appendingPathComponent("chapters/main.typ")
    try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("images"),
        withIntermediateDirectories: true,
    )
    let source = "= Project\n#image(\"../images/figure.svg\")"
    try Data(source.utf8).write(to: main)
    let image = Data("<svg/>".utf8)
    try image.write(to: project.appendingPathComponent("images/figure.svg"))
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"))
    let imported = try await library.importProject(at: project, mainFile: main, title: "Imported project")
    #expect(try await library.read(imported.id).text == source)
    #expect(imported.sourceURL.path.hasSuffix("Project/chapters/main.typ"))
    #expect(try Data(contentsOf: imported.folderURL.appendingPathComponent("Project/images/figure.svg")) == image)
    let single = try await library.importDocument(at: main)
    #expect(single.title == "main")
    let export = root.appendingPathComponent("Export")
    try await library.exportProject(imported.id, to: export)
    #expect(try String(contentsOf: export.appendingPathComponent("Project/chapters/main.typ"), encoding: .utf8) ==
        source)
    #expect(try Data(contentsOf: export.appendingPathComponent("Project/images/figure.svg")) == image)
    #expect(!FileManager.default.fileExists(atPath: export.appendingPathComponent("document.json").path))
    #expect(try String(contentsOf: export.appendingPathComponent("PROSE-ENTRYPOINT.txt"), encoding: .utf8)
        .contains("Project/chapters/main.typ"))
    let plain = root.appendingPathComponent("export.typ")
    try await library.exportSource(single.id, to: plain)
    await #expect(throws: LibraryError.self) { try await library.exportSource(single.id, to: plain) }
    await #expect(throws: LibraryError.self) { try await library.exportProject(imported.id, to: export) }
    #expect(try String(contentsOf: main, encoding: .utf8) == source)
    await #expect(throws: LibraryError.self) { try await library.importProject(
        at: project.appendingPathComponent("images"),
        mainFile: main,
    ) }
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: root)
    await #expect(throws: LibraryError.self) { try await library.importProject(at: project, mainFile: main) }
    #expect(try await library.list().count == 2)
}

@Test func libraryCorruptMetadataAndPathTraversalPreserveFiles() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DocumentLibrary(rootURL: root)
    let good = try await library.create(title: "Good", text: "safe")
    let damaged = try await library.create(title: "Damaged", text: "preserve this")
    let metadataURL = damaged.folderURL.appendingPathComponent("document.json")
    let original = try Data(contentsOf: metadataURL)
    try Data("{broken".utf8).write(to: metadataURL)
    #expect(try await library.list().map(\.id) == [good.id])
    #expect(await library.issues.count == 1)
    #expect(try String(contentsOf: damaged.sourceURL, encoding: .utf8) == "preserve this")
    var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    object["sourcePath"] = "../../outside.typ"
    try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
    await #expect(throws: LibraryError.self) { try await library.read(damaged.id) }
    try original.write(to: metadataURL)
    #expect(try await library.list().count == 2)
    let outside = root.appendingPathComponent("outside.typ")
    try Data("Outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: damaged.sourceURL)
    try FileManager.default.createSymbolicLink(at: damaged.sourceURL, withDestinationURL: outside)
    await #expect(throws: LibraryError.self) { try await library.read(damaged.id) }
}

@Test func libraryCloudMigrationPreservesBothSidesAndResumeDoesNotDuplicate() async throws {
    let fixture = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let localRoot = fixture.appendingPathComponent("Local")
    let cloudContainer = fixture.appendingPathComponent("Cloud")
    let local = DocumentLibrary(rootURL: localRoot, cloudResolver: { cloudContainer })
    let created = try await local.create(title: "Shared", text: "Local original")
    let enabled = try await local.setICloudEnabled(true)
    #expect(enabled.isICloud)
    #expect(enabled.copiedCount == 1)
    #expect(enabled.conflictCopies == 0)
    #expect(FileManager.default.fileExists(atPath: created.sourceURL.path))
    let cloudRead = try await local.read(created.id)
    #expect(cloudRead.document.sourceURL != created.sourceURL)
    _ = try await local.save(created.id, text: "New remote content", baseline: cloudRead.baseline)
    let restarted = DocumentLibrary(rootURL: localRoot, cloudResolver: { cloudContainer })
    _ = try await restarted.resumeICloud()
    #expect(try await restarted.list().count == 1)
    #expect(try await restarted.read(created.id).text == "New remote content")
    #expect(try await restarted.setICloudEnabled(true).copiedCount == 0)
    let staleLocal = DocumentLibrary(rootURL: localRoot, cloudResolver: { cloudContainer })
    let conflict = try await staleLocal.setICloudEnabled(true)
    #expect(conflict.conflictCopies == 1)
    let copiedID = try #require(conflict.idMappings[created.id])
    #expect(copiedID != created.id)
    #expect(try await staleLocal.read(created.id).text == "New remote content")
    #expect(try await staleLocal.read(copiedID).text == "Local original")
    let repeated = DocumentLibrary(rootURL: localRoot, cloudResolver: { cloudContainer })
    let repeatReport = try await repeated.setICloudEnabled(true)
    #expect(repeatReport.copiedCount == 0)
    #expect(repeatReport.idMappings[created.id] == copiedID)
    let preserved = try await repeated.read(copiedID)
    _ = try await repeated.save(copiedID, text: "Edited preserved copy", baseline: preserved.baseline)
    let another = DocumentLibrary(rootURL: localRoot, cloudResolver: { cloudContainer })
    let anotherReport = try await another.setICloudEnabled(true)
    #expect(anotherReport.conflictCopies == 1)
    #expect(anotherReport.idMappings[created.id] != copiedID)
    #expect(try await repeated.read(copiedID).text == "Edited preserved copy")
    let disabled = try await restarted.setICloudEnabled(false)
    #expect(disabled.isICloud == false)
    let newLocal = try #require(disabled.idMappings[created.id])
    #expect(try await restarted.read(newLocal).text == "New remote content")
    #expect(try String(contentsOf: created.sourceURL, encoding: .utf8) == "Local original")
    #expect(try await local.read(created.id).text == "New remote content")
}

@Test func libraryCloudUnavailableLeavesLocalLibraryIntact() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = DocumentLibrary(rootURL: root, cloudResolver: { throw LibraryError.cloudAccountUnavailable })
    let document = try await library.create(title: "Offline", text: "Keep writing")
    await #expect(throws: LibraryError.self) { try await library.setICloudEnabled(true) }
    await #expect(throws: LibraryError.self) { try await library.resumeICloud() }
    #expect(await library.rootURL == root.standardizedFileURL)
    #expect(await library.isICloud == false)
    #expect(try await library.read(document.id).text == "Keep writing")
    #expect(LibraryCloudEnvironment.state(of: document.sourceURL) == .local)
    try LibraryCloudEnvironment.requestDownloadIfNeeded(document.sourceURL)
    #expect(throws: LibraryError.self) { try LibraryCloudEnvironment.containerURL(identifier: "invalid.test.container")
    }
}

private final class LibraryEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

@Test func libraryPresenterAndAccountNotifications() async throws {
    let root = try libraryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = LibraryEventCounter()
    let monitor = LibraryFileMonitor(rootURL: root) { counter.increment() }
    defer { monitor.stop() }
    #expect(NSFileCoordinator.filePresenters.contains { $0 === monitor })
    try CoordinatedFileAccess.write(root) { folder in
        try Data("Hello".utf8).write(to: folder.appendingPathComponent("main.typ"))
    }
    for _ in 0 ..< 50 where counter.value == 0 {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(counter.value > 0)
    let account = LibraryAccountMonitor { counter.increment() }
    let before = counter.value
    NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
    #expect(counter.value > before)
    withExtendedLifetime((monitor, account)) {}
}
