import Foundation
import PDFKit
@testable import ProseCore
import ProseTestSupport
import Testing

private func discoveryPackage(_ fields: [String: Any]) throws -> UniversePackage {
    try JSONDecoder().decode(UniversePackage.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func discoveryDirectory() throws -> URL {
    let directory = TestPaths.temporaryDirectory.appendingPathComponent("Prose-discovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func universeTemplateAndPackageDiscoveryByWritingIntent() throws {
    let packages = try [
        discoveryPackage([
            "name": "charged-ieee",
            "version": "0.1.4",
            "description": "An IEEE paper",
            "categories": ["paper"],
            "template": ["path": "template", "entrypoint": "main.typ", "thumbnail": "thumbnail.png"],
        ]),
        discoveryPackage([
            "name": "basic-resume",
            "version": "0.2.9",
            "description": "A simple resume",
            "categories": ["cv"],
            "template": ["path": "template", "entrypoint": "main.typ"],
        ]),
        discoveryPackage([
            "name": "fletcher",
            "version": "0.5.8",
            "description": "Diagrams with nodes and arrows",
            "keywords": ["flowchart"],
            "categories": ["visualization"],
        ]),
        discoveryPackage([
            "name": "codly",
            "version": "1.3.0",
            "description": "Code blocks with syntax highlighting",
            "categories": ["components"],
        ]),
        discoveryPackage(["name": "future", "version": "1.0.0", "description": "More diagrams", "compiler": "99.0.0"]),
    ]
    let catalog = UniverseCatalogSnapshot(packages: packages, fetchedAt: Date(), source: .cache)
    #expect(catalog.discover("", mode: .templates).map(\.name) == ["charged-ieee", "basic-resume"])
    #expect(catalog.discover("简历", mode: .templates).map(\.name) == ["basic-resume"])
    #expect(catalog.discover("", mode: .templates, group: "research").map(\.name) == ["charged-ieee"])
    #expect(catalog.discover("论文", mode: .templates).map(\.name) == ["charged-ieee"])
    #expect(catalog.discover("流程图", mode: .packages, compilerVersion: "0.15.1").map(\.name) == ["fletcher"])
    #expect(catalog.discover("code", mode: .packages, group: "code").map(\.name) == ["codly"])
    #expect(catalog.discover("代码块", mode: .packages).map(\.name) == ["codly"])
    #expect(catalog.discover("resume", mode: .packages).isEmpty)
    #expect(catalog.discover("", mode: .templates, group: "invalid").isEmpty)
    #expect(packages[0].thumbnailURL?
        .absoluteString == "https://packages.typst.org/preview/thumbnails/charged-ieee-0.1.4-small.webp")
    #expect(packages[2].thumbnailURL == nil)
    #expect(UniverseDiscoveryGroup.groups(for: .templates).count == 6)
    #expect(UniverseDiscoveryGroup.groups(for: .packages).count == 7)
    let roundTrip = try JSONDecoder().decode(UniversePackage.self, from: JSONEncoder().encode(packages[0]))
    #expect(roundTrip == packages[0])
}

@Test func universeDiscoveryIndexDoesNotDependOnCurrentLanguageAndRanksNames() throws {
    let packages = try [
        discoveryPackage([
            "name": "mention",
            "version": "1.0.0",
            "description": "Use cetz in text",
            "categories": ["text"],
        ]),
        discoveryPackage([
            "name": "cetz",
            "version": "0.4.2",
            "description": "Café drawing",
            "categories": ["visualization"],
        ]),
        discoveryPackage([
            "name": "cetz-plus",
            "version": "1.0.0",
            "description": "More drawing",
            "categories": ["visualization"],
        ]),
    ]
    let catalog = UniverseCatalogSnapshot(packages: packages, fetchedAt: Date(), source: .cache)
    #expect(catalog.discover("CETZ", mode: .packages).map(\.name) == ["cetz", "cetz-plus", "mention"])
    #expect(catalog.discover("cafe", mode: .packages).map(\.name) == ["cetz"])
    #expect(catalog.discover("绘图", mode: .packages, group: "draw").count == 2)
    #expect(catalog.search("文字").map(\.name) == ["mention"])
}

@Test func universeTemplateMetadataRejectsInvalidPathsAndToleratesMissingMetadata() throws {
    let noTemplate = try discoveryPackage(["name": "plain", "version": "1.0.0", "template": ["path": "template"]])
    #expect(noTemplate.template == nil)
    for path in ["../escape", "/absolute", "a/../b", "a//b", "a\\b", "a\nb"] {
        #expect(!UniverseTemplateMetadata(path: path, entrypoint: "main.typ").isValid)
        #expect(!UniverseTemplateMetadata(path: "template", entrypoint: path).isValid)
    }
    #expect(UniverseTemplateMetadata(path: ".", entrypoint: "chapters/main.typ").isValid)
    #expect(!UniverseTemplateMetadata(path: "template", entrypoint: "run.sh").isValid)
    let invalid = try discoveryPackage([
        "name": "../bad",
        "version": "1.0.0",
        "template": ["path": "template", "entrypoint": "main.typ"],
    ])
    #expect(invalid.thumbnailURL == nil)
}

@Test func universeTemplateProjectValidationPreservesNestedSourcesAndAssets() async throws {
    let root = try discoveryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("storage")
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    let linkedStorage = root.appendingPathComponent("linked-storage")
    try FileManager.default.createSymbolicLink(at: linkedStorage, withDestinationURL: storage)
    let project = linkedStorage.appendingPathComponent("project")
    let nested = project.appendingPathComponent("chapters")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let source = "= Template\n#image(\"../image.svg\")\n"
    try Data(source.utf8).write(to: nested.appendingPathComponent("main.typ"))
    let asset = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
    try asset.write(to: project.appendingPathComponent("image.svg"))
    let prepared = try UniverseTemplateInstaller.validateProject(at: project, entrypoint: "chapters/main.typ")
    #expect(prepared.directoryURL.path == project.resolvingSymlinksInPath().path)
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("library"))
    let document = try await library.importProject(
        at: prepared.directoryURL,
        mainFile: prepared.mainFileURL,
        title: "A template",
    )
    #expect(try await library.read(document.id).text == source)
    #expect(try Data(contentsOf: document.sourceURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("image.svg")) == asset)
    for entry in ["../outside.typ", "/etc/passwd", "chapters/main.txt", "chapters//main.typ"] {
        #expect(throws: UniverseTemplateError.self) { try UniverseTemplateInstaller.validateProject(
            at: project,
            entrypoint: entry,
        ) }
    }
    let linkedProject = root.appendingPathComponent("linked-project")
    try FileManager.default.createSymbolicLink(at: linkedProject, withDestinationURL: project)
    #expect(throws: UniverseTemplateError.self) { try UniverseTemplateInstaller.validateProject(
        at: linkedProject,
        entrypoint: "chapters/main.typ",
    ) }
    let outside = root.appendingPathComponent("outside.typ")
    try Data("Private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: project.appendingPathComponent("link.typ"),
        withDestinationURL: outside,
    )
    #expect(throws: UniverseTemplateError.self) { try UniverseTemplateInstaller.validateProject(
        at: project,
        entrypoint: "chapters/main.typ",
    ) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "Private")
    try FileManager.default.removeItem(at: project.appendingPathComponent("link.typ"))
    let linkedFolder = project.appendingPathComponent("linked-folder")
    try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: root)
    #expect(throws: UniverseTemplateError.self) { try UniverseTemplateInstaller.validateProject(
        at: project,
        entrypoint: "chapters/main.typ",
    ) }
    try FileManager.default.removeItem(at: linkedFolder)
    try FileManager.default.removeItem(at: nested.appendingPathComponent("main.typ"))
    try FileManager.default.createSymbolicLink(
        at: nested.appendingPathComponent("main.typ"),
        withDestinationURL: outside,
    )
    #expect(throws: UniverseTemplateError.self) { try UniverseTemplateInstaller.validateProject(
        at: project,
        entrypoint: "chapters/main.typ",
    ) }
}

#if os(macOS)
    /// Network is deliberately opt-in. Exercises the real official registry, manifest parser,
    /// asset scaffolding, managed-library import, and PDF export through the bundled Tinymist.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_UNIVERSE_NETWORK"] == "1"))
    func officialUniverseTemplateCreatesRenderableManagedDocument() async throws {
        let root = try discoveryDirectory()
        let client = TinymistClient()
        defer { client.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let package = try discoveryPackage([
            "name": "charged-ieee",
            "version": "0.1.4",
            "compiler": "0.12.0",
            "template": ["path": "template", "entrypoint": "main.typ", "thumbnail": "thumbnail.png"],
        ])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Exports"),
            withIntermediateDirectories: true,
        )
        try await client.start(root: root, outputDirectory: root.appendingPathComponent("Exports"))
        let project = try await UniverseTemplateInstaller.materialize(
            package,
            using: client,
            in: root.appendingPathComponent("Downloads"),
        )
        let files = try FileManager.default.subpathsOfDirectory(atPath: project.directoryURL.path)
        #expect(files.contains("main.typ"))
        #expect(files.contains { $0.hasSuffix(".bib") })
        let library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"))
        let document = try await library.importProject(
            at: project.directoryURL,
            mainFile: project.mainFileURL,
            title: "IEEE paper",
        )
        let content = try await library.read(document.id).text
        #expect(content.contains("@preview/charged-ieee:0.1.4"))
        // Removing staging proves subsequent editing no longer depends on the downloaded folder.
        try FileManager.default.removeItem(at: project.directoryURL)
        try client.open(document.sourceURL, text: content, version: 1)
        let result = try await client.command("tinymist.exportPdf", arguments: [document.sourceURL.path])
        let pdf = try #require(result["path"].string)
        #expect((PDFDocument(url: URL(fileURLWithPath: pdf))?.pageCount ?? 0) > 0)
        let reread = try await library.read(document.id)
        #expect(reread.text == content)
    }

#endif

@Test func universeDiscoveryLargeIndexKeepsRepeatedQueriesFast() throws {
    let packages = try (0 ..< 2000).map { index in
        try discoveryPackage([
            "name": "package-\(index)",
            "version": "1.0.0",
            "description": "Charts and diagrams for research papers with typography and tables",
            "keywords": ["flowchart", "plot", "data"],
            "categories": ["visualization"],
        ])
    }
    let catalog = UniverseCatalogSnapshot(packages: packages, fetchedAt: Date(), source: .cache)
    let start = ContinuousClock.now
    for _ in 0 ..< 30 {
        #expect(catalog.discover("流程图", mode: .packages, group: "draw").count == 2000)
        #expect(catalog.discover("package-1999", mode: .packages).first?.name == "package-1999")
    }
    // Generous CI budget. Guards against normalizing every field on every UI query again.
    #expect(start.duration(to: .now) < .seconds(2))
}

#if os(macOS)
    @MainActor
    @Test func universeTemplateRejectsInvalidRequestsBeforeCreatingProject() async throws {
        let root = try discoveryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("downloads")
        let client = TinymistClient()
        let plain = try discoveryPackage(["name": "plain", "version": "1.0.0"])
        await #expect(throws: UniverseTemplateError.self) { try await UniverseTemplateInstaller.materialize(
            plain,
            using: client,
            in: destination,
        ) }
        let fields: [String: Any] = [
            "name": "template",
            "version": "1.0.0",
            "compiler": "99.0.0",
            "template": ["path": "template", "entrypoint": "main.typ"],
        ]
        let incompatible = try discoveryPackage(fields)
        await #expect(throws: UniverseTemplateError.self) { try await UniverseTemplateInstaller.materialize(
            incompatible,
            using: client,
            in: destination,
        ) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let compatible = try discoveryPackage(fields.merging(
            ["compiler": "0.12.0"],
            uniquingKeysWith: { _, new in new },
        ))
        // A disconnected engine fails without leaving a half-created project in the library.
        await #expect(throws: ServiceError.self) { try await UniverseTemplateInstaller.materialize(
            compatible,
            using: client,
            in: destination,
        ) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let task = Task { try await UniverseTemplateInstaller.materialize(compatible, using: client, in: destination) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

#endif

@Test func universeOldOfflineIndexRemainsUsableAndRefreshesTemplateMetadata() async throws {
    let root = try discoveryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("index.json")
    let now = Date()
    let old: [String: Any] = [
        "schema": 1,
        "fetchedAt": now.timeIntervalSinceReferenceDate,
        "packages": [["name": "paper", "version": "1.0.0"]],
    ]
    try JSONSerialization.data(withJSONObject: old).write(to: cache)
    let offline = UniverseCatalogStore(
        cacheURL: cache,
        transport: { _ in throw URLError(.notConnectedToInternet) },
        now: { now },
    )
    #expect(try await offline.load().source == .offlineCache)
    #expect(try await offline.load().packages.first?.name == "paper")
    let updated = try JSONSerialization.data(withJSONObject: [[
        "name": "paper",
        "version": "1.0.0",
        "template": ["path": "template", "entrypoint": "main.typ"],
    ]])
    let online = UniverseCatalogStore(
        cacheURL: cache,
        transport: { _ in UniverseHTTPResponse(data: updated, statusCode: 200) },
        now: { now },
    )
    #expect(try await online.load().discover("", mode: .templates).first?.name == "paper")
    #expect(try await online.load().source == .cache)
}
