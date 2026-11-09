import Foundation

/// One entry of a bibliography file, as the engine parsed it with Hayagriva
/// (`BlockRenderer.bibliography(_:)`). Its key is one Typst accepts.
public struct BibliographyEntry: Equatable, Sendable, Decodable {
    public struct Author: Equatable, Sendable, Decodable {
        /// The family name with its prefix: "van Gogh".
        public let family: String
        /// The given names, with any suffix after a comma: "John, Jr.".
        public let given: String?

        public init(family: String, given: String? = nil) {
            self.family = family
            self.given = given
        }

        /// The family name and initials: "Smith, J.", "Dubois, J.-P.".
        public var display: String {
            guard let given, !given.isEmpty else {
                return family
            }
            let names = given.split(separator: ",", maxSplits: 1)[0]
            let initials = names.split(separator: " ").map { name in
                name.split(separator: "-").compactMap { $0.first.map { "\($0)." } }.joined(separator: "-")
            }
            return "\(family), \(initials.joined(separator: " "))"
        }
    }

    public let key: String
    /// Hayagriva's entry type in kebab case: `article`, `book`, `thesis`. A
    /// BibLaTeX type maps to Hayagriva's (`inproceedings` is `article`).
    public let kind: String
    public let title: String?
    /// The authors; the editors when the entry has no authors.
    public let authors: [Author]
    public let year: Int?
    /// The journal, book or proceedings the entry appears in.
    public let container: String?
    public let doi: String?
    public let url: String?
    /// The file, relative to the project root.
    public let file: String
    /// The line the entry starts on, from 1; 0 when unknown.
    public let line: Int

    private enum CodingKeys: String, CodingKey {
        case key
        case kind = "type"
        case title
        case authors
        case year
        case container
        case doi
        case url
        case file
        case line
    }

    public init(
        key: String,
        kind: String = "misc",
        title: String? = nil,
        authors: [Author] = [],
        year: Int? = nil,
        container: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        file: String = "refs.bib",
        line: Int = 0,
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.authors = authors
        self.year = year
        self.container = container
        self.doi = doi
        self.url = url
        self.file = file
        self.line = line
    }
}

/// A problem in a bibliography file: a syntax error, a field Hayagriva cannot
/// read, a key defined twice, a missing file.
public struct BibliographyIssue: Equatable, Sendable, Decodable {
    public let file: String
    /// From 1; 0 when the problem has no place, such as a missing file.
    public let line: Int
    public let message: String
}

/// What became of one bibliography file.
public struct BibliographyFile: Equatable, Sendable, Decodable {
    /// Relative to the project root.
    public let path: String
    /// Entries listed from this file.
    public let entries: Int
    /// Whether Typst would load the file as it is. A file with a syntax error
    /// lists no entries; a file with a field Hayagriva cannot read lists its
    /// other entries but is not accepted, as Typst rejects the whole file.
    public let accepted: Bool
    /// Whether a `#bibliography` call in the document names the file. When no
    /// call names any file, the index lists every bibliography file in the
    /// project, not linked.
    public internal(set) var linked = true

    private enum CodingKeys: String, CodingKey {
        case path
        case entries
        case accepted
    }
}

/// The entries of a set of bibliography files, in file order and then in the
/// order of each file. A key already listed from an earlier file is left out
/// and reported.
public struct BibliographyContents: Equatable, Sendable, Decodable {
    public var entries: [BibliographyEntry]
    public var errors: [BibliographyIssue]
    public var files: [BibliographyFile]

    public static let empty = Self(entries: [], errors: [], files: [])

    public init(entries: [BibliographyEntry], errors: [BibliographyIssue] = [], files: [BibliographyFile] = []) {
        self.entries = entries
        self.errors = errors
        self.files = files
    }
}

/// The citation picker's index of the project's bibliography entries.
///
/// Which files: the ones the document's `#bibliography(...)` calls name
/// (`BlockRenderer.bibliographyFiles()`). When there are none, every `.bib`,
/// `.yml` and `.yaml` file in the project (`ProjectTree.bibliographyFiles`),
/// marked as not linked. The engine caches each file's parse by its version,
/// so `reload` after an edit or a change on disk parses only what changed.
@MainActor
public final class BibliographyIndex {
    public private(set) var contents = BibliographyContents.empty
    /// Changes when, and only when, the contents change.
    public private(set) var revision = 0
    private var table = SearchTable([])

    public init() {}

    public var entries: [BibliographyEntry] {
        contents.entries
    }

    /// Whether the files come from the document's `#bibliography` calls.
    /// False when the project has no call and the index lists every
    /// bibliography file it holds, or has none.
    public var isLinked: Bool {
        contents.files.contains(where: \.linked)
    }

    /// Replaces the contents; the revision moves only if they changed.
    public func update(_ contents: BibliographyContents) {
        update(contents, table: nil)
    }

    private func update(_ contents: BibliographyContents, table: SearchTable?) {
        guard contents != self.contents else {
            return
        }
        self.contents = contents
        self.table = table ?? SearchTable(contents.entries)
        revision += 1
    }

    /// Reads the project's bibliography files through the engine and prepares
    /// the search off the main thread, then updates the index.
    public func reload(using renderer: BlockRenderer, root: URL) async {
        let contents = await Self.load(using: renderer, root: root)
        guard contents != self.contents else {
            return
        }
        let table = await Task.detached(priority: .userInitiated) {
            SearchTable(contents.entries)
        }.value
        update(contents, table: table)
    }

    /// The linked files' entries, or every bibliography file's in the project,
    /// marked as not linked, when the document names none.
    public nonisolated static func load(using renderer: BlockRenderer, root: URL) async -> BibliographyContents {
        let linked = await renderer.bibliographyFiles()
        if !linked.isEmpty {
            return await renderer.bibliography(linked)
        }
        let found = await Task.detached(priority: .utility) {
            ProjectTree.bibliographyFiles(in: root)
        }.value
        guard !found.isEmpty else {
            return .empty
        }
        var contents = await renderer.bibliography(found)
        for index in contents.files.indices {
            contents.files[index].linked = false
        }
        return contents
    }

    /// Entries matching every word of the query in the key, an author's family
    /// name, the year, the title, the container or the DOI, ignoring case,
    /// diacritics and width. Ranked by the weakest word's match: key prefix,
    /// then author or year prefix, then title word prefix, then anywhere; ties
    /// keep file order. An empty query lists every entry.
    public func search(_ query: String, limit: Int? = nil) -> [BibliographyEntry] {
        let words = SearchTable.fold(query).split(whereSeparator: \.isWhitespace)
            .map { $0.utf8.filter { $0 > 1 } }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return Array(contents.entries.prefix(limit ?? .max))
        }
        return table.search(words).prefix(limit ?? .max).map { contents.entries[$0] }
    }
}

/// The entries' folded text as UTF-8 in one buffer, so a query word costs
/// one `memmem` pass over all entries and a closer look only at the entries it
/// hits. Each entry starts with 0, then holds its key, its authors' family
/// names and year, its title, then its container and DOI, every word after a
/// 1 (`wordStart`). A word prefix is then a search for 1 and the query word,
/// and no match runs from one entry into the next.
private struct SearchTable: Sendable {
    private static let entryStart: UInt8 = 0
    private static let wordStart: UInt8 = 1

    /// Where an entry's parts start in `bytes`; each part ends where the next
    /// starts.
    private struct Parts {
        var key: Int
        var authors: Int
        var title: Int
        var rest: Int
        var end: Int
    }

    private var bytes: [UInt8] = []
    private var parts: [Parts] = []

    init(_ entries: [BibliographyEntry]) {
        bytes.reserveCapacity(entries.count * 200)
        parts.reserveCapacity(entries.count)
        for entry in entries {
            // One fold per entry: the fields joined by a separator folding keeps.
            let fields = [entry.key, entry.title ?? "", entry.container ?? "", entry.doi ?? ""]
                + entry.authors.map(\.family) + [entry.year.map(String.init) ?? ""]
            let folded = Array(Self.fold(fields.joined(separator: "\u{1F}")).utf8)
                .split(separator: 0x1F, omittingEmptySubsequences: false)
            bytes.append(Self.entryStart)
            let key = bytes.count
            appendWhole(folded[0])
            let authors = bytes.count
            folded[4...].forEach { appendWords($0) }
            let title = bytes.count
            appendWords(folded[1])
            let rest = bytes.count
            appendWords(folded[2])
            appendWords(folded[3])
            parts.append(Parts(key: key, authors: authors, title: title, rest: rest, end: bytes.count))
        }
    }

    private mutating func appendWhole(_ text: ArraySlice<UInt8>) {
        bytes.append(Self.wordStart)
        bytes.append(contentsOf: text.lazy.filter { $0 > Self.wordStart })
    }

    /// Each word of a field after a `wordStart`, then the whole field if it
    /// has more than one word. A word is a run of ASCII letters and digits and
    /// any bytes outside ASCII; the rest of ASCII separates words.
    private mutating func appendWords(_ text: ArraySlice<UInt8>) {
        var count = 0
        var inWord = false
        for byte in text {
            let isWord = byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x41 && byte <= 0x5A)
            if isWord {
                if !inWord {
                    bytes.append(Self.wordStart)
                    count += 1
                }
                bytes.append(byte)
            }
            inWord = isWord
        }
        if count > 1 {
            appendWhole(text)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Indices of the entries matching every word, best first: by the weakest
    /// word's tier (0 key prefix, 1 author or year prefix, 2 title word prefix,
    /// 3 anywhere), then the sum of the tiers, then file order.
    func search(_ words: [[UInt8]]) -> [Int] {
        bytes.withUnsafeBytes { buffer -> [Int] in
            guard let base = buffer.baseAddress else {
                return []
            }
            // Candidates and their scores, narrowed by each word in turn.
            var found: [(entry: Int, worst: Int, sum: Int)] = []
            for (index, word) in words.enumerated() {
                let prefix = [Self.wordStart] + word
                func tier(_ entry: Int) -> Int {
                    let part = parts[entry]
                    let span = { (from: Int, to: Int) in
                        Self.find(prefix, in: base + from, count: to - from) != nil
                    }
                    if part.authors - part.key >= prefix.count,
                       memcmp(base + part.key, prefix, prefix.count) == 0
                    {
                        return 0
                    }
                    if span(part.authors, part.title) {
                        return 1
                    }
                    return span(part.title, part.rest) ? 2 : 3
                }
                if index == 0 {
                    var offset = 0
                    while offset < buffer.count,
                          let hit = Self.find(word, in: base + offset, count: buffer.count - offset)
                    {
                        let entry = entry(at: base.distance(to: hit))
                        let rank = tier(entry)
                        found.append((entry, rank, rank))
                        offset = parts[entry].end
                    }
                } else {
                    found = found.compactMap { candidate in
                        let part = parts[candidate.entry]
                        guard Self.find(word, in: base + part.key, count: part.end - part.key) != nil else {
                            return nil
                        }
                        let rank = tier(candidate.entry)
                        return (candidate.entry, max(candidate.worst, rank), candidate.sum + rank)
                    }
                }
                if found.isEmpty {
                    return []
                }
            }
            var order = found.map { $0.worst << 48 | $0.sum << 24 | $0.entry }
            order.sort()
            return order.map { $0 & 0xFFFFFF }
        }
    }

    /// The entry holding a byte offset: the last whose key starts at or
    /// before it.
    private func entry(at offset: Int) -> Int {
        var low = 0
        var high = parts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if parts[middle].key <= offset {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    private static func find(_ needle: [UInt8], in haystack: UnsafeRawPointer, count: Int) -> UnsafeRawPointer? {
        needle.withUnsafeBytes { needle in
            memmem(haystack, count, needle.baseAddress, needle.count).map { UnsafeRawPointer($0) }
        }
    }
}
