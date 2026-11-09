import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

// Phase 5 step F: an opt-in check of `HTTPZoteroSource` against the real
// Zotero library on this Mac (citations note, step D outcome). It runs only
// with `PROSE_REAL_ZOTERO=1`, which `scripts/test.sh` never sets. It only
// reads from Zotero and writes only inside its own temporary folder.

/// Runs `body` and prints how long it took.
private func timed<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let elapsed = start.duration(to: clock.now)
    let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    print("PROSE REAL ZOTERO \(label): \(String(format: "%.1f", milliseconds)) ms")
    return value
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_REAL_ZOTERO"] == "1"))
func realZoteroLibraryAnswersEveryCallProseMakes() async throws {
    let zotero = HTTPZoteroSource()
    let key = "Furmanek_2019_Coordination"

    let status = try await timed("ready") { try await zotero.ready() }
    print("PROSE REAL ZOTERO versions: Zotero \(status.zotero), Better BibTeX \(status.betterBibTeX)")
    #expect(!status.zotero.isEmpty)
    #expect(!status.betterBibTeX.isEmpty)

    // One word goes to Better BibTeX as it is.
    let furmanek = try await timed("search Furmanek") { try await zotero.search("Furmanek") }
    let item = try #require(furmanek.first { $0.key == key })
    #expect(!item.itemKey.isEmpty)

    // Two words: the policy sends the longest word and filters by both.
    let query = "Furmanek coordination"
    let word = try #require(ZoteroSearch.remoteWord(for: query))
    #expect(word == "coordination")
    let wide = try await timed("search \(word)") { try await zotero.search(word) }
    let rows = ZoteroSearch.results(wide, query: query, collectionItems: [], projectKeys: [])
    print("PROSE REAL ZOTERO search \(word): \(wide.count) items, \(rows.count) rows for \"\(query)\"")
    #expect(rows.contains { $0.item.key == key })

    // A broad query: the answer holds raw control characters from abstracts.
    let broad = try await timed("search the") { try await zotero.search("the") }
    let broadRows = ZoteroSearch.results(broad, query: "the", collectionItems: [], projectKeys: [])
    print("PROSE REAL ZOTERO search the: \(broad.count) items, \(broadRows.count) rows")
    #expect(broad.count > ZoteroSearch.limit)
    #expect(broadRows.count <= ZoteroSearch.limit)

    // Export, then parse the entry with the engine's bibliography parser.
    let exported = try await timed("export") { try await zotero.export([key]) }
    #expect(exported.contains("{\(key),"))
    let root = TestPaths.temporaryDirectory.appendingPathComponent("real-zotero-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "@\(key)\n\n#bibliography(\"refs.bib\")\n".write(
        to: root.appendingPathComponent("main.typ"),
        atomically: true,
        encoding: .utf8,
    )
    try exported.write(to: root.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
    let renderer = try await BlockRenderer(root: root, main: root.appendingPathComponent("main.typ"))
    let contents = await timed("parse export") { await renderer.bibliography(["refs.bib"]) }
    #expect(contents.errors.isEmpty)
    let entry = try #require(contents.entries.first { $0.key == key })
    print("PROSE REAL ZOTERO entry: \(entry.title ?? "no title") (\(entry.year.map(String.init) ?? "no year"))")
    #expect(entry.title?.localizedCaseInsensitiveContains("coordination") == true)
    #expect(entry.year == 2019)
    #expect(entry.year == item.year)

    // Collections, and a search inside one that holds the item.
    let collections = try await timed("collections") { try await zotero.collections() }
    print("PROSE REAL ZOTERO collections: \(collections.count)")
    #expect(collections.count > 1)
    let memberships = try await timed("itemCollections") { try await zotero.itemCollections([key]) }
    let collection = try #require(memberships[key]?.first)
    print("PROSE REAL ZOTERO item collection: \(collection.name)")
    let inCollection = try await timed("collection search Furmanek") {
        try await zotero.collectionItems(collection.key, query: "Furmanek")
    }
    #expect(inCollection.contains(item.itemKey))
}
