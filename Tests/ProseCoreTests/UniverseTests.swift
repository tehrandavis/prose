import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

private let universeFixture = Data("""
[
 {"name":"cetz","version":"0.9.0","description":"Older drawing package","categories":["visualization"]},
 {"name":"cetz","version":"0.10.1","description":"Draw on a canvas","authors":["Example Author"],"license":"MIT","keywords":["draw","café"],"categories":["visualization"],"disciplines":["mathematics"],"compiler":"0.14.0","template":{"path":"template"}},
 {"name":"cetz","version":"0.10.0","description":"Previous version"},
 {"name":"fletcher","version":"0.5.8","description":"Draw diagrams with nodes and arrows","keywords":["flowchart","graph"],"categories":["visualization","components"]},
 {"name":"fletcher","version":"0.5.8","description":"Duplicate version"},
 {"name":"modern-text","version":"1.0.0","description":"Text tools","categories":["text"],"compiler":"0.16.0"},
 {"name":"minimal","version":"1.0.0"},
 {"name":"../escape","version":"1.0.0"},
 {"name":"invalid","version":"latest"}
]
""".utf8)

private actor UniverseTestServer {
    var response = UniverseHTTPResponse(data: universeFixture, statusCode: 200)
    var offline = false
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) throws -> UniverseHTTPResponse {
        requests.append(request)
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        return response
    }

    func setOffline(_ value: Bool) {
        offline = value
    }

    func setResponse(_ response: UniverseHTTPResponse) {
        self.response = response
    }
}

private func universeDirectory() throws -> URL {
    let directory = TestPaths.temporaryDirectory.appendingPathComponent("Prose-Universe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func universeDiscoverSearchAndInsertPinnedPackage() async throws {
    let directory = try universeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = UniverseTestServer()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = UniverseCatalogStore(
        cacheURL: directory.appendingPathComponent("index.json"),
        transport: { try await server.send($0) },
        now: { now },
    )
    let snapshot = try await store.load()
    #expect(snapshot.source == .network)
    #expect(snapshot.packages.map(\.name) == ["cetz", "fletcher", "minimal", "modern-text"])
    #expect(snapshot.search("cetz").first?.version == "0.10.1")
    #expect(snapshot.search("draw", category: "visualization").map(\.name) == ["cetz", "fletcher"])
    #expect(snapshot.search("FLOWCHART graph").map(\.name) == ["fletcher"])
    #expect(snapshot.search("cafe").first?.name == "cetz")
    #expect(snapshot.search("绘图").count == 2)
    #expect(snapshot.search("mathematics").first?.name == "cetz")
    #expect(snapshot.search("draw", category: "text").isEmpty)
    #expect(snapshot.search("nothing matches").isEmpty)
    #expect(UniverseCategory.title(for: "future-category") == "future-category")
    let selected = try #require(snapshot.search("fletcher").first)
    #expect(try selected.pinnedImport() == Snippet(text: "#import \"@preview/fletcher:0.5.8\"\n"))
    #expect(selected.documentationURL.absoluteString == "https://typst.app/universe/package/fletcher/0.5.8/")
    let request = try #require(await server.requests.first)
    #expect(request.url == UniverseCatalogStore.indexURL)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.timeoutInterval == 8)
    #expect(snapshot.search("minimal").first?.license == L10n.text("Unspecified"))
}

@Test func universeCacheOfflineRefreshAndRecovery() async throws {
    let directory = try universeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("nested/index.json")
    let server = UniverseTestServer()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = UniverseCatalogStore(cacheURL: cacheURL, transport: { try await server.send($0) }, now: { now })
    #expect(await store.cached() == nil)
    _ = try await store.load()
    let cache = try Data(contentsOf: cacheURL)
    let cached = try await store.load()
    #expect(cached.source == .cache)
    #expect(cached.fetchedAt == now)
    #expect(await server.requests.count == 1)
    await server.setOffline(true)
    let offline = try await store.load(forceRefresh: true)
    #expect(offline.source == .offlineCache)
    #expect(offline.packages == cached.packages)
    #expect(try Data(contentsOf: cacheURL) == cache)
    let later = now.addingTimeInterval(UniverseCatalogStore.cacheLifetime + 1)
    let expired = UniverseCatalogStore(cacheURL: cacheURL, transport: { try await server.send($0) }, now: { later })
    #expect(try await expired.load().source == .offlineCache)
    await server.setOffline(false)
    await server.setResponse(UniverseHTTPResponse(data: Data("not JSON".utf8), statusCode: 200))
    #expect(try await expired.load().source == .offlineCache)
    #expect(try Data(contentsOf: cacheURL) == cache)
    await server.setResponse(UniverseHTTPResponse(data: universeFixture, statusCode: 200))
    let refreshed = try await expired.load()
    #expect(refreshed.source == .network)
    #expect(refreshed.fetchedAt == later)
    #expect(try await expired.load().source == .cache)
}

@Test func universeInvalidIndexRetryAndUnavailableCache() async throws {
    let directory = try universeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("index.json")
    try Data("corrupt cache".utf8).write(to: cacheURL)
    let server = UniverseTestServer()
    let store = UniverseCatalogStore(cacheURL: cacheURL, transport: { try await server.send($0) })
    #expect(await store.cached() == nil)
    await server.setResponse(UniverseHTTPResponse(data: universeFixture, statusCode: 503))
    await #expect(throws: UniverseError.self) { try await store.load() }
    await server.setResponse(UniverseHTTPResponse(data: Data("[]".utf8), statusCode: 200))
    await #expect(throws: UniverseError.self) { try await store.load() }
    await server.setResponse(UniverseHTTPResponse(data: universeFixture, statusCode: 200))
    #expect(try await store.load().source == .network)
    #expect(await store.cached()?.packages.count == 4)
    // A directory at the cache file's path prevents persistence without preventing discovery.
    let noCache = UniverseCatalogStore(cacheURL: directory, transport: { try await server.send($0) })
    #expect(try await noCache.load().packages.count == 4)
    #expect(await noCache.cached() == nil)
    let unavailable = UniverseCatalogStore(
        cacheURL: directory.appendingPathComponent("missing.json"),
        transport: { _ in throw URLError(.timedOut) },
    )
    await #expect(throws: UniverseError.self) { try await unavailable.load() }
    for data in [Data("{}".utf8), Data("[]".utf8), Data(repeating: 0x20, count: 12 * 1024 * 1024 + 1)] {
        #expect(throws: UniverseError.self) { try UniverseCatalogStore.decodeIndex(data) }
    }
}

@Test func universeImportValidationAndCompilerRequirements() throws {
    let packages = try UniverseCatalogStore.decodeIndex(universeFixture)
    #expect(packages.first { $0.name == "cetz" }?.isCompatible(with: "0.15.1") == true)
    #expect(packages.first { $0.name == "modern-text" }?.isCompatible(with: "0.15.1") == false)
    #expect(packages.first { $0.name == "modern-text" }?.isCompatible(with: "0.16.0") == true)
    #expect(packages.first { $0.name == "minimal" }?.isCompatible(with: "0.15.1") == true)
    for (name, version) in [
        ("../escape", "1.0.0"),
        ("good\n", "1.0.0"),
        ("evil\"\n#panic()", "1.0.0"),
        ("good", "1.0.0\": *"),
        ("good", "1.0"),
        ("good", "1.-1.0"),
        ("good", "1.2.99999999999999999999999999999999999999"),
    ] {
        let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": version])
        let package = try JSONDecoder().decode(UniversePackage.self, from: data)
        #expect(throws: UniverseError.self) { try package.pinnedImport() }
    }
    #expect(UniverseError.invalidIndex.localizedDescription == L10n
        .text("The Universe index is invalid. Please refresh again later."))
    #expect(UniverseError.invalidPackage.localizedDescription == L10n
        .text("The package name or version is invalid, so an import cannot be generated."))
    #expect(UniverseError.unavailable.localizedDescription == L10n
        .text("Cannot reach Typst Universe. Refresh when connected; the cached index is still available."))
}

@Test func universeCancelledRefreshDoesNotReportOfflineSuccess() async throws {
    let directory = try universeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent("index.json")
    let populated = UniverseCatalogStore(
        cacheURL: cacheURL,
        transport: { _ in UniverseHTTPResponse(data: universeFixture, statusCode: 200) },
    )
    _ = try await populated.load()
    let cancelled = UniverseCatalogStore(cacheURL: cacheURL, transport: { _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) { try await cancelled.load(forceRefresh: true) }
}
