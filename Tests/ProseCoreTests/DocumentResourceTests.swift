import Foundation
import ImageIO
@testable import ProseCore
import ProseTestSupport
import Testing
import UniformTypeIdentifiers

private struct ResourceFixture {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("resources-" + UUID().uuidString)
    let svg = Data(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\"><rect width=\"24\" height=\"24\" fill=\"red\"/></svg>"
            .utf8,
    )

    func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = root.appendingPathComponent("main.typ")
        try Data("Body".utf8).write(to: document)
        return document
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func importedResourcesSurviveOriginalRemovalAndExportWithLibrary() async throws {
    let fixture = ResourceFixture()
    _ = try fixture.prepare()
    defer { fixture.close() }
    let library = DocumentLibrary(rootURL: fixture.root.appendingPathComponent("Library"))
    let document = try await library.create(text: "Body")
    let original = fixture.root.appendingPathComponent("图片 «示例» \"quoted\".svg")
    try fixture.svg.write(to: original)
    let store = DocumentResourceStore()
    let resources = try await store.importResources(
        [.file(original), .file(original)], kind: .image, in: document.folderURL, relativeTo: document.sourceURL,
    )
    #expect(resources.count == 2)
    #expect(resources[0].url != resources[1].url)
    #expect(resources[0].name == original.lastPathComponent)
    let snippet = try TypstInsertion.make("image", values: ["path": resources[0].relativePath])
    #expect(!snippet.text.contains(fixture.root.path))
    #expect(snippet.text.contains("\\\"quoted\\\""))
    _ = try await library.save(document.id, text: snippet.text, baseline: nil)
    try FileManager.default.removeItem(at: original)
    #expect(try Data(contentsOf: resources[0].url) == fixture.svg)
    #expect(try await store.list(kind: .image, in: document.folderURL, relativeTo: document.sourceURL).count == 2)
    let exported = fixture.root.appendingPathComponent("Export")
    try await library.exportProject(document.id, to: exported)
    #expect(try Data(contentsOf: exported.appendingPathComponent(resources[0].relativePath)) == fixture.svg)
    #expect(try await library.read(document.id).text == snippet.text)
}

@Test(arguments: [false, true])
func resourcesCreateAndReuseAssetsWithEitherDirectoryURLHint(directoryHint: Bool) async throws {
    let fixture = ResourceFixture()
    let document = try fixture.prepare()
    defer { fixture.close() }
    let original = fixture.root.appendingPathComponent("figure.svg")
    try fixture.svg.write(to: original)
    let root = URL(fileURLWithPath: fixture.root.path, isDirectory: directoryHint)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: assets.path))
    let store = DocumentResourceStore()
    let first = try await #require(store.importResources(
        [.file(original)], kind: .image, in: root, relativeTo: document,
    ).first)
    #expect(FileManager.default.fileExists(atPath: assets.path))
    let second = try await #require(store.importResources(
        [.file(original)], kind: .image, in: root, relativeTo: document,
    ).first)
    #expect(first.url != second.url)
    #expect(try Data(contentsOf: first.url) == fixture.svg)
    #expect(try Data(contentsOf: second.url) == fixture.svg)
    #expect(first.relativePath.hasPrefix("assets/"))
    #expect(second.relativePath.hasPrefix("assets/"))
}

@Test func resourcesUseTheActiveSubdocumentBaseAndSkipSymlinks() async throws {
    let fixture = ResourceFixture()
    let main = try fixture.prepare()
    defer { fixture.close() }
    let chapter = fixture.root.appendingPathComponent("chapters/chapter.typ")
    try FileManager.default.createDirectory(at: chapter.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("Chapter".utf8).write(to: chapter)
    let original = fixture.root.appendingPathComponent("figure.svg")
    try fixture.svg.write(to: original)
    let store = DocumentResourceStore()
    let resource = try await #require(store.importResources(
        [.file(original)], kind: .image, in: fixture.root, relativeTo: chapter,
    ).first)
    #expect(resource.relativePath.hasPrefix("../assets/"))
    #expect(chapter.deletingLastPathComponent().appendingPathComponent(resource.relativePath)
        .standardizedFileURL == resource.url)
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("linked.svg"),
        withDestinationURL: original,
    )
    let listed = try await store.list(kind: .image, in: fixture.root, relativeTo: main)
    #expect(listed.map(\.relativePath).count == 2, "Resources: \(listed.map(\.relativePath))")
    #expect(try await store.list(kind: .document, in: fixture.root, relativeTo: main).map(\.url) == [chapter])
    try await store.discardImport([resource])
    #expect(!FileManager.default.fileExists(atPath: resource.url.path))
}

@Test func invalidImportsRollBackTheBatchAndNeverFollowAssetDirectoryLinks() async throws {
    let fixture = ResourceFixture()
    let document = try fixture.prepare()
    defer { fixture.close() }
    let original = fixture.root.appendingPathComponent("figure.svg")
    try fixture.svg.write(to: original)
    let video = fixture.root.appendingPathComponent("movie.mp4")
    try Data("video".utf8).write(to: video)
    let store = DocumentResourceStore()
    await #expect(throws: DocumentResourceError.unsupported) {
        try await store.importResources(
            [.file(original), .file(video)],
            kind: .image,
            in: fixture.root,
            relativeTo: document,
        )
    }
    let assets = fixture.root.appendingPathComponent("assets")
    #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty)
    await #expect(throws: DocumentResourceError.invalidImage) {
        try await store.importResources(
            [.image(Data("broken".utf8))],
            kind: .image,
            in: fixture.root,
            relativeTo: document,
        )
    }
    await #expect(throws: DocumentResourceError.invalidLocation) {
        try await store.list(kind: .image, in: assets, relativeTo: document)
    }
    try FileManager.default.removeItem(at: assets)
    try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: fixture.root)
    await #expect(throws: DocumentResourceError.invalidLocation) {
        try await store.importResources([.file(original)], kind: .image, in: fixture.root, relativeTo: document)
    }
    #expect(try Data(contentsOf: original) == fixture.svg)
}

@Test func convertedImageFilesKeepFullResolutionAndApplyOrientation() async throws {
    let fixture = ResourceFixture()
    let document = try fixture.prepare()
    defer { fixture.close() }
    let context = try #require(CGContext(
        data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    try CGImageDestinationAddImage(
        destination,
        #require(context.makeImage()),
        [kCGImagePropertyOrientation: 6] as CFDictionary,
    )
    try #require(CGImageDestinationFinalize(destination))
    let original = fixture.root.appendingPathComponent("portrait.tiff")
    try (data as Data).write(to: original)
    let store = DocumentResourceStore()
    let resources = try await store.importResources(
        [.file(original), .image(data as Data)], kind: .image, in: fixture.root, relativeTo: document,
    )
    for resource in resources {
        #expect(resource.url.pathExtension == "png")
        let source = try #require(CGImageSourceCreateWithURL(resource.url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 3)
        #expect(image.height == 2)
    }
    try await store.discardImport(resources)
    #expect(resources.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(try Data(contentsOf: original) == data as Data)
}
