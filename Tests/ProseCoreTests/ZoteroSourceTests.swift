import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

// Phase 5 step E: the Zotero client, the search policy, the link record and
// `references-prose.bib` (citations note, step D outcome). Nothing here
// contacts Zotero: requests go to a `URLProtocol` stub or to a closed port.

// MARK: - A stub for Zotero's port

/// Answers requests for hosts ending in `.zotero-stub`, each host with its
/// own script, so tests running in parallel do not share answers.
private final class ZoteroStub: URLProtocol, @unchecked Sendable {
    struct Request {
        let path: String
        let query: [String: String]
        let body: [String: Any]?
    }

    typealias Script = @Sendable (_ path: String, _ method: String?, _ params: [Any]) -> (Int, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var scripts: [String: Script] = [:]
    private nonisolated(unsafe) static var requests: [String: [String]] = [:]

    /// A base URL whose requests `script` answers.
    static func base(_ script: @escaping Script) -> URL {
        let host = "z\(UUID().uuidString.prefix(8).lowercased()).zotero-stub"
        lock.withLock { scripts[host] = script }
        return URL(string: "http://\(host):23119") ?? URL(fileURLWithPath: "/")
    }

    static func methods(for base: URL) -> [String] {
        lock.withLock { requests[base.host ?? ""] ?? [] }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".zotero-stub") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let script = Self.lock.withLock({ Self.scripts[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var method: String?
        var params: [Any] = []
        if let body = Self.body(of: request),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            method = object["method"] as? String
            params = object["params"] as? [Any] ?? []
        }
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        Self.lock.withLock { Self.requests[host, default: []].append(method ?? path) }
        let (status, data) = script(url.path, method, params + (url.query.map { [$0] } ?? []))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A Better BibTeX answer as captured in step D, with the raw tab and line
/// breaks its abstracts carry inside strings.
private let capturedSearch: Data = {
    let parts: [String] = [
        #"{"jsonrpc":"2.0","result":[{"id":"http://zotero.org/users/2104204/items/NSPZRSQM","#,
        #""type":"article-journal","title":"Coordination dynamics of \"joint\" action","#,
        #""author":[{"family":"Furmanek","given":"Mariusz P."},{"family":"Davis","given":"Tehran J."}],"#,
        #""issued":{"date-parts":[["2019",5]]},"container-title":"Human Movement Science","#,
        #""DOI":"10.1016/j.humov.2019.01.001","abstract":"First line"#,
        "\n\tSecond line\u{1}",
        #"","citekey":"Furmanek_2019_Coordination","citation-key":"Furmanek_2019_Coordination"},"#,
        #"{"id":"http://zotero.org/groups/77/items/ABCD1234","type":"book","title":"Group Book","#,
        #""editor":[{"literal":"The Committee"}],"issued":{"literal":"circa 1999"},"#,
        #""citation-key":"Committee_1999"},{"id":"x","title":"No key"}],"id":1}"#,
    ]
    return Data(parts.joined().utf8)
}()

private func rpc(_ result: Any) -> (Int, Data) {
    (200, (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "result": result, "id": 1])) ?? Data())
}

// MARK: - JSON

@Test func controlCharactersInsideStringsAreEscapedBeforeDecoding() throws {
    // Strict JSON forbids raw control characters in strings.
    #expect((try? JSONSerialization.jsonObject(with: capturedSearch)) == nil)
    let escaped = ZoteroJSON.escapingControlCharacters(capturedSearch)
    let text = try #require(String(data: escaped, encoding: .utf8))
    #expect(text.contains(#"First line\u000a\u0009Second line\u0001""#))
    // An escaped quote does not end the string.
    #expect(text.contains(#"Coordination dynamics of \"joint\" action"#))
    let object = try #require(try ZoteroJSON.object(from: capturedSearch) as? [String: Any])
    let items = try #require(object["result"] as? [[String: Any]])
    #expect(items.first?["abstract"] as? String == "First line\n\tSecond line\u{1}")
    // Whitespace between tokens is kept as it is, and clean data is untouched.
    let spaced = Data("{\n\t\"a\": \"b\\n\"\r\n}".utf8)
    #expect(ZoteroJSON.escapingControlCharacters(spaced) == spaced)
    let raw = Data("[\"a\u{0}b\", \"\\\\\", \"c\u{1F}\"]".utf8)
    #expect(String(data: ZoteroJSON.escapingControlCharacters(raw), encoding: .utf8)
        == #"["a\u0000b", "\\", "c\u001f"]"#)
}

// MARK: - The client

@Test func httpSourceSpeaksBetterBibTeXAndTheLocalAPI() async throws {
    let base = ZoteroStub.base { path, method, params in
        switch method {
        case "api.ready": return rpc(["zotero": "10.0.8", "betterbibtex": "9.0.77"])
        case "item.search":
            return params.first as? String == "Furmanek" ? (200, capturedSearch) : rpc([Any]())
        case "item.export":
            let keys = params.first as? [String] ?? []
            #expect(params.last as? String == "Better BibLaTeX")
            return rpc(keys.map { "@article{\($0),\n  title = {T},\n}\n" }.joined())
        case "item.collections":
            return rpc(["Furmanek_2019_Coordination": [
                ["key": "COLL1", "name": "Thesis", "parentCollection": false],
            ]])
        case nil where path == "/api/users/0/collections":
            return (
                200,
                Data(#"[{"key":"P1","data":{"name":"Work","parentCollection":false}},"#.utf8)
                    + Data(#"{"key":"C1","data":{"name":"Thesis","parentCollection":"P1"}}]"#.utf8),
            )
        case nil where path == "/api/users/0/collections/C1/items/top":
            #expect((params.last as? String)?.contains("q=Furmanek") == true)
            return (200, Data(#"[{"key":"NSPZRSQM","data":{"title":"x"}}]"#.utf8))
        default:
            return (200, Data(#"{"jsonrpc":"2.0","error":{"code":-32601,"message":"no such method"},"id":1}"#.utf8))
        }
    }
    let source = HTTPZoteroSource(base: base, configuration: ZoteroStub.configuration)
    #expect(try await source.ready() == ZoteroStatus(zotero: "10.0.8", betterBibTeX: "9.0.77"))

    let items = try await source.search("Furmanek")
    #expect(items.map(\.key) == ["Furmanek_2019_Coordination", "Committee_1999"])
    let first = try #require(items.first)
    #expect(first.itemKey == "NSPZRSQM")
    #expect(first.title == "Coordination dynamics of \"joint\" action")
    #expect(first.authors == [
        .init(family: "Furmanek", given: "Mariusz P."), .init(family: "Davis", given: "Tehran J."),
    ])
    #expect(first.year == 2019 && first.container == "Human Movement Science")
    #expect(first.doi == "10.1016/j.humov.2019.01.001" && first.kind == "article-journal")
    #expect(first.leadAuthor == "Furmanek et al.")
    #expect(first.selectURL?.absoluteString == "zotero://select/library/items/NSPZRSQM")
    let group = items[1]
    #expect(group.authors.map(\.family) == ["The Committee"] && group.year == 1999)
    #expect(group.selectURL?.absoluteString == "zotero://select/groups/77/items/ABCD1234")
    #expect(try await source.search("nothing").isEmpty)

    let exported = try await source.export(["Furmanek_2019_Coordination"])
    #expect(ProseBibliography.keys(in: exported) == ["Furmanek_2019_Coordination"])
    let memberships = try await source.itemCollections(["Furmanek_2019_Coordination"])
    #expect(memberships["Furmanek_2019_Coordination"] == [ZoteroCollection(key: "COLL1", name: "Thesis")])

    let collections = try await source.collections()
    #expect(collections == [
        ZoteroCollection(key: "P1", name: "Work"), ZoteroCollection(key: "C1", name: "Thesis", parent: "P1"),
    ])
    #expect(ZoteroCollection.paths(collections).map(\.path) == ["Work", "Work / Thesis"])
    #expect(try await source.collectionItems("C1", query: "Furmanek") == ["NSPZRSQM"])
    #expect(ZoteroStub.methods(for: base).contains("item.search"))
}

@Test func httpSourceReportsAMissingBetterBibTeXAndServerErrors() async throws {
    // Zotero answers its connector ping, but the JSON-RPC endpoint is missing.
    let missing = ZoteroStub.base { path, _, _ in
        path == "/connector/ping" ? (200, Data("Zotero is running".utf8)) : (404, Data("No endpoint".utf8))
    }
    let source = HTTPZoteroSource(base: missing, configuration: ZoteroStub.configuration)
    await #expect(throws: ZoteroError.betterBibTeXMissing) { try await source.ready() }

    // An unknown method is an error, not an empty result.
    let old = ZoteroStub.base { _, _, _ in
        (200, Data(#"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}"#.utf8))
    }
    let oldSource = HTTPZoteroSource(base: old, configuration: ZoteroStub.configuration)
    await #expect(throws: ZoteroError.server("Method not found")) { try await oldSource.search("Smith") }
    // `api.ready` fails while Zotero answers its ping.
    await #expect(throws: ZoteroError.betterBibTeXMissing) { try await oldSource.ready() }
    let garbled = ZoteroStub.base { _, _, _ in (200, Data("<html>".utf8)) }
    let garbledSource = HTTPZoteroSource(base: garbled, configuration: ZoteroStub.configuration)
    await #expect(throws: ZoteroError.self) { try await garbledSource.export(["a"]) }
    await #expect(throws: ZoteroError.self) { try await garbledSource.collections() }
    #expect(ZoteroError.notRunning.errorDescription == "Zotero is not running.")
    #expect(ZoteroError.betterBibTeXMissing.errorDescription?.contains("Better BibTeX") == true)
    #expect(ZoteroError.server("x").errorDescription?.contains("x") == true)
}

@Test func httpSourceSaysNotRunningAtOnceWhenNothingListens() async throws {
    let port = closedLoopbackPort()
    let source = try HTTPZoteroSource(base: #require(URL(string: "http://127.0.0.1:\(port)")))
    let start = ContinuousClock.now
    await #expect(throws: ZoteroError.notRunning) { try await source.ready() }
    await #expect(throws: ZoteroError.notRunning) { try await source.search("Smith") }
    // Alone this takes about 40 ms. With the core suites running in parallel a
    // refused loopback connection can take a second or more, so the bound only
    // rules out a hang: each request times out after 2 s, a resource after 10 s.
    #expect(ContinuousClock.now - start < .seconds(6))
}

/// A loopback port nothing listens on. Port 1 needs root to listen on and
/// nothing does on macOS, so a connection is refused at once. (A port bound,
/// read and closed could be taken by a parallel test before the request.)
private func closedLoopbackPort() -> UInt16 {
    1
}

// MARK: - Search policy

@Test func zoteroSearchSendsTheLongestWordAndFiltersByEveryWord() {
    #expect(ZoteroSearch.remoteWord(for: "Fu") == nil)
    #expect(ZoteroSearch.remoteWord(for: "a b c") == nil)
    #expect(ZoteroSearch.remoteWord(for: "  Furmanek ") == "Furmanek")
    #expect(ZoteroSearch.remoteWord(for: "2019 Furmanek coordination") == "coordination")
    #expect(ZoteroSearch.remoteWord(for: "abc xyz") == "abc")

    func item(_ index: Int, family: String = "Smith", title: String = "Walking", year: Int = 2020) -> ZoteroItem {
        ZoteroItem(
            key: "\(family)_\(year)_\(index)",
            itemKey: "K\(index)",
            title: title,
            authors: [.init(family: family, given: "A.")],
            year: year,
        )
    }
    let items = [
        item(1, family: "Dübois", title: "Joint action"),
        item(2, title: "Joint action in pairs", year: 2019),
        item(3, title: "Running"),
        item(4, family: "Jones", title: "Joint attention", year: 2019),
    ]
    // Every word, across family names, title, year and key, ignoring case
    // and diacritics; the linked collection's items first.
    let results = ZoteroSearch.results(
        items,
        query: "joint 2019",
        collectionItems: ["K4"],
        projectKeys: ["Smith_2019_2"],
    )
    #expect(results.map(\.item.itemKey) == ["K4", "K2"])
    #expect(results.map(\.inCollection) == [true, false])
    #expect(results.map(\.inProject) == [false, true])
    #expect(ZoteroSearch.results(items, query: "DUBOIS", collectionItems: [], projectKeys: [])
        .map(\.item.itemKey) == ["K1"])
    #expect(ZoteroSearch.results(items, query: "smith_2020_3", collectionItems: [], projectKeys: [])
        .map(\.item.itemKey) == ["K3"])
    // Words outside these fields do not count.
    #expect(ZoteroSearch.results(items, query: "pairs walking", collectionItems: [], projectKeys: []).isEmpty)
    // At most 50, the collection's first; a key Zotero lists twice once.
    let many = (0 ..< 80).map { item($0) } + [item(3)]
    let limited = ZoteroSearch.results(many, query: "smith", collectionItems: ["K70", "K75"], projectKeys: [])
    #expect(limited.count == ZoteroSearch.limit)
    #expect(limited.prefix(2).map(\.item.itemKey) == ["K70", "K75"])
    #expect(Set(limited.map(\.item.key)).count == limited.count)
}

// MARK: - The link

@Test func aZoteroLinkIsStoredWithTheProjectInRecentJSON() throws {
    let base = TestPaths.temporaryDirectory.appendingPathComponent("zotero-link-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appendingPathComponent("Paper")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = ProjectStore(directory: base.appendingPathComponent("Projects"))
    var record = try store.remember(folder)
    #expect(record.zotero == nil)
    let link = ZoteroLink(bibliography: "refs.bib", collection: "C1", collectionName: "Work / Thesis")
    record.zotero = link
    try store.update(record)
    // Reopening keeps it; nothing is written into the folder.
    let reopened = try store.remember(folder)
    #expect(reopened.zotero == link)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    let json = try String(contentsOf: base.appendingPathComponent("Projects/recent.json"), encoding: .utf8)
    #expect(json.contains("\"collectionName\" : \"Work \\/ Thesis\""))
    // A record written before step E has no link and still reads.
    let old = json.replacingOccurrences(of: #""zotero" : \{[^}]*\},?"#, with: "", options: .regularExpression)
    try Data(old.utf8).write(to: base.appendingPathComponent("Projects/recent.json"))
    #expect(store.recent().first?.zotero == nil)
    #expect(store.recent().first?.path == reopened.path)
}

// MARK: - references-prose.bib

@Test func proseBibliographyAppendsAndRemovesEntriesByteForByte() {
    let file = """
    % Written by Prose
    @article{a,
      title = {A {Nested} title},
      note = {mail me@x.org},
    }

    @comment{not an entry}
    @string{jhm = "Journal"}
    @book(b,
      title = "Paren (form)",
    )
    @misc{ c ,title={C}}

    """
    #expect(ProseBibliography.keys(in: file) == ["a", "b", "c"])
    // Removing one keeps every other byte.
    let withoutB = ProseBibliography.removing(["b"], from: file)
    #expect(withoutB == file.replacingOccurrences(of: "@book(b,\n  title = \"Paren (form)\",\n)\n", with: ""))
    let withoutAC = ProseBibliography.removing(["a", "c"], from: file)
    #expect(withoutAC == """
    % Written by Prose
    @comment{not an entry}
    @string{jhm = "Journal"}
    @book(b,
      title = "Paren (form)",
    )

    """)
    #expect(ProseBibliography.removing(["zzz"], from: file) == nil)
    #expect(ProseBibliography.removing(["a", "b", "c"], from: "@a{a,}\n@b{b,}\n@c{c,}\n")?.isEmpty == true)

    // Appending keeps the text and adds a blank line before the entry.
    #expect(ProseBibliography.appending("\n@a{x,}\n\n", to: "") == "@a{x,}\n")
    #expect(ProseBibliography.appending("@a{y,}", to: "@a{x,}") == "@a{x,}\n\n@a{y,}\n")
    #expect(ProseBibliography.appending("@a{y,}", to: "@a{x,}\n") == "@a{x,}\n\n@a{y,}\n")
    #expect(ProseBibliography.appending("@a{y,}", to: "@a{x,}\n\n") == "@a{x,}\n\n@a{y,}\n")
    #expect(ProseBibliography.appending("  ", to: "keep") == "keep")
    // An unclosed entry ends the scan.
    #expect(ProseBibliography.keys(in: "@a{x,}\n@b{y, title = {open\n") == ["x"])
}

@Test func theBibliographyCallGainsTheProseFileAndKeepsItsArguments() {
    let name = ProseBibliography.fileName
    func apply(_ source: String) -> String? {
        guard case let .replace(range, text) = BibliographyCall.adding(name, to: source) else {
            return nil
        }
        return (source as NSString).replacingCharacters(in: range, with: text)
    }
    #expect(apply("#bibliography(\"refs.bib\")\n") == "#bibliography((\"refs.bib\", \"references-prose.bib\"))\n")
    #expect(apply("#bibliography( \"refs.bib\" , style: \"apa\", title: [Works])")
        == "#bibliography( (\"refs.bib\", \"references-prose.bib\") , style: \"apa\", title: [Works])")
    #expect(apply("#bibliography((\"a.bib\", \"b.yml\"), style: \"apa\")")
        == "#bibliography((\"a.bib\", \"b.yml\", \"references-prose.bib\"), style: \"apa\")")
    #expect(apply("#bibliography((\n  \"a.bib\",\n))") == "#bibliography((\n  \"a.bib\", \"references-prose.bib\",\n))")
    #expect(apply("#bibliography(())") == "#bibliography((\"references-prose.bib\",))")
    // Escapes in a path survive.
    #expect(apply(#"#bibliography("a \"b\".bib")"#) == #"#bibliography(("a \"b\".bib", "references-prose.bib"))"#)
    // Skipped: a set rule with only named arguments, a comment, another
    // function whose name ends the same way.
    #expect(apply("#set bibliography(style: \"apa\")\n#bibliography(\"r.bib\")")
        == "#set bibliography(style: \"apa\")\n#bibliography((\"r.bib\", \"references-prose.bib\"))")
    #expect(apply("// #bibliography(\"old.bib\")\n#my-bibliography(\"x\")\n#bibliography(\"r.bib\")")
        ==
        "// #bibliography(\"old.bib\")\n#my-bibliography(\"x\")\n#bibliography((\"r.bib\", \"references-prose.bib\"))")
    #expect(BibliographyCall.adding(name, to: "#bibliography((\"refs.bib\", \"references-prose.bib\"))")
        == .alreadyNamed)
    #expect(BibliographyCall.adding(name, to: "#bibliography(\"references-prose.bib\")") == .alreadyNamed)
    #expect(BibliographyCall.adding(name, to: "= No call\n") == .noCall)
    #expect(BibliographyCall.adding(name, to: "#set bibliography(style: \"apa\")") == .noCall)
    #expect(BibliographyCall.adding(name, to: "#bibliography(files)") == .unsupported)
    #expect(BibliographyCall.adding(name, to: "#bibliography((\"a.bib\", files))") == .unsupported)
    #expect(BibliographyCall.adding(name, to: "#bibliography(\"open") == .unsupported)
    #expect(BibliographyCall.quoted("a\\b\"c") == #""a\\b\"c""#)
}
