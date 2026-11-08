import Foundation

/// The official index uses the same template fields as a package's typst.toml.
public struct UniverseTemplateMetadata: Codable, Equatable, Sendable {
    public let path: String
    public let entrypoint: String
    public let thumbnail: String?

    public init(path: String, entrypoint: String, thumbnail: String? = nil) {
        self.path = path
        self.entrypoint = entrypoint
        self.thumbnail = thumbnail
    }

    public var isValid: Bool {
        Self.isRelativePath(path, allowDot: true) && Self.isRelativePath(entrypoint)
            && (entrypoint as NSString).pathExtension.lowercased() == "typ"
    }

    static func isRelativePath(_ path: String, allowDot: Bool = false) -> Bool {
        if allowDot, path == "." {
            return true
        }
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum UniverseDiscoveryMode: String, CaseIterable, Sendable {
    case templates
    case packages
}

/// Intent-oriented groups deliberately combine several of Universe's technical categories.
public struct UniverseDiscoveryGroup: Identifiable, Sendable {
    public let id: String
    public let titleKey: String
    public let symbolName: String
    public var title: String {
        L10n.text(titleKey)
    }

    let categories: Set<String>
    let terms: [String]

    public static func groups(for mode: UniverseDiscoveryMode) -> [Self] {
        mode == .templates ? templateGroups : packageGroups
    }

    private static let templateGroups: [Self] = [
        .init(id: "", titleKey: "All templates", symbolName: "grid-four", categories: [], terms: []),
        .init(
            id: "research",
            titleKey: "Research & study",
            symbolName: "book-open-text",
            categories: ["paper", "thesis"],
            terms: ["academic", "research", "dissertation", "论文", "学术"],
        ),
        .init(
            id: "work",
            titleKey: "Work & reports",
            symbolName: "file-text",
            categories: ["report", "office"],
            terms: ["report", "letter", "invoice", "memo", "报告", "信函"],
        ),
        .init(
            id: "career",
            titleKey: "CVs & applications",
            symbolName: "notebook",
            categories: ["cv"],
            terms: ["resume", "curriculum vitae", "cover letter", "简历", "求职"],
        ),
        .init(
            id: "present",
            titleKey: "Slides & posters",
            symbolName: "layout",
            categories: ["presentation", "poster", "flyer"],
            terms: ["slides", "presentation", "poster", "海报", "演示"],
        ),
        .init(
            id: "books",
            titleKey: "Books & writing",
            symbolName: "books",
            categories: ["book"],
            terms: ["book", "novel", "notes", "journal", "书籍", "笔记"],
        ),
    ]
    private static let packageGroups: [Self] = [
        .init(id: "", titleKey: "All packages", symbolName: "grid-four", categories: [], terms: []),
        .init(
            id: "draw",
            titleKey: "Diagrams & charts",
            symbolName: "wave-sine",
            categories: ["visualization"],
            terms: ["diagram", "chart", "plot", "drawing", "graph", "绘图", "图表", "流程图"],
        ),
        .init(
            id: "math",
            titleKey: "Math & science",
            symbolName: "sigma",
            categories: [],
            terms: ["math", "equation", "physics", "chemistry", "algebra", "数学", "公式", "科学"],
        ),
        .init(
            id: "code",
            titleKey: "Code & algorithms",
            symbolName: "code",
            categories: [],
            terms: ["code", "algorithm", "pseudocode", "syntax", "代码", "算法"],
        ),
        .init(
            id: "layout",
            titleKey: "Layout & typography",
            symbolName: "layout",
            categories: ["layout", "text", "model", "languages"],
            terms: ["typography", "page", "font", "layout", "排版", "字体"],
        ),
        .init(
            id: "data",
            titleKey: "Tables & data",
            symbolName: "table",
            categories: ["integration"],
            terms: ["table", "csv", "data", "spreadsheet", "表格", "数据"],
        ),
        .init(
            id: "tools",
            titleKey: "Writing tools",
            symbolName: "brackets-curly",
            categories: ["utility", "components", "scripting", "fun"],
            terms: ["bibliography", "citation", "reference", "glossary", "工具", "参考文献"],
        ),
    ]

    func matches(_ package: UniversePackage, text: String) -> Bool {
        !categories.isDisjoint(with: package.categories) || terms.contains { text.contains($0) }
    }
}

/// Constructed once per catalog snapshot, off the UI actor. Searches do no package normalization.
struct UniverseSearchIndex: Sendable {
    private struct Query: Hashable {
        let text: String
        let category: String
        let mode: UniverseDiscoveryMode?
        let group: String
        let compiler: String?
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Query: [UniversePackage]] = [:]
        private var order: [Query] = []
        func get(_ key: Query) -> [UniversePackage]? {
            lock.withLock { values[key] }
        }

        func put(_ value: [UniversePackage], for key: Query) {
            lock.withLock {
                if values[key] == nil {
                    if order.count == 16 {
                        values.removeValue(forKey: order.removeFirst())
                    }
                    order.append(key)
                }
                values[key] = value
            }
        }
    }

    // SwiftUI can ask for the same immutable catalog/filter repeatedly during
    // selection and layout. Reuse those results, bounded to 16 queries per index.
    private let results = Results()
    private struct Entry: Sendable {
        let package: UniversePackage
        let name: String
        let text: String
        let keywords: String
        let groups: Set<String>
    }

    private let entries: [Entry]
    private static let featured = [
        "charged-ieee",
        "basic-resume",
        "ilm",
        "modern-acad-cv",
        "unequivocal-ams",
        "cetz",
        "fletcher",
        "lilaq",
        "codly",
        "tablex",
        "glossarium",
        "physica",
    ]
    /// Both languages are indexed together, so changing app language never invalidates search.
    private static let concepts: [[String]] = [
        ["diagram", "diagrams", "flowchart", "flowcharts", "流程图", "框图"],
        ["draw", "drawing", "canvas", "绘图", "画图"],
        ["chart", "charts", "plot", "plots", "图表", "绘制图表"],
        ["math", "mathematics", "equation", "equations", "数学", "公式"],
        ["code", "syntax", "代码", "代码块"],
        ["algorithm", "algorithms", "pseudocode", "算法", "伪代码"],
        ["resume", "cv", "curriculum vitae", "简历", "求职"],
        ["paper", "academic", "research", "论文", "学术"],
        ["thesis", "dissertation", "学位论文", "毕业论文"],
        ["slides", "presentation", "presentations", "演示", "幻灯片"],
        ["report", "reports", "报告"], ["poster", "posters", "海报"],
        ["book", "books", "书籍"], ["table", "tables", "csv", "表格"],
        ["typography", "layout", "排版"], ["font", "fonts", "字体"],
        ["bibliography", "citation", "references", "参考文献", "引用"],
        ["chemistry", "化学"], ["physics", "物理"], ["chinese", "cjk", "中文"],
    ]

    init(packages: [UniversePackage]) {
        let translated = Dictionary(uniqueKeysWithValues: UniverseCategory.all.map { ($0.id, $0.searchTerms) })
        entries = packages.map { package in
            let keywords = Self
                .normalize((package.keywords + package.categories + package.disciplines).joined(separator: " "))
            let text = Self
                .normalize(([package.name, package.description, keywords] + package.authors + package.categories
                        .compactMap { translated[$0] }).joined(separator: " "))
            let mode: UniverseDiscoveryMode = package.isTemplate ? .templates : .packages
            let groups = Set(UniverseDiscoveryGroup.groups(for: mode).filter { !$0.id.isEmpty && $0.matches(
                package,
                text: text,
            ) }.map(\.id))
            return Entry(
                package: package,
                name: Self.normalize(package.name),
                text: text,
                keywords: keywords,
                groups: groups,
            )
        }
    }

    func search(
        _ query: String,
        category: String = "",
        mode: UniverseDiscoveryMode? = nil,
        group: String = "",
        compilerVersion: String? = nil,
    ) -> [UniversePackage] {
        let query = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = Query(text: query, category: category, mode: mode, group: group, compiler: compilerVersion)
        if let cached = results.get(key) {
            return cached
        }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let expanded = words.map { word in Self.concepts.first { $0.contains(word) } ?? [word] }
        let found = entries.compactMap { entry -> (Entry, Int)? in
            if let mode, (mode == .templates) != entry.package.isTemplate {
                return nil
            }
            if !category.isEmpty, !entry.package.categories.contains(category) {
                return nil
            }
            if !group.isEmpty, !entry.groups.contains(group) {
                return nil
            }
            if let compilerVersion, !entry.package.isCompatible(with: compilerVersion) {
                return nil
            }
            guard expanded.allSatisfy({ terms in terms.contains { entry.text.contains($0) } }) else {
                return nil
            }
            var score = 0
            if !query.isEmpty {
                if entry.name == query {
                    score += 1000
                } else if entry.name.hasPrefix(query) {
                    score += 300
                } else if entry.name.contains(query) {
                    score += 100
                }
                score += words.filter { entry.text.contains($0) }.count * 30
                score += words.filter { entry.keywords.contains($0) }.count * 10
            } else if mode != nil,
                      let featured = Self.featured
                      .firstIndex(of: entry.name)
            {
                score += Self.featured.count - featured
            }
            return (entry, score)
        }.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.name < rhs.0.name : lhs.1 > rhs.1 }.map(\.0.package)
        results.put(found, for: key)
        return found
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
