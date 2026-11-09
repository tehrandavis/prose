import Foundation

/// Errors from operations on a project folder opened in place.
public enum ProjectError: LocalizedError, Equatable {
    case outsideProject
    case invalidName
    case exists
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .outsideProject: L10n.text("That file is outside the open folder.")
        case .invalidName: L10n.text("Use a name without slashes that does not start with a dot.")
        case .exists: L10n.text("An item with that name already exists. Choose a different name.")
        case .unavailable: L10n.text("The folder is no longer available. It may have been moved, renamed or deleted.")
        }
    }
}

/// One file or folder in a project tree.
public struct ProjectNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var id: String {
        url.path
    }

    public var name: String {
        url.lastPathComponent
    }

    public var isTypst: Bool {
        !isDirectory && url.pathExtension.lowercased() == "typ"
    }

    public init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }
}

/// Listing and file operations for a folder edited in place. Hidden files and
/// symbolic links are never listed, and no operation reaches outside the root.
public enum ProjectTree {
    /// A folder with more entries than this shows a count until it is opened.
    public static let largeFolderLimit = 2000

    public static func children(of directory: URL) throws -> [ProjectNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
            )
        } catch {
            throw ProjectError.unavailable
        }
        var nodes: [ProjectNode] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                nodes.append(ProjectNode(url: url, isDirectory: true))
            } else if values.isRegularFile == true {
                nodes.append(ProjectNode(url: url, isDirectory: false))
            }
        }
        // Folders first, then files, each in Finder's order.
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// `main.typ` at the root, else the only Typst file in the project, else the
    /// first Typst file at the root.
    public static func defaultMainEntry(in root: URL) -> URL? {
        let main = root.appendingPathComponent("main.typ")
        if FileManager.default.fileExists(atPath: main.path) {
            return main.standardizedFileURL
        }
        if let sources = try? ProjectSources.list(in: root), sources.count == 1 {
            return sources[0].standardizedFileURL
        }
        return (try? children(of: root))?.first(where: \.isTypst)?.url
    }

    /// Files whose names contain the query, case- and width-insensitively.
    public static func search(_ query: String, in root: URL, limit: Int = 200) -> [ProjectNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else {
            return []
        }
        var matches: [ProjectNode] = []
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            // The enumerator does not follow links. skipDescendants() here would
            // skip the rest of the link's parent folder instead.
            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true,
               file.lastPathComponent.range(of: query, options: [.caseInsensitive, .widthInsensitive]) != nil
            {
                matches.append(ProjectNode(url: file, isDirectory: false))
                if matches.count == limit {
                    break
                }
            }
        }
        return matches.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Every BibLaTeX (`.bib`) and Hayagriva (`.yml`, `.yaml`) file in the
    /// project, relative to the root, in Finder's order. Hidden files and
    /// symbolic links are skipped. The bibliography index's list when no
    /// `#bibliography` call names a file.
    public static func bibliographyFiles(in root: URL) -> [String] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else {
            return []
        }
        var found: [String] = []
        for case let file as URL in files {
            guard ["bib", "yml", "yaml"].contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let path = try? relativePath(of: file, in: base)
            else {
                continue
            }
            found.append(path)
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func relativePath(of url: URL, in root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else {
            throw ProjectError.outsideProject
        }
        return String(path.dropFirst(base.count + 1))
    }

    /// "Untitled.typ", then "Untitled 2.typ" and so on: the first unused name.
    public static func availableName(_ base: String, extension ext: String?, in directory: URL) -> String {
        func name(_ index: Int) -> String {
            let stem = index == 1 ? base : "\(base) \(index)"
            return ext.map { stem + "." + $0 } ?? stem
        }
        var index = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name(index)).path) {
            index += 1
        }
        return name(index)
    }

    /// A new Typst file. A name without an extension gets `.typ`.
    @discardableResult
    public static func createFile(named name: String, in directory: URL, root: URL) throws -> URL {
        var name = try validated(name)
        if (name as NSString).pathExtension.isEmpty {
            name += ".typ"
        }
        let url = try destination(name, in: directory, root: root)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw ProjectError.unavailable
        }
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in directory: URL, root: URL) throws -> URL {
        let url = try destination(validated(name), in: directory, root: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public static func rename(_ url: URL, to name: String, root: URL) throws -> URL {
        _ = try relativePath(of: url, in: root)
        let target = try destination(validated(name), in: url.deletingLastPathComponent(), root: root)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Moves the item to the Trash. Prose never deletes project files outright.
    public static func trash(_ url: URL, root: URL) throws {
        _ = try relativePath(of: url, in: root)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func validated(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), name.count <= 255 else {
            throw ProjectError.invalidName
        }
        return name
    }

    private static func destination(_ name: String, in directory: URL, root: URL) throws -> URL {
        let directory = directory.standardizedFileURL
        if directory.resolvingSymlinksInPath().path != root.standardizedFileURL.resolvingSymlinksInPath().path {
            _ = try relativePath(of: directory, in: root)
        }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.exists
        }
        return url
    }
}

/// What Prose remembers about a folder opened in place. Nothing is written into
/// the folder itself.
public struct ProjectRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmark: Data
    /// The main entry, relative to the folder.
    public var mainEntry: String?
    /// Expanded folders, relative to the folder. The root is always expanded.
    public var expanded: [String]
    public var lastOpened: Date

    public var name: String {
        (path as NSString).lastPathComponent
    }
}

/// Recent folders, stored in `Application Support/Prose/Projects/recent.json`.
public struct ProjectStore: Sendable {
    public static let recentLimit = 20
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("recent.json")
    }

    public func recent() -> [ProjectRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([ProjectRecord].self, from: data)
        else {
            return []
        }
        return records.sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Records a folder as opened now, keeping its main entry and folds if known.
    @discardableResult
    public func remember(_ folder: URL, now: Date = Date()) throws -> ProjectRecord {
        let folder = folder.standardizedFileURL
        var records = recent()
        var record = records.first { $0.path == folder.path } ?? ProjectRecord(
            id: UUID(),
            path: folder.path,
            bookmark: Data(),
            mainEntry: ProjectTree.defaultMainEntry(in: folder).flatMap { try? ProjectTree.relativePath(
                of: $0,
                in: folder,
            ) },
            expanded: [],
            lastOpened: now,
        )
        record.bookmark = try Self.bookmark(for: folder)
        record.lastOpened = now
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        try write(Array(records.prefix(Self.recentLimit)))
        return record
    }

    public func update(_ record: ProjectRecord) throws {
        var records = recent()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            return
        }
        records[index] = record
        try write(records)
    }

    public func forget(_ id: UUID) throws {
        try write(recent().filter { $0.id != id })
    }

    /// Resolves a remembered folder. A folder that moved is found through its
    /// bookmark and its path is updated; a missing folder throws `unavailable`.
    public func resolve(_ record: ProjectRecord) throws -> URL {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: Self.resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ), FileManager.default.fileExists(atPath: url.path) {
            if stale || url.standardizedFileURL.path != record.path {
                var moved = record
                moved.path = url.standardizedFileURL.path
                moved.bookmark = (try? Self.bookmark(for: url)) ?? record.bookmark
                try? update(moved)
            }
            return url.standardizedFileURL
        }
        throw ProjectError.unavailable
    }

    private func write(_ records: [ProjectRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    /// The App Store edition runs in the sandbox, where only a security-scoped
    /// bookmark can reopen a folder after relaunch.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static var resolveOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: isSandboxed ? [.withSecurityScope] : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }
}

/// The compile status dot in the title row.
public enum CompileStatus: String, Sendable {
    /// The last compile succeeded and matches the buffer.
    case succeeded
    /// Compiling, or the buffer changed since the last compile.
    case compiling
    /// The last compile failed; any preview is stale.
    case failed
    /// The typesetting service is not running.
    case offline

    public static func resolve(
        serviceReady: Bool,
        serviceStatus: String,
        errors: Int,
        previewStale: Bool,
        hasSuccessfulPreview: Bool,
    ) -> CompileStatus {
        guard serviceReady else {
            return .offline
        }
        if errors > 0 || serviceStatus == "Document Needs Attention"
            || serviceStatus == "Showing Last Preview · Check Source"
        {
            return .failed
        }
        if previewStale || serviceStatus == "Typesetting" || !hasSuccessfulPreview {
            return .compiling
        }
        return .succeeded
    }

    /// Words for VoiceOver and the help tag; the same words the checks use.
    public var label: String {
        switch self {
        case .succeeded: L10n.text("Up to date")
        case .compiling: L10n.text("Checking…")
        case .failed: L10n.text("Document Needs Attention")
        case .offline: L10n.text("Disconnected")
        }
    }
}
