import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

private func sampleArchive() throws -> Data {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: repository.appendingPathComponent("Examples/Books/SICP/" + SampleBook.sicp.archiveName))
}

@Test func sampleBookDownloadCacheIndependentCopiesAndProjectMigration() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("Prose-books-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try sampleArchive()
    let book = SampleBook.sicp
    #expect(book.matches("sicp"))
    #expect(book.matches("计算机 书籍"))
    #expect(!book.matches("resume"))
    let cache = root.appendingPathComponent("Cache"), staging = root.appendingPathComponent("Staging")
    let store = SampleBookStore(cacheURL: cache, transport: { request in
        #expect(request.url == book.downloadURL)
        return UniverseHTTPResponse(data: archive, statusCode: 200)
    })
    let first = try await store.materialize(book, in: staging)
    let cloud = root.appendingPathComponent("Cloud")
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"), cloudResolver: { cloud })
    let one = try await library.importProject(at: first.directoryURL, mainFile: first.mainFileURL, title: book.title)
    try FileManager.default.removeItem(at: first.directoryURL)
    let original = try await library.read(one.id)
    #expect(original.text.contains("#import \"styles/book.typ\""))
    #expect(original.text.contains("```scheme"))
    #expect(try FileManager.default
        .subpathsOfDirectory(atPath: one.sourceURL.deletingLastPathComponent().appendingPathComponent("fig").path)
        .filter { $0.hasSuffix(".svg") }.count == 84)
    _ = try await library.save(one.id, text: original.text + "\nMy annotation.\n", baseline: original.baseline)

    // A new store, no network, same verified cache: independent second copy.
    let offline = SampleBookStore(cacheURL: cache, transport: { _ in throw URLError(.notConnectedToInternet) })
    let second = try await offline.materialize(book, in: staging)
    let two = try await library.importProject(at: second.directoryURL, mainFile: second.mainFileURL, title: book.title)
    #expect(one.id != two.id)
    #expect(try await library.read(two.id).text == original.text)
    #expect(try await library.read(one.id).text.hasSuffix("My annotation.\n"))
    let migrated = try await library.setICloudEnabled(true)
    #expect(migrated.copiedCount == 2)
    let cloudDocument = try await library.read(two.id).document
    let styles = cloudDocument.sourceURL.deletingLastPathComponent().appendingPathComponent("styles/book.typ")
    #expect(try String(contentsOf: styles, encoding: .utf8).contains("#let book(body)"))
    let exported = root.appendingPathComponent("Exported")
    try await library.exportProject(two.id, to: exported)
    #expect(try String(contentsOf: exported.appendingPathComponent("Project/styles/book.typ"), encoding: .utf8)
        .contains("set page"))
    #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("Project/LICENSE").path))
    #expect(try await library.list().count == 2, "A book remains one document, not a row for every dependency")
}

@Test func sampleBookRejectsCorruptionRetriesAndDoesNotLeavePartialDocuments() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("Prose-books-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try sampleArchive()
    let cache = root.appendingPathComponent("Cache"), staging = root.appendingPathComponent("Staging")
    for response in [
        UniverseHTTPResponse(data: archive, statusCode: 503),
        UniverseHTTPResponse(data: Data("broken".utf8), statusCode: 200),
        UniverseHTTPResponse(data: Data(repeating: 0, count: archive.count), statusCode: 200),
    ] {
        let broken = SampleBookStore(cacheURL: cache, transport: { _ in response })
        await #expect(throws: SampleBookError.self) { try await broken.materialize(.sicp, in: staging) }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 0, count: archive.count).write(to: cache.appendingPathComponent(SampleBook.sicp.archiveName))
    let repaired = SampleBookStore(
        cacheURL: cache,
        transport: { _ in UniverseHTTPResponse(data: archive, statusCode: 200) },
    )
    let project = try await repaired.materialize(.sicp, in: staging)
    #expect(FileManager.default.fileExists(atPath: project.mainFileURL.path))
    #expect(try Data(contentsOf: cache.appendingPathComponent(SampleBook.sicp.archiveName)) == archive)
    let task = Task { try await repaired.materialize(.sicp, in: staging) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
