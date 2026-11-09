import Foundation

/// One item from Zotero, as Better BibTeX's `item.search` returns it
/// (CSL-JSON). The citation key is the one Better BibTeX's auto-export writes.
public struct ZoteroItem: Equatable, Sendable {
    public let key: String
    /// Zotero's own item key, the last part of the item's URI (`NSPZRSQM`).
    public let itemKey: String
    /// The item's URI: `http://zotero.org/users/2104204/items/NSPZRSQM`.
    public let uri: String
    public let title: String?
    public let authors: [BibliographyEntry.Author]
    public let year: Int?
    public let container: String?
    public let doi: String?
    /// The CSL type: `article-journal`, `book`, `chapter`.
    public let kind: String

    public init(
        key: String,
        itemKey: String,
        uri: String = "",
        title: String? = nil,
        authors: [BibliographyEntry.Author] = [],
        year: Int? = nil,
        container: String? = nil,
        doi: String? = nil,
        kind: String = "document",
    ) {
        self.key = key
        self.itemKey = itemKey
        self.uri = uri.isEmpty ? "http://zotero.org/users/0/items/\(itemKey)" : uri
        self.title = title
        self.authors = authors
        self.year = year
        self.container = container
        self.doi = doi
        self.kind = kind
    }

    /// Reads one CSL-JSON item; nil when it has no citation key.
    init?(csl: [String: Any]) {
        guard let key = (csl["citekey"] as? String) ?? (csl["citation-key"] as? String), !key.isEmpty else {
            return nil
        }
        let uri = (csl["id"] as? String) ?? ""
        let names = (csl["author"] as? [[String: Any]]) ?? (csl["editor"] as? [[String: Any]]) ?? []
        self.init(
            key: key,
            itemKey: uri.split(separator: "/").last.map(String.init) ?? "",
            uri: uri,
            title: csl["title"] as? String,
            authors: names.compactMap { name in
                guard let family = (name["family"] as? String) ?? (name["literal"] as? String) else {
                    return nil
                }
                return BibliographyEntry.Author(family: family, given: name["given"] as? String)
            },
            year: Self.year(csl["issued"]),
            container: csl["container-title"] as? String,
            doi: csl["DOI"] as? String,
            kind: (csl["type"] as? String) ?? "document",
        )
    }

    /// The year of a CSL date: its first `date-parts` number, else the first
    /// four digits of its `literal` or `raw` text.
    private static func year(_ value: Any?) -> Int? {
        guard let date = value as? [String: Any] else {
            return nil
        }
        if let parts = date["date-parts"] as? [[Any]], let first = parts.first?.first {
            if let year = first as? Int {
                return year
            }
            if let text = first as? String, let year = Int(text) {
                return year
            }
        }
        let text = (date["literal"] as? String) ?? (date["raw"] as? String) ?? ""
        guard let range = text.range(of: #"\d{4}"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range])
    }

    /// The first author's family name, with "et al." when there are more.
    public var leadAuthor: String {
        guard let first = authors.first else {
            return ""
        }
        return authors.count > 1 ? "\(first.family) \(L10n.text("et al."))" : first.family
    }

    /// `zotero://select/library/items/<key>`, or the group library's form
    /// for an item of a group: Zotero selects the item in its window.
    public var selectURL: URL? {
        let parts = uri.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "groups"), parts.count > index + 1 {
            return URL(string: "zotero://select/groups/\(parts[index + 1])/items/\(itemKey)")
        }
        return URL(string: "zotero://select/library/items/\(itemKey)")
    }
}

/// A Zotero collection, with its parent's key when it is nested.
public struct ZoteroCollection: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let parent: String?

    public var id: String {
        key
    }

    public init(key: String, name: String, parent: String? = nil) {
        self.key = key
        self.name = name
        self.parent = parent
    }

    /// Each collection's name after its parents' names (`Thesis / Chapter 2`),
    /// sorted by that path.
    public static func paths(_ collections: [Self]) -> [(collection: Self, path: String)] {
        let byKey = Dictionary(collections.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func path(_ collection: Self, depth: Int) -> String {
            guard depth < 32, let parent = collection.parent.flatMap({ byKey[$0] }) else {
                return collection.name
            }
            return path(parent, depth: depth + 1) + " / " + collection.name
        }
        return collections.map { ($0, path($0, depth: 0)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// The versions `api.ready` reports.
public struct ZoteroStatus: Equatable, Sendable {
    public let zotero: String
    public let betterBibTeX: String

    public init(zotero: String, betterBibTeX: String) {
        self.zotero = zotero
        self.betterBibTeX = betterBibTeX
    }
}

public enum ZoteroError: LocalizedError, Equatable {
    /// Nothing answers on Zotero's port.
    case notRunning
    /// Zotero answers but Better BibTeX's JSON-RPC does not.
    case betterBibTeXMissing
    /// The server answered with an error or something Prose cannot read.
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: L10n.text("Zotero is not running.")
        case .betterBibTeXMissing: L10n.text("Zotero is running, but the Better BibTeX plugin is not installed.")
        case let .server(message): L10n.format("Zotero answered with an error: %@", message)
        }
    }
}

/// What Prose asks of Zotero (citations note, step D outcome). The app talks
/// to `HTTPZoteroSource`; tests script their own.
public protocol ZoteroSource: Sendable {
    /// Whether Zotero and Better BibTeX answer. Throws `ZoteroError`.
    func ready() async throws -> ZoteroStatus
    /// Better BibTeX's `item.search`: the items whose fields hold `text` as
    /// one phrase.
    func search(_ text: String) async throws -> [ZoteroItem]
    /// The BibLaTeX entries of the citation keys, as Better BibTeX's
    /// auto-export writes them.
    func export(_ keys: [String]) async throws -> String
    /// Every collection in the library (Zotero's local API).
    func collections() async throws -> [ZoteroCollection]
    /// The item keys of the top-level items in `collection` that match
    /// `query` (Zotero's local API).
    func collectionItems(_ collection: String, query: String) async throws -> Set<String>
    /// The collections each citation key's item is in.
    func itemCollections(_ keys: [String]) async throws -> [String: [ZoteroCollection]]
}

/// Zotero on this Mac: Better BibTeX's JSON-RPC and Zotero's read-only local
/// API, both on `127.0.0.1:23119`. Requests time out after 2 s without data,
/// so a Zotero that is not running is reported at once (the connection is
/// refused) or within 2 s.
public struct HTTPZoteroSource: ZoteroSource {
    public static let defaultBase = URL(string: "http://127.0.0.1:23119")!
    public let base: URL
    private let session: URLSession

    public init(base: URL = Self.defaultBase, configuration: URLSessionConfiguration? = nil) {
        self.base = base
        let configuration = configuration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func ready() async throws -> ZoteroStatus {
        do {
            let result = try await call("api.ready", [])
            let versions = result as? [String: Any] ?? [:]
            return ZoteroStatus(
                zotero: versions["zotero"] as? String ?? "",
                betterBibTeX: versions["betterbibtex"] as? String ?? "",
            )
        } catch ZoteroError.notRunning {
            throw ZoteroError.notRunning
        } catch {
            throw await pingConnector() ? ZoteroError.betterBibTeXMissing : ZoteroError.notRunning
        }
    }

    public func search(_ text: String) async throws -> [ZoteroItem] {
        let result = try await call("item.search", [text])
        guard let items = result as? [[String: Any]] else {
            throw ZoteroError.server(L10n.text("The search result could not be read."))
        }
        return items.compactMap(ZoteroItem.init(csl:))
    }

    public func export(_ keys: [String]) async throws -> String {
        let result = try await call("item.export", [keys, "Better BibLaTeX"])
        // Better BibTeX returns the text; older versions returned
        // `[status, contentType, text]`.
        if let text = result as? String {
            return text
        }
        if let text = (result as? [Any])?.last as? String {
            return text
        }
        throw ZoteroError.server(L10n.text("The exported entry could not be read."))
    }

    public func collections() async throws -> [ZoteroCollection] {
        var collections: [ZoteroCollection] = []
        var start = 0
        while true {
            let page = try await local(
                "/api/users/0/collections",
                ["limit": "100", "start": String(start), "format": "json"],
            )
            let found = page.compactMap { object -> ZoteroCollection? in
                guard let key = object["key"] as? String, let data = object["data"] as? [String: Any],
                      let name = data["name"] as? String
                else {
                    return nil
                }
                return ZoteroCollection(key: key, name: name, parent: data["parentCollection"] as? String)
            }
            collections += found
            guard page.count == 100, start < 5000 else {
                return collections
            }
            start += 100
        }
    }

    public func collectionItems(_ collection: String, query: String) async throws -> Set<String> {
        let page = try await local(
            "/api/users/0/collections/\(collection)/items/top",
            ["q": query, "limit": "100", "format": "json"],
        )
        return Set(page.compactMap { $0["key"] as? String })
    }

    public func itemCollections(_ keys: [String]) async throws -> [String: [ZoteroCollection]] {
        let result = try await call("item.collections", [keys])
        guard let map = result as? [String: Any] else {
            throw ZoteroError.server(L10n.text("The collections could not be read."))
        }
        return map.mapValues { value in
            ((value as? [[String: Any]]) ?? []).compactMap { object in
                guard let key = object["key"] as? String, let name = object["name"] as? String else {
                    return nil
                }
                return ZoteroCollection(key: key, name: name, parent: object["parentCollection"] as? String)
            }
        }
    }

    /// One JSON-RPC call to Better BibTeX; returns its `result`.
    private func call(_ method: String, _ parameters: [Any]) async throws -> Any {
        var request = URLRequest(url: base.appendingPathComponent("better-bibtex/json-rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": method,
            "params": parameters,
            "id": 1,
        ] as [String: Any])
        let data = try await load(request)
        guard let object = try? ZoteroJSON.object(from: data) as? [String: Any] else {
            throw ZoteroError.server(L10n.text("The answer could not be read."))
        }
        if let error = object["error"] as? [String: Any] {
            throw ZoteroError.server(error["message"] as? String ?? "\(error["code"] ?? "")")
        }
        return object["result"] ?? NSNull()
    }

    /// A GET to Zotero's local API that returns an array of objects.
    private func local(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw ZoteroError.server(path)
        }
        let data = try await load(URLRequest(url: url))
        guard let objects = try? ZoteroJSON.object(from: data) as? [[String: Any]] else {
            throw ZoteroError.server(L10n.text("The answer could not be read."))
        }
        return objects
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.connectionErrors.contains(error.code) ? ZoteroError.notRunning : ZoteroError
                .server(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ZoteroError.server("HTTP \(code)")
        }
        return data
    }

    /// Zotero's connector endpoint answers whenever Zotero runs, with or
    /// without Better BibTeX.
    private func pingConnector() async -> Bool {
        await (try? load(URLRequest(url: base.appendingPathComponent("connector/ping")))) != nil
    }

    private static let connectionErrors: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .dnsLookupFailed, .resourceUnavailable,
    ]
}

/// Better BibTeX writes control characters from abstracts raw inside JSON
/// strings, which JSON parsers reject (step D outcome). They are escaped
/// first.
public enum ZoteroJSON {
    /// Escapes U+0000 to U+001F inside JSON strings as `\u00XX`, leaving
    /// everything outside strings, and every other byte, as it is.
    public static func escapingControlCharacters(_ data: Data) -> Data {
        guard data.contains(where: { $0 < 0x20 }) else {
            return data
        }
        var output = Data()
        output.reserveCapacity(data.count + 64)
        var inString = false
        var escaped = false
        let hex = Array("0123456789abcdef".utf8)
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                } else if byte < 0x20 {
                    output.append(contentsOf: Array("\\u00".utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 0xF)]])
                    continue
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            }
            output.append(byte)
        }
        return output
    }

    public static func object(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: escapingControlCharacters(data), options: [.fragmentsAllowed])
    }
}

/// How the Zotero tab searches (step D outcome, change 1): Better BibTeX
/// matches one phrase, so Prose sends the longest word of the query and
/// filters the items by every word itself.
public enum ZoteroSearch {
    /// The query needs this many characters before Zotero is asked.
    public static let minimumLength = 3
    public static let limit = 50
    public static let pause = Duration.milliseconds(250)

    /// One row of the Zotero tab.
    public struct Result: Equatable, Sendable, Identifiable {
        public let item: ZoteroItem
        /// In the project's linked Zotero collection.
        public let inCollection: Bool
        /// Its key is already in a project bibliography file.
        public let inProject: Bool

        public var id: String {
            item.key
        }

        public init(item: ZoteroItem, inCollection: Bool, inProject: Bool) {
            self.item = item
            self.inCollection = inCollection
            self.inProject = inProject
        }
    }

    /// The word to send to Zotero: the query's longest word, when the query
    /// and that word have at least `minimumLength` characters.
    public static func remoteWord(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else {
            return nil
        }
        // The first of the longest words, so the choice is stable.
        var longest = Substring()
        for word in trimmed.split(whereSeparator: \.isWhitespace) where word.count > longest.count {
            longest = word
        }
        return longest.count >= minimumLength ? String(longest) : nil
    }

    /// Whether every word of the query is in an author's family name, the
    /// title, the year or the key, ignoring case, diacritics and width.
    public static func matches(_ item: ZoteroItem, words: [String]) -> Bool {
        let fields = (item.authors.map(\.family) + [item.title ?? "", item.year.map(String.init) ?? "", item.key])
            .map(fold)
        return words.allSatisfy { word in fields.contains { $0.contains(word) } }
    }

    /// The rows for `items`: those matching every word, the linked
    /// collection's first, then in Zotero's order, at most `limit`.
    public static func results(
        _ items: [ZoteroItem],
        query: String,
        collectionItems: Set<String>,
        projectKeys: Set<String>,
        limit: Int = limit,
    ) -> [Result] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        let matching = items.filter { matches($0, words: words) && seen.insert($0.key).inserted }
        let inCollection = matching.filter { collectionItems.contains($0.itemKey) }
        let rest = matching.filter { !collectionItems.contains($0.itemKey) }
        return (inCollection + rest).prefix(limit).map {
            Result(
                item: $0,
                inCollection: collectionItems.contains($0.itemKey),
                inProject: projectKeys.contains($0.key),
            )
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// A project's link to Zotero (step D outcome, change 2): the project's
/// Better BibTeX auto-exported file and the collection behind it. Stored in
/// `recent.json` with the project, never in the project folder.
public struct ZoteroLink: Codable, Equatable, Sendable {
    /// The auto-exported file, relative to the project folder. Prose never
    /// writes into it.
    public var bibliography: String
    public var collection: String
    /// The collection's name after its parents' names, as chosen.
    public var collectionName: String

    public init(bibliography: String, collection: String, collectionName: String) {
        self.bibliography = bibliography
        self.collection = collection
        self.collectionName = collectionName
    }
}
